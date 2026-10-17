//+------------------------------------------------------------------+
//|                                                Execution.mqh      |
//|  TwinPulse Hedge EA                                                 |
//|  All order handling: market entries, closes, Close By, partial     |
//|  closes and stop modifications.  Every order is checked with       |
//|  OrderCheck and sent with bounded retries.                         |
//+------------------------------------------------------------------+
#pragma once

#include "Config.mqh"
#include "Utils.mqh"
#include "Logger.mqh"
#include "State.mqh"

//+------------------------------------------------------------------+
//| TP_Exec_FillingMode - filling mode accepted by the broker         |
//+------------------------------------------------------------------+
ENUM_ORDER_TYPE_FILLING TP_Exec_FillingMode(void)
  {
   int filling = (int)SymbolInfoInteger(g_symbol, SYMBOL_FILLING_MODE);
   if((filling & SYMBOL_FILLING_FOK) == SYMBOL_FILLING_FOK)
      return ORDER_FILLING_FOK;
   if((filling & SYMBOL_FILLING_IOC) == SYMBOL_FILLING_IOC)
      return ORDER_FILLING_IOC;
   if((filling & SYMBOL_FILLING_RETURN) == SYMBOL_FILLING_RETURN)
      return ORDER_FILLING_RETURN;
   return ORDER_FILLING_IOC;
  }

//+------------------------------------------------------------------+
//| TP_Exec_CurrentSpreadPrice - current spread in price units        |
//+------------------------------------------------------------------+
double TP_Exec_CurrentSpreadPrice(void)
  {
   MqlTick tick;
   if(SymbolInfoTick(g_symbol, tick) && tick.ask > 0.0 && tick.bid > 0.0)
      return (tick.ask - tick.bid);

   double points = (double)SymbolInfoInteger(g_symbol, SYMBOL_SPREAD);
   if(points <= 0.0) return 0.0;
   return points * g_point;
  }

//+------------------------------------------------------------------+
//| TP_Exec_NormalizePrice - round a price to the symbol digits       |
//+------------------------------------------------------------------+
double TP_Exec_NormalizePrice(const double price)
  {
   return NormalizeDouble(price, g_digits);
  }

//+------------------------------------------------------------------+
//| TP_Exec_StopDistance - minimum allowed stop distance in price     |
//+------------------------------------------------------------------+
double TP_Exec_StopDistance(void)
  {
   long stops = SymbolInfoInteger(g_symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double d = (double)stops * g_point;
   if(d < 2.0 * g_point) d = 2.0 * g_point;
   return d;
  }

//+------------------------------------------------------------------+
//| TP_Exec_Retriable - the retcode allows a retry with a new price   |
//+------------------------------------------------------------------+
bool TP_Exec_Retriable(const uint retcode)
  {
   if(retcode == TRADE_RETCODE_REQUOTE)           return true;
   if(retcode == TRADE_RETCODE_REJECT)            return true;
   if(retcode == TRADE_RETCODE_PRICE_CHANGED)     return true;
   if(retcode == TRADE_RETCODE_PRICE_OFF)         return true;
   if(retcode == TRADE_RETCODE_TOO_MANY_REQUESTS) return true;
   if(retcode == TRADE_RETCODE_TIMEOUT)           return true;
   return false;
  }

//+------------------------------------------------------------------+
//| TP_Exec_Fatal - the retcode means we must stop trading             |
//+------------------------------------------------------------------+
bool TP_Exec_Fatal(const uint retcode)
  {
   if(retcode == TRADE_RETCODE_NO_MONEY)       return true;
   if(retcode == TRADE_RETCODE_MARKET_CLOSED)  return true;
   if(retcode == TRADE_RETCODE_TRADE_DISABLED) return true;
   if(retcode == TRADE_RETCODE_INVALID)        return true;
   if(retcode == TRADE_RETCODE_INVALID_VOLUME) return true;
   if(retcode == TRADE_RETCODE_INVALID_PRICE)  return true;
   if(retcode == TRADE_RETCODE_INVALID_STOPS)  return true;
   if(retcode == TRADE_RETCODE_LIMIT_VOLUME)   return true;
   if(retcode == TRADE_RETCODE_LIMIT_POSITIONS) return true;
   if(retcode == TRADE_RETCODE_SERVER_DISABLES_AT) return true;
   if(retcode == TRADE_RETCODE_CLIENT_DISABLES_AT) return true;
   if(retcode == TRADE_RETCODE_ONLY_REAL)      return true;
   return false;
  }

//+------------------------------------------------------------------+
//| TP_Exec_SendRequest - OrderCheck + OrderSend with retries         |
//+------------------------------------------------------------------+
bool TP_Exec_SendRequest(MqlTradeRequest &request, MqlTradeResult &result, const string what)
  {
   int attempts = MaxOrderRetries;
   if(attempts < 1) attempts = 1;
   if(attempts > 10) attempts = 10;

   for(int attempt = 1; attempt <= attempts; attempt++)
     {
      MqlTradeCheckResult check;
      ZeroMemory(check);
      if(!OrderCheck(request, check) || check.retcode != 0)
        {
         uint chk = check.retcode;
         if(chk == 0) chk = (uint)GetLastError();
         if(!TP_Exec_Retriable(chk))
           {
            TP_LogError(StringFormat("%s failed in OrderCheck: %u (%s)", what, chk,
                                     g_trade.ResultRetcodeDescription(chk)));
            return false;
           }
        }

      if(!g_trade.OrderSend(request, result))
        {
         uint rc = g_trade.ResultRetcode();
         if(!TP_Exec_Retriable(rc))
           {
            TP_LogError(StringFormat("%s failed: %u (%s)", what, rc, g_trade.ResultRetcodeDescription(rc)));
            return false;
           }
        }
      else
        {
         uint rc = result.retcode;
         if(rc == 0 || rc == TRADE_RETCODE_DONE || rc == TRADE_RETCODE_DONE_PARTIAL || rc == TRADE_RETCODE_PLACED)
            return true;

         if(rc == TRADE_RETCODE_FILL_REQUIRED)
           {
            // retry with the next filling mode
            if(request.type_filling == ORDER_FILLING_FOK)
               request.type_filling = ORDER_FILLING_IOC;
            else if(request.type_filling == ORDER_FILLING_IOC)
               request.type_filling = ORDER_FILLING_RETURN;
            else
              {
               TP_LogError(StringFormat("%s: fill required and no alternative filling mode.", what));
               return false;
              }
            continue;
           }

         if(TP_Exec_Retriable(rc))
           {
            Sleep(100);
            continue;
           }

         TP_LogError(StringFormat("%s failed: %u (%s)", what, rc, g_trade.ResultRetcodeDescription(rc)));
         return false;
        }

      Sleep(150);
     }

   TP_LogError(StringFormat("%s failed after %d attempts.", what, attempts));
   return false;
  }

//+------------------------------------------------------------------+
//| TP_Exec_FreeMarginOk - enough free margin for an extra order       |
//+------------------------------------------------------------------+
bool TP_Exec_FreeMarginOk(const ENUM_ORDER_TYPE orderType, const double volume, const double price)
  {
   double margin = 0.0;
   if(!OrderCalcMargin(orderType, g_symbol, volume, price, margin))
     {
      TP_LogWarn("OrderCalcMargin failed, the order is not sent.");
      return false;
     }
   double free = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   if(margin > free)
     {
      TP_LogWarn(StringFormat("Not enough free margin: need %.2f, free %.2f.", margin, free));
      return false;
     }
   return true;
  }

//+------------------------------------------------------------------+
//| TP_Exec_OpenLeg - open one leg of a cycle                          |
//+------------------------------------------------------------------+
bool TP_Exec_OpenLeg(const int legIndex, const double volume, const double sl, const double tp, const int cycleId)
  {
   MqlTick tick;
   if(!SymbolInfoTick(g_symbol, tick))
     {
      TP_LogError("SymbolInfoTick failed, cannot open a leg.");
      return false;
     }

   bool isBuy = TP_LegIsBuy(legIndex);
   double price = isBuy ? tick.ask : tick.bid;
   price = TP_Exec_NormalizePrice(price);

   //--- stops must respect the minimum stop distance ------------------
   double minDist = TP_Exec_StopDistance();
   double slPrice = TP_Exec_NormalizePrice(sl);
   if(isBuy)
     {
      if(price - slPrice < minDist) slPrice = TP_Exec_NormalizePrice(price - minDist);
     }
   else
     {
      if(slPrice - price < minDist) slPrice = TP_Exec_NormalizePrice(price + minDist);
     }

   MqlTradeRequest request;
   MqlTradeResult  result;
   ZeroMemory(request);
   ZeroMemory(result);

   request.action       = TRADE_ACTION_DEAL;
   request.symbol       = g_symbol;
   request.magic        = (ulong)g_magic;
   request.volume       = volume;
   request.type         = isBuy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   request.price        = price;
   request.deviation    = DeviationPoints;
   request.magic        = (ulong)g_magic;
   request.comment      = TP_MakeComment(cycleId, legIndex);
   request.type_filling = TP_Exec_FillingMode();
   request.type_time    = ORDER_TIME_GTC;

   if(slPrice > 0.0) request.stoploss = slPrice;
   if(tp > 0.0)      request.takeprofit = TP_Exec_NormalizePrice(tp);

   //--- a position must never be opened without a stop loss ---------
   if(slPrice <= 0.0)
     {
      if(g_tp.atr5 <= 0.0)
        {
         TP_LogError("No ATR available, the leg is not opened without a stop loss.");
         return false;
        }
      double dist = HardSL_ATR * g_tp.atr5;
      if(dist < minDist) dist = minDist;
      slPrice = TP_Exec_NormalizePrice(isBuy ? (price - dist) : (price + dist));
      request.stoploss = slPrice;
     }

   if(!TP_Exec_FreeMarginOk(request.type, volume, price))
      return false;

   string what = StringFormat("open %s %.2f lots", TP_LegName(legIndex), volume);
   if(!TP_Exec_SendRequest(request, result, what))
      return false;

   TP_LogInfo(StringFormat("%s OK: %s %.2f @ %s (deal %I64u)",
                           what, isBuy ? "BUY" : "SELL", volume,
                           TP_Str(price, g_digits), result.deal));
   return true;
  }

//+------------------------------------------------------------------+
//| TP_Exec_CloseLeg - close a full position                           |
//+------------------------------------------------------------------+
bool TP_Exec_CloseLeg(const ulong ticket)
  {
   if(ticket == 0) return false;
   if(!g_trade.PositionClose(ticket))
     {
      uint rc = g_trade.ResultRetcode();
      TP_LogWarn(StringFormat("Close of ticket %I64u failed: %u (%s)", ticket, rc,
                              g_trade.ResultRetcodeDescription(rc)));
      return false;
     }
   return true;
  }

//+------------------------------------------------------------------+
//| TP_Exec_CloseBy - close two opposite positions against each other  |
//+------------------------------------------------------------------+
bool TP_Exec_CloseBy(const ulong ticket1, const ulong ticket2)
  {
   if(ticket1 == 0 || ticket2 == 0 || ticket1 == ticket2) return false;
   if(!g_trade.PositionCloseBy(ticket1, ticket2))
     {
      uint rc = g_trade.ResultRetcode();
      TP_LogWarn(StringFormat("Close By %I64u / %I64u failed: %u (%s)", ticket1, ticket2, rc,
                              g_trade.ResultRetcodeDescription(rc)));
      return false;
     }
   TP_LogInfo(StringFormat("Close By executed: %I64u / %I64u", ticket1, ticket2));
   return true;
  }

//+------------------------------------------------------------------+
//| TP_Exec_PartialClose - close a part of a position                  |
//+------------------------------------------------------------------+
bool TP_Exec_PartialClose(const ulong ticket, const double volume)
  {
   if(ticket == 0 || volume <= 0.0) return false;
   if(!g_trade.PositionClosePartial(ticket, volume))
     {
      uint rc = g_trade.ResultRetcode();
      TP_LogWarn(StringFormat("Partial close of %I64u (%.2f) failed: %u (%s)", ticket, volume, rc,
                              g_trade.ResultRetcodeDescription(rc)));
      return false;
     }
   TP_LogInfo(StringFormat("Partial close: ticket %I64u volume %.2f", ticket, volume));
   return true;
  }

//+------------------------------------------------------------------+
//| TP_Exec_ModifySL - change the stop loss (and optionally the TP)   |
//|  The stop is never moved further away from the market.             |
//+------------------------------------------------------------------+
bool TP_Exec_ModifySL(const ulong ticket, const double newSl, const double newTp)
  {
   if(ticket == 0) return false;
   if(!g_pos.SelectByTicket(ticket))
      return false;

   double curSl = g_pos.SL();
   double curTp = g_pos.TP();
   bool isBuy = (g_pos.PositionType() == POSITION_TYPE_BUY);

   double sl = TP_Exec_NormalizePrice(newSl);
   double tp = TP_Exec_NormalizePrice(newTp);

   //--- never widen a stop -------------------------------------------
   if(curSl > 0.0)
     {
      if(isBuy && sl > 0.0 && sl < curSl) sl = curSl;
      if(!isBuy && sl > 0.0 && sl > curSl) sl = curSl;
     }

   //--- never change a stop into something invalid -------------------
   if(sl > 0.0 && MathAbs(sl - curSl) < g_point && MathAbs(tp - curTp) < g_point)
      return true;    // nothing to do

   MqlTradeRequest request;
   MqlTradeResult  result;
   ZeroMemory(request);
   ZeroMemory(result);

   request.action     = TRADE_ACTION_SLTP;
   request.symbol     = g_symbol;
   request.position   = ticket;
   request.magic      = (ulong)g_magic;
   request.sl         = sl;
   request.tp         = tp;
   request.deviation  = DeviationPoints;
   request.type_filling = TP_Exec_FillingMode();
   request.type_time  = ORDER_TIME_GTC;

   if(!g_trade.OrderSend(request, result))
     {
      uint rc = g_trade.ResultRetcode();
      if(rc == TRADE_RETCODE_NO_CHANGES) return true;
      if(TP_Exec_Retriable(rc))
        {
         Sleep(100);
         if(!g_trade.OrderSend(request, result))
           {
            rc = g_trade.ResultRetcode();
            TP_LogWarn(StringFormat("SL modify of %I64u failed: %u (%s)", ticket, rc,
                                    g_trade.ResultRetcodeDescription(rc)));
            return false;
           }
         return true;
        }
      TP_LogWarn(StringFormat("SL modify of %I64u failed: %u (%s)", ticket, rc,
                              g_trade.ResultRetcodeDescription(rc)));
      return false;
     }

   if(result.retcode != 0 && result.retcode != TRADE_RETCODE_DONE)
     {
      if(result.retcode == TRADE_RETCODE_NO_CHANGES) return true;
      TP_LogWarn(StringFormat("SL modify of %I64u: %u (%s)", ticket, result.retcode,
                              g_trade.ResultRetcodeDescription(result.retcode)));
      return false;
     }
   return true;
  }
