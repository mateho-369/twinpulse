//+------------------------------------------------------------------+
//|                                                Execution.mqh      |
//|  TwinPulse Hedge EA                                                 |
//|  All order handling: market entries, closes, Close By, partial     |
//|  closes and stop modifications.  Every order is checked with       |
//|  OrderCheck and sent with bounded retries.                         |
//+------------------------------------------------------------------+
#ifndef TP_EXECUTION_MQH
#define TP_EXECUTION_MQH

#include "Config.mqh"
#include "Utils.mqh"
#include "Logger.mqh"
#include "State.mqh"

//--- result of a close request ----------------------------------------
//| OK      : the request was sent and executed                        |
//| GONE    : nothing was sent, the position is already closed         |
//| NOPAIR  : nothing was sent, the request is invalid (a Close By     |
//|           pair that cannot be netted, a zero volume, ...)          |
//| FAIL    : the request was sent and failed                          |
enum ENUM_TP_CLOSE_RESULT
  {
   TP_CLOSE_OK      = 0,
   TP_CLOSE_GONE    = 1,
   TP_CLOSE_NOPAIR  = 2,
   TP_CLOSE_FAIL    = 3
  };

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
   // ORDER_FILLING_RETURN is the documented fallback when the symbol
   // exposes neither of the market filling flags.
   return ORDER_FILLING_RETURN;
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

//--- log de-dup: a failing open retries every timer tick, the same
//--- block reason / send error is logged once per state --------------
string g_lastSendBlock = "";   // TP_Exec_SendRequest errors
string g_lastOpenBlock = "";   // open path blocks (margin, ATR, tick)

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
            if(TP_DedupShouldLog(g_lastSendBlock, StringFormat("send:%s:%u", what, chk)))
               TP_LogError(StringFormat("%s failed in OrderCheck, code %u", what, chk));
            return false;
           }
        }

      if(!g_trade.OrderSend(request, result))
        {
         //--- the OrderSend(request, result) overload fills only the local
         //--- result struct, g_trade.ResultRetcode() is stale here
         uint rc = result.retcode;
         if(rc == 0) rc = (uint)GetLastError();
         if(!TP_Exec_Retriable(rc))
           {
            if(TP_DedupShouldLog(g_lastSendBlock, StringFormat("send:%s:%u", what, rc)))
               TP_LogError(StringFormat("%s failed: %u (%s)", what, rc, result.comment));
            return false;
           }
        }
      else
        {
         uint rc = result.retcode;
         if(rc == 0 || rc == TRADE_RETCODE_DONE || rc == TRADE_RETCODE_DONE_PARTIAL || rc == TRADE_RETCODE_PLACED)
           {
            g_lastSendBlock = "";   // a working request may fail and log again
            return true;
           }

         if(rc == TRADE_RETCODE_INVALID_FILL)
           {
            // retry with the next filling mode
            if(request.type_filling == ORDER_FILLING_FOK)
               request.type_filling = ORDER_FILLING_IOC;
            else if(request.type_filling == ORDER_FILLING_IOC)
               request.type_filling = ORDER_FILLING_RETURN;
            else
              {
               if(TP_DedupShouldLog(g_lastSendBlock, StringFormat("send:%s:fill", what)))
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

         if(TP_DedupShouldLog(g_lastSendBlock, StringFormat("send:%s:%u", what, rc)))
            TP_LogError(StringFormat("%s failed: %u (%s)", what, rc, result.comment));
         return false;
        }

      Sleep(150);
     }

   if(TP_DedupShouldLog(g_lastSendBlock, StringFormat("send:%s:retries", what)))
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
      if(TP_DedupShouldLog(g_lastOpenBlock, "open: margin calc failed"))
         TP_LogWarn("OrderCalcMargin failed, the order is not sent.");
      return false;
     }
   double free = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   if(margin > free)
     {
      if(TP_DedupShouldLog(g_lastOpenBlock, "open: not enough free margin"))
         TP_LogWarn(StringFormat("Not enough free margin: need %.2f, free %.2f.", margin, free));
      return false;
     }
   g_lastOpenBlock = "";   // the margin is fine again, a later block logs again
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
      if(TP_DedupShouldLog(g_lastOpenBlock, "open: symbol tick failed"))
         TP_LogError("SymbolInfoTick failed, cannot open a leg.");
      return false;
     }

   bool isBuy = TP_LegIsBuy(legIndex);
   double price = isBuy ? tick.ask : tick.bid;
   price = TP_Exec_NormalizePrice(price);

   //--- stops must respect the minimum stop distance ------------------
   //--- decided in integer points, a 1e-12 noise must not flip it -----
   double minDist = TP_Exec_StopDistance();
   double slPrice = TP_Exec_NormalizePrice(sl);
   long minPts = 1;
   if(g_point > 0.0) minPts = (long)MathRound(minDist / g_point);
   if(isBuy)
     {
      if(TP_PointsDelta(price, slPrice, g_point) < minPts)
         slPrice = TP_Exec_NormalizePrice(price - minPts * g_point);
     }
   else
     {
      if(TP_PointsDelta(slPrice, price, g_point) < minPts)
         slPrice = TP_Exec_NormalizePrice(price + minPts * g_point);
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
   request.comment      = TP_MakeComment(cycleId, legIndex);
   request.type_filling = TP_Exec_FillingMode();
   request.type_time    = ORDER_TIME_GTC;

   if(slPrice > 0.0) request.sl = slPrice;
   if(tp > 0.0)      request.tp = TP_Exec_NormalizePrice(tp);

   //--- a position must never be opened without a stop loss ---------
   if(slPrice <= 0.0)
     {
      if(g_tp.atr5 <= 0.0)
        {
         if(TP_DedupShouldLog(g_lastOpenBlock, "open: no ATR"))
            TP_LogError("No ATR available, the leg is not opened without a stop loss.");
         return false;
        }
      double dist = HardSL_ATR * g_tp.atr5;
      if(dist < minDist) dist = minDist;
      slPrice = TP_Exec_NormalizePrice(isBuy ? (price - dist) : (price + dist));
      request.sl = slPrice;
     }

   if(!TP_Exec_FreeMarginOk(request.type, volume, price))
      return false;

   string what = StringFormat("open %s %.2f lots", TP_LegName(legIndex), volume);
   if(!TP_Exec_SendRequest(request, result, what))
      return false;

   TP_LogInfo(StringFormat("%s OK: %s %.2f @ %s (deal %I64u)",
                           what, isBuy ? "BUY" : "SELL", volume,
                           TP_Str(price, g_digits), result.deal));
   g_lastOpenBlock = "";   // a real open, a later block logs again

   //--- spread accounting for the decision analysis -----------------
   double spreadNow = tick.ask - tick.bid;
   double contract  = SymbolInfoDouble(g_symbol, SYMBOL_TRADE_CONTRACT_SIZE);
   g_tp.legs[legIndex].spreadOpen = spreadNow;
   g_tp.legs[legIndex].spreadCost = TP_SpreadCost(spreadNow, volume, contract);
   g_tp.legs[legIndex].booked     = false;
   return true;
  }

//+------------------------------------------------------------------+
//| TP_Exec_NoteGone - a position is already closed (server SL/TP, an |
//| earlier Close By or a manual close). Mark the leg closed, rebuild |
//| the map, do not log a failure: the next TP_Legs_DetectClosedLegs  |
//| books the realised money with the reason "server_close".          |
//+------------------------------------------------------------------+
void TP_Exec_NoteGone(const ulong ticket)
  {
   for(int i = 0; i < TP_LEG_COUNT; i++)
     {
      if(g_tp.legs[i].open && g_tp.legs[i].ticket == ticket)
        {
         g_tp.legs[i].open = false;
         TP_LogInfo(StringFormat("%s: ticket %I64u is already closed, no request sent.",
                                 TP_LegName(i), ticket));
         break;
        }
     }
   TP_State_SyncPositions();
  }

//+------------------------------------------------------------------+
//| TP_Exec_CloseLeg - close a full position                           |
//|  A position that no longer exists is reported as TP_CLOSE_GONE,   |
//|  nothing is sent and no failure is logged.                        |
//+------------------------------------------------------------------+
ENUM_TP_CLOSE_RESULT TP_Exec_CloseLeg(const ulong ticket)
  {
   if(ticket == 0) return TP_CLOSE_GONE;
   if(!PositionSelectByTicket(ticket))
     {
      TP_Exec_NoteGone(ticket);
      return TP_CLOSE_GONE;
     }

   //--- drop the stale retcode of the previous request, so a call that
   //--- sends nothing can be told from a request that really failed
   g_trade.ResetResult();
   bool ok = g_trade.PositionClose(ticket);
   uint rc = g_trade.ResultRetcode();
   if(ok)
     {
      g_stats.closeAttempts++;
      return TP_CLOSE_OK;
     }

   //--- second safety net: CTrade::PositionClose returns false without
   //--- sending anything when the position vanished - re-check the ticket
   if(!PositionSelectByTicket(ticket))
     {
      TP_Exec_NoteGone(ticket);
      return TP_CLOSE_GONE;
     }

   //--- the position still exists: a request was sent and failed -----
   g_stats.closeAttempts++;
   g_stats.closeFailures++;
   if(rc == 0) rc = (uint)GetLastError();
   TP_LogWarn(StringFormat("Close of ticket %I64u failed: %u (%s)", ticket, rc,
                           g_trade.ResultRetcodeDescription()));
   return TP_CLOSE_FAIL;
  }

//+------------------------------------------------------------------+
//| TP_Exec_CloseBy - close two opposite positions against each other  |
//|  Both tickets must exist, be opposite, on the same symbol and with |
//|  the same magic, otherwise nothing is sent.                       |
//+------------------------------------------------------------------+
ENUM_TP_CLOSE_RESULT TP_Exec_CloseBy(const ulong ticket1, const ulong ticket2)
  {
   //--- a Close By with a zero or identical ticket is invalid: never
   //--- sent (the terminal prints "failed close position #0 ..." and
   //--- the server answers "Invalid request")
   if(!TP_CloseByTicketsOk(ticket1, ticket2)) return TP_CLOSE_NOPAIR;

   //--- both tickets must exist ---------------------------------------
   bool   alive1 = PositionSelectByTicket(ticket1);
   bool   buy1   = false;
   string sym1   = "";
   long   magic1 = 0;
   if(alive1)
     {
      buy1   = ((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);
      sym1   = PositionGetString(POSITION_SYMBOL);
      magic1 = (long)PositionGetInteger(POSITION_MAGIC);
     }

   bool   alive2 = PositionSelectByTicket(ticket2);
   bool   buy2   = false;
   string sym2   = "";
   long   magic2 = 0;
   if(alive2)
     {
      buy2   = ((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);
      sym2   = PositionGetString(POSITION_SYMBOL);
      magic2 = (long)PositionGetInteger(POSITION_MAGIC);
     }

   if(!alive1 || !alive2)
     {
      if(!alive1) TP_Exec_NoteGone(ticket1);
      if(!alive2) TP_Exec_NoteGone(ticket2);
      return TP_CLOSE_GONE;
     }

   //--- opposite types, same symbol, same magic ----------------------
   if(buy1 == buy2 || sym1 != sym2 || sym1 != g_symbol ||
      magic1 != magic2 || magic1 != g_magic)
      return TP_CLOSE_NOPAIR;

   g_trade.ResetResult();
   bool ok = g_trade.PositionCloseBy(ticket1, ticket2);
   uint rc = g_trade.ResultRetcode();
   if(ok)
     {
      g_stats.closeAttempts++;
      g_stats.closeByCount++;
      TP_LogInfo(StringFormat("Close By executed: %I64u / %I64u", ticket1, ticket2));
      return TP_CLOSE_OK;
     }

   //--- second safety net: nothing was sent when a ticket vanished ---
   bool still1 = PositionSelectByTicket(ticket1);
   bool still2 = PositionSelectByTicket(ticket2);
   if(!still1 || !still2)
     {
      if(!still1) TP_Exec_NoteGone(ticket1);
      if(!still2) TP_Exec_NoteGone(ticket2);
      return TP_CLOSE_GONE;
     }

   //--- both positions still exist: a request was sent and failed ----
   g_stats.closeAttempts++;
   g_stats.closeFailures++;
   if(rc == 0) rc = (uint)GetLastError();
   TP_LogWarn(StringFormat("Close By %I64u / %I64u failed: %u (%s)", ticket1, ticket2, rc,
                           g_trade.ResultRetcodeDescription()));
   return TP_CLOSE_FAIL;
  }

//+------------------------------------------------------------------+
//| TP_Exec_PartialClose - close a part of a position                  |
//+------------------------------------------------------------------+
ENUM_TP_CLOSE_RESULT TP_Exec_PartialClose(const ulong ticket, const double volume)
  {
   if(ticket == 0 || volume <= 0.0) return TP_CLOSE_NOPAIR;
   if(!PositionSelectByTicket(ticket))
     {
      TP_Exec_NoteGone(ticket);
      return TP_CLOSE_GONE;
     }

   g_trade.ResetResult();
   bool ok = g_trade.PositionClosePartial(ticket, volume);
   uint rc = g_trade.ResultRetcode();
   if(ok)
     {
      g_stats.closeAttempts++;
      TP_LogInfo(StringFormat("Partial close: ticket %I64u volume %.2f", ticket, volume));
      return TP_CLOSE_OK;
     }

   //--- second safety net: nothing was sent when the ticket vanished -
   if(!PositionSelectByTicket(ticket))
     {
      TP_Exec_NoteGone(ticket);
      return TP_CLOSE_GONE;
     }

   //--- the position still exists: a request was sent and failed -----
   g_stats.closeAttempts++;
   g_stats.closeFailures++;
   if(rc == 0) rc = (uint)GetLastError();
   TP_LogWarn(StringFormat("Partial close of %I64u (%.2f) failed: %u (%s)", ticket, volume, rc,
                           g_trade.ResultRetcodeDescription()));
   return TP_CLOSE_FAIL;
  }

//+------------------------------------------------------------------+
//| TP_Exec_ModifySL - change the stop loss (and optionally the TP)   |
//|  The stop is never moved further away from the market. The caller  |
//|  has already clamped the stop into the legal region (TP_ClampStop)|
//|  and validated it against the freeze level.                       |
//|  The retcode and the comment are always read from the local       |
//|  result struct: the OrderSend(request, result) overload does not  |
//|  fill g_trade.ResultRetcode(), that value is stale.               |
//+------------------------------------------------------------------+
bool TP_Exec_ModifySL(const ulong ticket, const double newSl, const double newTp)
  {
   if(ticket == 0) return false;
   if(!g_pos.SelectByTicket(ticket))
     {
      //--- the position vanished (server SL/TP): mark the leg gone ---
      TP_Exec_NoteGone(ticket);
      return false;
     }

   double curSl = g_pos.StopLoss();
   double curTp = g_pos.TakeProfit();
   bool isBuy = (g_pos.PositionType() == POSITION_TYPE_BUY);

   double sl = TP_Exec_NormalizePrice(newSl);
   double tp = TP_Exec_NormalizePrice(newTp);

   //--- never widen a stop (integer points) --------------------------
   if(curSl > 0.0)
     {
      if(isBuy && sl > 0.0 && TP_PointsDelta(sl, curSl, g_point) < 0) sl = curSl;
      if(!isBuy && sl > 0.0 && TP_PointsDelta(sl, curSl, g_point) > 0) sl = curSl;
     }

   //--- never change a stop into something invalid -------------------
   //--- nothing to do when both levels are within one point -----------
   if(sl > 0.0 && TP_PointsBetween(sl, curSl, g_point) < 1 &&
      TP_PointsBetween(tp, curTp, g_point) < 1)
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

   //--- one logical attempt: the requote retry belongs to it ---------
   g_stats.modifyAttempts++;

   for(int attempt = 1; attempt <= 2; attempt++)
     {
      ZeroMemory(result);
      bool ok = g_trade.OrderSend(request, result);
      //--- the local result struct is the only truth after the call --
      uint rc = result.retcode;
      if(rc == 0 && !ok) rc = (uint)GetLastError();

      if(ok && (rc == 0 || rc == TRADE_RETCODE_DONE ||
                rc == TRADE_RETCODE_DONE_PARTIAL || rc == TRADE_RETCODE_PLACED))
         return true;
      if(rc == TRADE_RETCODE_NO_CHANGES)
         return true;

      if(TP_Exec_Retriable(rc) && attempt == 1)
        {
         Sleep(100);
         continue;
        }

      g_stats.modifyFailures++;
      TP_LogWarn(StringFormat("SL modify of %I64u failed: %u (%s)", ticket, rc, result.comment));
      return false;
     }

   g_stats.modifyFailures++;
   return false;
  }

#endif // TP_EXECUTION_MQH
