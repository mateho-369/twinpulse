//+------------------------------------------------------------------+
//|                                     TwinPulseSelfTest.mq5        |
//|                                                                  |
//|  Pure function tests of the TwinPulse Hedge EA.                   |
//|  Run this script on any chart, every line must print PASS.        |
//|  It never opens a position and never changes the account. It      |
//|  writes one small temporary file to Common\Files and deletes it.  |
//+------------------------------------------------------------------+
#property copyright "TwinPulse Hedge EA"
#property version   "1.00"
#property description "Self test of the pure functions of the TwinPulse Hedge EA."

#include <TwinPulse/Config.mqh>
#include <TwinPulse/Utils.mqh>
#include <TwinPulse/Logger.mqh>
#include <TwinPulse/State.mqh>
#include <TwinPulse/News.mqh>
#include <TwinPulse/Execution.mqh>
#include <TwinPulse/Risk.mqh>
#include <TwinPulse/Regime.mqh>
#include <TwinPulse/Bank.mqh>
#include <TwinPulse/Legs.mqh>

//--- test counters ----------------------------------------------------
int g_passed = 0;
int g_failed = 0;

//+------------------------------------------------------------------+
//| TP_Check - compare a boolean result                                |
//+------------------------------------------------------------------+
void TP_Check(const string name, const bool ok)
  {
   if(ok)
     {
      g_passed++;
      Print("PASS  ", name);
     }
   else
     {
      g_failed++;
      Print("FAIL  ", name);
     }
  }

//+------------------------------------------------------------------+
//| TP_CheckEq - compare two doubles with a tolerance                 |
//+------------------------------------------------------------------+
void TP_CheckEq(const string name, const double actual, const double expected, const double eps)
  {
   bool ok = (MathAbs(actual - expected) <= eps);
   if(ok)
     {
      g_passed++;
      Print(StringFormat("PASS  %s (%.6f)", name, actual));
     }
   else
     {
      g_failed++;
      Print(StringFormat("FAIL  %s (got %.6f, expected %.6f)", name, actual, expected));
     }
  }

//+------------------------------------------------------------------+
//| Test 1 - lot normalisation                                        |
//+------------------------------------------------------------------+
void Test_Lots(void)
  {
   Print("--- lot normalisation ---");
   TP_CheckEq("lot 0.010 stays 0.01",
              TP_NormalizeVolume(0.01, 0.01, 10.0, 0.01, 0.0), 0.01, 1e-8);
   TP_CheckEq("lot 0.011 snaps down to the step",
              TP_NormalizeVolume(0.011, 0.01, 10.0, 0.01, 0.0), 0.01, 1e-8);
   TP_CheckEq("lot 0.015 snaps to 0.02",
              TP_NormalizeVolume(0.015, 0.01, 10.0, 0.01, 0.0), 0.02, 1e-8);
   TP_CheckEq("lot below the minimum is lifted",
              TP_NormalizeVolume(0.004, 0.01, 10.0, 0.01, 0.0), 0.01, 1e-8);
   TP_CheckEq("lot above the maximum is cut",
              TP_NormalizeVolume(100.0, 0.01, 5.0, 0.01, 0.0), 5.00, 1e-8);
   TP_CheckEq("the volume limit is respected",
              TP_NormalizeVolume(0.02, 0.01, 10.0, 0.01, 0.01), 0.01, 1e-8);
   TP_CheckEq("a zero volume stays zero",
              TP_NormalizeVolume(0.0, 0.01, 10.0, 0.01, 0.0), 0.0, 1e-8);
  }

//+------------------------------------------------------------------+
//| Test 2 - the cost floor and the target distances                  |
//+------------------------------------------------------------------+
void Test_CostFloor(void)
  {
   Print("--- cost floor and targets ---");
   TP_CheckEq("cost floor is 3 x spread",
              TP_Legs_CostFloorOf(0.20, 0.001), 0.60, 1e-8);
   TP_CheckEq("cost floor has a minimum of 3 points",
              TP_Legs_CostFloorOf(0.0, 0.001), 0.003, 1e-8);
   TP_CheckEq("leg A target uses the floor when the ATR is small",
              TP_Legs_TargetDistanceOf(0.35, 0.20, 0.001, true), 0.60, 1e-8);
   TP_CheckEq("leg A target uses the ATR when it is large",
              TP_Legs_TargetDistanceOf(2.00, 0.20, 0.001, true), 1.20, 1e-8);
   TP_CheckEq("leg B target uses the ATR",
              TP_Legs_TargetDistanceOf(2.00, 0.20, 0.001, false), 3.00, 1e-8);
   TP_CheckEq("leg B target respects the floor",
              TP_Legs_TargetDistanceOf(0.10, 0.20, 0.001, false), 0.60, 1e-8);
  }

//+------------------------------------------------------------------+
//| Test 3 - efficiency ratio and choppiness on synthetic data         |
//+------------------------------------------------------------------+
void Test_Indicators(void)
  {
   Print("--- efficiency ratio and choppiness ---");

   //--- a perfect uptrend: ER must be 1.0 ---------------------------
   double trend[];
   ArrayResize(trend, 25);
   for(int i = 0; i < 25; i++) trend[i] = 2000.0 + i * 1.0;
   TP_CheckEq("efficiency ratio of a perfect trend is 1.0",
              TP_ComputeER(trend, 25, 20), 1.0, 1e-6);

   //--- a perfect round trip: ER must be 0.0 ------------------------
   double roundTrip[];
   ArrayResize(roundTrip, 25);
   for(int i = 0; i < 25; i++) roundTrip[i] = 2000.0 + (i % 2);
   TP_Check("efficiency ratio of a round trip is below 0.1",
            TP_ComputeER(roundTrip, 25, 20) < 0.1);

   //--- a flat series must not divide by zero -----------------------
   double flat[];
   ArrayResize(flat, 25);
   ArrayInitialize(flat, 2000.0);
   TP_CheckEq("efficiency ratio of a flat series is 0.0",
              TP_ComputeER(flat, 25, 20), 0.0, 1e-8);

   //--- choppiness: a trend is not choppy ---------------------------
   double hi[], lo[], cl[];
   ArrayResize(hi, 25); ArrayResize(lo, 25); ArrayResize(cl, 25);
   for(int i = 0; i < 25; i++)
     {
      double mid = 2000.0 + i * 1.0;
      hi[i] = mid + 0.10;
      lo[i] = mid - 0.10;
      cl[i] = mid;
     }
   double chopTrend = TP_ComputeCHOP(hi, lo, cl, 25, 20);
   TP_Check("choppiness of a trend is below 50", chopTrend < 50.0);

   //--- choppiness: a sideways market is choppy ---------------------
   for(int i = 0; i < 25; i++)
     {
      double mid = 2000.0 + (i % 2) * 1.0;
      hi[i] = mid + 0.60;
      lo[i] = mid - 0.60;
      cl[i] = mid;
     }
   double chopSide = TP_ComputeCHOP(hi, lo, cl, 25, 20);
   TP_Check("choppiness of a sideways market is above 50", chopSide > 50.0);
  }

//+------------------------------------------------------------------+
//| Test 4 - regime classification                                     |
//+------------------------------------------------------------------+
void Test_Regime(void)
  {
   Print("--- regime classification ---");
   const double erRange = 0.30, chopRange = 55.0, adxRange = 22.0;
   const double erTrend = 0.40, adxTrend = 28.0;

   TP_Check("quiet market is RANGE",
            TP_ClassifyRegime(0.10, 70.0, 15.0, 0.0, true, false, false, false,
                              erRange, chopRange, adxRange, erTrend, adxTrend) == TP_REG_RANGE);
   TP_Check("strong uptrend is TREND_UP",
            TP_ClassifyRegime(0.60, 30.0, 35.0, 1.0, true, false, false, false,
                              erRange, chopRange, adxRange, erTrend, adxTrend) == TP_REG_TREND_UP);
   TP_Check("strong downtrend is TREND_DOWN",
            TP_ClassifyRegime(0.60, 30.0, 35.0, -1.0, false, false, false, false,
                              erRange, chopRange, adxRange, erTrend, adxTrend) == TP_REG_TREND_DOWN);
   TP_Check("a trend against the H1 EMA stays NEUTRAL",
            TP_ClassifyRegime(0.60, 30.0, 35.0, 1.0, false, false, false, false,
                              erRange, chopRange, adxRange, erTrend, adxTrend) == TP_REG_NEUTRAL);
   TP_Check("a mixed market is NEUTRAL",
            TP_ClassifyRegime(0.20, 40.0, 20.0, 0.0, true, false, false, false,
                              erRange, chopRange, adxRange, erTrend, adxTrend) == TP_REG_NEUTRAL);
   TP_Check("an ATR spike is CHAOS",
            TP_ClassifyRegime(0.10, 70.0, 15.0, 0.0, true, true, false, false,
                              erRange, chopRange, adxRange, erTrend, adxTrend) == TP_REG_CHAOS);
   TP_Check("a news block is CHAOS",
            TP_ClassifyRegime(0.10, 70.0, 15.0, 0.0, true, false, true, false,
                              erRange, chopRange, adxRange, erTrend, adxTrend) == TP_REG_CHAOS);
   TP_Check("a spread spike is CHAOS",
            TP_ClassifyRegime(0.10, 70.0, 15.0, 0.0, true, false, false, true,
                              erRange, chopRange, adxRange, erTrend, adxTrend) == TP_REG_CHAOS);
  }

//+------------------------------------------------------------------+
//| Test 5 - bank and shred math                                       |
//+------------------------------------------------------------------+
void Test_Bank(void)
  {
   Print("--- bank and shred ---");
   TP_CheckEq("the shred cost is the loss plus the spread",
              TP_Bank_ShredCost(0.10, 0.20), 0.30, 1e-8);
   TP_Check("money greater-or-equal accepts decimal equality",
            TP_MoneyGE(0.30, 0.10 + 0.20));
   TP_Check("money less-or-equal accepts decimal equality",
            TP_MoneyLE(0.10 + 0.20, 0.30));
   TP_Check("a sub-epsilon negative balance is treated as zero",
            TP_MoneyGE(-TP_MONEY_EPSILON * 0.5, 0.0));
   TP_Check("a full bank can shred", TP_Bank_CanShred(0.30, 0.10, 0.20));
   TP_Check("bank equality accepts the floating-point cost boundary",
            TP_Bank_CanShred(0.30, 0.10, 0.20));
   TP_Check("a short bank cannot shred", !TP_Bank_CanShred(0.29, 0.10, 0.20));
   TP_Check("an empty bank cannot shred", !TP_Bank_CanShred(0.0, 0.10, 0.20));
   TP_CheckEq("the bank after the shred",
              TP_Bank_AfterShred(0.30, 0.10, 0.20), 0.0, 1e-8);
   TP_Check("an exact bank boundary leaves exactly zero after shredding",
            TP_Bank_AfterShred(0.30, 0.10, 0.20) == 0.0);
   TP_CheckEq("the thresholds scale with the volume",
              TP_ScaledUSD(0.10, 0.02), 0.20, 1e-8);
   TP_CheckEq("the thresholds scale with the volume, 4 legs",
              TP_ScaledUSD(CycleTargetUSD, 0.04), 8.00, 1e-8);
  }

//+------------------------------------------------------------------+
//| Test 6 - the re-balance condition                                  |
//+------------------------------------------------------------------+
void Test_Rebalance(void)
  {
   Print("--- re-balance condition ---");
   TP_Check("a side that is not missing is never re-opened",
            !TP_Legs_RebalanceCondition(false, 10.0, 0.10));
   TP_Check("a survivor at break even allows the re-open",
            TP_Legs_RebalanceCondition(true, -0.05, 0.10));
   TP_Check("a survivor exactly at the tolerance allows the re-open",
            TP_Legs_RebalanceCondition(true, -0.10, 0.10));
   TP_Check("a survivor within money epsilon of the tolerance allows the re-open",
            TP_Legs_RebalanceCondition(true, -0.10 - 5.0e-10, 0.10));
   TP_Check("a survivor below the tolerance blocks the re-open",
            !TP_Legs_RebalanceCondition(true, -0.11, 0.10));
   TP_Check("a survivor in profit allows the re-open",
            TP_Legs_RebalanceCondition(true, 0.50, 0.10));
  }

//+------------------------------------------------------------------+
//| Test 7 - the time filters                                          |
//+------------------------------------------------------------------+
void Test_TimeFilters(void)
  {
   Print("--- time filters ---");
   // 2024.01.10 is a Wednesday, 2024.01.12 a Friday, 2024.01.13 a Saturday
   datetime wednesday = StringToTime("2024.01.10 12:00");
   datetime wednesdayNight = StringToTime("2024.01.10 22:00");
   datetime friday = StringToTime("2024.01.12 19:00");
   datetime fridayLate = StringToTime("2024.01.12 21:30");
   datetime saturday = StringToTime("2024.01.13 10:00");

   TP_Check("a Wednesday at noon allows a new cycle",
            TP_Risk_SessionFilter(wednesday, 0, 21, 21, 24, 20, true));
   TP_Check("a Wednesday at 22:00 is inside the rollover block",
            !TP_Risk_SessionFilter(wednesdayNight, 0, 21, 21, 24, 20, false));
   TP_Check("a Friday at 19:00 still allows a new cycle",
            TP_Risk_SessionFilter(friday, 0, 21, 21, 24, 20, true));
   TP_Check("a Friday at 21:30 is blocked",
            !TP_Risk_SessionFilter(fridayLate, 0, 21, 21, 24, 20, false));
   TP_Check("Saturday is blocked", !TP_Risk_SessionFilter(saturday, 0, 21, 21, 24, 20, false));
   TP_Check("the session start blocks a time before its boundary",
            !TP_Risk_SessionFilter(wednesday, 13, 21, 21, 24, 20, true));
   TP_Check("the session start boundary itself is allowed",
            TP_Risk_SessionFilter(wednesday, 12, 21, 21, 24, 20, true));

   //--- the rollover flatten window (FlattenBeforeRollover) ---------
   datetime beforeFlatten = StringToTime("2024.01.10 20:49");
   datetime earlyEvening  = StringToTime("2024.01.10 20:50");
   TP_Check("20:49 is outside the pre-rollover window",
            !TP_Risk_InRolloverBlock(beforeFlatten, 10, 21, 24));
   TP_Check("20:50 is inside the pre-rollover window (10 min before 21:00)",
            TP_Risk_InRolloverBlock(earlyEvening, 10, 21, 24));
   TP_Check("21:30 stays blocked by the base rollover window",
            TP_Risk_InRolloverBlock(StringToTime("2024.01.10 21:30"), 10, 21, 24));
   TP_Check("without minutes the block starts at the rollover hour",
            !TP_Risk_InRolloverBlock(earlyEvening, 0, 21, 24));
   TP_Check("the session filter blocks a re-open at 20:50 when the flatten is armed",
            !TP_Risk_SessionFilter(earlyEvening, 0, 21, 21, 24, 20, false, 10));
   TP_Check("the session filter still allows a re-open at 20:50 when the flatten is off",
            TP_Risk_SessionFilter(earlyEvening, 0, 21, 21, 24, 20, false));

   //--- midnight wrap: the same UTC windows shifted by +2 server hours
   //--- (rollover 21-24 UTC becomes 23-2, session 0-21 becomes 2-23) -
   TP_Check("a wrapped hour window includes hours after the start",
            TP_Risk_InHourWindow(23, 23, 2) && TP_Risk_InHourWindow(0, 23, 2) && TP_Risk_InHourWindow(1, 23, 2));
   TP_Check("a wrapped hour window excludes hours after its end",
            !TP_Risk_InHourWindow(2, 23, 2) && !TP_Risk_InHourWindow(12, 23, 2));
   TP_Check("a normal hour window is unchanged by the wrap helper",
            TP_Risk_InHourWindow(21, 21, 24) && !TP_Risk_InHourWindow(0, 21, 24) && !TP_Risk_InHourWindow(24, 21, 24));
   TP_Check("an equal start and end is an empty window",
            !TP_Risk_InHourWindow(12, 24, 24));
   TP_Check("the wrapped rollover window blocks 00:30 and 23:30",
            TP_Risk_InRolloverBlock(StringToTime("2024.01.10 00:30"), 0, 23, 2) &&
            TP_Risk_InRolloverBlock(StringToTime("2024.01.10 23:30"), 0, 23, 2));
   TP_Check("the wrapped rollover window frees 02:30 and noon",
            !TP_Risk_InRolloverBlock(StringToTime("2024.01.10 02:30"), 0, 23, 2) &&
            !TP_Risk_InRolloverBlock(StringToTime("2024.01.10 12:00"), 0, 23, 2));
   TP_Check("the pre-rollover extension works with a wrapped window",
            TP_Risk_InRolloverBlock(StringToTime("2024.01.10 22:55"), 10, 23, 2));
   TP_Check("a wrapped session (2-23) allows noon and blocks 01:00 / the rollover hours",
            TP_Risk_SessionFilter(wednesday, 2, 23, 23, 2, 22, true) &&
            !TP_Risk_SessionFilter(StringToTime("2024.01.10 01:00"), 2, 23, 23, 2, 22, true) &&
            !TP_Risk_SessionFilter(StringToTime("2024.01.10 23:30"), 2, 23, 23, 2, 22, false));
  }

//+------------------------------------------------------------------+
//| Test 8 - the order comment and the helpers                         |
//+------------------------------------------------------------------+
void Test_Comment(void)
  {
   Print("--- order comment ---");
   int cycleId = -1;
   int legIdx  = -1;

   TP_Check("the comment is built correctly",
            StringLen(TP_MakeComment(7, TP_LEG_BUY_A)) == StringLen("TP|7|BUY_A"));
   TP_Check("the comment round trip works",
            TP_ParseComment(TP_MakeComment(7, TP_LEG_BUY_A), cycleId, legIdx));
   TP_Check("the cycle id survives", cycleId == 7);
   TP_Check("the leg index survives", legIdx == TP_LEG_BUY_A);
   TP_Check("cycle ids accept only decimal digits",
            TP_IsDigits("26101701") && !TP_IsDigits("26x01701") &&
            !TP_IsDigits("") && !TP_IsDigits("-7"));
   TP_Check("a foreign comment is rejected",
            !TP_ParseComment("OTHER|7|BUY_A", cycleId, legIdx));
   TP_Check("a broken comment is rejected",
            !TP_ParseComment("TP|7|UNKNOWN", cycleId, legIdx));
   TP_Check("the mirror of BUY_A is SELL_A", TP_LegMirror(TP_LEG_BUY_A) == TP_LEG_SELL_A);
   TP_Check("the mirror of SELL_B is BUY_B", TP_LegMirror(TP_LEG_SELL_B) == TP_LEG_BUY_B);
   TP_Check("BUY_B is in slot B", TP_LegSlot(TP_LEG_BUY_B) == 1);
   TP_Check("SELL_A is in slot A", TP_LegSlot(TP_LEG_SELL_A) == 0);
  }

//+------------------------------------------------------------------+
//| Test 9 - the median                                                |
//+------------------------------------------------------------------+
void Test_Median(void)
  {
   Print("--- median ---");
   double v[];
   ArrayResize(v, 5);
   v[0] = 5.0; v[1] = 1.0; v[2] = 3.0; v[3] = 2.0; v[4] = 4.0;
   TP_CheckEq("the median of 1..5 is 3", TP_Median(v), 3.0, 1e-8);

   double w[];
   ArrayResize(w, 4);
   w[0] = 4.0; w[1] = 1.0; w[2] = 3.0; w[3] = 2.0;
   TP_CheckEq("the median of 1..4 is 2.5", TP_Median(w), 2.5, 1e-8);
  }

//+------------------------------------------------------------------+
//| Test 10 - stop clamping, stop-through and the freeze zone         |
//+------------------------------------------------------------------+
void Test_StopClamp(void)
  {
   Print("--- stop clamp, stop through, freeze ---");

   //--- the minimum distance -----------------------------------------
   TP_CheckEq("the stop distance is max(stops, freeze, 1) x point",
              TP_StopMinDistance(20, 30, 0.001), 0.030, 1e-8);
   TP_CheckEq("the stops level wins when it is larger",
              TP_StopMinDistance(50, 30, 0.001), 0.050, 1e-8);
   TP_CheckEq("zero levels are lifted to one point",
              TP_StopMinDistance(0, 0, 0.001), 0.001, 1e-8);

   //--- BUY: minDist = max(20, 30, 1) x 0.001 = 0.030 ---------------
   TP_CheckEq("a buy stop far below the bid is kept",
              TP_ClampStop(true, 4200.0, 4245.139, 4245.339, 20, 30, 0.001), 4200.0, 1e-8);
   TP_CheckEq("a buy stop inside the stops level is pushed down",
              TP_ClampStop(true, 4245.130, 4245.139, 4245.339, 20, 30, 0.001), 4245.109, 1e-8);
   TP_CheckEq("a buy stop above the bid is clamped under it",
              TP_ClampStop(true, 4245.632, 4245.139, 4245.339, 20, 30, 0.001), 4245.109, 1e-8);

   //--- SELL: minDist = 0.030 above the ask -------------------------
   TP_CheckEq("a sell stop far above the ask is kept",
              TP_ClampStop(false, 4300.0, 4245.139, 4245.339, 20, 30, 0.001), 4300.0, 1e-8);
   TP_CheckEq("a sell stop inside the stops level is pushed up",
              TP_ClampStop(false, 4245.350, 4245.139, 4245.339, 20, 30, 0.001), 4245.369, 1e-8);
   TP_CheckEq("a sell stop below the ask is clamped above it",
              TP_ClampStop(false, 4244.900, 4245.139, 4245.339, 20, 30, 0.001), 4245.369, 1e-8);
   //--- clamp boundary: exactly minPts points away is legal ---------
   TP_CheckEq("BUY boundary: a stop exactly 30 points below the bid is kept",
              TP_ClampStop(true, 4245.109, 4245.139, 4245.339, 20, 30, 0.001), 4245.109, 1e-8);
   TP_CheckEq("BUY boundary: a noisy equal stop is kept",
              TP_ClampStop(true, 4245.139 - 30 * 0.001, 4245.139, 4245.339, 20, 30, 0.001),
              4245.139 - 30 * 0.001, 1e-8);
   TP_CheckEq("BUY boundary: one point closer is pushed away",
              TP_ClampStop(true, 4245.110, 4245.139, 4245.339, 20, 30, 0.001), 4245.109, 1e-8);
   TP_CheckEq("SELL boundary: a stop exactly 30 points above the ask is kept",
              TP_ClampStop(false, 4245.369, 4245.139, 4245.339, 20, 30, 0.001), 4245.369, 1e-8);
   TP_CheckEq("SELL boundary: a noisy equal stop is kept",
              TP_ClampStop(false, 4245.339 + 30 * 0.001, 4245.139, 4245.339, 20, 30, 0.001),
              4245.339 + 30 * 0.001, 1e-8);
   TP_CheckEq("SELL boundary: one point closer is pushed away",
              TP_ClampStop(false, 4245.368, 4245.139, 4245.339, 20, 30, 0.001), 4245.369, 1e-8);

   //--- stop through: the example of the smoke test log -------------
   TP_Check("the buy stop of the log is beyond the bid (STOP_THROUGH)",
            TP_StopThroughMarket(true, 4245.632, 4245.139, 4245.339, 0.001));
   TP_Check("a buy stop below the bid is not through",
            !TP_StopThroughMarket(true, 4244.0, 4245.139, 4245.339, 0.001));
   TP_Check("a sell stop above the ask is not through",
            !TP_StopThroughMarket(false, 4246.0, 4245.139, 4245.339, 0.001));
   TP_Check("a sell stop below the ask is through",
            TP_StopThroughMarket(false, 4245.200, 4245.139, 4245.339, 0.001));
   TP_Check("a missing stop is never through the market",
            !TP_StopThroughMarket(true, 0.0, 4245.139, 4245.339, 0.001));
   //--- the exact boundary counts as through, noise must not flip it -
   TP_Check("BUY boundary: bid == stop is through",
            TP_StopThroughMarket(true, 4245.220, 4245.220, 4245.420, 0.001));
   TP_Check("BUY boundary: a noisy equal bid is through",
            TP_StopThroughMarket(true, 4245.190 + 30 * 0.001, 4245.220, 4245.420, 0.001));
   TP_Check("BUY boundary: bid 1 point above the stop is not through",
            !TP_StopThroughMarket(true, 4245.220, 4245.221, 4245.421, 0.001));
   TP_Check("SELL boundary: ask == stop is through",
            TP_StopThroughMarket(false, 4245.220, 4245.020, 4245.220, 0.001));
   TP_Check("SELL boundary: a noisy equal ask is through",
            TP_StopThroughMarket(false, 4245.190 + 30 * 0.001, 4245.020, 4245.220, 0.001));
   TP_Check("SELL boundary: ask 1 point below the stop is not through",
            !TP_StopThroughMarket(false, 4245.220, 4245.019, 4245.219, 0.001));

   //--- better than the current stop --------------------------------
   TP_Check("a higher buy stop is better", TP_StopIsBetter(true, 4245.0, 4244.0, 0.001));
   TP_Check("a lower buy stop is not better", !TP_StopIsBetter(true, 4243.0, 4244.0, 0.001));
   TP_Check("an equal buy stop is skipped", !TP_StopIsBetter(true, 4244.0, 4244.0, 0.001));
   TP_Check("a lower sell stop is better", TP_StopIsBetter(false, 4243.0, 4244.0, 0.001));
   TP_Check("a higher sell stop is not better", !TP_StopIsBetter(false, 4245.0, 4244.0, 0.001));
   TP_Check("any stop beats a missing one", TP_StopIsBetter(true, 1.0, 0.0, 0.001));
   TP_Check("a missing candidate is never better", !TP_StopIsBetter(true, 0.0, 0.0, 0.001));
   //--- the exact boundary: equal (within one point) is not better ---
   TP_Check("BUY boundary: 1 point higher is better",
            TP_StopIsBetter(true, 4244.001, 4244.0, 0.001));
   TP_Check("BUY boundary: a noisy equal stop is not better",
            !TP_StopIsBetter(true, 4244.0 + 1e-12, 4244.0, 0.001));
   TP_Check("SELL boundary: 1 point lower is better",
            TP_StopIsBetter(false, 4243.999, 4244.0, 0.001));
   TP_Check("SELL boundary: a noisy equal stop is not better",
            !TP_StopIsBetter(false, 4244.0, 4244.0 + 1e-12, 0.001));

   //--- the freeze zone ---------------------------------------------
   TP_Check("price inside the freeze zone blocks the modify",
            TP_StopFrozen(4245.200, 4245.190, 30, 0.001));
   TP_Check("price outside the freeze zone allows the modify",
            !TP_StopFrozen(4245.500, 4245.190, 30, 0.001));
   TP_Check("the freeze boundary itself blocks the modify",
            TP_StopFrozen(4245.220, 4245.190, 30, 0.001));
   //--- boundary: one point outside is free, noise must not flip it --
   TP_Check("one point beyond the freeze boundary allows the modify",
            !TP_StopFrozen(4245.221, 4245.190, 30, 0.001));
   TP_Check("the noisy freeze boundary blocks the modify",
            TP_StopFrozen(4245.190 + 30 * 0.001, 4245.190, 30, 0.001));
   TP_Check("a missing level is never frozen",
            !TP_StopFrozen(4245.200, 0.0, 30, 0.001));
   TP_Check("a zero freeze level never blocks",
            !TP_StopFrozen(4245.200, 4245.190, 0, 0.001));

   //--- the smoke test scenario end to end --------------------------
   //--- "modify #158 buy sl 4228.706 -> 4245.632 [Invalid stops]"
   //--- while the bid was 4245.139: the market came back through the
   //--- desired stop, so the action is a market close, not a modify
   TP_Check("scenario: the invalid modify of the log is a STOP_THROUGH",
            TP_StopThroughMarket(true, 4245.632, 4245.139, 4245.339, 0.001));
   TP_CheckEq("scenario: the clamp alone would drop the stop under the bid",
              TP_ClampStop(true, 4245.632, 4245.139, 4245.339, 20, 30, 0.001), 4245.109, 1e-8);

   //--- break even arming (min stop distance here: 0.030) -----------
   //--- normal ATR: the ATR distance wins ---------------------------
   TP_CheckEq("a normal ATR arms the break even at 0.6 x ATR",
              TP_BreakEvenArmDistance(0.6, 2.0, 0.20, 20, 30, 0.001), 1.20, 1e-8);
   //--- small ATR: the placeable floor wins: 0.20 + 0.030 + 0.20 ----
   TP_CheckEq("a small ATR arms at spread + min stop + spread",
              TP_BreakEvenArmDistance(0.6, 0.10, 0.20, 20, 30, 0.001), 0.430, 1e-8);
   TP_CheckEq("a zero ATR still arms at the placeable floor",
              TP_BreakEvenArmDistance(0.6, 0.0, 0.20, 20, 30, 0.001), 0.430, 1e-8);
   TP_Check("the arming floor is never below 2 x spread + min stop",
            TP_BreakEvenArmDistance(0.6, 0.10, 0.20, 20, 30, 0.001) >= 0.20 + 0.030 + 0.20);
   //--- the arming decision: the exact boundary counts as armed ------
   double armBoundary = TP_BreakEvenArmDistance(0.6, 0.10, 0.20, 20, 30, 0.001); // 0.430
   TP_Check("BE arms exactly at the arm distance",
            TP_BreakEvenArmed(armBoundary, armBoundary, 0.001));
   TP_Check("BE arms with a noisy equal distance",
            TP_BreakEvenArmed(armBoundary + 1e-12, armBoundary, 0.001));
   TP_Check("BE does not arm one point below the arm distance",
            !TP_BreakEvenArmed(armBoundary - 0.001, armBoundary, 0.001));
   TP_Check("BE arms one point above the arm distance",
            TP_BreakEvenArmed(armBoundary + 0.001, armBoundary, 0.001));

   //--- scenario: with the floor the break even stop is placeable    ---
   //--- and below the bid the moment the trigger arms -----------------
   double arm  = TP_BreakEvenArmDistance(0.6, 0.10, 0.20, 20, 30, 0.001);
   double bidS = 4200.0 + arm;
   double beSl = 4200.0 + 0.20;
   TP_Check("scenario: the break even stop is below the bid when it arms",
            !TP_StopThroughMarket(true, beSl, bidS, bidS + 0.20, 0.001));
   TP_CheckEq("scenario: the clamp keeps the break even stop (it has room)",
              TP_ClampStop(true, beSl, bidS, bidS + 0.20, 20, 30, 0.001), beSl, 1e-8);
   //--- the old naive trigger (0.6 x 0.10 = 0.06) armed while the bid
   //--- was still below the break even level: immediate STOP_THROUGH
   TP_Check("scenario: the old trigger armed through the market (why the floor exists)",
            TP_StopThroughMarket(true, beSl, 4200.0 + 0.06, 4200.0 + 0.26, 0.001));
  }

//+------------------------------------------------------------------+
//| Test 11 - Common\Files round trip (FileOpen flag placement)       |
//+------------------------------------------------------------------+
void Test_FileRoundTrip(void)
  {
   Print("--- Common\\Files round trip ---");
   string name = "TwinPulse_selftest.tmp";

   //--- FILE_COMMON must sit in open_flags, not in the codepage ------
   int w = FileOpen(name, FILE_WRITE | FILE_CSV | FILE_ANSI | FILE_SHARE_READ | FILE_COMMON, ',', CP_ACP);
   TP_Check("the test file opens in Common\\Files", w != INVALID_HANDLE);
   if(w != INVALID_HANDLE)
     {
      FileWriteString(w, "hello,common\n");
      FileWriteString(w, "second,line\n");
      FileFlush(w);
      FileClose(w);
     }

   TP_Check("FileIsExist finds the test file in Common\\Files", FileIsExist(name, FILE_COMMON));

   int r = FileOpen(name, FILE_READ | FILE_CSV | FILE_ANSI | FILE_SHARE_READ | FILE_COMMON, ',', CP_ACP);
   TP_Check("the test file reads back from Common\\Files", r != INVALID_HANDLE);
   bool ok = false;
   if(r != INVALID_HANDLE)
     {
      string a1 = FileReadString(r);
      string a2 = FileReadString(r);
      string b1 = FileReadString(r);
      string b2 = FileReadString(r);
      FileClose(r);
      ok = (a1 == "hello" && a2 == "common" && b1 == "second" && b2 == "line");
     }
   TP_Check("the round trip content matches", ok);

   FileDelete(name, FILE_COMMON);
   TP_Check("the test file is deleted again", !FileIsExist(name, FILE_COMMON));
  }

//+------------------------------------------------------------------+
//| Test 12 - log de-duplication (the timer must not flood the logs)   |
//+------------------------------------------------------------------+
void Test_Dedup(void)
  {
   Print("--- log de-duplication ---");
   string last = "";
   long before = g_logDupSuppressed;

   TP_Check("the first reason is logged", TP_DedupShouldLog(last, "session filter"));
   TP_Check("the same reason twice is logged once", !TP_DedupShouldLog(last, "session filter"));
   TP_Check("the same reason three times is still suppressed", !TP_DedupShouldLog(last, "session filter"));
   TP_Check("a changed reason is logged again", TP_DedupShouldLog(last, "spread too high"));
   TP_Check("and its repeats are suppressed again", !TP_DedupShouldLog(last, "spread too high"));
   TP_Check("switching back to the first reason logs it again", TP_DedupShouldLog(last, "session filter"));
   TP_CheckEq("suppressed duplicates are counted", (double)(g_logDupSuppressed - before), 3.0, 1e-8);

   //--- the per-leg "last reason" behaves the same and resets --------
   string perLeg = "not re-opened: cooldown";
   TP_Check("another key chain is independent", TP_DedupShouldLog(perLeg, "shred skipped: bank does not cover"));
   perLeg = "";   // the leg state changed (opened / closed / shredded)
   TP_Check("a cleared reason logs again after a state change", TP_DedupShouldLog(perLeg, "shred skipped: bank does not cover"));
  }

//+------------------------------------------------------------------+
//| Test 13 - Close By ticket guard, leg set filter, spread math      |
//+------------------------------------------------------------------+
void Test_DecisionHelpers(void)
  {
   Print("--- close-by guard, leg set, spread math ---");

   //--- a Close By with ticket 0 must never be sent -----------------
   TP_Check("a Close By with two tickets is allowed", TP_CloseByTicketsOk(105, 110));
   TP_Check("ticket 0 as the first ticket is refused", !TP_CloseByTicketsOk(0, 110));
   TP_Check("ticket 0 as the second ticket is refused", !TP_CloseByTicketsOk(110, 0));
   TP_Check("two zero tickets are refused", !TP_CloseByTicketsOk(0, 0));
   TP_Check("the same ticket twice is refused", !TP_CloseByTicketsOk(110, 110));

   //--- LegSet filter ------------------------------------------------
   TP_Check("LegSet 0 allows every leg", TP_LegSetAllows(TP_LEG_BUY_A, 0) && TP_LegSetAllows(TP_LEG_BUY_B, 0));
   TP_Check("LegSet 1 keeps only the slot A legs", TP_LegSetAllows(TP_LEG_BUY_A, 1) && TP_LegSetAllows(TP_LEG_SELL_A, 1));
   TP_Check("LegSet 1 drops the slot B legs", !TP_LegSetAllows(TP_LEG_BUY_B, 1) && !TP_LegSetAllows(TP_LEG_SELL_B, 1));
   TP_Check("LegSet 2 keeps only the slot B legs", TP_LegSetAllows(TP_LEG_BUY_B, 2) && TP_LegSetAllows(TP_LEG_SELL_B, 2));
   TP_Check("LegSet 2 drops the slot A legs", !TP_LegSetAllows(TP_LEG_BUY_A, 2) && !TP_LegSetAllows(TP_LEG_SELL_A, 2));

   //--- spread accounting --------------------------------------------
   TP_CheckEq("spread cost = spread x volume x contract size",
              TP_SpreadCost(0.30, 0.02, 100.0), 0.60, 1e-8);
   TP_CheckEq("zero spread costs nothing", TP_SpreadCost(0.0, 0.02, 100.0), 0.0, 1e-8);
   TP_CheckEq("gross before spread = net + spread cost",
              TP_GrossBeforeSpread(-2.17, 0.60), -1.57, 1e-8);
   TP_CheckEq("gross minus spread cost is the net again",
              TP_GrossBeforeSpread(-2.17, 0.60) - 0.60, -2.17, 1e-8);
  }

//+------------------------------------------------------------------+
//| Test 14 - bank accounting: close -> re-open -> shred -> close     |
//|  The bank must always equal the sum of the realised money of the  |
//|  closed positions. The bug: a re-opened leg kept the realized of  |
//|  its previous position, so the next close booked the old money    |
//|  again (RegisterClose delta = cumulative - realized(old + new)).  |
//+------------------------------------------------------------------+
void Test_BankAccounting(void)
  {
   Print("--- bank accounting (close / re-open / shred / close) ---");
   const int leg = TP_LEG_BUY_B;

   //--- a new position session resets EVERY per-position field ------
   g_tp.legs[leg].realized      = -2.94;   // garbage of the old session
   g_tp.legs[leg].booked        = true;
   g_tp.legs[leg].beDone        = true;
   g_tp.legs[leg].peakPrice     = 1900.0;
   g_tp.legs[leg].lastModify    = 12345;
   g_tp.legs[leg].modifyFails   = 2;
   g_tp.legs[leg].modifyBackoff = 999;
   TP_State_NewPositionSession(leg);
   TP_Check("a new position session resets realized (the bank bug)",
            g_tp.legs[leg].realized == 0.0);
   TP_Check("a new position session resets booked / beDone / modify state",
            !g_tp.legs[leg].booked && !g_tp.legs[leg].beDone &&
            g_tp.legs[leg].peakPrice == 0.0 && g_tp.legs[leg].lastModify == 0 &&
            g_tp.legs[leg].modifyFails == 0 && g_tp.legs[leg].modifyBackoff == 0);

   //--- position 1 opens and closes with +1.50 ----------------------
   double bank = 0.0;
   double delta = TP_Bank_CloseDelta(g_tp.legs[leg].realized, 1.50);
   g_tp.legs[leg].realized = 1.50;
   bank += delta;
   TP_CheckEq("close 1 books the full realised money of position 1", bank, 1.50, 1e-8);

   //--- the leg RE-OPENS: position 2 starts with realized = 0 -------
   TP_State_NewPositionSession(leg);
   TP_Check("the re-open resets realized to zero",
            g_tp.legs[leg].realized == 0.0);

   //--- a partial shred books its delta (as TP_Bank_TryShred does) --
   double shred = -0.43;
   bank += shred;
   g_tp.legs[leg].realized += shred;
   TP_CheckEq("the shred books only its own delta", bank, 1.07, 1e-8);

   //--- position 2 closes: cumulative -1.00 (shred included) --------
   delta = TP_Bank_CloseDelta(g_tp.legs[leg].realized, -1.00);
   g_tp.legs[leg].realized = -1.00;
   bank += delta;
   TP_CheckEq("close 2 books only the rest of position 2", delta, -0.57, 1e-8);
   TP_CheckEq("the bank is the sum of the realised money (1.50 - 1.00)", bank, 0.50, 1e-8);

   //--- the same numbers with the STALE realized of the old session --
   //--- give the wrong bank the smoke test showed (+2.94) ------------
   double stale = 1.50 + shred;          // position 1 + shred, never reset
   double wrongDelta = TP_Bank_CloseDelta(stale, -1.00);
   TP_CheckEq("with the stale realized the close would book the old money again",
              wrongDelta, -2.07, 1e-8);
   TP_Check("the stale bookkeeping does not equal the realised sum",
            MathAbs((1.07 + wrongDelta) - 0.50) > 0.01);
  }

//+------------------------------------------------------------------+
//| OnStart - run every test                                          |
//+------------------------------------------------------------------+
void OnStart()
  {
   g_passed = 0;
   g_failed = 0;

   Print("=====================================================");
   Print("  TwinPulse Hedge EA - self test");
   Print("=====================================================");

   Test_Lots();
   Test_CostFloor();
   Test_Indicators();
   Test_Regime();
   Test_Bank();
   Test_Rebalance();
   Test_TimeFilters();
   Test_Comment();
   Test_Median();
   Test_StopClamp();
   Test_FileRoundTrip();
   Test_Dedup();
   Test_DecisionHelpers();
   Test_BankAccounting();

   Print("=====================================================");
   Print(StringFormat("  self test finished: %d passed, %d failed", g_passed, g_failed));
   Print("=====================================================");

   if(g_failed == 0)
      Print("  ALL TESTS PASSED");
   else
      Print("  THERE ARE FAILED TESTS, the EA must not be trusted");
  }
