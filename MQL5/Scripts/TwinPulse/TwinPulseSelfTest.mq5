//+------------------------------------------------------------------+
//|                                     TwinPulseSelfTest.mq5        |
//|                                                                  |
//|  Pure function tests of the TwinPulse Hedge EA.                   |
//|  Run this script on any chart, every line must print PASS.        |
//|  It never opens a position and never changes the account.          |
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
   TP_Check("a full bank can shred", TP_Bank_CanShred(0.30, 0.10, 0.20));
   TP_Check("a short bank cannot shred", !TP_Bank_CanShred(0.29, 0.10, 0.20));
   TP_Check("an empty bank cannot shred", !TP_Bank_CanShred(0.0, 0.10, 0.20));
   TP_CheckEq("the bank after the shred",
              TP_Bank_AfterShred(0.30, 0.10, 0.20), 0.0, 1e-8);
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
   TP_Check("the session start is respected",
            !TP_Risk_SessionFilter(wednesday, 8, 21, 21, 24, 20, true));
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

   Print("=====================================================");
   Print(StringFormat("  self test finished: %d passed, %d failed", g_passed, g_failed));
   Print("=====================================================");

   if(g_failed == 0)
      Print("  ALL TESTS PASSED");
   else
      Print("  THERE ARE FAILED TESTS, the EA must not be trusted");
  }
