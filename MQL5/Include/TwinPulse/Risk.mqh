//+------------------------------------------------------------------+
//|                                                   Risk.mqh        |
//|  TwinPulse Hedge EA                                                 |
//|  Brakes, session filters, spread control and margin checks.        |
//+------------------------------------------------------------------+
#pragma once

#include "Config.mqh"
#include "Utils.mqh"
#include "Logger.mqh"
#include "State.mqh"
#include "Execution.mqh"

//+------------------------------------------------------------------+
//| TP_Risk_InitSpreadSamples - warm up the rolling median spread     |
//| from the tick history of the last 10 minutes.                      |
//+------------------------------------------------------------------+
void TP_Risk_InitSpreadSamples(void)
  {
   g_tp.spreadCount = 0;
   g_tp.spreadHead  = 0;

   datetime from = TimeCurrent() - 600;
   MqlTick ticks[];
   int got = CopyTicksRange(g_symbol, PERIOD_M1, from, TimeCurrent(), ticks);
   if(got > 0)
     {
      int step = got / 100;
      if(step < 1) step = 1;
      for(int i = 0; i < got; i += step)
        {
         if(ticks[i].ask <= 0.0 || ticks[i].bid <= 0.0) continue;
         double sp = ticks[i].ask - ticks[i].bid;
         if(sp <= 0.0) continue;
         g_tp.spreadSamples[g_tp.spreadHead] = sp;
         g_tp.spreadHead = (g_tp.spreadHead + 1) % TP_SPREAD_SAMPLES;
         if(g_tp.spreadCount < TP_SPREAD_SAMPLES) g_tp.spreadCount++;
        }
     }

   if(g_tp.spreadCount == 0)
     {
      double s = TP_Exec_CurrentSpreadPrice();
      if(s > 0.0)
        {
         g_tp.spreadSamples[0] = s;
         g_tp.spreadHead = 1;
         g_tp.spreadCount = 1;
        }
     }

   double tmp[];
   ArrayResize(tmp, g_tp.spreadCount);
   for(int i = 0; i < g_tp.spreadCount; i++) tmp[i] = g_tp.spreadSamples[i];
   g_tp.medianSpread = TP_Median(tmp);

   TP_LogInfo(StringFormat("Rolling median spread initialised: %.3f (%d samples)",
                           g_tp.medianSpread, g_tp.spreadCount));
  }

//+------------------------------------------------------------------+
//| TP_Risk_UpdateSpreadSample - add one spread sample and refresh    |
//| the rolling median.                                                |
//+------------------------------------------------------------------+
void TP_Risk_UpdateSpreadSample(void)
  {
   datetime now = TimeCurrent();
   if(g_tp.lastSpreadSample != 0 && (now - g_tp.lastSpreadSample) < SpreadSampleSec)
      return;
   g_tp.lastSpreadSample = now;

   double spread = TP_Exec_CurrentSpreadPrice();
   if(spread <= 0.0) return;

   g_tp.spreadSamples[g_tp.spreadHead] = spread;
   g_tp.spreadHead = (g_tp.spreadHead + 1) % TP_SPREAD_SAMPLES;
   if(g_tp.spreadCount < TP_SPREAD_SAMPLES) g_tp.spreadCount++;

   double tmp[];
   ArrayResize(tmp, g_tp.spreadCount);
   for(int i = 0; i < g_tp.spreadCount; i++) tmp[i] = g_tp.spreadSamples[i];
   g_tp.medianSpread = TP_Median(tmp);
  }

//+------------------------------------------------------------------+
//| TP_Risk_MaxSpreadPrice - effective maximum spread for new orders  |
//+------------------------------------------------------------------+
double TP_Risk_MaxSpreadPrice(void)
  {
   double limit = MaxSpreadPrice;
   if(g_tp.medianSpread > 0.0)
     {
      double mult = SpreadMedianMult * g_tp.medianSpread;
      if(mult < limit) limit = mult;
     }
   return limit;
  }

//+------------------------------------------------------------------+
//| TP_Risk_SpreadOK - is the current spread small enough?            |
//+------------------------------------------------------------------+
bool TP_Risk_SpreadOK(void)
  {
   double spread = TP_Exec_CurrentSpreadPrice();
   double limit  = TP_Risk_MaxSpreadPrice();
   if(limit <= 0.0) return true;
   return (spread <= limit);
  }

//+------------------------------------------------------------------+
//| TP_Risk_SessionFilter - pure time filter, used by the self test   |
//+------------------------------------------------------------------+
bool TP_Risk_SessionFilter(const datetime t,
                           const int sessionStart, const int sessionEnd,
                           const int rolloverStart, const int rolloverEnd,
                           const int fridayStop, const bool newCycle)
  {
   if(TP_IsWeekend(t)) return false;

   int hour = TP_ServerHour(t);
   if(hour >= rolloverStart && hour < rolloverEnd) return false;

   if(newCycle)
     {
      if(hour < sessionStart || hour >= sessionEnd) return false;
      if(TP_IsFriday(t) && hour >= fridayStop) return false;
     }
   return true;
  }

//+------------------------------------------------------------------+
//| TP_Risk_SessionOK - time based filters                            |
//|  newCycle = true for a brand new cycle, false for a re-open.      |
//+------------------------------------------------------------------+
bool TP_Risk_SessionOK(const datetime t, const bool newCycle)
  {
   return TP_Risk_SessionFilter(t, SessionStartHour, SessionEndHour,
                                RolloverStartHour, RolloverEndHour,
                                FridayStopHour, newCycle);
  }

//+------------------------------------------------------------------+
//| TP_Risk_MarginLevelOK - margin level must stay above the limit   |
//+------------------------------------------------------------------+
bool TP_Risk_MarginLevelOK(void)
  {
   double level = AccountInfoDouble(ACCOUNT_MARGIN_LEVEL);
   if(level <= 0.0) return true;              // no margin used
   return (level >= MinMarginLevelPct);
  }

//+------------------------------------------------------------------+
//| TP_Risk_VolumeOK - the total volume must stay below the cap      |
//+------------------------------------------------------------------+
bool TP_Risk_VolumeOK(const double extraVolume)
  {
   double total = TP_State_TotalVolume() + extraVolume;
   if(total > MaxTotalLots + 1e-8)
     {
      TP_LogWarn(StringFormat("MaxTotalLots reached: %.2f of %.2f lots.", total, MaxTotalLots));
      return false;
     }
   return true;
  }

//+------------------------------------------------------------------+
//| TP_Risk_AllowsOpen - consolidated brake check for a new position  |
//+------------------------------------------------------------------+
bool TP_Risk_AllowsOpen(const double volume, string &reason)
  {
   reason = "";

   if(!g_tp.tradeAllowed) { reason = g_tp.blockReason; return false; }
   if(g_tp.dailyLocked)  { reason = "daily loss stop"; return false; }
   if(g_tp.basketLocked) { reason = "basket stop"; return false; }
   if(!TP_Risk_SpreadOK()) { reason = "spread too high"; return false; }
   if(!TP_Risk_MarginLevelOK()) { reason = "margin level too low"; return false; }
   if(!TP_Risk_VolumeOK(volume)) { reason = "max total lots"; return false; }
   if(RiskMode == TP_RISK_OFF) { reason = "RiskMode OFF"; return false; }
   return true;
  }

//+------------------------------------------------------------------+
//| TP_Risk_UpdateDayEquity - roll the daily baseline over            |
//+------------------------------------------------------------------+
void TP_Risk_UpdateDayEquity(void)
  {
   int stamp = TP_DayStamp(TimeCurrent());
   if(stamp == g_tp.dayStamp) return;

   g_tp.dayStamp       = stamp;
   g_tp.dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   g_tp.dailyLocked    = false;
   TP_State_Save();
   TP_LogInfo(StringFormat("New server day %d, start of day equity %.2f",
                           stamp, g_tp.dayStartEquity));
  }

//+------------------------------------------------------------------+
//| TP_Risk_BasketStopHit - the cycle lost too much                    |
//+------------------------------------------------------------------+
bool TP_Risk_BasketStopHit(void)
  {
   if(TP_State_OpenLegCount() == 0) return false;
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(equity <= 0.0) return false;
   double limit = -(equity * BasketStopPct / 100.0);
   return (TP_State_CycleTotal() <= limit);
  }

//+------------------------------------------------------------------+
//| TP_Risk_DailyStopHit - the account lost too much today             |
//+------------------------------------------------------------------+
bool TP_Risk_DailyStopHit(void)
  {
   if(g_tp.dayStartEquity <= 0.0) return false;
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double limit  = g_tp.dayStartEquity * (1.0 - DailyStopPct / 100.0);
   return (equity <= limit);
  }

//+------------------------------------------------------------------+
//| TP_Risk_LegAgeMinutes - age of a leg in minutes                    |
//+------------------------------------------------------------------+
int TP_Risk_LegAgeMinutes(const int legIndex)
  {
   if(legIndex < 0 || legIndex >= TP_LEG_COUNT) return 0;
   if(!g_tp.legs[legIndex].open) return 0;
   if(g_tp.legs[legIndex].openTime <= 0) return 0;
   return (int)((TimeCurrent() - g_tp.legs[legIndex].openTime) / 60);
  }

//+------------------------------------------------------------------+
//| TP_Risk_SwapEstimate - expected nightly swap cost of the book     |
//+------------------------------------------------------------------+
double TP_Risk_SwapEstimate(void)
  {
   double swapLong  = SymbolInfoDouble(g_symbol, SYMBOL_SWAP_LONG);
   double swapShort = SymbolInfoDouble(g_symbol, SYMBOL_SWAP_SHORT);
   double total = 0.0;
   for(int i = 0; i < TP_LEG_COUNT; i++)
     {
      if(!g_tp.legs[i].open) continue;
      double s = TP_LegIsBuy(i) ? swapLong : swapShort;
      total += MathAbs(s * g_tp.legs[i].volume);
     }
   return total;
  }

//+------------------------------------------------------------------+
//| TP_Risk_SwapModeText - short description of the swap mode         |
//+------------------------------------------------------------------+
string TP_Risk_SwapModeText(void)
  {
   int mode = (int)SymbolInfoInteger(g_symbol, SYMBOL_SWAP_MODE);
   if(mode == 0) return "points";
   if(mode == 1) return "currency";
   return "interest";
  }
