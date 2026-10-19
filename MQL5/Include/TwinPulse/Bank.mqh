//+------------------------------------------------------------------+
//|                                                   Bank.mqh        |
//|  TwinPulse Hedge EA                                                 |
//|  Profit bank and loss shredding.                                   |
//|                                                                   |
//|  Bank  : realised money of the running cycle that is not used up  |
//|  Shred : use the bank to remove one volume step of the oldest     |
//|          losing leg, so the counter trend leg dies with a small   |
//|          controlled loss instead of running into the hard stop.    |
//+------------------------------------------------------------------+
#ifndef TP_BANK_MQH
#define TP_BANK_MQH

#include "Config.mqh"
#include "Utils.mqh"
#include "Logger.mqh"
#include "State.mqh"
#include "Execution.mqh"

//--- forward declaration, implemented in Legs.mqh (which includes this
//--- file): a full shred books the closed leg exactly once -----------
void TP_Legs_RegisterClose(const int legIndex, const string reason, const double closePrice);

//+------------------------------------------------------------------+
//| TP_Bank_ShredCost - bank needed to shred one step                 |
//|  (the loss of the step plus the cost of the spread)                |
//+------------------------------------------------------------------+
double TP_Bank_ShredCost(const double lossOfStep, const double spreadCost)
  {
   return MathAbs(lossOfStep) + MathAbs(spreadCost);
  }

//+------------------------------------------------------------------+
//| TP_Bank_CanShred - pure test, is the bank big enough?              |
//+------------------------------------------------------------------+
bool TP_Bank_CanShred(const double bank, const double lossOfStep, const double spreadCost)
  {
   if(bank <= 0.0) return false;
   return TP_MoneyGE(bank, TP_Bank_ShredCost(lossOfStep, spreadCost));
  }

//+------------------------------------------------------------------+
//| TP_Bank_AfterShred - bank remaining after the shred                |
//+------------------------------------------------------------------+
double TP_Bank_AfterShred(const double bank, const double lossOfStep, const double spreadCost)
  {
   double remaining = bank - TP_Bank_ShredCost(lossOfStep, spreadCost);
   if(TP_MoneyNearZero(remaining)) return 0.0;
   return remaining;
  }

//+------------------------------------------------------------------+
//| TP_Bank_Add - add realised money to the bank and to the cycle     |
//+------------------------------------------------------------------+
void TP_Bank_Add(const double amount)
  {
   g_tp.bank          += amount;
   g_tp.cycleRealized += amount;
  }

//+------------------------------------------------------------------+
//| TP_Bank_FindOldestLoser - index of the oldest losing open leg      |
//+------------------------------------------------------------------+
bool TP_Bank_FindOldestLoser(int &legIndex)
  {
   legIndex = -1;
   datetime oldest = 0;
   for(int i = 0; i < TP_LEG_COUNT; i++)
     {
      if(!g_tp.legs[i].open) continue;
      if(TP_MoneyGE(g_tp.legs[i].profit, 0.0)) continue;
      if(legIndex < 0 || g_tp.legs[i].openTime < oldest)
        {
         legIndex = i;
         oldest   = g_tp.legs[i].openTime;
        }
     }
   return (legIndex >= 0);
  }

//+------------------------------------------------------------------+
//| TP_Bank_TryShred - close one volume step of the oldest loser      |
//|  when the bank covers it.                                          |
//+------------------------------------------------------------------+
bool TP_Bank_TryShred(void)
  {
   if(!TP_UseBank()) return false;
   if(g_tp.bank <= 0.0) return false;

   int leg = -1;
   if(!TP_Bank_FindOldestLoser(leg)) return false;

   double vol    = g_tp.legs[leg].volume;
   double spread = TP_Exec_CurrentSpreadPrice();
   if(vol <= 0.0) return false;

   double vmin = SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_MIN);
   double step = ShredStepLot;
   if(step <= 0.0) step = 0.01;
   if(step > vol) step = vol;

   double lossOfStep = MathAbs(g_tp.legs[leg].profit) * (step / vol);
   double spreadCost = TP_PriceToMoney(g_symbol, step, spread);

   //--- would the rest of the leg become too small? -------------------
   double rest = vol - step;
   if(rest < vmin - 1e-8)
     {
      double fullLoss    = MathAbs(g_tp.legs[leg].profit);
      double fullSpread  = TP_PriceToMoney(g_symbol, vol, spread);
      if(!TP_Bank_CanShred(g_tp.bank, fullLoss, fullSpread))
        {
         //--- the timer tries again every second: the same block reason
         //--- is logged once until the leg state changes -------------
         if(TP_DedupShouldLog(g_tp.legs[leg].lastReason, "shred skipped: bank does not cover the full leg loss"))
            TP_LogInfo(StringFormat("Shred skipped on %s: bank %.2f does not cover the full leg loss %.2f",
                                    TP_LegName(leg), g_tp.bank, TP_Bank_ShredCost(fullLoss, fullSpread)));
         return false;
        }
     }
   else if(!TP_Bank_CanShred(g_tp.bank, lossOfStep, spreadCost))
      return false;

   //--- perform the shred --------------------------------------------
   ulong  ticket   = g_tp.legs[leg].ticket;
   ulong  positionId = g_tp.legs[leg].positionId;
   double bankBefore = g_tp.bank;
   datetime started = TimeCurrent();

   bool ok = false;
   if(rest < vmin - 1e-8)
     {
      TP_LogInfo(StringFormat("Shredding the whole leg %s (%.2f lots), the rest would be below the minimum volume.",
                              TP_LegName(leg), vol));
      ok = (TP_Exec_CloseLeg(ticket) == TP_CLOSE_OK);
     }
   else
     {
      TP_LogInfo(StringFormat("Shredding %.2f lots of %s, loss %.2f, bank %.2f",
                              step, TP_LegName(leg), lossOfStep, bankBefore));
      ok = (TP_Exec_PartialClose(ticket, step) == TP_CLOSE_OK);
     }
   if(!ok) return false;

   double closePrice = 0.0;
   double realised   = TP_State_RealizedForPosition(positionId, started, closePrice);
   TP_Bank_Add(realised);
   g_tp.legs[leg].realized += realised;
   g_tp.cycleShredded += MathMax(0.0, -realised);
   g_tp.legs[leg].lastReason = "";   // the state changed, a later block logs again

   //--- a full shred closes the leg: exactly one legs.csv row with the
   //--- real exit reason "shred" (the realised money is already booked
   //--- above, RegisterClose only adds the remaining delta ~= 0) -----
   if(rest < vmin - 1e-8)
      TP_Legs_RegisterClose(leg, "shred", closePrice);

   TP_LogInfo(StringFormat("Shred done on %s: realised %.2f, bank %.2f -> %.2f, shredded total %.2f",
                           TP_LegName(leg), realised, bankBefore, g_tp.bank, g_tp.cycleShredded));
   TP_State_Save();
   return true;
  }

#endif // TP_BANK_MQH
