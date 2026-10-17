//+------------------------------------------------------------------+
//|                                                Regime.mqh         |
//|  TwinPulse Hedge EA                                                 |
//|  Deterministic market regime detection, evaluated on closed M15    |
//|  bars.  The pure classifier is unit tested by TwinPulseSelfTest.   |
//+------------------------------------------------------------------+
#pragma once

#include "Config.mqh"
#include "Utils.mqh"
#include "Logger.mqh"
#include "State.mqh"
#include "Execution.mqh"
#include "Risk.mqh"

//--- indicator handles -------------------------------------------------
int g_hAtr5    = INVALID_HANDLE;   // ATR(14) M5
int g_hAtrM15  = INVALID_HANDLE;   // ATR(14) M15
int g_hAdx     = INVALID_HANDLE;   // ADX(14) M15
int g_hBands   = INVALID_HANDLE;   // Bollinger(20,2) M15
int g_hEmaM15  = INVALID_HANDLE;   // EMA50 M15
int g_hEmaH1   = INVALID_HANDLE;   // EMA50 H1

//--- forward declarations ---------------------------------------------
void TP_Regime_Update(void);
int  TP_Regime_Get(void);
string TP_RegimeName(const int regime);
int  TP_ClassifyRegime(const double er, const double chop, const double adx,
                       const double slopeAtr, const bool priceAboveH1,
                       const bool atrSpike, const bool newsBlock, const bool spreadHot,
                       const double erRange, const double chopRange, const double adxRange,
                       const double erTrend, const double adxTrend);

//+------------------------------------------------------------------+
//| TP_BufValue - value of an indicator buffer, offset counted back    |
//| from the last copied element (0 = newest).                         |
//+------------------------------------------------------------------+
double TP_BufValue(const double &buf[], const int count, const int offset)
  {
   if(count <= 0) return 0.0;
   if(offset < 0) return 0.0;
   if(offset >= count) return 0.0;
   return buf[count - 1 - offset];
  }

//+------------------------------------------------------------------+
//| TP_Regime_HandlesReady - wait until the indicators are calculated  |
//+------------------------------------------------------------------+
bool TP_Regime_HandlesReady(void)
  {
   int handles[6];
   handles[0] = g_hAtr5;
   handles[1] = g_hAtrM15;
   handles[2] = g_hAdx;
   handles[3] = g_hBands;
   handles[4] = g_hEmaM15;
   handles[5] = g_hEmaH1;

   for(int pass = 0; pass < 30; pass++)
     {
      bool ready = true;
      for(int i = 0; i < 6; i++)
        {
         if(handles[i] == INVALID_HANDLE) { ready = false; break; }
         if(BarsCalculated(handles[i]) < 0) { ready = false; break; }
        }
      if(ready) return true;
      Sleep(200);
     }
   return false;
  }

//+------------------------------------------------------------------+
//| TP_Regime_Init - create every indicator handle                     |
//+------------------------------------------------------------------+
bool TP_Regime_Init(void)
  {
   g_hAtr5   = iATR(g_symbol, PERIOD_M5, 14);
   g_hAtrM15 = iATR(g_symbol, PERIOD_M15, 14);
   g_hAdx    = iADX(g_symbol, PERIOD_M15, 14);
   g_hBands  = iBands(g_symbol, PERIOD_M15, (int)BBPeriod, 0.0, BBDev, PRICE_CLOSE);
   g_hEmaM15 = iMA(g_symbol, PERIOD_M15, 50, 0, MODE_EMA, PRICE_CLOSE);
   g_hEmaH1  = iMA(g_symbol, PERIOD_H1, 50, 0, MODE_EMA, PRICE_CLOSE);

   if(g_hAtr5 == INVALID_HANDLE || g_hAtrM15 == INVALID_HANDLE || g_hAdx == INVALID_HANDLE ||
      g_hBands == INVALID_HANDLE || g_hEmaM15 == INVALID_HANDLE || g_hEmaH1 == INVALID_HANDLE)
     {
      TP_LogError(StringFormat("Indicator handle creation failed (error %d).", GetLastError()));
      return false;
     }

   if(!TP_Regime_HandlesReady())
      TP_LogWarn("The indicators are not calculated yet, the regime detection starts with the first bars.");

   return true;
  }

//+------------------------------------------------------------------+
//| TP_Regime_Release - release the indicator handles                  |
//+------------------------------------------------------------------+
void TP_Regime_Release(void)
  {
   if(g_hAtr5   != INVALID_HANDLE) { IndicatorRelease(g_hAtr5);   g_hAtr5   = INVALID_HANDLE; }
   if(g_hAtrM15 != INVALID_HANDLE) { IndicatorRelease(g_hAtrM15); g_hAtrM15 = INVALID_HANDLE; }
   if(g_hAdx    != INVALID_HANDLE) { IndicatorRelease(g_hAdx);    g_hAdx    = INVALID_HANDLE; }
   if(g_hBands  != INVALID_HANDLE) { IndicatorRelease(g_hBands);  g_hBands  = INVALID_HANDLE; }
   if(g_hEmaM15 != INVALID_HANDLE) { IndicatorRelease(g_hEmaM15); g_hEmaM15 = INVALID_HANDLE; }
   if(g_hEmaH1  != INVALID_HANDLE) { IndicatorRelease(g_hEmaH1);  g_hEmaH1  = INVALID_HANDLE; }
  }

//+------------------------------------------------------------------+
//| TP_ClassifyRegime - pure regime classifier                         |
//|                                                                   |
//|  CHAOS  : ATR spike, spread spike or inside a news block           |
//|  RANGE  : CHOP > chopRange and ER < erRange and ADX < adxRange     |
//|  TREND  : (ER > erTrend or ADX > adxTrend) and the EMA50 slope    |
//|           agrees with the price versus the EMA50 on H1             |
//|  NEUTRAL: everything else                                          |
//+------------------------------------------------------------------+
int TP_ClassifyRegime(const double er, const double chop, const double adx,
                      const double slopeAtr, const bool priceAboveH1,
                      const bool atrSpike, const bool newsBlock, const bool spreadHot,
                      const double erRange, const double chopRange, const double adxRange,
                      const double erTrend, const double adxTrend)
  {
   if(atrSpike || newsBlock || spreadHot)
      return TP_REG_CHAOS;

   if(chop > chopRange && er < erRange && adx < adxRange)
      return TP_REG_RANGE;

   if((er > erTrend) || (adx > adxTrend))
     {
      if(slopeAtr > 0.0 && priceAboveH1)  return TP_REG_TREND_UP;
      if(slopeAtr < 0.0 && !priceAboveH1) return TP_REG_TREND_DOWN;
     }

   return TP_REG_NEUTRAL;
  }

//+------------------------------------------------------------------+
//| TP_RegimeName - readable regime name                              |
//+------------------------------------------------------------------+
string TP_RegimeName(const int regime)
  {
   switch(regime)
     {
      case TP_REG_RANGE:      return "RANGE";
      case TP_REG_TREND_UP:   return "TREND_UP";
      case TP_REG_TREND_DOWN: return "TREND_DOWN";
      case TP_REG_NEUTRAL:    return "NEUTRAL";
      case TP_REG_CHAOS:      return "CHAOS";
     }
   return "UNKNOWN";
  }

//+------------------------------------------------------------------+
//| TP_Regime_Get - current regime                                    |
//+------------------------------------------------------------------+
int TP_Regime_Get(void) { return g_tp.regime; }

//+------------------------------------------------------------------+
//| TP_Regime_UpdateAtr - refresh ATR5 and its rolling median          |
//|  Called on every new M5 bar.                                       |
//+------------------------------------------------------------------+
void TP_Regime_UpdateAtr(void)
  {
   if(g_hAtr5 == INVALID_HANDLE) return;

   //--- ATR on M5 (closed bar) ---------------------------------------
   double atr5buf[];
   ArraySetAsSeries(atr5buf, false);
   int atrCount = CopyBuffer(g_hAtr5, 0, 1, 3, atr5buf);
   if(atrCount < 3)
      g_tp.atr5 = 0.0;
   else
      g_tp.atr5 = TP_BufValue(atr5buf, atrCount, 0);

   //--- median ATR5 over the last 100 closed bars --------------------
   double atrHist[];
   ArraySetAsSeries(atrHist, false);
   int histCount = CopyBuffer(g_hAtr5, 0, 1, 100, atrHist);
   if(histCount > 1)
     {
      double tmp[];
      ArrayResize(tmp, histCount);
      for(int i = 0; i < histCount; i++) tmp[i] = atrHist[i];
      g_tp.regimeAtrMed = TP_Median(tmp);
     }
   else
      g_tp.regimeAtrMed = g_tp.atr5;
  }

//+------------------------------------------------------------------+
//| TP_Regime_Update - recompute the regime from closed M15 bars       |
//+------------------------------------------------------------------+
void TP_Regime_Update(void)
  {
   if(g_hAtr5 == INVALID_HANDLE || g_hAtrM15 == INVALID_HANDLE || g_hAdx == INVALID_HANDLE ||
      g_hBands == INVALID_HANDLE || g_hEmaM15 == INVALID_HANDLE || g_hEmaH1 == INVALID_HANDLE)
      return;

   TP_Regime_UpdateAtr();

   //--- ATR on M15 ----------------------------------------------------
   double atrM15buf[];
   ArraySetAsSeries(atrM15buf, false);
   int atrM15Count = CopyBuffer(g_hAtrM15, 0, 1, 3, atrM15buf);
   g_tp.atrM15 = (atrM15Count >= 3) ? TP_BufValue(atrM15buf, atrM15Count, 0) : 0.0;

   //--- ADX on M15 ----------------------------------------------------
   double adxbuf[];
   ArraySetAsSeries(adxbuf, false);
   int adxCount = CopyBuffer(g_hAdx, 0, 1, 3, adxbuf);
   g_tp.regimeAdx = (adxCount >= 3) ? TP_BufValue(adxbuf, adxCount, 0) : 0.0;

   //--- EMA50 on M15 and its slope over SlopeBars --------------------
   double emaBuf[];
   ArraySetAsSeries(emaBuf, false);
   int emaCount = CopyBuffer(g_hEmaM15, 0, 1, SlopeBars + 2, emaBuf);
   double slope = 0.0;
   if(emaCount >= SlopeBars + 1)
     {
      double emaNow  = TP_BufValue(emaBuf, emaCount, 0);
      double emaPrev = TP_BufValue(emaBuf, emaCount, SlopeBars);
      slope = (emaNow - emaPrev) / TP_SafeDiv(g_tp.atrM15, 1.0, 0.0);
     }
   g_tp.regimeSlope = slope;

   //--- EMA50 on H1 and the price relation ----------------------------
   double emaH1buf[];
   ArraySetAsSeries(emaH1buf, false);
   int emaH1Count = CopyBuffer(g_hEmaH1, 0, 1, 2, emaH1buf);
   double emaH1 = (emaH1Count >= 2) ? TP_BufValue(emaH1buf, emaH1Count, 0) : 0.0;

   //--- M15 close and the Bollinger middle line -----------------------
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   int need = RegimeERPeriod + 3;
   if(SlopeBars + 2 > need) need = SlopeBars + 2;
   int rateCount = CopyRates(g_symbol, PERIOD_M15, 1, need, rates);
   if(rateCount < 5)
     {
      TP_LogWarn("Not enough M15 history for the regime detection yet.");
      return;
     }

   double lastClose = rates[0].close;
   g_tp.regimeAboveH1 = (emaH1 > 0.0) ? (lastClose > emaH1) : (lastClose > 0.0);

   double bbBuf[];
   ArraySetAsSeries(bbBuf, false);
   int bbCount = CopyBuffer(g_hBands, 0, 1, 2, bbBuf);
   g_tp.regimeBbMid = (bbCount >= 2) ? TP_BufValue(bbBuf, bbCount, 0) : 0.0;

   //--- efficiency ratio and choppiness on chronological arrays -------
   int win = RegimeERPeriod + 1;
   if(win > rateCount) win = rateCount;
   if(win < 5) return;

   double closes[];
   double highs[];
   double lows[];
   ArrayResize(closes, win);
   ArrayResize(highs, win);
   ArrayResize(lows, win);
   for(int i = 0; i < win; i++)
     {
      closes[win - 1 - i] = rates[i].close;
      highs[win - 1 - i]  = rates[i].high;
      lows[win - 1 - i]   = rates[i].low;
     }

   g_tp.regimeEr   = TP_ComputeER(closes, win, RegimeERPeriod);
   g_tp.regimeChop = TP_ComputeCHOP(highs, lows, closes, win, RegimeERPeriod);

   //--- chaos conditions ----------------------------------------------
   bool atrSpike = false;
   if(g_tp.regimeAtrMed > 0.0 && g_tp.atr5 > 0.0)
      atrSpike = (g_tp.atr5 / g_tp.regimeAtrMed) > AtrSpikeRatio;

   bool spreadHot = false;
   double maxSpread = TP_Risk_MaxSpreadPrice();
   double spread = TP_Exec_CurrentSpreadPrice();
   if(maxSpread > 0.0 && spread > maxSpread) spreadHot = true;

   int regime = TP_ClassifyRegime(g_tp.regimeEr, g_tp.regimeChop, g_tp.regimeAdx,
                                   g_tp.regimeSlope, g_tp.regimeAboveH1,
                                   atrSpike, g_tp.newsBlock, spreadHot,
                                   ErRange, ChopRange, AdxRange, ErTrend, AdxTrend);

   if(regime != g_tp.regime)
     {
      TP_LogInfo(StringFormat("Regime change: %s -> %s (ER %.3f, CHOP %.1f, ADX %.1f, slope %.2f)",
                               TP_RegimeName(g_tp.regime), TP_RegimeName(regime),
                               g_tp.regimeEr, g_tp.regimeChop, g_tp.regimeAdx, g_tp.regimeSlope));
     }
   g_tp.regime = regime;
  }
