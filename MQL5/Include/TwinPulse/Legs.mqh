//+------------------------------------------------------------------+
//|                                                   Legs.mqh        |
//|  TwinPulse Hedge EA                                                 |
//|  The heart of the EA: the four legs of a cycle, their targets,     |
//|  the re-balance rule of the owner and the cycle level exits.       |
//+------------------------------------------------------------------+
#ifndef TP_LEGS_MQH
#define TP_LEGS_MQH

#include "Config.mqh"
#include "Utils.mqh"
#include "Logger.mqh"
#include "State.mqh"
#include "Execution.mqh"
#include "Risk.mqh"
#include "Regime.mqh"
#include "Bank.mqh"

//--- forward declarations ---------------------------------------------
void TP_Legs_Update(void);
void TP_Legs_TryStartCycle(void);
void TP_Legs_TryRebalance(void);
void TP_Legs_CloseCycle(const string reason);
double TP_Legs_TargetDistance(const int legIndex);
bool   TP_Legs_RebalanceCondition(const bool sideMissing, const double survivorPnl, const double tolerance);

//+------------------------------------------------------------------+
//| TP_Legs_CostFloorOf - pure cost floor calculation                  |
//+------------------------------------------------------------------+
double TP_Legs_CostFloorOf(const double spread, const double point)
  {
   double floorDist = CostFloorSpreadMult * spread;
   if(floorDist < 3.0 * point) floorDist = 3.0 * point;
   return floorDist;
  }

//+------------------------------------------------------------------+
//| TP_Legs_CostFloor - minimal target distance imposed by the costs  |
//+------------------------------------------------------------------+
double TP_Legs_CostFloor(void)
  {
   return TP_Legs_CostFloorOf(TP_Exec_CurrentSpreadPrice(), g_point);
  }

//+------------------------------------------------------------------+
//| TP_Legs_TargetDistanceOf - pure target distance calculation       |
//|  Leg A : TargetA_ATR x ATR5, Leg B : TargetB_ATR x ATR5            |
//|  Both are lifted to at least the cost floor.                       |
//+------------------------------------------------------------------+
double TP_Legs_TargetDistanceOf(const double atr, const double spread, const double point, const bool isLegA)
  {
   if(atr <= 0.0) return 0.0;
   double dist = isLegA ? (TargetA_ATR * atr) : (TargetB_ATR * atr);
   double floorDist = TP_Legs_CostFloorOf(spread, point);
   if(dist < floorDist) dist = floorDist;
   return dist;
  }

//+------------------------------------------------------------------+
//| TP_Legs_TargetDistance - target distance of a leg in price units   |
//+------------------------------------------------------------------+
double TP_Legs_TargetDistance(const int legIndex)
  {
   double atr = g_tp.atr5;
   if(atr <= 0.0) atr = g_tp.atrM15;
   if(atr <= 0.0) return 0.0;

   bool isLegA = (TP_LegSlot(legIndex) == 0);
   return TP_Legs_TargetDistanceOf(atr, TP_Exec_CurrentSpreadPrice(), g_point, isLegA);
  }

//+------------------------------------------------------------------+
//| TP_Legs_StopDistance - hard stop distance of a leg in price units  |
//+------------------------------------------------------------------+
double TP_Legs_StopDistance(void)
  {
   double atr = g_tp.atr5;
   if(atr <= 0.0) atr = g_tp.atrM15;
   if(atr <= 0.0) return 0.0;

   double dist = HardSL_ATR * atr;
   double minDist = TP_Exec_StopDistance();
   if(dist < minDist) dist = minDist;
   return dist;
  }

//+------------------------------------------------------------------+
//| TP_Legs_ProfitDistance - how far the price moved in our favour    |
//+------------------------------------------------------------------+
double TP_Legs_ProfitDistance(const int legIndex)
  {
   if(!g_tp.legs[legIndex].open) return 0.0;

   MqlTick tick;
   if(!SymbolInfoTick(g_symbol, tick)) return 0.0;

   if(TP_LegIsBuy(legIndex))
      return (tick.bid - g_tp.legs[legIndex].openPrice);
   return (g_tp.legs[legIndex].openPrice - tick.ask);
  }

//+------------------------------------------------------------------+
//| TP_Legs_RebalanceCondition - pure re-balance test                 |
//|  The surviving side must be back at (or above) the tolerance.      |
//+------------------------------------------------------------------+
bool TP_Legs_RebalanceCondition(const bool sideMissing, const double survivorPnl, const double tolerance)
  {
   if(!sideMissing) return false;
   return (survivorPnl >= -MathAbs(tolerance));
  }

//+------------------------------------------------------------------+
//| TP_Legs_ReopenReference - the P/L that decides a re-open          |
//|  The surviving legs of the opposite side are the reference.        |
//+------------------------------------------------------------------+
double TP_Legs_ReopenReference(const int legIndex, double &refVolume)
  {
   int side = TP_LegIsBuy(legIndex) ? TP_SIDE_BUY : TP_SIDE_SELL;
   int opp  = (side == TP_SIDE_BUY) ? TP_SIDE_SELL : TP_SIDE_BUY;

   refVolume = 0.0;
   double oppVol = TP_State_OpenVolume(opp);
   if(oppVol > 0.0)
     {
      refVolume = oppVol;
      return TP_State_SideFloating(opp);
     }

   double sameVol = TP_State_OpenVolume(side);
   if(sameVol > 0.0)
     {
      refVolume = sameVol;
      return TP_State_SideFloating(side);
     }

   refVolume = TP_State_TotalVolume();
   return TP_State_AllFloating();
  }

//+------------------------------------------------------------------+
//| TP_Legs_ReopenAllowed - all conditions for a re-open               |
//+------------------------------------------------------------------+
bool TP_Legs_ReopenAllowed(const int legIndex, string &reason)
  {
   reason = "";

   //--- regime ------------------------------------------------------
   if(TP_UseRegime())
     {
      int regime = g_tp.regime;
      if(regime == TP_REG_CHAOS) { reason = "regime CHAOS"; return false; }
      if(regime == TP_REG_NEUTRAL) { reason = "regime NEUTRAL"; return false; }
      if((regime == TP_REG_TREND_UP || regime == TP_REG_TREND_DOWN))
        {
         bool up = (regime == TP_REG_TREND_UP);
         bool legBuy = TP_LegIsBuy(legIndex);
         if(TP_IsOneSide())
           {
            if(legBuy != up) { reason = "counter trend side in ONE_SIDE"; return false; }
           }
         else
           {
            // in a trend only the with-trend side is re-opened
            if(legBuy != up) { reason = "counter trend side"; return false; }
           }
        }
     }

   //--- session, spread, brakes -------------------------------------
   if(!TP_Risk_SessionOK(TimeCurrent(), false)) { reason = "session filter"; return false; }
   if(!TP_Risk_SpreadOK()) { reason = "spread too high"; return false; }
   if(g_tp.dailyLocked) { reason = "daily loss stop"; return false; }
   if(g_tp.basketLocked) { reason = "basket stop"; return false; }
   if(!TP_Risk_MarginLevelOK()) { reason = "margin level too low"; return false; }

   //--- cooldown -----------------------------------------------------
   if(g_tp.lastReopen > 0 && (TimeCurrent() - g_tp.lastReopen) < ReopenCooldownSec)
     { reason = "cooldown"; return false; }

   //--- the surviving side must be at break even ---------------------
   double refVolume = 0.0;
   double refPnl = TP_Legs_ReopenReference(legIndex, refVolume);
   double tol = TP_ScaledUSD(RebalanceTolUSD, refVolume);
   if(!TP_Legs_RebalanceCondition(true, refPnl, tol))
     { reason = StringFormat("survivor P/L %.2f below tolerance %.2f", refPnl, tol); return false; }

   //--- and the mirror leg of the same slot must be at break even ----
   int mirror = TP_LegMirror(legIndex);
   if(g_tp.legs[mirror].open)
     {
      double mtol = TP_ScaledUSD(RebalanceTolUSD, g_tp.legs[mirror].volume);
      if(g_tp.legs[mirror].profit < -mtol)
        { reason = StringFormat("mirror %s P/L %.2f below tolerance %.2f",
                                TP_LegName(mirror), g_tp.legs[mirror].profit, mtol); return false; }
     }

   return true;
  }

//+------------------------------------------------------------------+
//| TP_Legs_LotFor - volume of a leg                                   |
//+------------------------------------------------------------------+
double TP_Legs_LotFor(const int legIndex)
  {
   double vmin   = SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_MIN);
   double vmax   = SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_MAX);
   double vstep  = SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_STEP);
   double vlimit = SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_LIMIT);

   double lot = BaseLot;

   if(RiskMode == TP_RISK_PERCENT)
     {
      double equity  = AccountInfoDouble(ACCOUNT_EQUITY);
      double slDist  = TP_Legs_StopDistance();
      double perLot  = TP_TickMoneyPerUnit(g_symbol, 1.0);
      double riskUSD = equity * LegRiskPct / 100.0;
      if(slDist > 0.0 && perLot > 0.0)
         lot = TP_SafeDiv(riskUSD, slDist * perLot, BaseLot);
      else
         lot = BaseLot;
     }
   else
     {
      double mult = TP_EffectiveLotMultiplier();
      int gen = g_tp.legs[legIndex].generation;
      if(gen < 0) gen = 0;
      if(gen > 5) gen = 5;
      lot = BaseLot * MathPow(mult, gen);
     }

   return TP_NormalizeVolume(lot, vmin, vmax, vstep, vlimit);
  }

//+------------------------------------------------------------------+
//| TP_Legs_OpenOne - open one leg of the cycle                       |
//+------------------------------------------------------------------+
bool TP_Legs_OpenOne(const int legIndex, const bool isReopen)
  {
   double lot = TP_Legs_LotFor(legIndex);

   string reason = "";
   if(!TP_Risk_AllowsOpen(lot, reason))
     {
      TP_LogInfo(StringFormat("%s not opened: %s", TP_LegName(legIndex), reason));
      return false;
     }

   MqlTick tick;
   if(!SymbolInfoTick(g_symbol, tick)) return false;

   bool isBuy = TP_LegIsBuy(legIndex);
   double price = isBuy ? tick.ask : tick.bid;
   double stopDist = TP_Legs_StopDistance();
   if(stopDist <= 0.0)
     {
      TP_LogWarn(StringFormat("%s not opened: no ATR for the stop loss.", TP_LegName(legIndex)));
      return false;
     }

   double sl = isBuy ? (price - stopDist) : (price + stopDist);
   sl = TP_Exec_NormalizePrice(sl);

   if(!TP_Exec_OpenLeg(legIndex, lot, sl, 0.0, g_tp.cycleId))
      return false;

   g_tp.openedLegs++;
   if(isReopen)
     {
      g_tp.legs[legIndex].generation++;
      g_tp.lastReopen = TimeCurrent();
     }
   else
      g_tp.lastOpen = TimeCurrent();

   g_tp.legs[legIndex].used = true;
   return true;
  }

//+------------------------------------------------------------------+
//| TP_Legs_RegisterClose - book the realised money of a closed leg   |
//+------------------------------------------------------------------+
void TP_Legs_RegisterClose(const int legIndex, const string reason, const double closePrice)
  {
   ulong posId = g_tp.legs[legIndex].positionId;
   double price = closePrice;
   double cumulative = TP_State_RealizedForPosition(posId, g_tp.legs[legIndex].openTime, price);
   double delta = cumulative - g_tp.legs[legIndex].realized;
   g_tp.legs[legIndex].realized = cumulative;
   TP_Bank_Add(delta);

   g_tp.closedLegs++;
   g_tp.legs[legIndex].wasOpen = false;

   TP_LogLegCSV(legIndex, g_tp.cycleId, g_tp.legs[legIndex].volume,
                g_tp.legs[legIndex].openPrice, price, delta, reason,
                g_tp.bank, TP_RegimeName(g_tp.regime),
                TP_Exec_CurrentSpreadPrice(), g_tp.atr5);
  }

//+------------------------------------------------------------------+
//| TP_Legs_DetectClosedLegs - find legs that disappeared between two |
//| synchronisations (stop loss, take profit or a manual close) and   |
//| book their realised money.                                        |
//+------------------------------------------------------------------+
void TP_Legs_DetectClosedLegs(void)
  {
   for(int i = 0; i < TP_LEG_COUNT; i++)
     {
      if(g_tp.legs[i].wasOpen && !g_tp.legs[i].open)
        {
         TP_LogInfo(StringFormat("%s was closed by the server.", TP_LegName(i)));
         TP_Legs_RegisterClose(i, "server_close", 0.0);
        }
      g_tp.legs[i].wasOpen = g_tp.legs[i].open;
     }
  }

//+------------------------------------------------------------------+
//| TP_Legs_CloseWinner - close a leg that reached its target          |
//|  When the opposite leg of the same slot shows a positive combined |
//|  result the pair is closed with Close By, that saves one spread.   |
//+------------------------------------------------------------------+
void TP_Legs_CloseWinner(const int legIndex)
  {
   int mirror = TP_LegMirror(legIndex);
   ulong ticket = g_tp.legs[legIndex].ticket;

   if(g_tp.legs[mirror].open)
     {
      double v1 = g_tp.legs[legIndex].volume;
      double v2 = g_tp.legs[mirror].volume;
      double combined = g_tp.legs[legIndex].profit + g_tp.legs[mirror].profit;
      double need = TP_ScaledUSD(MinBankUSD, v1);

      if(MathAbs(v1 - v2) < 1e-8 && combined >= need)
        {
         TP_LogInfo(StringFormat("Close By: %s and %s, combined %.2f >= %.2f",
                                 TP_LegName(legIndex), TP_LegName(mirror), combined, need));
         if(TP_Exec_CloseBy(ticket, g_tp.legs[mirror].ticket))
           {
            TP_Legs_RegisterClose(legIndex, "closeby_winner", 0.0);
            TP_Legs_RegisterClose(mirror, "closeby_loser", 0.0);
            return;
           }
         TP_LogWarn("Close By failed, the winner is closed alone.");
        }
     }

   if(TP_Exec_CloseLeg(ticket))
      TP_Legs_RegisterClose(legIndex, "target", 0.0);
  }

//+------------------------------------------------------------------+
//| TP_Legs_ManageRunner - break even and trailing of the leg B        |
//+------------------------------------------------------------------+
void TP_Legs_ManageRunner(const int legIndex)
  {
   if(!g_tp.legs[legIndex].open) return;

   bool isBuy = TP_LegIsBuy(legIndex);
   double atr = g_tp.atr5;
   if(atr <= 0.0) return;

   MqlTick tick;
   if(!SymbolInfoTick(g_symbol, tick)) return;

   double entry = g_tp.legs[legIndex].openPrice;
   double spread = TP_Exec_CurrentSpreadPrice();

   //--- track the best price -----------------------------------------
   double best = g_tp.legs[legIndex].peakPrice;
   if(best <= 0.0) best = isBuy ? tick.bid : tick.ask;
   if(isBuy)
     {
      if(tick.bid > best) best = tick.bid;
     }
   else
     {
      if(tick.ask < best) best = tick.ask;
     }
   g_tp.legs[legIndex].peakPrice = best;

   double newSl = g_tp.legs[legIndex].sl;
   double currentSl = g_tp.legs[legIndex].sl;

   //--- break even ----------------------------------------------------
   double beDist = BE_ATR * atr;
   double moved = isBuy ? (tick.bid - entry) : (entry - tick.ask);
   if(!g_tp.legs[legIndex].beDone && moved >= beDist)
     {
      double beSl = isBuy ? (entry + spread) : (entry - spread);
      if(currentSl <= 0.0 || (isBuy && beSl > currentSl) || (!isBuy && (beSl < currentSl || currentSl <= 0.0)))
        {
         newSl = TP_Exec_NormalizePrice(beSl);
         g_tp.legs[legIndex].beDone = true;
         TP_LogInfo(StringFormat("%s: break even stop moved to %s", TP_LegName(legIndex),
                                 TP_Str(newSl, g_digits)));
        }
     }

   //--- trailing ------------------------------------------------------
   double trailDist = Trail_ATR * atr;
   double trailSl = isBuy ? (best - trailDist) : (best + trailDist);
   if(g_tp.legs[legIndex].beDone)
     {
      if(currentSl <= 0.0 || (isBuy && trailSl > currentSl) || (!isBuy && trailSl < currentSl))
         newSl = TP_Exec_NormalizePrice(trailSl);
     }

   if(newSl <= 0.0) return;
   if(currentSl > 0.0)
     {
      if(isBuy && newSl <= currentSl) return;      // never widen
      if(!isBuy && newSl >= currentSl) return;
     }

   //--- throttle: at most one stop modification every two seconds ----
   if(g_tp.legs[legIndex].lastModify > 0 &&
      (TimeCurrent() - g_tp.legs[legIndex].lastModify) < 2)
      return;

   if(TP_Exec_ModifySL(g_tp.legs[legIndex].ticket, newSl, g_tp.legs[legIndex].tp))
     {
      g_tp.legs[legIndex].sl = newSl;
      g_tp.legs[legIndex].lastModify = TimeCurrent();
     }
  }

//+------------------------------------------------------------------+
//| TP_Legs_Update - per tick management of the open legs              |
//+------------------------------------------------------------------+
void TP_Legs_Update(void)
  {
   for(int i = 0; i < TP_LEG_COUNT; i++)
     {
      if(!g_tp.legs[i].open) continue;

      //--- time stop --------------------------------------------------
      int age = TP_Risk_LegAgeMinutes(i);
      if(age > MaxLoserMinutes && g_tp.legs[i].profit < 0.0)
        {
         if(!TP_Bank_TryShred())
           {
            TP_LogInfo(StringFormat("Time stop: %s is %.0f minutes old, closing it.", TP_LegName(i), age));
            if(TP_Exec_CloseLeg(g_tp.legs[i].ticket))
               TP_Legs_RegisterClose(i, "time_stop", 0.0);
           }
         continue;
        }

      //--- target ------------------------------------------------------
      double target = TP_Legs_TargetDistance(i);
      if(target > 0.0)
        {
         double moved = TP_Legs_ProfitDistance(i);
         if(moved >= target)
           {
            TP_LogInfo(StringFormat("%s reached its target (%.3f of %.3f), profit %.2f",
                                    TP_LegName(i), moved, target, g_tp.legs[i].profit));
            TP_Legs_CloseWinner(i);
            continue;
           }
        }

      //--- runner management -----------------------------------------
      if(TP_LegSlot(i) == 1)
         TP_Legs_ManageRunner(i);
     }
  }

//+------------------------------------------------------------------+
//| TP_Legs_TryStartCycle - open a new cycle of four legs              |
//+------------------------------------------------------------------+
void TP_Legs_TryStartCycle(void)
  {
   if(TP_State_OpenLegCount() > 0) return;
   if(g_tp.dailyLocked || g_tp.basketLocked) return;
   if(!g_tp.tradeAllowed) return;
   if(RiskMode == TP_RISK_OFF) return;

   if(!TP_Risk_SessionOK(TimeCurrent(), true)) return;
   if(!TP_Risk_SpreadOK()) return;
   if(!TP_Risk_MarginLevelOK()) return;
   if(g_tp.atr5 <= 0.0 || g_tp.atrM15 <= 0.0) return;

   int regime = g_tp.regime;
   bool onlyBuy = false;
   bool onlySell = false;

   if(TP_UseRegime())
     {
      if(regime == TP_REG_CHAOS) return;
      if(TP_IsOneSide())
        {
         if(regime != TP_REG_TREND_UP && regime != TP_REG_TREND_DOWN) return;
         onlyBuy  = (regime == TP_REG_TREND_UP);
         onlySell = (regime == TP_REG_TREND_DOWN);
        }
      else if(!TP_IsPureIdea())
        {
         if(regime != TP_REG_RANGE) return;
        }
     }

   //--- the price must be close to the Bollinger middle line ---------
   double mid = g_tp.regimeBbMid;
   if(mid > 0.0)
     {
      MqlTick tick;
      if(!SymbolInfoTick(g_symbol, tick)) return;
      double price = (tick.ask + tick.bid) * 0.5;
      double maxDist = BBRangeATR * g_tp.atrM15;
      if(MathAbs(price - mid) > maxDist) return;
     }

   //--- start the cycle ------------------------------------------------
   g_tp.cycleId++;
   if(g_tp.cycleId < 1) g_tp.cycleId = 1;
   g_tp.cycleStart   = TimeCurrent();
   g_tp.cycleRegime  = regime;
   g_tp.bank         = 0.0;
   g_tp.cycleRealized= 0.0;
   g_tp.cycleShredded= 0.0;
   g_tp.closedLegs   = 0;
   g_tp.openedLegs   = 0;
   g_tp.lastReopen   = TimeCurrent();

   for(int i = 0; i < TP_LEG_COUNT; i++)
     {
      g_tp.legs[i].used       = false;
      g_tp.legs[i].generation = 0;
      g_tp.legs[i].beDone     = false;
      g_tp.legs[i].realized   = 0.0;
      g_tp.legs[i].peakPrice  = 0.0;
     }

   int opened = 0;
   for(int i = 0; i < TP_LEG_COUNT; i++)
     {
      if(onlyBuy  && !TP_LegIsBuy(i))  continue;
      if(onlySell && TP_LegIsBuy(i))   continue;
      if(TP_Legs_OpenOne(i, false)) opened++;
     }

   TP_State_SyncPositions();
   TP_State_Save();

   if(opened == 0)
     {
      TP_LogWarn("Cycle start aborted, no leg could be opened.");
      g_tp.cycleId--;
      return;
     }

   TP_LogInfo(StringFormat("Cycle %d started: %d legs, regime %s, ATR5 %.3f, spread %.3f",
                           g_tp.cycleId, opened, TP_RegimeName(regime),
                           g_tp.atr5, TP_Exec_CurrentSpreadPrice()));
  }

//+------------------------------------------------------------------+
//| TP_Legs_TryRebalance - re-open the legs that are missing           |
//+------------------------------------------------------------------+
void TP_Legs_TryRebalance(void)
  {
   if(TP_State_OpenLegCount() == 0) return;

   int openBuy  = TP_State_CountOpenLegs(TP_SIDE_BUY);
   int openSell = TP_State_CountOpenLegs(TP_SIDE_SELL);
   int wanted   = g_legsPerSide;

   bool sideMissing = (openBuy < wanted) || (openSell < wanted);
   if(!sideMissing) return;

   for(int i = 0; i < TP_LEG_COUNT; i++)
     {
      if(g_tp.legs[i].open) continue;
      if(!g_tp.legs[i].used) continue;         // never opened in this cycle

      string reason = "";
      if(!TP_Legs_ReopenAllowed(i, reason))
        {
         TP_LogInfo(StringFormat("%s not re-opened: %s", TP_LegName(i), reason));
         continue;
        }

      TP_LogInfo(StringFormat("%s is re-opened to balance the cycle.", TP_LegName(i)));
      TP_Legs_OpenOne(i, true);
      TP_State_SyncPositions();
     }
  }

//+------------------------------------------------------------------+
//| TP_Legs_CloseCycle - close every leg of the running cycle          |
//+------------------------------------------------------------------+
void TP_Legs_CloseCycle(const string reason)
  {
   int openCount = TP_State_OpenLegCount();
   if(openCount == 0)
     {
      g_tp.bank = 0.0;
      g_tp.cycleRealized = 0.0;
      return;
     }

   TP_LogInfo(StringFormat("Closing the cycle %d (%d legs), reason: %s",
                           g_tp.cycleId, openCount, reason));

   //--- first close the pairs with Close By ---------------------------
   for(int slot = 0; slot < TP_SLOT_COUNT; slot++)
     {
      int buyLeg  = (slot == 0) ? TP_LEG_BUY_A  : TP_LEG_BUY_B;
      int sellLeg = (slot == 0) ? TP_LEG_SELL_A : TP_LEG_SELL_B;
      if(!g_tp.legs[buyLeg].open || !g_tp.legs[sellLeg].open) continue;
      if(MathAbs(g_tp.legs[buyLeg].volume - g_tp.legs[sellLeg].volume) > 1e-8) continue;

      if(TP_Exec_CloseBy(g_tp.legs[buyLeg].ticket, g_tp.legs[sellLeg].ticket))
        {
         TP_Legs_RegisterClose(buyLeg,  "cycle_closeby", 0.0);
         TP_Legs_RegisterClose(sellLeg, "cycle_closeby", 0.0);
        }
     }

   //--- then close whatever is left -----------------------------------
   for(int i = 0; i < TP_LEG_COUNT; i++)
     {
      if(!g_tp.legs[i].open) continue;
      if(TP_Exec_CloseLeg(g_tp.legs[i].ticket))
         TP_Legs_RegisterClose(i, "cycle_close", 0.0);
     }

   TP_State_SyncPositions();

   TP_LogCycleCSV(g_tp.cycleId, g_tp.cycleStart, TimeCurrent(), TP_RegimeName(g_tp.cycleRegime),
                  g_tp.openedLegs, g_tp.closedLegs, g_tp.cycleRealized, g_tp.bank,
                  g_tp.cycleShredded, reason, TP_Exec_CurrentSpreadPrice(), g_tp.atr5);

   g_tp.bank          = 0.0;
   g_tp.cycleRealized = 0.0;
   g_tp.cycleShredded = 0.0;
   g_tp.openedLegs    = 0;
   g_tp.closedLegs    = 0;
   TP_State_Save();
  }

#endif // TP_LEGS_MQH
