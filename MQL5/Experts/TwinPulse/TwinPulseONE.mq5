//+------------------------------------------------------------------+
//|  TwinPulseONE.mq5 - 38 tested variants + 3 new (Z) in ONE file
//|  XAUUSDm M5 scalper, fixed 0.01 lot, broker SL on every leg,
//|  AllowLive=false, no grid, no averaging down.
//|  Pick the variant with the InpPreset input. TP_CUSTOM = the inputs
//|  exactly as typed, which is how every old .set file behaves.
//|  Since 1.14 this file IS the source (the generator was removed in
//|  5a4b7f6); edit it by hand. Changes: see the 1.14 block below.
//+------------------------------------------------------------------+
//+------------------------------------------------------------------+
//|                                                TwinPulseScalp.mq5|
//|  Gold scalper for the London-New York overlap.                    |
//|                                                                   |
//|  Design rules taken from the measured failures of rounds 1-3:      |
//|   * every position carries a BROKER stop loss from the moment it   |
//|     exists (rule: no position without a stop);                     |
//|   * a take profit below InpMinTPxSpread x spread is refused - the  |
//|     broker would take most of it (spread 0.26 measured);           |
//|   * a RANDOM entry mode with identical exits runs every round, so  |
//|     the entry can be judged against luck and not against zero;     |
//|   * fixed 0.01 lot, never increased, no grid, no averaging down;   |
//|   * hard cap on simultaneous positions, set by margin not greed;   |
//|   * every close writes pos_net; the report must match to the cent. |
//|                                                                   |
//|  AllowLive stays false: on a real account the EA refuses to start. |
//+------------------------------------------------------------------+
//  1.14 (Claude review):
//   * multi-leg side rules add back the spread a leg paid at the open, so
//     the 2B+2S book can actually be built (mode 0 is unchanged)
//   * TP_MarketScore EMA slope had its sign inverted (array order)
//   * mode 2 reads InpFixedBuy / InpFixedSell instead of copying mode 1
//   * refuses a NETTING account when it would hold more than one leg
//   * a day stop retries closing legs that a failed close-all left open
//   * mode 4 random split is seeded (reproducible control)
//   * experiment Z: H1 trend filter + its random twin (presets Z1..Z3)
//  1.15:
//   * CSV: side and reason come from the deal (DEAL_TYPE, DEAL_REASON); a
//     leg dropped by TP_Sync before its close event is found in a recent
//     cache. 1.13/1.14 wrote "long/stop" for every such row.
//   * OnTester prints and saves the per-trade mean, 95% CI, win rate vs
//     break-even and both halves; "OnTester result" = mean x 100
//  1.16:
//   * InpSignalTF (M1/M5), fixed TP/SL in price, max trades per day
//   * experiment Q: the owner's M1 scalper (~20/day, TP 2-3 USD, SL
//     1.5-2 USD) with random twins Q2/Q4. All older presets stay on M5.
//  1.17:
//   * mode 6 PULSE, the owner's cycle: 1B+1S probe, add 2 to the winner,
//     trail winners, hold the loser until it is back near break-even, then
//     cap it, trail it, add 2 to it; repeat. No trade cap, 30 USD day loss.
//     Presets P1_Pulse and its control P2_PulseRnd (adds to a random side).
//  1.18 (P1 logic untouched; P1/P2 behave exactly as in 1.17 - saved as
//  branch claude/pulse-1.17-P1-baseline):
//   * InpPulseMaxSpread: start a cycle only when the spread is cheap
//   * InpPulseVirtual: enter on the side that moves first instead of
//     paying for a 1B+1S probe (one spread saved, no held loser)
//   * presets P3/P4 (spread gate 0.20) and P5/P6 (virtual + gate), each
//     with its random control
//  1.19: OnTester halves split by CALENDAR time, not trade order; a pass
//     also needs >= 2/3 of months positive and no month > 50% of the net
//  1.20 demo-ready: default preset P1_Pulse; Friday weekend close for
//     PULSE (InpWeekendClose, 21:00 server); status panel on the chart;
//     a DAY SUMMARY line per day and a RUN SUMMARY on removal in the log
//+------------------------------------------------------------------+
#property copyright "TwinPulse"
#property version   "1.20"

#include <Trade\Trade.mqh>

//--- identity
input long   InpMagic           = 26101710;  // Magic
input string InpComment         = "TPS";     // Comment
input bool   InpAllowLive       = false;     // Allow a REAL account (always false)

//--- size
input double InpLots            = 0.01;      // Lots per position (fixed)
input int    InpMaxPositions    = 3;         // Max simultaneous positions
input double InpMinMarginLevel  = 300.0;     // Do not open below this margin level %

//--- operating mode
input int    InpMode            = 0;         // 0=single 1=hedge 2=2+2 3=adaptive 4=adaptive-random 5=hybrid 6=pulse
//--- mode 6 "pulse": the owner's cycle (probe 1B+1S, add to the winner,
//--- trail the winners, hold the loser until it comes back, repeat)
input double InpPulseTrigUSD    = 1.00;      // Pulse: a side this much in profit is the winner
input int    InpPulseAdd        = 2;         // Pulse: legs added to the winning side
input double InpPulseTrailStart = 1.00;      // Pulse: start trailing at +this price (1.00 = 1 USD @0.01)
input double InpPulseTrailDist  = 0.70;      // Pulse: trail distance, price
input double InpPulseSL         = 5.00;      // Pulse: hard broker stop on EVERY leg, price (big-loss cap)
input double InpPulseBETol      = 0.30;      // Pulse: held loser counts as "back" at >= -this USD
input bool   InpPulseRandom     = false;     // Pulse CONTROL: add to a random side, not the winner
input double InpPulseMaxSpread  = 0.0;       // Pulse: start a cycle only when spread <= this (0 = off)
input bool   InpPulseVirtual    = false;     // Pulse: VIRTUAL probe - no 1B+1S, enter on the side that moves first
input int    InpAdxPeriod       = 14;        // ADX period (market score)
input double InpScoreStrong     = 0.60;      // |score| >= this -> 3 on one side, 0 on the other
input double InpScoreMild       = 0.20;      // |score| >= this -> 2/1 split
input double InpReopenTolUSD    = 0.10;      // re-open only when the opposite side is >= -this
input double InpHedgeTarget_ATR = 3.00;      // hedge legs: take profit, x ATR
input int    InpFixedBuy        = 2;         // Mode 2: BUY legs to hold
input int    InpFixedSell       = 2;         // Mode 2: SELL legs to hold

//--- entry
input int    InpEntryMode       = 0;         // 0=pullback 1=mean-rev 2=breakout 3=random
input int    InpFastEMA         = 9;         // Fast EMA (M5)
input int    InpSlowEMA         = 21;        // Slow EMA (M5)
input int    InpATRPeriod       = 14;        // ATR (M5)
input int    InpBBPeriod        = 20;        // Bollinger period
input double InpBBDev           = 2.0;       // Bollinger deviation
input int    InpRSIPeriod       = 14;        // RSI period
input double InpRSIBuy          = 30.0;      // Mean-rev: buy below this RSI
input double InpRSISell         = 70.0;      // Mean-rev: sell above this RSI
input int    InpBreakBars       = 20;        // Breakout: bars to look back
input int    InpRandomSeed      = 11;        // Random control seed
input bool   InpHTFFilter       = false;     // Mode 0: trade only with the H1 trend (experiment Z)
input int    InpHTFPeriod       = 50;        // H1 EMA period for the trend filter

//--- exits
input double InpTP_ATR          = 2.00;      // Take profit, x ATR
input double InpSL_ATR          = 2.00;      // Stop loss, x ATR
input double InpMinTPxSpread    = 5.0;       // TP must be at least this many spreads
input double InpTP_Price        = 0.0;       // Fixed TP distance in price (0 = use ATR). XAUUSDm 0.01 lot: 1.00 = 1 USD
input double InpSL_Price        = 0.0;       // Fixed SL distance in price (0 = use ATR)
input int    InpMaxTradesDay    = 0;         // Max new trades per day (0 = no limit)
input ENUM_TIMEFRAMES InpSignalTF = PERIOD_M5; // Signal timeframe (M5 = all tested presets)
input double InpMaxSL_Price     = 6.00;      // Hard cap of the stop, price units
input double InpTrailStart_ATR  = 1.20;      // Start trailing at +x ATR (0 = off)
input double InpTrail_ATR       = 1.00;      // Trail distance, x ATR

//--- session / filters
input int    InpSessionStart    = 13;        // First server hour to open (13 = London/NY overlap)
input int    InpSessionEnd      = 17;        // Last server hour to open (17 = exclusive)
input int    InpFridayStop      = 20;        // No new trades after this hour on Friday
input double InpMaxSpread       = 0.60;      // Max spread at entry, price units
input bool   InpUseNews         = false;     // Skip around high-impact news (needs TwinPulse_news.csv)
input int    InpNewsMinutes     = 15;        // Minutes before/after a news time to skip

//--- day control
input double InpDailyLossUSD    = 10.0;      // Close all + stop at this daily loss (USD, 0 = off)
input double InpDailyTargetUSD  = 50.0;      // Close all + stop at this daily profit (USD, 0 = off)

//--- logging
input bool   InpWriteCsv        = true;
input bool   InpVerboseLog      = true;

//+------------------------------------------------------------------+
//|  GENERATED by tools/build_one_file.py - do not edit by hand.      |
//|  One file, every variant: pick InpPreset, or TP_CUSTOM to use the |
//|  inputs below exactly as typed (the old .set files still load).   |
//+------------------------------------------------------------------+
enum ENUM_TP_PRESET
  {
   TP_CUSTOM = 0,                          // custom - use the inputs below
   TP_S1_Pullback = 1,                       // S1_Pullback
   TP_S1_Pullback_N = 2,                     // S1_Pullback_N
   TP_S2_WideTP = 3,                         // S2_WideTP
   TP_S2_WideTP_N = 4,                       // S2_WideTP_N
   TP_S3_MeanRev = 5,                        // S3_MeanRev
   TP_S3_MeanRev_N = 6,                      // S3_MeanRev_N
   TP_S4_Breakout = 7,                       // S4_Breakout
   TP_S4_Breakout_N = 8,                     // S4_Breakout_N
   TP_S5_Random = 9,                         // S5_Random
   TP_S5_Random_N = 10,                      // S5_Random_N
   TP_S6_Trail = 11,                         // S6_Trail
   TP_S6_Trail_N = 12,                       // S6_Trail_N
   TP_S7_Session = 13,                       // S7_Session
   TP_S7_Session_N = 14,                     // S7_Session_N
   TP_S8_Hedge4 = 15,                        // S8_Hedge4
   TP_S8_Hedge4_N = 16,                      // S8_Hedge4_N
   TP_S9_Hybrid = 17,                        // S9_Hybrid
   TP_S9_Hybrid_N = 18,                      // S9_Hybrid_N
   TP_S10_Adaptive = 19,                     // S10_Adaptive
   TP_S10_Adaptive_N = 20,                   // S10_Adaptive_N
   TP_S11_AdaptiveRnd = 21,                  // S11_AdaptiveRnd
   TP_S11_AdaptiveRnd_N = 22,                // S11_AdaptiveRnd_N
   TP_X1_TP20_SL20 = 23,                     // X1_TP20_SL20
   TP_X1_TP20_SL20_N = 24,                   // X1_TP20_SL20_N
   TP_X2_TP13_SL20 = 25,                     // X2_TP13_SL20
   TP_X2_TP13_SL20_N = 26,                   // X2_TP13_SL20_N
   TP_X3_TP20_SL13 = 27,                     // X3_TP20_SL13
   TP_X3_TP20_SL13_N = 28,                   // X3_TP20_SL13_N
   TP_X4_TP15_SL15 = 29,                     // X4_TP15_SL15
   TP_X4_TP15_SL15_N = 30,                   // X4_TP15_SL15_N
   TP_X5_TP30_SL15 = 31,                     // X5_TP30_SL15
   TP_X5_TP30_SL15_N = 32,                   // X5_TP30_SL15_N
   TP_X6_MaxPos1 = 33,                       // X6_MaxPos1
   TP_X6_MaxPos1_N = 34,                     // X6_MaxPos1_N
   TP_Y1_LossOff = 35,                       // Y1_LossOff
   TP_Y2_LossOff_T50 = 36,                   // Y2_LossOff_T50
   TP_Y3_Loss30 = 37,                        // Y3_Loss30
   TP_Y4_Loss30_T50 = 38,                    // Y4_Loss30_T50
   TP_Z1_PullHTF = 39,                       // Z1_PullHTF (pullback + H1 trend, no day stops)
   TP_Z2_RndHTF = 40,                        // Z2_RndHTF (random + H1 trend: the filter's own control)
   TP_Z3_Rnd = 41,                           // Z3_Rnd (random, no filter, no day stops: plain control)
   TP_Q1_M1_TP2SL2 = 42,                     // Q1 M1 scalp: pullback, TP 2 USD, SL 2 USD, max 20/day
   TP_Q2_M1_TP2SL2_Rnd = 43,                 // Q2 = Q1 with RANDOM entry (control)
   TP_Q3_M1_TP3SL15 = 44,                    // Q3 M1 scalp: pullback, TP 3 USD, SL 1.5 USD, max 20/day
   TP_Q4_M1_TP3SL15_Rnd = 45,                // Q4 = Q3 with RANDOM entry (control)
   TP_P1_Pulse = 46,                         // P1 owner's pulse cycle on M1, no trade limit, day loss 30
   TP_P2_PulseRnd = 47,                      // P2 = P1 but adds to a RANDOM side (control)
   TP_P3_PulseSpr = 48,                      // P3 = P1 + new cycle only when spread <= 0.20
   TP_P4_PulseSprRnd = 49,                   // P4 = P3 random control
   TP_P5_PulseVirt = 50,                     // P5 = virtual probe (1 spread saved) + spread <= 0.20
   TP_P6_PulseVirtRnd = 51,                  // P6 = P5 random control
  };

input ENUM_TP_PRESET InpPreset = TP_P1_Pulse; // Preset (default P1_Pulse = the owner's PULSE, ready for demo)
input bool   InpWeekendClose    = true;      // Pulse: close every leg on Friday at InpWeekendHour (no weekend gap)
input int    InpWeekendHour     = 21;        // Pulse: Friday server hour for the weekend close
input bool   InpShowPanel       = true;      // Show the status panel on the chart

int      CFG_InpMaxPositions;
double   CFG_InpMinMarginLevel;
int      CFG_InpMode;
int      CFG_InpEntryMode;
double   CFG_InpTP_ATR;
double   CFG_InpSL_ATR;
double   CFG_InpTrailStart_ATR;
double   CFG_InpTrail_ATR;
int      CFG_InpSessionStart;
int      CFG_InpSessionEnd;
double   CFG_InpDailyLossUSD;
double   CFG_InpDailyTargetUSD;
double   CFG_InpTP_Price;
double   CFG_InpSL_Price;
int      CFG_InpMaxTradesDay;
ENUM_TIMEFRAMES g_tf = PERIOD_M5;   // the signal timeframe, set in TP_ApplyPreset
bool     CFG_InpPulseRandom;
double   CFG_InpPulseMaxSpread;
bool     CFG_InpPulseVirtual;
bool     CFG_InpHTFFilter;

string TP_PresetLabel()
  {
   switch(InpPreset)
     {
      case TP_S1_Pullback: return "S1_Pullback";
      case TP_S1_Pullback_N: return "S1_Pullback_N";
      case TP_S2_WideTP: return "S2_WideTP";
      case TP_S2_WideTP_N: return "S2_WideTP_N";
      case TP_S3_MeanRev: return "S3_MeanRev";
      case TP_S3_MeanRev_N: return "S3_MeanRev_N";
      case TP_S4_Breakout: return "S4_Breakout";
      case TP_S4_Breakout_N: return "S4_Breakout_N";
      case TP_S5_Random: return "S5_Random";
      case TP_S5_Random_N: return "S5_Random_N";
      case TP_S6_Trail: return "S6_Trail";
      case TP_S6_Trail_N: return "S6_Trail_N";
      case TP_S7_Session: return "S7_Session";
      case TP_S7_Session_N: return "S7_Session_N";
      case TP_S8_Hedge4: return "S8_Hedge4";
      case TP_S8_Hedge4_N: return "S8_Hedge4_N";
      case TP_S9_Hybrid: return "S9_Hybrid";
      case TP_S9_Hybrid_N: return "S9_Hybrid_N";
      case TP_S10_Adaptive: return "S10_Adaptive";
      case TP_S10_Adaptive_N: return "S10_Adaptive_N";
      case TP_S11_AdaptiveRnd: return "S11_AdaptiveRnd";
      case TP_S11_AdaptiveRnd_N: return "S11_AdaptiveRnd_N";
      case TP_X1_TP20_SL20: return "X1_TP20_SL20";
      case TP_X1_TP20_SL20_N: return "X1_TP20_SL20_N";
      case TP_X2_TP13_SL20: return "X2_TP13_SL20";
      case TP_X2_TP13_SL20_N: return "X2_TP13_SL20_N";
      case TP_X3_TP20_SL13: return "X3_TP20_SL13";
      case TP_X3_TP20_SL13_N: return "X3_TP20_SL13_N";
      case TP_X4_TP15_SL15: return "X4_TP15_SL15";
      case TP_X4_TP15_SL15_N: return "X4_TP15_SL15_N";
      case TP_X5_TP30_SL15: return "X5_TP30_SL15";
      case TP_X5_TP30_SL15_N: return "X5_TP30_SL15_N";
      case TP_X6_MaxPos1: return "X6_MaxPos1";
      case TP_X6_MaxPos1_N: return "X6_MaxPos1_N";
      case TP_Y1_LossOff: return "Y1_LossOff";
      case TP_Y2_LossOff_T50: return "Y2_LossOff_T50";
      case TP_Y3_Loss30: return "Y3_Loss30";
      case TP_Y4_Loss30_T50: return "Y4_Loss30_T50";
      case TP_Z1_PullHTF: return "Z1_PullHTF";
      case TP_Z2_RndHTF: return "Z2_RndHTF";
      case TP_Z3_Rnd: return "Z3_Rnd";
      case TP_Q1_M1_TP2SL2: return "Q1_M1_TP2SL2";
      case TP_Q2_M1_TP2SL2_Rnd: return "Q2_M1_TP2SL2_Rnd";
      case TP_Q3_M1_TP3SL15: return "Q3_M1_TP3SL15";
      case TP_Q4_M1_TP3SL15_Rnd: return "Q4_M1_TP3SL15_Rnd";
      case TP_P1_Pulse: return "P1_Pulse";
      case TP_P2_PulseRnd: return "P2_PulseRnd";
      case TP_P3_PulseSpr: return "P3_PulseSpr";
      case TP_P4_PulseSprRnd: return "P4_PulseSprRnd";
      case TP_P5_PulseVirt: return "P5_PulseVirt";
      case TP_P6_PulseVirtRnd: return "P6_PulseVirtRnd";
     }
   return "custom";
  }

//--- every preset value is absolute: no dependence on what the
//--- inputs were before, so a saved .set cannot leak into a preset
void TP_ApplyPreset()
  {
   CFG_InpMaxPositions = InpMaxPositions;
   CFG_InpMinMarginLevel = InpMinMarginLevel;
   CFG_InpMode = InpMode;
   CFG_InpEntryMode = InpEntryMode;
   CFG_InpTP_ATR = InpTP_ATR;
   CFG_InpSL_ATR = InpSL_ATR;
   CFG_InpTrailStart_ATR = InpTrailStart_ATR;
   CFG_InpTrail_ATR = InpTrail_ATR;
   CFG_InpSessionStart = InpSessionStart;
   CFG_InpSessionEnd = InpSessionEnd;
   CFG_InpDailyLossUSD = InpDailyLossUSD;
   CFG_InpDailyTargetUSD = InpDailyTargetUSD;
   CFG_InpHTFFilter = InpHTFFilter;
   CFG_InpTP_Price = InpTP_Price;
   CFG_InpSL_Price = InpSL_Price;
   CFG_InpMaxTradesDay = InpMaxTradesDay;
   g_tf = InpSignalTF;
   CFG_InpPulseRandom = InpPulseRandom;
   CFG_InpPulseMaxSpread = InpPulseMaxSpread;
   CFG_InpPulseVirtual = InpPulseVirtual;
   if(InpPreset == TP_CUSTOM) return;
   CFG_InpPulseRandom = false;
   CFG_InpPulseMaxSpread = 0.0;
   CFG_InpPulseVirtual = false;
   CFG_InpHTFFilter = false;   // only the Z presets switch it on
   CFG_InpTP_Price = 0.0;      // only the Q presets use fixed distances,
   CFG_InpSL_Price = 0.0;      // a daily trade cap and the M1 timeframe
   CFG_InpMaxTradesDay = 0;
   g_tf = PERIOD_M5;

   switch(InpPreset)
     {
      case TP_S1_Pullback:
         CFG_InpMaxPositions = 3;
         CFG_InpMinMarginLevel = 300.00;
         CFG_InpMode = 0;
         CFG_InpEntryMode = 0;
         CFG_InpTP_ATR = 2.00;
         CFG_InpSL_ATR = 2.00;
         CFG_InpTrailStart_ATR = 1.20;
         CFG_InpTrail_ATR = 1.00;
         CFG_InpSessionStart = 13;
         CFG_InpSessionEnd = 17;
         CFG_InpDailyLossUSD = 10.00;
         CFG_InpDailyTargetUSD = 50.00;
         break;
      case TP_S1_Pullback_N:
         CFG_InpMaxPositions = 3;
         CFG_InpMinMarginLevel = 300.00;
         CFG_InpMode = 0;
         CFG_InpEntryMode = 0;
         CFG_InpTP_ATR = 2.00;
         CFG_InpSL_ATR = 2.00;
         CFG_InpTrailStart_ATR = 1.20;
         CFG_InpTrail_ATR = 1.00;
         CFG_InpSessionStart = 13;
         CFG_InpSessionEnd = 17;
         CFG_InpDailyLossUSD = 10.00;
         CFG_InpDailyTargetUSD = 0.00;
         break;
      case TP_S2_WideTP:
         CFG_InpMaxPositions = 3;
         CFG_InpMinMarginLevel = 300.00;
         CFG_InpMode = 0;
         CFG_InpEntryMode = 0;
         CFG_InpTP_ATR = 3.50;
         CFG_InpSL_ATR = 2.00;
         CFG_InpTrailStart_ATR = 1.20;
         CFG_InpTrail_ATR = 1.00;
         CFG_InpSessionStart = 13;
         CFG_InpSessionEnd = 17;
         CFG_InpDailyLossUSD = 10.00;
         CFG_InpDailyTargetUSD = 50.00;
         break;
      case TP_S2_WideTP_N:
         CFG_InpMaxPositions = 3;
         CFG_InpMinMarginLevel = 300.00;
         CFG_InpMode = 0;
         CFG_InpEntryMode = 0;
         CFG_InpTP_ATR = 3.50;
         CFG_InpSL_ATR = 2.00;
         CFG_InpTrailStart_ATR = 1.20;
         CFG_InpTrail_ATR = 1.00;
         CFG_InpSessionStart = 13;
         CFG_InpSessionEnd = 17;
         CFG_InpDailyLossUSD = 10.00;
         CFG_InpDailyTargetUSD = 0.00;
         break;
      case TP_S3_MeanRev:
         CFG_InpMaxPositions = 3;
         CFG_InpMinMarginLevel = 300.00;
         CFG_InpMode = 0;
         CFG_InpEntryMode = 1;
         CFG_InpTP_ATR = 2.50;
         CFG_InpSL_ATR = 2.00;
         CFG_InpTrailStart_ATR = 1.20;
         CFG_InpTrail_ATR = 1.00;
         CFG_InpSessionStart = 13;
         CFG_InpSessionEnd = 17;
         CFG_InpDailyLossUSD = 10.00;
         CFG_InpDailyTargetUSD = 50.00;
         break;
      case TP_S3_MeanRev_N:
         CFG_InpMaxPositions = 3;
         CFG_InpMinMarginLevel = 300.00;
         CFG_InpMode = 0;
         CFG_InpEntryMode = 1;
         CFG_InpTP_ATR = 2.50;
         CFG_InpSL_ATR = 2.00;
         CFG_InpTrailStart_ATR = 1.20;
         CFG_InpTrail_ATR = 1.00;
         CFG_InpSessionStart = 13;
         CFG_InpSessionEnd = 17;
         CFG_InpDailyLossUSD = 10.00;
         CFG_InpDailyTargetUSD = 0.00;
         break;
      case TP_S4_Breakout:
         CFG_InpMaxPositions = 3;
         CFG_InpMinMarginLevel = 300.00;
         CFG_InpMode = 0;
         CFG_InpEntryMode = 2;
         CFG_InpTP_ATR = 2.50;
         CFG_InpSL_ATR = 2.50;
         CFG_InpTrailStart_ATR = 1.20;
         CFG_InpTrail_ATR = 1.00;
         CFG_InpSessionStart = 13;
         CFG_InpSessionEnd = 17;
         CFG_InpDailyLossUSD = 10.00;
         CFG_InpDailyTargetUSD = 50.00;
         break;
      case TP_S4_Breakout_N:
         CFG_InpMaxPositions = 3;
         CFG_InpMinMarginLevel = 300.00;
         CFG_InpMode = 0;
         CFG_InpEntryMode = 2;
         CFG_InpTP_ATR = 2.50;
         CFG_InpSL_ATR = 2.50;
         CFG_InpTrailStart_ATR = 1.20;
         CFG_InpTrail_ATR = 1.00;
         CFG_InpSessionStart = 13;
         CFG_InpSessionEnd = 17;
         CFG_InpDailyLossUSD = 10.00;
         CFG_InpDailyTargetUSD = 0.00;
         break;
      case TP_S5_Random:
         CFG_InpMaxPositions = 3;
         CFG_InpMinMarginLevel = 300.00;
         CFG_InpMode = 0;
         CFG_InpEntryMode = 3;
         CFG_InpTP_ATR = 3.50;
         CFG_InpSL_ATR = 2.00;
         CFG_InpTrailStart_ATR = 1.20;
         CFG_InpTrail_ATR = 1.00;
         CFG_InpSessionStart = 13;
         CFG_InpSessionEnd = 17;
         CFG_InpDailyLossUSD = 10.00;
         CFG_InpDailyTargetUSD = 50.00;
         break;
      case TP_S5_Random_N:
         CFG_InpMaxPositions = 3;
         CFG_InpMinMarginLevel = 300.00;
         CFG_InpMode = 0;
         CFG_InpEntryMode = 3;
         CFG_InpTP_ATR = 3.50;
         CFG_InpSL_ATR = 2.00;
         CFG_InpTrailStart_ATR = 1.20;
         CFG_InpTrail_ATR = 1.00;
         CFG_InpSessionStart = 13;
         CFG_InpSessionEnd = 17;
         CFG_InpDailyLossUSD = 10.00;
         CFG_InpDailyTargetUSD = 0.00;
         break;
      case TP_S6_Trail:
         CFG_InpMaxPositions = 3;
         CFG_InpMinMarginLevel = 300.00;
         CFG_InpMode = 0;
         CFG_InpEntryMode = 0;
         CFG_InpTP_ATR = 5.00;
         CFG_InpSL_ATR = 2.00;
         CFG_InpTrailStart_ATR = 1.20;
         CFG_InpTrail_ATR = 1.00;
         CFG_InpSessionStart = 13;
         CFG_InpSessionEnd = 17;
         CFG_InpDailyLossUSD = 10.00;
         CFG_InpDailyTargetUSD = 50.00;
         break;
      case TP_S6_Trail_N:
         CFG_InpMaxPositions = 3;
         CFG_InpMinMarginLevel = 300.00;
         CFG_InpMode = 0;
         CFG_InpEntryMode = 0;
         CFG_InpTP_ATR = 5.00;
         CFG_InpSL_ATR = 2.00;
         CFG_InpTrailStart_ATR = 1.20;
         CFG_InpTrail_ATR = 1.00;
         CFG_InpSessionStart = 13;
         CFG_InpSessionEnd = 17;
         CFG_InpDailyLossUSD = 10.00;
         CFG_InpDailyTargetUSD = 0.00;
         break;
      case TP_S7_Session:
         CFG_InpMaxPositions = 3;
         CFG_InpMinMarginLevel = 300.00;
         CFG_InpMode = 0;
         CFG_InpEntryMode = 0;
         CFG_InpTP_ATR = 2.00;
         CFG_InpSL_ATR = 2.00;
         CFG_InpTrailStart_ATR = 1.20;
         CFG_InpTrail_ATR = 1.00;
         CFG_InpSessionStart = 1;
         CFG_InpSessionEnd = 20;
         CFG_InpDailyLossUSD = 10.00;
         CFG_InpDailyTargetUSD = 50.00;
         break;
      case TP_S7_Session_N:
         CFG_InpMaxPositions = 3;
         CFG_InpMinMarginLevel = 300.00;
         CFG_InpMode = 0;
         CFG_InpEntryMode = 0;
         CFG_InpTP_ATR = 2.00;
         CFG_InpSL_ATR = 2.00;
         CFG_InpTrailStart_ATR = 1.20;
         CFG_InpTrail_ATR = 1.00;
         CFG_InpSessionStart = 1;
         CFG_InpSessionEnd = 20;
         CFG_InpDailyLossUSD = 10.00;
         CFG_InpDailyTargetUSD = 0.00;
         break;
      case TP_S8_Hedge4:
         CFG_InpMaxPositions = 4;
         CFG_InpMinMarginLevel = 250.00;
         CFG_InpMode = 1;
         CFG_InpEntryMode = 0;
         CFG_InpTP_ATR = 2.00;
         CFG_InpSL_ATR = 2.00;
         CFG_InpTrailStart_ATR = 1.20;
         CFG_InpTrail_ATR = 1.00;
         CFG_InpSessionStart = 13;
         CFG_InpSessionEnd = 17;
         CFG_InpDailyLossUSD = 10.00;
         CFG_InpDailyTargetUSD = 50.00;
         break;
      case TP_S8_Hedge4_N:
         CFG_InpMaxPositions = 4;
         CFG_InpMinMarginLevel = 250.00;
         CFG_InpMode = 1;
         CFG_InpEntryMode = 0;
         CFG_InpTP_ATR = 2.00;
         CFG_InpSL_ATR = 2.00;
         CFG_InpTrailStart_ATR = 1.20;
         CFG_InpTrail_ATR = 1.00;
         CFG_InpSessionStart = 13;
         CFG_InpSessionEnd = 17;
         CFG_InpDailyLossUSD = 10.00;
         CFG_InpDailyTargetUSD = 0.00;
         break;
      case TP_S9_Hybrid:
         CFG_InpMaxPositions = 4;
         CFG_InpMinMarginLevel = 250.00;
         CFG_InpMode = 5;
         CFG_InpEntryMode = 0;
         CFG_InpTP_ATR = 2.00;
         CFG_InpSL_ATR = 2.00;
         CFG_InpTrailStart_ATR = 1.20;
         CFG_InpTrail_ATR = 1.00;
         CFG_InpSessionStart = 13;
         CFG_InpSessionEnd = 17;
         CFG_InpDailyLossUSD = 10.00;
         CFG_InpDailyTargetUSD = 50.00;
         break;
      case TP_S9_Hybrid_N:
         CFG_InpMaxPositions = 4;
         CFG_InpMinMarginLevel = 250.00;
         CFG_InpMode = 5;
         CFG_InpEntryMode = 0;
         CFG_InpTP_ATR = 2.00;
         CFG_InpSL_ATR = 2.00;
         CFG_InpTrailStart_ATR = 1.20;
         CFG_InpTrail_ATR = 1.00;
         CFG_InpSessionStart = 13;
         CFG_InpSessionEnd = 17;
         CFG_InpDailyLossUSD = 10.00;
         CFG_InpDailyTargetUSD = 0.00;
         break;
      case TP_S10_Adaptive:
         CFG_InpMaxPositions = 4;
         CFG_InpMinMarginLevel = 250.00;
         CFG_InpMode = 3;
         CFG_InpEntryMode = 0;
         CFG_InpTP_ATR = 2.00;
         CFG_InpSL_ATR = 2.00;
         CFG_InpTrailStart_ATR = 1.20;
         CFG_InpTrail_ATR = 1.00;
         CFG_InpSessionStart = 13;
         CFG_InpSessionEnd = 17;
         CFG_InpDailyLossUSD = 10.00;
         CFG_InpDailyTargetUSD = 50.00;
         break;
      case TP_S10_Adaptive_N:
         CFG_InpMaxPositions = 4;
         CFG_InpMinMarginLevel = 250.00;
         CFG_InpMode = 3;
         CFG_InpEntryMode = 0;
         CFG_InpTP_ATR = 2.00;
         CFG_InpSL_ATR = 2.00;
         CFG_InpTrailStart_ATR = 1.20;
         CFG_InpTrail_ATR = 1.00;
         CFG_InpSessionStart = 13;
         CFG_InpSessionEnd = 17;
         CFG_InpDailyLossUSD = 10.00;
         CFG_InpDailyTargetUSD = 0.00;
         break;
      case TP_S11_AdaptiveRnd:
         CFG_InpMaxPositions = 4;
         CFG_InpMinMarginLevel = 250.00;
         CFG_InpMode = 4;
         CFG_InpEntryMode = 0;
         CFG_InpTP_ATR = 2.00;
         CFG_InpSL_ATR = 2.00;
         CFG_InpTrailStart_ATR = 1.20;
         CFG_InpTrail_ATR = 1.00;
         CFG_InpSessionStart = 13;
         CFG_InpSessionEnd = 17;
         CFG_InpDailyLossUSD = 10.00;
         CFG_InpDailyTargetUSD = 50.00;
         break;
      case TP_S11_AdaptiveRnd_N:
         CFG_InpMaxPositions = 4;
         CFG_InpMinMarginLevel = 250.00;
         CFG_InpMode = 4;
         CFG_InpEntryMode = 0;
         CFG_InpTP_ATR = 2.00;
         CFG_InpSL_ATR = 2.00;
         CFG_InpTrailStart_ATR = 1.20;
         CFG_InpTrail_ATR = 1.00;
         CFG_InpSessionStart = 13;
         CFG_InpSessionEnd = 17;
         CFG_InpDailyLossUSD = 10.00;
         CFG_InpDailyTargetUSD = 0.00;
         break;
      case TP_X1_TP20_SL20:
         CFG_InpMaxPositions = 3;
         CFG_InpMinMarginLevel = 300.00;
         CFG_InpMode = 0;
         CFG_InpEntryMode = 0;
         CFG_InpTP_ATR = 2.00;
         CFG_InpSL_ATR = 2.00;
         CFG_InpTrailStart_ATR = 0.00;
         CFG_InpTrail_ATR = 0.00;
         CFG_InpSessionStart = 13;
         CFG_InpSessionEnd = 17;
         CFG_InpDailyLossUSD = 10.00;
         CFG_InpDailyTargetUSD = 50.00;
         break;
      case TP_X1_TP20_SL20_N:
         CFG_InpMaxPositions = 3;
         CFG_InpMinMarginLevel = 300.00;
         CFG_InpMode = 0;
         CFG_InpEntryMode = 0;
         CFG_InpTP_ATR = 2.00;
         CFG_InpSL_ATR = 2.00;
         CFG_InpTrailStart_ATR = 0.00;
         CFG_InpTrail_ATR = 0.00;
         CFG_InpSessionStart = 13;
         CFG_InpSessionEnd = 17;
         CFG_InpDailyLossUSD = 10.00;
         CFG_InpDailyTargetUSD = 0.00;
         break;
      case TP_X2_TP13_SL20:
         CFG_InpMaxPositions = 3;
         CFG_InpMinMarginLevel = 300.00;
         CFG_InpMode = 0;
         CFG_InpEntryMode = 0;
         CFG_InpTP_ATR = 1.30;
         CFG_InpSL_ATR = 2.00;
         CFG_InpTrailStart_ATR = 0.00;
         CFG_InpTrail_ATR = 0.00;
         CFG_InpSessionStart = 13;
         CFG_InpSessionEnd = 17;
         CFG_InpDailyLossUSD = 10.00;
         CFG_InpDailyTargetUSD = 50.00;
         break;
      case TP_X2_TP13_SL20_N:
         CFG_InpMaxPositions = 3;
         CFG_InpMinMarginLevel = 300.00;
         CFG_InpMode = 0;
         CFG_InpEntryMode = 0;
         CFG_InpTP_ATR = 1.30;
         CFG_InpSL_ATR = 2.00;
         CFG_InpTrailStart_ATR = 0.00;
         CFG_InpTrail_ATR = 0.00;
         CFG_InpSessionStart = 13;
         CFG_InpSessionEnd = 17;
         CFG_InpDailyLossUSD = 10.00;
         CFG_InpDailyTargetUSD = 0.00;
         break;
      case TP_X3_TP20_SL13:
         CFG_InpMaxPositions = 3;
         CFG_InpMinMarginLevel = 300.00;
         CFG_InpMode = 0;
         CFG_InpEntryMode = 0;
         CFG_InpTP_ATR = 2.00;
         CFG_InpSL_ATR = 1.30;
         CFG_InpTrailStart_ATR = 0.00;
         CFG_InpTrail_ATR = 0.00;
         CFG_InpSessionStart = 13;
         CFG_InpSessionEnd = 17;
         CFG_InpDailyLossUSD = 10.00;
         CFG_InpDailyTargetUSD = 50.00;
         break;
      case TP_X3_TP20_SL13_N:
         CFG_InpMaxPositions = 3;
         CFG_InpMinMarginLevel = 300.00;
         CFG_InpMode = 0;
         CFG_InpEntryMode = 0;
         CFG_InpTP_ATR = 2.00;
         CFG_InpSL_ATR = 1.30;
         CFG_InpTrailStart_ATR = 0.00;
         CFG_InpTrail_ATR = 0.00;
         CFG_InpSessionStart = 13;
         CFG_InpSessionEnd = 17;
         CFG_InpDailyLossUSD = 10.00;
         CFG_InpDailyTargetUSD = 0.00;
         break;
      case TP_X4_TP15_SL15:
         CFG_InpMaxPositions = 3;
         CFG_InpMinMarginLevel = 300.00;
         CFG_InpMode = 0;
         CFG_InpEntryMode = 0;
         CFG_InpTP_ATR = 1.50;
         CFG_InpSL_ATR = 1.50;
         CFG_InpTrailStart_ATR = 0.00;
         CFG_InpTrail_ATR = 0.00;
         CFG_InpSessionStart = 13;
         CFG_InpSessionEnd = 17;
         CFG_InpDailyLossUSD = 10.00;
         CFG_InpDailyTargetUSD = 50.00;
         break;
      case TP_X4_TP15_SL15_N:
         CFG_InpMaxPositions = 3;
         CFG_InpMinMarginLevel = 300.00;
         CFG_InpMode = 0;
         CFG_InpEntryMode = 0;
         CFG_InpTP_ATR = 1.50;
         CFG_InpSL_ATR = 1.50;
         CFG_InpTrailStart_ATR = 0.00;
         CFG_InpTrail_ATR = 0.00;
         CFG_InpSessionStart = 13;
         CFG_InpSessionEnd = 17;
         CFG_InpDailyLossUSD = 10.00;
         CFG_InpDailyTargetUSD = 0.00;
         break;
      case TP_X5_TP30_SL15:
         CFG_InpMaxPositions = 3;
         CFG_InpMinMarginLevel = 300.00;
         CFG_InpMode = 0;
         CFG_InpEntryMode = 0;
         CFG_InpTP_ATR = 3.00;
         CFG_InpSL_ATR = 1.50;
         CFG_InpTrailStart_ATR = 0.00;
         CFG_InpTrail_ATR = 0.00;
         CFG_InpSessionStart = 13;
         CFG_InpSessionEnd = 17;
         CFG_InpDailyLossUSD = 10.00;
         CFG_InpDailyTargetUSD = 50.00;
         break;
      case TP_X5_TP30_SL15_N:
         CFG_InpMaxPositions = 3;
         CFG_InpMinMarginLevel = 300.00;
         CFG_InpMode = 0;
         CFG_InpEntryMode = 0;
         CFG_InpTP_ATR = 3.00;
         CFG_InpSL_ATR = 1.50;
         CFG_InpTrailStart_ATR = 0.00;
         CFG_InpTrail_ATR = 0.00;
         CFG_InpSessionStart = 13;
         CFG_InpSessionEnd = 17;
         CFG_InpDailyLossUSD = 10.00;
         CFG_InpDailyTargetUSD = 0.00;
         break;
      case TP_X6_MaxPos1:
         CFG_InpMaxPositions = 1;
         CFG_InpMinMarginLevel = 300.00;
         CFG_InpMode = 0;
         CFG_InpEntryMode = 0;
         CFG_InpTP_ATR = 2.00;
         CFG_InpSL_ATR = 2.00;
         CFG_InpTrailStart_ATR = 1.20;
         CFG_InpTrail_ATR = 1.00;
         CFG_InpSessionStart = 13;
         CFG_InpSessionEnd = 17;
         CFG_InpDailyLossUSD = 10.00;
         CFG_InpDailyTargetUSD = 50.00;
         break;
      case TP_X6_MaxPos1_N:
         CFG_InpMaxPositions = 1;
         CFG_InpMinMarginLevel = 300.00;
         CFG_InpMode = 0;
         CFG_InpEntryMode = 0;
         CFG_InpTP_ATR = 2.00;
         CFG_InpSL_ATR = 2.00;
         CFG_InpTrailStart_ATR = 1.20;
         CFG_InpTrail_ATR = 1.00;
         CFG_InpSessionStart = 13;
         CFG_InpSessionEnd = 17;
         CFG_InpDailyLossUSD = 10.00;
         CFG_InpDailyTargetUSD = 0.00;
         break;
      case TP_Y1_LossOff:
         CFG_InpMaxPositions = 3;
         CFG_InpMinMarginLevel = 300.00;
         CFG_InpMode = 0;
         CFG_InpEntryMode = 0;
         CFG_InpTP_ATR = 2.00;
         CFG_InpSL_ATR = 2.00;
         CFG_InpTrailStart_ATR = 1.20;
         CFG_InpTrail_ATR = 1.00;
         CFG_InpSessionStart = 13;
         CFG_InpSessionEnd = 17;
         CFG_InpDailyLossUSD = 0.00;
         CFG_InpDailyTargetUSD = 0.00;
         break;
      case TP_Y2_LossOff_T50:
         CFG_InpMaxPositions = 3;
         CFG_InpMinMarginLevel = 300.00;
         CFG_InpMode = 0;
         CFG_InpEntryMode = 0;
         CFG_InpTP_ATR = 2.00;
         CFG_InpSL_ATR = 2.00;
         CFG_InpTrailStart_ATR = 1.20;
         CFG_InpTrail_ATR = 1.00;
         CFG_InpSessionStart = 13;
         CFG_InpSessionEnd = 17;
         CFG_InpDailyLossUSD = 0.00;
         CFG_InpDailyTargetUSD = 50.00;
         break;
      case TP_Y3_Loss30:
         CFG_InpMaxPositions = 3;
         CFG_InpMinMarginLevel = 300.00;
         CFG_InpMode = 0;
         CFG_InpEntryMode = 0;
         CFG_InpTP_ATR = 2.00;
         CFG_InpSL_ATR = 2.00;
         CFG_InpTrailStart_ATR = 1.20;
         CFG_InpTrail_ATR = 1.00;
         CFG_InpSessionStart = 13;
         CFG_InpSessionEnd = 17;
         CFG_InpDailyLossUSD = 30.00;
         CFG_InpDailyTargetUSD = 0.00;
         break;
      case TP_Y4_Loss30_T50:
         CFG_InpMaxPositions = 3;
         CFG_InpMinMarginLevel = 300.00;
         CFG_InpMode = 0;
         CFG_InpEntryMode = 0;
         CFG_InpTP_ATR = 2.00;
         CFG_InpSL_ATR = 2.00;
         CFG_InpTrailStart_ATR = 1.20;
         CFG_InpTrail_ATR = 1.00;
         CFG_InpSessionStart = 13;
         CFG_InpSessionEnd = 17;
         CFG_InpDailyLossUSD = 30.00;
         CFG_InpDailyTargetUSD = 50.00;
         break;
      //--- experiment Z: same exits as Y1_LossOff (the honest per-trade
      //--- measurement, no day stops), entry changed in one switch only
      case TP_Z1_PullHTF:
      case TP_Z2_RndHTF:
      case TP_Z3_Rnd:
         CFG_InpMaxPositions = 3;
         CFG_InpMinMarginLevel = 300.00;
         CFG_InpMode = 0;
         CFG_InpEntryMode = (InpPreset == TP_Z1_PullHTF) ? 0 : 3;
         CFG_InpTP_ATR = 2.00;
         CFG_InpSL_ATR = 2.00;
         CFG_InpTrailStart_ATR = 1.20;
         CFG_InpTrail_ATR = 1.00;
         CFG_InpSessionStart = 13;
         CFG_InpSessionEnd = 17;
         CFG_InpDailyLossUSD = 0.00;
         CFG_InpDailyTargetUSD = 0.00;
         CFG_InpHTFFilter = (InpPreset != TP_Z3_Rnd);
         break;
      //--- experiment Q: the owner's M1 scalper - about 20 trades a day,
      //--- 1-4 USD per trade, small losses. One position at a time, the
      //--- London + New York hours, no trailing, no day stops (so the
      //--- per-trade number is clean). Each has its random twin.
      case TP_Q1_M1_TP2SL2:
      case TP_Q2_M1_TP2SL2_Rnd:
      case TP_Q3_M1_TP3SL15:
      case TP_Q4_M1_TP3SL15_Rnd:
         CFG_InpMaxPositions = 1;
         CFG_InpMinMarginLevel = 300.00;
         CFG_InpMode = 0;
         CFG_InpEntryMode = (InpPreset == TP_Q1_M1_TP2SL2 || InpPreset == TP_Q3_M1_TP3SL15) ? 0 : 3;
         CFG_InpTP_ATR = 2.00;            // unused: fixed distances below
         CFG_InpSL_ATR = 2.00;
         CFG_InpTrailStart_ATR = 0.00;    // trailing off
         CFG_InpTrail_ATR = 1.00;
         CFG_InpSessionStart = 8;
         CFG_InpSessionEnd = 20;
         CFG_InpDailyLossUSD = 0.00;
         CFG_InpDailyTargetUSD = 0.00;
         CFG_InpMaxTradesDay = 20;
         g_tf = PERIOD_M1;
         if(InpPreset == TP_Q1_M1_TP2SL2 || InpPreset == TP_Q2_M1_TP2SL2_Rnd)
           { CFG_InpTP_Price = 2.00; CFG_InpSL_Price = 2.00; }
         else
           { CFG_InpTP_Price = 3.00; CFG_InpSL_Price = 1.50; }
         break;
      //--- experiment P: the owner's pulse cycle. No trade limit, the
      //--- only brake is a 30 USD day loss (stop for the day). Every leg
      //--- has a 5 USD broker stop; trail/trigger/add use the Pulse inputs.
      case TP_P1_Pulse:
      case TP_P2_PulseRnd:
      case TP_P3_PulseSpr:
      case TP_P4_PulseSprRnd:
      case TP_P5_PulseVirt:
      case TP_P6_PulseVirtRnd:
         CFG_InpMaxPositions = 4;
         CFG_InpMinMarginLevel = 300.00;
         CFG_InpMode = 6;
         CFG_InpEntryMode = 0;
         CFG_InpTP_ATR = 2.00;
         CFG_InpSL_ATR = 2.00;
         CFG_InpTrailStart_ATR = 0.00;
         CFG_InpTrail_ATR = 1.00;
         CFG_InpSessionStart = 8;
         CFG_InpSessionEnd = 20;
         CFG_InpDailyLossUSD = 30.00;
         CFG_InpDailyTargetUSD = 0.00;
         CFG_InpMaxTradesDay = 0;
         g_tf = PERIOD_M1;
         CFG_InpPulseRandom = (InpPreset == TP_P2_PulseRnd || InpPreset == TP_P4_PulseSprRnd ||
                               InpPreset == TP_P6_PulseVirtRnd);
         //P3..P6: the P1 logic untouched, only the cost of a cycle changes
         if(InpPreset >= TP_P3_PulseSpr) CFG_InpPulseMaxSpread = 0.20;
         CFG_InpPulseVirtual = (InpPreset == TP_P5_PulseVirt || InpPreset == TP_P6_PulseVirtRnd);
         break;
     }

   PrintFormat("TwinPulseONE preset %s applied (20 config values overridden)",
               TP_PresetLabel());
  }
//+------------------------------------------------------------------+


//==================================================================
CTrade   trade;
int      hFast = INVALID_HANDLE;
int      hSlow = INVALID_HANDLE;
int      hATR  = INVALID_HANDLE;
int      hBB   = INVALID_HANDLE;
int      hRSI  = INVALID_HANDLE;
int      hADX  = INVALID_HANDLE;
int      hHTF  = INVALID_HANDLE;   // H1 EMA, only when the trend filter is on

int      g_csv = INVALID_HANDLE;
string   g_csvName = "TwinPulse_legs.csv";
int      g_log = INVALID_HANDLE;

//--- open positions we track
#define MAXPOS 16
struct ScalpPos
  {
   ulong    ticket;
   int      side;          // +1 long, -1 short
   double   entry;
   double   lots;
   double   sl;
   double   tp;
   double   atr;
   double   spread;
   double   spreadUSD;     // what the spread cost this leg at the open, in USD
   double   stopDist;
   double   trailStart;
   double   trailDist;
   datetime openTime;
   bool     trailOn;
   int      nBuyAtOpen;    // the book this leg was opened into - the CSV row
   int      nSellAtOpen;   // must describe the decision, not the aftermath
  };
ScalpPos g_pos[MAXPOS];
int      g_nPos = 0;

//--- multi-leg bookkeeping
bool     g_closingAll = false;   // a daily stop is closing everything
datetime g_closeAllUntil = 0;    // classify deals until this moment as daily_exit
int      g_nBuy  = 0;            // open legs by side
int      g_nSell = 0;
double   g_dayFloating = 0.0;    // floating P/L of our open legs
string   g_splitTag = "0B0S";    // the book RIGHT NOW, for the log
int      g_legsAtOpen = 0;
string   g_rowSplit = "0B0S";    // the book that a CSV row describes
int      g_rowLegs = 0;

//--- adaptive statistics
long     g_legSum = 0;           // sum of open-leg counts sampled every tick
long     g_legSamples = 0;
int      g_legMax = 0;

//--- day state
datetime g_dayAnchor    = 0;
double   g_dayStartEquity = 0.0;
double   g_dayNet       = 0.0;
bool     g_dayLocked    = false;
int      g_dayTrades    = 0;      // new trades opened today
double   g_daySpreadSum = 0.0;    // spread paid at each open today (for the day summary)
int      g_daySpreadN   = 0;
int      g_runOpens     = 0;      // whole run, for the run summary (demo review)
double   g_runNet       = 0.0;
int      g_runDays      = 0;
int      g_runWinDays   = 0;
int      g_runStopDays  = 0;
datetime g_runStart     = 0;
datetime g_lastPanel    = 0;
datetime g_lastCloseTry = 0;      // retry a day stop whose close-all failed

int      g_cycle = 0;
datetime g_lastBarM5    = 0;

//--- stats printed at the end
int      g_opens = 0;
int      g_skipsSpread = 0;
int      g_skipsTP = 0;
int      g_modFail = 0;

//==================================================================
//  session block (same proven logic as TwinPulseTrend)
//==================================================================
#define TP_MAX_SESSIONS 8

bool     g_sessLoaded = false;
bool     g_sessValid  = false;
datetime g_sessFrom[7][TP_MAX_SESSIONS];
datetime g_sessTo[7][TP_MAX_SESSIONS];
int      g_sessCount[7];

ulong    g_modBlockTicket = 0;
datetime g_modBlockUntil  = 0;
ulong    g_modLoggedTicket = 0;
int      g_modSuppressed  = 0;

int TP_SecOfDay(datetime t)
  {
   MqlDateTime d;
   TimeToStruct(t, d);
   return (d.hour * 3600 + d.min * 60 + d.sec);
  }

datetime TP_DayStart(datetime t)
  {
   MqlDateTime d;
   TimeToStruct(t, d);
   d.hour = 0;
   d.min  = 0;
   d.sec  = 0;
   return StructToTime(d);
  }

void TP_LoadSessions(void)
  {
   g_sessLoaded = true;
   g_sessValid  = false;
   for(int d = 0; d < 7; d++)
     {
      g_sessCount[d] = 0;
      for(uint i = 0; i < TP_MAX_SESSIONS; i++)
        {
         datetime from = 0;
         datetime to   = 0;
         if(!SymbolInfoSessionTrade(_Symbol, (ENUM_DAY_OF_WEEK)d, i, from, to))
            break;
         g_sessFrom[d][g_sessCount[d]] = from;
         g_sessTo[d][g_sessCount[d]]   = to;
         g_sessCount[d]++;
         g_sessValid = true;
        }
     }
  }

bool TP_SessionOpenAt(datetime t)
  {
   if(!g_sessLoaded) TP_LoadSessions();
   if(!g_sessValid) return true;

   int secs = TP_SecOfDay(t);
   MqlDateTime d;
   TimeToStruct(t, d);
   int dow = d.day_of_week;

   for(int i = 0; i < g_sessCount[dow]; i++)
     {
      int f = TP_SecOfDay(g_sessFrom[dow][i]);
      int e = TP_SecOfDay(g_sessTo[dow][i]);
      if(e == 0) e = 86400;
      if(f <= e)
        {
         if(secs >= f && secs < e) return true;
        }
      else
        {
         if(secs >= f) return true;
        }
     }

   int ydow = (dow + 6) % 7;
   for(int i = 0; i < g_sessCount[ydow]; i++)
     {
      int f = TP_SecOfDay(g_sessFrom[ydow][i]);
      int e = TP_SecOfDay(g_sessTo[ydow][i]);
      if(e == 0) e = 86400;
      if(f > e && secs < e) return true;
     }
   return false;
  }

datetime TP_NextSessionOpen(datetime t)
  {
   if(!g_sessLoaded) TP_LoadSessions();
   if(!g_sessValid) return 0;

   datetime day = TP_DayStart(t);
   for(int add = 0; add <= 8; add++)
     {
      datetime base = day + (datetime)(add * 86400);
      MqlDateTime d;
      TimeToStruct(base, d);
      int dow = d.day_of_week;
      datetime best = 0;
      for(int i = 0; i < g_sessCount[dow]; i++)
        {
         int f = TP_SecOfDay(g_sessFrom[dow][i]);
         datetime cand = base + (datetime)f;
         if(cand <= t) continue;
         if(best == 0 || cand < best) best = cand;
        }
      if(best != 0) return best;
     }
   return 0;
  }

bool TP_MarketOpen(void)
  {
   if(SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE) == SYMBOL_TRADE_MODE_DISABLED)
      return false;
   return TP_SessionOpenAt(TimeCurrent());
  }

//==================================================================
//  logging + csv
//==================================================================
void TP_Log(string msg)
  {
   if(!InpVerboseLog) return;
   if(g_log == INVALID_HANDLE) return;
   FileWrite(g_log, TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS), msg);
   FileFlush(g_log);
  }

void TP_CsvHeader(void)
  {
   if(!InpWriteCsv) return;
   if(g_csv == INVALID_HANDLE) return;
   FileWrite(g_csv, "time", "cycle", "leg", "side", "volume", "open_price",
             "close_price", "reason", "profit", "pos_net", "bank", "regime",
             "spread", "atr5", "spread_open", "spread_cost", "gross", "stop_dist",
             "split", "open_legs");
  }

void TP_CsvRow(datetime when, string leg, int side, double lots, double entry,
               double exitPx, string reason, double profit, double swap,
               double comm, double atr, double spread, double stopDist)
  {
   if(!InpWriteCsv) return;
   if(g_csv == INVALID_HANDLE) return;

   string sideName = "short";
   if(side > 0) sideName = "long";

   double posNet = profit + swap + comm;
   double cost   = spread * lots * 100.0;   // spread cost at 100 oz contract

   FileWrite(g_csv,
             TimeToString(when, TIME_DATE | TIME_SECONDS),
             IntegerToString(g_cycle),
             leg,
             sideName,
             DoubleToString(lots, 2),
             DoubleToString(entry, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS)),
             DoubleToString(exitPx, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS)),
             reason,
             DoubleToString(profit, 2),
             DoubleToString(posNet, 2),
             "0",
             "",
             DoubleToString(spread, 3),
             DoubleToString(atr, 3),
             DoubleToString(spread, 3),
             DoubleToString(cost, 2),
             DoubleToString(profit, 2),
             DoubleToString(stopDist, 3),
             g_rowSplit,
             IntegerToString(g_rowLegs));
   FileFlush(g_csv);
  }

//==================================================================
//  small helpers
//==================================================================
double TP_Ask(void) { return SymbolInfoDouble(_Symbol, SYMBOL_ASK); }
double TP_Bid(void) { return SymbolInfoDouble(_Symbol, SYMBOL_BID); }
double TP_Point(void)
  {
   double p = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   if(p <= 0.0) p = 0.01;
   return p;
  }
int TP_Digits(void) { return (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS); }
double TP_Spread(void)
  {
   double a = TP_Ask();
   double b = TP_Bid();
   if(a <= 0.0 || b <= 0.0) return 0.0;
   return (a - b);
  }
double TP_NormPrice(double p) { return NormalizeDouble(p, TP_Digits()); }

double TP_NormLots(double lots)
  {
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(step <= 0.0) step = 0.01;
   lots = MathFloor(lots / step + 0.0000001) * step;
   if(lots < minLot) lots = minLot;
   if(lots > maxLot) lots = maxLot;
   return NormalizeDouble(lots, 2);
  }

double TP_StopsLevel(void)
  {
   long lvl = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   if(lvl < 0) lvl = 0;
   return ((double)lvl) * TP_Point();
  }

//==================================================================
//  indicators
//==================================================================
bool TP_Ind(double &fast, double &slow, double &atr,
            double &bbUp, double &bbLo, double &rsi)
  {
   double bf[3], bs[3], ba[3], bu[3], bl[3], br[3];
   if(CopyBuffer(hFast, 0, 0, 3, bf) < 3) return false;
   if(CopyBuffer(hSlow, 0, 0, 3, bs) < 3) return false;
   if(CopyBuffer(hATR,  0, 0, 3, ba) < 3) return false;
   if(CopyBuffer(hBB,   1, 0, 3, bu) < 3) return false;   // upper band
   if(CopyBuffer(hBB,   2, 0, 3, bl) < 3) return false;   // lower band
   if(CopyBuffer(hRSI,  0, 0, 3, br) < 3) return false;

   fast = bf[1];
   slow = bs[1];
   atr  = ba[1];
   bbUp = bu[1];
   bbLo = bl[1];
   rsi  = br[1];
   return (atr > 0.0);
  }

//==================================================================
//  position bookkeeping
//==================================================================
int TP_Idx(ulong ticket)
  {
   for(int i = 0; i < g_nPos; i++)
      if(g_pos[i].ticket == ticket) return i;
   return -1;
  }

//--- legs that left g_pos recently. In the tester a stop/target is filled
//--- before OnTick, OnTick's TP_Sync drops the slot, and only THEN does
//--- OnTradeTransaction arrive - so it found no slot and every row came out
//--- as side=long, reason=stop (1.13 run: "all 3307 trades have reason stop").
#define TP_RECENT 32
ScalpPos g_recent[TP_RECENT];
int      g_recentNext = 0;

void TP_RemoveIdx(int idx)
  {
   if(idx < 0 || idx >= g_nPos) return;
   g_recent[g_recentNext] = g_pos[idx];
   g_recentNext = (g_recentNext + 1) % TP_RECENT;
   for(int i = idx; i < g_nPos - 1; i++) g_pos[i] = g_pos[i + 1];
   if(g_nPos > 0) g_nPos--;
  }

int TP_RecentIdx(ulong ticket)
  {
   for(int i = 0; i < TP_RECENT; i++)
      if(g_recent[i].ticket == ticket && ticket != 0) return i;
   return -1;
  }

void TP_Sync(void)
  {
   //--- drop the slots whose position is gone
   for(int i = g_nPos - 1; i >= 0; i--)
     {
      if(!PositionSelectByTicket(g_pos[i].ticket))
         TP_RemoveIdx(i);
     }

   //--- adopt positions of ours we do not track (restart, tester reload)
   for(int i = 0; i < PositionsTotal(); i++)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      if(TP_Idx(t) >= 0) continue;
      if(g_nPos >= MAXPOS) break;

      int k = g_nPos;
      g_pos[k].ticket   = t;
      g_pos[k].entry    = PositionGetDouble(POSITION_PRICE_OPEN);
      g_pos[k].lots     = PositionGetDouble(POSITION_VOLUME);
      g_pos[k].sl       = PositionGetDouble(POSITION_SL);
      g_pos[k].tp       = PositionGetDouble(POSITION_TP);
      g_pos[k].openTime = (datetime)PositionGetInteger(POSITION_TIME);
      g_pos[k].side     = 1;
      if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL) g_pos[k].side = -1;
      g_pos[k].atr        = 0.0;
      g_pos[k].spread     = 0.0;
      g_pos[k].spreadUSD  = 0.0;   // unknown for an adopted leg: judged strictly
      g_pos[k].stopDist   = 0.0;   // 0 = not initialised by TP_Open yet
      g_pos[k].trailStart = 0.0;
      g_pos[k].trailDist  = 0.0;
      g_pos[k].trailOn    = false;
      g_pos[k].nBuyAtOpen  = 0;
      g_pos[k].nSellAtOpen = 0;
      g_nPos++;
     }
  }

//==================================================================
//  the book: counts, floating P/L, split tag
//==================================================================
void TP_RecountBook(void)
  {
   g_nBuy = 0;
   g_nSell = 0;
   g_dayFloating = 0.0;

   for(int i = 0; i < g_nPos; i++)
     {
      if(!PositionSelectByTicket(g_pos[i].ticket)) continue;
      if(g_pos[i].side > 0) g_nBuy++;
      else                  g_nSell++;
      g_dayFloating += PositionGetDouble(POSITION_PROFIT) +
                       PositionGetDouble(POSITION_SWAP);
     }
   g_splitTag = StringFormat("%dB%dS", g_nBuy, g_nSell);

   int open = g_nBuy + g_nSell;
   if(open > g_legMax) g_legMax = open;
   g_legSum += open;
   g_legSamples++;
  }

//--- the spread, as money for a given volume
double TP_SpreadUSD(double spread, double lots)
  {
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   if(tickSize <= 0.0 || tickValue <= 0.0 || spread <= 0.0) return 0.0;
   return spread / tickSize * tickValue * lots;
  }

//--- P/L of one leg as the side rules judge it.
//--- Mode 0 keeps the measured behaviour (plain P/L, so every old result
//--- stays comparable). The multi-leg modes add back the spread the leg paid
//--- at the open: a leg that is exactly at -spread has not moved against us,
//--- and judging it as a loser made the 2B+2S book impossible to build -
//--- the second side was always refused one tick after the first opened.
double TP_LegJudgedProfit(int i)
  {
   double p = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
   if(CFG_InpMode != 0) p += g_pos[i].spreadUSD;
   return p;
  }

//--- total P/L of one side, in USD
double TP_SideProfit(int side)
  {
   double sum = 0.0;
   for(int i = 0; i < g_nPos; i++)
     {
      if(g_pos[i].side != side) continue;
      if(!PositionSelectByTicket(g_pos[i].ticket)) continue;
      sum += TP_LegJudgedProfit(i);
     }
   return sum;
  }

//--- is any open leg on this side losing?
bool TP_SideHasLoser(int side)
  {
   for(int i = 0; i < g_nPos; i++)
     {
      if(g_pos[i].side != side) continue;
      if(!PositionSelectByTicket(g_pos[i].ticket)) continue;
      if(TP_LegJudgedProfit(i) < 0.0) return true;
     }
   return false;
  }

//==================================================================
//  market score -> target counts
//==================================================================
double TP_Clamp(double v, double lo, double hi)
  {
   if(v < lo) return lo;
   if(v > hi) return hi;
   return v;
  }

double TP_MarketScore(double fast, double slow, double atr, double adx,
                      double bbUp, double bbLo, double close1)
  {
   //--- 1) EMA slope over two bars, in ATR units
   double f3[4];
   double slope = 0.0;
   if(CopyBuffer(hFast, 0, 1, 4, f3) >= 4)
     {
      //f3 is not a series array: CopyBuffer fills it oldest first, so
      //f3[3] = bar 1 and f3[1] = bar 3. The old line (f3[0] - f3[2]) was
      //bar 4 minus bar 2 - the slope with its SIGN INVERTED, which pushed
      //the adaptive/hybrid split against the trend (40% of the score).
      double d = (f3[3] - f3[1]) / atr;
      slope = TP_Clamp(d / 0.50, -1.0, 1.0);
     }

   //--- 2) ADX strength, sign from the EMA stack
   double strength = TP_Clamp((adx - 18.0) / 18.0, 0.0, 1.0);
   double dirAdx = 0.0;
   if(fast > slow) dirAdx = strength;
   else if(fast < slow) dirAdx = -strength;

   //--- 3) position inside the Bollinger channel
   double bbPos = 0.0;
   double half = (bbUp - bbLo) * 0.5;
   if(half > 0.0)
      bbPos = TP_Clamp((close1 - (bbUp + bbLo) * 0.5) / half, -1.0, 1.0);

   return 0.40 * slope + 0.30 * dirAdx + 0.30 * bbPos;
  }

void TP_CountsFromScore(double score, int &nBuy, int &nSell)
  {
   nBuy  = 0;
   nSell = 0;

   if(score >= InpScoreStrong)       { nBuy = 3; nSell = 0; }
   else if(score >= InpScoreMild)    { nBuy = 2; nSell = 1; }
   else if(score > -InpScoreMild)    { nBuy = 2; nSell = 2; }
   else if(score > -InpScoreStrong)  { nBuy = 1; nSell = 2; }
   else                              { nBuy = 0; nSell = 3; }

   if(nBuy + nSell > CFG_InpMaxPositions)
     {
      if(nBuy >= nSell) nBuy = CFG_InpMaxPositions - nSell;
      else              nSell = CFG_InpMaxPositions - nBuy;
      if(nBuy + nSell > CFG_InpMaxPositions)
        {
         nBuy = CFG_InpMaxPositions / 2;
         nSell = CFG_InpMaxPositions - nBuy;
        }
     }
  }

//==================================================================
//  trailing
//==================================================================
bool TP_CanModifyNow(void)
  {
   if(TimeCurrent() < g_modBlockUntil)
     {
      g_modSuppressed++;
      return false;
     }
   if(!TP_MarketOpen())
     {
      datetime next = TP_NextSessionOpen(TimeCurrent());
      if(next <= TimeCurrent()) next = TimeCurrent() + 300;
      g_modBlockUntil = next;
      g_modSuppressed++;
      return false;
     }
   return true;
  }

void TP_ManagePositions(void)
  {
   double bid = TP_Bid();
   double ask = TP_Ask();
   if(bid <= 0.0 || ask <= 0.0) return;

   double minDist = TP_StopsLevel() + TP_Point();

   for(int i = 0; i < g_nPos; i++)
     {
      if(!PositionSelectByTicket(g_pos[i].ticket)) continue;
      if(g_pos[i].trailStart <= 0.0) continue;     // trailing off for this position
      if(g_pos[i].trailDist <= 0.0) continue;

      double cur = bid;
      if(g_pos[i].side < 0) cur = ask;

      double prof = cur - g_pos[i].entry;
      if(g_pos[i].side < 0) prof = g_pos[i].entry - cur;

      if(prof < g_pos[i].trailStart) continue;

      double want = cur - g_pos[i].trailDist;
      if(g_pos[i].side < 0) want = cur + g_pos[i].trailDist;
      want = TP_NormPrice(want);

      bool better = false;
      if(g_pos[i].sl <= 0.0) better = true;
      else if(g_pos[i].side > 0 && want > g_pos[i].sl + TP_Point() * 0.5) better = true;
      else if(g_pos[i].side < 0 && want < g_pos[i].sl - TP_Point() * 0.5) better = true;
      if(!better) continue;

      //keep a legal distance from the market
      if(g_pos[i].side > 0 && want > bid - minDist) continue;
      if(g_pos[i].side < 0 && want < ask + minDist) continue;

      if(!TP_CanModifyNow()) return;

      if(trade.PositionModify(g_pos[i].ticket, want, g_pos[i].tp))
        {
         g_pos[i].sl = want;
         if(!g_pos[i].trailOn)
           {
            g_pos[i].trailOn = true;
            TP_Log(StringFormat("trail on ticket %s", IntegerToString((long)g_pos[i].ticket)));
           }
        }
      else
        {
         int rc = (int)trade.ResultRetcode();
         if(rc == TRADE_RETCODE_MARKET_CLOSED || rc == TRADE_RETCODE_TRADE_DISABLED)
           {
            datetime next = TP_NextSessionOpen(TimeCurrent());
            if(next <= TimeCurrent()) next = TimeCurrent() + 300;
            g_modBlockUntil = next;
           }
         else
           {
            g_modFail++;
            TP_Log(StringFormat("modify failed rc=%d", rc));
           }
        }
     }
  }

//==================================================================
//  news
//==================================================================
bool TP_NewsBlocked(void)
  {
   if(!InpUseNews) return false;

   int h = FileOpen("TwinPulse_news.csv", FILE_READ | FILE_CSV | FILE_ANSI |
                    FILE_SHARE_READ | FILE_COMMON, ',', CP_ACP);
   if(h == INVALID_HANDLE) return false;

   bool blocked = false;
   while(!FileIsEnding(h))
     {
      string s = FileReadString(h);
      if(s == "") continue;
      datetime t = StringToTime(s);
      if(t <= 0) continue;
      long diff = (long)TimeCurrent() - (long)t;
      if(diff < 0) diff = -diff;
      if(diff <= (long)InpNewsMinutes * 60)
        {
         blocked = true;
         break;
        }
     }
   FileClose(h);
   return blocked;
  }

//==================================================================
//  day control
//==================================================================
void TP_UpdateDay(void)
  {
   datetime anchor = TP_DayStart(TimeCurrent());
   if(anchor == g_dayAnchor) return;
   if(g_dayAnchor != 0 && (g_dayTrades > 0 || g_dayNet != 0.0))
     {
      //one line per trading day: this is what a demo week is reviewed from
      TP_Log(StringFormat("DAY SUMMARY %s opens=%d net=%.2f avgSpread=%.3f dayStop=%s equity=%.2f",
                          TimeToString(g_dayAnchor, TIME_DATE), g_dayTrades, g_dayNet,
                          (g_daySpreadN > 0) ? g_daySpreadSum / g_daySpreadN : 0.0,
                          g_dayLocked ? "yes" : "no", AccountInfoDouble(ACCOUNT_EQUITY)));
      g_runDays++;
      g_runNet   += g_dayNet;
      g_runOpens += g_dayTrades;
      if(g_dayNet > 0.0) g_runWinDays++;
      if(g_dayLocked && g_dayNet < 0.0) g_runStopDays++;
     }
   g_dayAnchor      = anchor;
   g_dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   g_dayNet         = 0.0;
   g_dayLocked      = false;
   g_dayTrades      = 0;
   g_daySpreadSum   = 0.0;
   g_daySpreadN     = 0;
  }

void TP_CloseAll(string why)
  {
   if(g_nPos <= 0) return;
   g_closingAll = true;
   int closed = 0;
   for(int i = g_nPos - 1; i >= 0; i--)
     {
      ulong t = g_pos[i].ticket;
      if(t == 0) continue;
      if(!PositionSelectByTicket(t)) continue;
      if(trade.PositionClose(t)) closed++;
     }
   g_closingAll = false;
   g_closeAllUntil = TimeCurrent() + 120;   // deals may arrive queued
   TP_Log(StringFormat("%s: closed %d leg(s), day net %.2f", why, closed, g_dayNet));
  }

//--- closed + floating P/L of the day, in USD
double TP_DayTotal(void)
  {
   return g_dayNet + g_dayFloating;
  }

bool TP_DayLocked(void)
  {
   if(g_dayLocked)
     {
      //a close-all can fail (requote, market closed, busy context); the
      //stop said FLAT, so keep trying every few seconds until it is
      if(g_nPos > 0 && (long)TimeCurrent() - (long)g_lastCloseTry >= 5 && TP_MarketOpen())
        {
         g_lastCloseTry = TimeCurrent();
         TP_CloseAll("day locked - retry closing leftover legs");
        }
      return true;
     }

   double total = TP_DayTotal();

   if(CFG_InpDailyLossUSD > 0.0 && total <= -CFG_InpDailyLossUSD)
     {
      g_dayLocked = true;
      g_lastCloseTry = TimeCurrent();
      TP_CloseAll("DAILY LOSS STOP - closing all");
      TP_Log(StringFormat("daily loss stop: %.2f USD - no entries until tomorrow", total));
      return true;
     }
   if(CFG_InpDailyTargetUSD > 0.0 && total >= CFG_InpDailyTargetUSD)
     {
      g_dayLocked = true;
      g_lastCloseTry = TimeCurrent();
      TP_CloseAll("DAILY TARGET - closing all");
      TP_Log(StringFormat("DAILY TARGET reached: %.2f USD - no entries until tomorrow", total));
      return true;
     }
   return false;
  }

//==================================================================
//  entry
//==================================================================
bool TP_SessionWindow(void)
  {
   MqlDateTime d;
   TimeToStruct(TimeCurrent(), d);
   if(d.day_of_week == 0 || d.day_of_week == 6) return false;
   if(d.day_of_week == 5 && d.hour >= InpFridayStop) return false;

   if(CFG_InpSessionStart <= CFG_InpSessionEnd)
     {
      if(d.hour < CFG_InpSessionStart) return false;
      if(d.hour >= CFG_InpSessionEnd)   return false;
     }
   else
     {
      if(d.hour >= CFG_InpSessionEnd && d.hour < CFG_InpSessionStart) return false;
     }
   return true;
  }

//--- the owner's two side rules, applied before any entry
bool TP_SideAllowed(int dir)
  {
   //rule 5: never add to a side that is in loss (that would be averaging down)
   if(TP_SideHasLoser(dir)) return false;

   //owner's re-open rule: the opposite side must have recovered to -tol or better
   double opp = TP_SideProfit(-dir);
   if(opp < -InpReopenTolUSD) return false;

   return true;
  }

bool TP_CanOpen(double &outSLDist)
  {
   outSLDist = 0.0;

   if(g_nPos >= CFG_InpMaxPositions) return false;
   if(CFG_InpMaxTradesDay > 0 && g_dayTrades >= CFG_InpMaxTradesDay) return false;
   if(TP_DayLocked()) return false;
   if(!TP_SessionWindow()) return false;
   if(!TP_MarketOpen()) return false;
   if(TP_NewsBlocked()) return false;

   double spread = TP_Spread();
   if(InpMaxSpread > 0.0 && spread > InpMaxSpread) { g_skipsSpread++; return false; }

   double marginOne = 0.0;
   if(!OrderCalcMargin(ORDER_TYPE_BUY, _Symbol, InpLots, TP_Ask(), marginOne)) return false;
   double eq  = AccountInfoDouble(ACCOUNT_EQUITY);
   double lvl = (marginOne > 0.0) ? (eq / (marginOne * (g_nPos + 1)) * 100.0) : 0.0;
   if(CFG_InpMinMarginLevel > 0.0 && lvl < CFG_InpMinMarginLevel) return false;

   return true;
  }

bool TP_Open(int dir, double atr, double spread, double tpAtr)
  {
   double slDist = CFG_InpSL_ATR * atr;
   if(CFG_InpMode == 0 && CFG_InpSL_Price > 0.0) slDist = CFG_InpSL_Price;   // fixed (Q presets)
   if(InpMaxSL_Price > 0.0 && slDist > InpMaxSL_Price) slDist = InpMaxSL_Price;

   double minDist = TP_StopsLevel() + TP_Point() * 2.0;
   if(slDist < minDist) slDist = minDist;

   double tpDist = tpAtr * atr;
   if(CFG_InpMode == 0 && CFG_InpTP_Price > 0.0) tpDist = CFG_InpTP_Price;   // fixed (Q presets)

   //--- rule 2: a target that does not clear the spread several times over
   //--- is a donation to the broker - refuse it instead of running it
   double minTP = InpMinTPxSpread * (spread + TP_Point());
   if(tpDist < minTP)
     {
      g_skipsTP++;
      return false;
     }
   if(tpDist < minDist) tpDist = minDist;

   double lots = TP_NormLots(InpLots);
   double price = TP_Ask();
   double sl = price - slDist;
   double tp = price + tpDist;

   if(dir < 0)
     {
      price = TP_Bid();
      sl = price + slDist;
      tp = price - tpDist;
     }

   price = TP_NormPrice(price);
   sl    = TP_NormPrice(sl);
   tp    = TP_NormPrice(tp);

   g_cycle++;
   string comment = StringFormat("%s|%d", InpComment, g_cycle);

   bool ok = false;
   if(dir > 0) ok = trade.Buy(lots, _Symbol, price, sl, tp, comment);
   else        ok = trade.Sell(lots, _Symbol, price, sl, tp, comment);

   if(!ok || trade.ResultRetcode() != TRADE_RETCODE_DONE)
     {
      TP_Log(StringFormat("open failed dir=%d rc=%d", dir, trade.ResultRetcode()));
      return false;
     }

   double fill = trade.ResultPrice();
   if(fill <= 0.0) fill = price;

   //--- resolve the ticket: the newest position of ours that we do not
   //--- track yet is the one we have just opened
   TP_Sync();
   int idx = -1;
   datetime newest = 0;          // datetime, not ulong: comparing the two
                                 // raised warning 45 (sign mismatch)
   for(int i = 0; i < g_nPos; i++)
     {
      if(g_pos[i].stopDist > 0.0) continue;        // already initialised
      datetime t = g_pos[i].openTime;
      if(t >= newest) { newest = t; idx = i; }
     }
   if(idx >= 0)
     {
      g_pos[idx].atr        = atr;
      g_pos[idx].spread     = spread;
      g_pos[idx].spreadUSD  = TP_SpreadUSD(spread, lots);
      g_pos[idx].stopDist   = slDist;
      g_pos[idx].trailStart = CFG_InpTrailStart_ATR * atr;
      g_pos[idx].trailDist  = CFG_InpTrail_ATR * atr;
      g_pos[idx].trailOn    = false;
     }

   g_opens++;
   g_dayTrades++;

   //--- the book INCLUDING the leg we have just opened. Counting it here (and
   //--- not after the close) is what makes "money per split" mean something:
   //--- a row closed by its stop used to report the book after the leg left it,
   //--- which was 0B0S for every last-leg trade.
   int nb = 0, ns = 0;
   for(int i = 0; i < g_nPos; i++)
     {
      if(g_pos[i].side > 0) nb++;
      else                  ns++;
     }
   g_legsAtOpen = nb + ns;
   g_rowSplit   = StringFormat("%dB%dS", nb, ns);
   g_rowLegs    = g_legsAtOpen;
   if(idx >= 0)
     {
      g_pos[idx].nBuyAtOpen  = nb;
      g_pos[idx].nSellAtOpen = ns;
     }

   //an "open" row carries zero money: it exists so the summary can measure how
   //many legs were open at the moment of the decision (average / max legs)
   TP_CsvRow(TimeCurrent(), StringFormat("E%d", CFG_InpEntryMode), dir, lots, fill,
             0.0, "open", 0.0, 0.0, 0.0, atr, spread, slDist);

   TP_Log(StringFormat("OPEN dir=%d lots=%.2f fill=%.3f sl=%.3f tp=%.3f atr=%.2f spread=%.3f split=%s",
                       dir, lots, fill, sl, tp, atr, spread, g_rowSplit));
   return true;
  }

//==================================================================
//  mode 6 - PULSE: the owner's cycle
//==================================================================
//  IDLE    flat. On a new bar (and the usual filters) open 1 BUY + 1 SELL.
//  PROBE   both open. The first side whose P/L reaches +InpPulseTrigUSD is
//          the winner (CONTROL P2: a coin decides instead). Add
//          InpPulseAdd legs to the winner and trail every winner leg.
//  RIDE    winners trail; the loser is held. When no winner is left:
//          loser still open -> RECOVER, nothing open -> IDLE.
//  RECOVER only the held loser is open. When it is back to >= -BETol USD,
//          its stop moves to about -BETol (big loss saved), it trails, and
//          InpPulseAdd legs open on its side -> RIDE with that side as the
//          winner. If it never comes back, its 5 USD broker stop ends it.
//  Every leg carries InpPulseSL as a broker stop from the first moment.
//------------------------------------------------------------------
#define PULSE_IDLE    0
#define PULSE_PROBE   1
#define PULSE_RIDE    2
#define PULSE_RECOVER 3
#define PULSE_VPROBE  4   // virtual probe: watching price, nothing open yet

int      g_pulseState = PULSE_IDLE;
int      g_pulseWin   = 0;        // +1 / -1 while riding
double   g_pulseAtr   = 0.0;      // last ATR, for the CSV only
int      g_pulseCycles = 0;
double   g_pulseRef    = 0.0;      // virtual probe: mid price at arming

int TP_SideCount(int side)
  {
   int c = 0;
   for(int i = 0; i < g_nPos; i++)
      if(g_pos[i].side == side && PositionSelectByTicket(g_pos[i].ticket)) c++;
   return c;
  }

//--- open one leg with a broker stop and no target; returns its slot or -1
int TP_PulseOpenLeg(int dir, bool trail)
  {
   if(g_nPos >= CFG_InpMaxPositions) return -1;
   double spread = TP_Spread();
   if(InpMaxSpread > 0.0 && spread > InpMaxSpread) { g_skipsSpread++; return -1; }

   double marginOne = 0.0;
   if(!OrderCalcMargin(ORDER_TYPE_BUY, _Symbol, InpLots, TP_Ask(), marginOne)) return -1;
   double eq  = AccountInfoDouble(ACCOUNT_EQUITY);
   double lvl = (marginOne > 0.0) ? (eq / (marginOne * (g_nPos + 1)) * 100.0) : 0.0;
   if(CFG_InpMinMarginLevel > 0.0 && lvl < CFG_InpMinMarginLevel) return -1;

   double slDist  = InpPulseSL;
   double minDist = TP_StopsLevel() + TP_Point() * 2.0;
   if(slDist < minDist) slDist = minDist;

   double lots  = TP_NormLots(InpLots);
   double price = (dir > 0) ? TP_Ask() : TP_Bid();
   double sl    = (dir > 0) ? price - slDist : price + slDist;
   price = TP_NormPrice(price);
   sl    = TP_NormPrice(sl);

   g_cycle++;
   string comment = StringFormat("%s|P%d", InpComment, g_pulseCycles);
   bool ok = (dir > 0) ? trade.Buy(lots, _Symbol, price, sl, 0.0, comment)
                       : trade.Sell(lots, _Symbol, price, sl, 0.0, comment);
   if(!ok || trade.ResultRetcode() != TRADE_RETCODE_DONE)
     {
      TP_Log(StringFormat("pulse open failed dir=%d rc=%d", dir, trade.ResultRetcode()));
      return -1;
     }

   TP_Sync();
   int idx = -1;
   datetime newest = 0;
   for(int i = 0; i < g_nPos; i++)
     {
      if(g_pos[i].stopDist > 0.0) continue;
      if(g_pos[i].openTime >= newest) { newest = g_pos[i].openTime; idx = i; }
     }
   if(idx < 0) return -1;

   g_pos[idx].atr        = g_pulseAtr;
   g_pos[idx].spread     = spread;
   g_pos[idx].spreadUSD  = TP_SpreadUSD(spread, lots);
   g_pos[idx].stopDist   = slDist;
   g_pos[idx].trailStart = trail ? InpPulseTrailStart : 0.0;
   g_pos[idx].trailDist  = trail ? InpPulseTrailDist  : 0.0;
   g_pos[idx].trailOn    = false;

   TP_RecountBook();
   g_pos[idx].nBuyAtOpen  = g_nBuy;
   g_pos[idx].nSellAtOpen = g_nSell;
   g_rowSplit = StringFormat("%dB%dS", g_nBuy, g_nSell);
   g_rowLegs  = g_nBuy + g_nSell;
   g_opens++;
   g_dayTrades++;

   double fill = trade.ResultPrice();
   if(fill <= 0.0) fill = price;
   TP_CsvRow(TimeCurrent(), "P", dir, lots, fill, 0.0, "open", 0.0, 0.0, 0.0,
             g_pulseAtr, spread, slDist);
   g_daySpreadSum += spread;
   g_daySpreadN++;
   TP_Log(StringFormat("PULSE open dir=%d fill=%.3f sl=%.3f trail=%d state=%d book=%s",
                       dir, fill, sl, (int)trail, g_pulseState, g_rowSplit));
   return idx;
  }

//--- switch trailing on for every open leg of one side
void TP_PulseTrailSide(int side)
  {
   for(int i = 0; i < g_nPos; i++)
     {
      if(g_pos[i].side != side) continue;
      g_pos[i].trailStart = InpPulseTrailStart;
      g_pos[i].trailDist  = InpPulseTrailDist;
     }
  }

void TP_PulseAdd(int side)
  {
   for(int k = 0; k < InpPulseAdd; k++)
      if(TP_PulseOpenLeg(side, true) < 0) break;
  }

//--- VIRTUAL probe: instead of paying for 1 BUY + 1 SELL, remember the mid
//--- price; the side the market moves to first (by the same trigger as the
//--- real probe) gets 1 + InpPulseAdd legs. Saves the losing probe leg and
//--- its spread; there is no held loser, so no recovery phase.
void TP_PulseVirtualArm(void)
  {
   g_pulseRef = (TP_Ask() + TP_Bid()) * 0.5;
   if(g_pulseState != PULSE_VPROBE) g_pulseCycles++;
   g_pulseState = PULSE_VPROBE;
  }

double TP_UsdToPrice(double usd)
  {
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double lots      = TP_NormLots(InpLots);
   if(tickSize <= 0.0 || tickValue <= 0.0 || lots <= 0.0) return usd;
   return usd / (tickValue * lots) * tickSize;
  }

void TP_PulseProbe(void)
  {
   g_pulseCycles++;
   int b = TP_PulseOpenLeg(1, false);
   int s = TP_PulseOpenLeg(-1, false);
   if(b < 0 && s < 0) { g_pulseState = PULSE_IDLE; return; }
   g_pulseWin = 0;
   g_pulseState = PULSE_PROBE;
  }

//--- move the held loser's stop to about -BETol USD from its entry
void TP_PulseCapLoser(int side)
  {
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double minDist   = TP_StopsLevel() + TP_Point();
   for(int i = 0; i < g_nPos; i++)
     {
      if(g_pos[i].side != side) continue;
      if(!PositionSelectByTicket(g_pos[i].ticket)) continue;
      double lots = PositionGetDouble(POSITION_VOLUME);
      double dist = 0.0;
      if(tickSize > 0.0 && tickValue > 0.0 && lots > 0.0)
         dist = InpPulseBETol / (tickValue * lots) * tickSize;
      double want = (side > 0) ? g_pos[i].entry - dist : g_pos[i].entry + dist;
      want = TP_NormPrice(want);
      //only tighten, and only at a legal distance from the market
      if(side > 0 && (want <= g_pos[i].sl || want > TP_Bid() - minDist)) continue;
      if(side < 0 && (want >= g_pos[i].sl || want < TP_Ask() + minDist)) continue;
      if(!TP_CanModifyNow()) return;
      if(trade.PositionModify(g_pos[i].ticket, want, g_pos[i].tp))
         g_pos[i].sl = want;
     }
  }

void TP_PulseTick(void)
  {
   int nb = TP_SideCount(1);
   int ns = TP_SideCount(-1);

   //--- virtual probe armed: enter on the side that moves first
   if(g_pulseState == PULSE_VPROBE && nb + ns == 0)
     {
      if(g_pulseRef <= 0.0) return;
      if(!TP_SessionWindow() || !TP_MarketOpen()) { g_pulseState = PULSE_IDLE; return; }
      if(CFG_InpPulseMaxSpread > 0.0 && TP_Spread() > CFG_InpPulseMaxSpread) return;
      double mid  = (TP_Ask() + TP_Bid()) * 0.5;
      double trig = TP_UsdToPrice(InpPulseTrigUSD);
      int win = 0;
      if(mid - g_pulseRef >= trig)      win = 1;
      else if(g_pulseRef - mid >= trig) win = -1;
      if(win == 0) return;
      if(CFG_InpPulseRandom)
         win = ((int)(MathRand() % 100) < 50) ? 1 : -1;   // CONTROL
      g_pulseWin = win;
      g_pulseState = PULSE_RIDE;
      if(TP_PulseOpenLeg(win, true) >= 0) TP_PulseAdd(win);
      TP_Log(StringFormat("PULSE virtual winner=%d move=%.2f%s", win, mid - g_pulseRef,
                          CFG_InpPulseRandom ? " RANDOM" : ""));
      return;
     }

   //--- flat: whatever happened, the next cycle starts on a new bar
   if(nb + ns == 0)
     {
      if(g_pulseState == PULSE_VPROBE) return;           // still watching
      if(g_pulseState != PULSE_IDLE)
         TP_Log(StringFormat("PULSE cycle %d done, day net %.2f", g_pulseCycles, g_dayNet));
      g_pulseState = PULSE_IDLE;
      g_pulseWin = 0;
      return;
     }

   //--- legs found after a restart: ride whichever side is ahead
   if(g_pulseState == PULSE_IDLE)
     {
      g_pulseWin = (TP_SideProfit(1) >= TP_SideProfit(-1)) ? 1 : -1;
      TP_PulseTrailSide(g_pulseWin);
      g_pulseState = PULSE_RIDE;
      return;
     }

   if(g_pulseState == PULSE_PROBE)
     {
      //one side already stopped out: the survivor is the winner, ride it
      if(nb == 0 || ns == 0)
        {
         g_pulseWin = (nb > 0) ? 1 : -1;
         TP_PulseTrailSide(g_pulseWin);
         g_pulseState = PULSE_RIDE;
         return;
        }
      double pb = 0.0, ps = 0.0;
      for(int i = 0; i < g_nPos; i++)
        {
         if(!PositionSelectByTicket(g_pos[i].ticket)) continue;
         double p = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
         if(g_pos[i].side > 0) pb += p; else ps += p;
        }
      int win = 0;
      if(pb >= InpPulseTrigUSD)      win = 1;
      else if(ps >= InpPulseTrigUSD) win = -1;
      if(win == 0) return;

      if(CFG_InpPulseRandom)
         win = ((int)(MathRand() % 100) < 50) ? 1 : -1;   // CONTROL

      g_pulseWin = win;
      TP_PulseTrailSide(win);
      TP_PulseAdd(win);
      g_pulseState = PULSE_RIDE;
      TP_Log(StringFormat("PULSE winner=%d (buy %.2f sell %.2f)%s", win, pb, ps,
                          CFG_InpPulseRandom ? " RANDOM" : ""));
      return;
     }

   if(g_pulseState == PULSE_RIDE)
     {
      int nWin  = (g_pulseWin > 0) ? nb : ns;
      int nLose = (g_pulseWin > 0) ? ns : nb;
      if(nWin > 0) return;                       // winners still trailing
      if(nLose > 0) { g_pulseState = PULSE_RECOVER; return; }
      return;                                    // flat is handled above
     }

   if(g_pulseState == PULSE_RECOVER)
     {
      int lose = -g_pulseWin;
      double back = 0.0;                         // the held side's real P/L, spread included
      for(int i = 0; i < g_nPos; i++)
        {
         if(g_pos[i].side != lose) continue;
         if(!PositionSelectByTicket(g_pos[i].ticket)) continue;
         back += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
        }
      if(back < -InpPulseBETol) return;          // not back yet; the broker stop guards it
      //the held side came back: cap it near break-even, trail it, add to it
      TP_PulseCapLoser(lose);
      TP_PulseTrailSide(lose);
      TP_PulseAdd(lose);
      g_pulseWin = lose;
      g_pulseState = PULSE_RIDE;
      TP_Log("PULSE loser came back - capped, trailing, added");
     }
  }

//==================================================================
//  the signal, once per closed M5 bar
//==================================================================
//--- the single-position entry rules (S1..S7)
int TP_SignalDir(double fast, double slow, double atr, double bbUp, double bbLo,
                 double rsi, double close1, double low1, double high1)
  {
   int dir = 0;

   if(CFG_InpEntryMode == 0)
     {
      //pullback continuation: trend up, price dips to the fast EMA and closes above it
      if(fast > slow && close1 > fast && low1 <= fast + 0.25 * atr) dir = 1;
      if(fast < slow && close1 < fast && high1 >= fast - 0.25 * atr) dir = -1;
     }
   else if(CFG_InpEntryMode == 1)
     {
      //mean reversion at the Bollinger band
      if(close1 < bbLo && rsi < InpRSIBuy)  dir = 1;
      if(close1 > bbUp && rsi > InpRSISell) dir = -1;
     }
   else if(CFG_InpEntryMode == 2)
     {
      //range breakout
      int hi = iHighest(_Symbol, g_tf, MODE_HIGH, InpBreakBars, 2);
      int lo = iLowest(_Symbol, g_tf, MODE_LOW, InpBreakBars, 2);
      if(hi >= 0 && lo >= 0)
        {
         double hh = iHigh(_Symbol, g_tf, hi);
         double ll = iLow(_Symbol, g_tf, lo);
         if(close1 > hh) dir = 1;
         if(close1 < ll) dir = -1;
        }
     }
   return dir;
  }

//--- experiment Z: the H1 trend. +1 = H1 EMA rising over 3 closed bars AND
//--- the last H1 close above it, -1 = the mirror, 0 = no clear trend (no trade)
int TP_HTFDir(void)
  {
   if(hHTF == INVALID_HANDLE) return 0;
   double e[4];
   if(CopyBuffer(hHTF, 0, 1, 4, e) < 4) return 0;   // oldest first: e[3] = bar 1
   double c = iClose(_Symbol, PERIOD_H1, 1);
   if(c <= 0.0) return 0;
   if(e[3] > e[0] && c > e[3]) return 1;
   if(e[3] < e[0] && c < e[3]) return -1;
   return 0;
  }

void TP_OnNewBar(void)
  {
   double fast, slow, atr, bbUp, bbLo, rsi;
   if(!TP_Ind(fast, slow, atr, bbUp, bbLo, rsi)) return;

   double slDist = 0.0;
   if(!TP_CanOpen(slDist)) return;

   double close1 = iClose(_Symbol, g_tf, 1);
   double low1   = iLow(_Symbol, g_tf, 1);
   double high1  = iHigh(_Symbol, g_tf, 1);
   if(close1 <= 0.0) return;

   double spread = TP_Spread();

   //-----------------------------------------------------------------
   //  pulse (mode 6): a new cycle starts only from a flat book
   //-----------------------------------------------------------------
   if(CFG_InpMode == 6)
     {
      g_pulseAtr = atr;
      //cost gate: a cycle pays ~5 spreads, so start one only when it is cheap
      if(CFG_InpPulseMaxSpread > 0.0 && spread > CFG_InpPulseMaxSpread)
        {
         if(g_pulseState == PULSE_VPROBE) g_pulseState = PULSE_IDLE;   // drop a stale reference
         return;
        }
      //like the real probe, a virtual probe waits until one side moves by the
      //trigger - its reference is set once, not reset every bar
      if(g_nPos == 0 && g_pulseState == PULSE_IDLE)
        {
         if(CFG_InpPulseVirtual) TP_PulseVirtualArm();
         else                    TP_PulseProbe();
        }
      return;
     }

   //-----------------------------------------------------------------
   //  single-position scalp (S1..S7)
   //-----------------------------------------------------------------
   if(CFG_InpMode == 0)
     {
      int dir = TP_SignalDir(fast, slow, atr, bbUp, bbLo, rsi, close1, low1, high1);
      if(CFG_InpEntryMode == 3)
        {
         if((int)(MathRand() % 100) < 50) dir = 1;
         else dir = -1;
        }
      if(dir == 0) return;
      if(CFG_InpHTFFilter && TP_HTFDir() != dir) return;   // with the H1 trend only
      if(!TP_SideAllowed(dir)) return;
      TP_Open(dir, atr, spread, CFG_InpTP_ATR);
      return;
     }

   //-----------------------------------------------------------------
   //  multi-leg modes: how many legs of each side do we want now?
   //-----------------------------------------------------------------
   int wantBuy = 0;
   int wantSell = 0;

   if(CFG_InpMode == 1)
     {
      //fixed 2 BUY + 2 SELL - the owner's original hedge idea
      wantBuy = 2;
      wantSell = 2;
     }
   else if(CFG_InpMode == 2)
     {
      //fixed counts from the inputs, default 2/2 (was hard-coded 2/2,
      //which made mode 2 an exact copy of mode 1)
      wantBuy  = (InpFixedBuy  > 0) ? InpFixedBuy  : 0;
      wantSell = (InpFixedSell > 0) ? InpFixedSell : 0;
     }
   else if(CFG_InpMode == 3 || CFG_InpMode == 4)
     {
      double adx = 0.0;
      double bd[3];
      if(CopyBuffer(hADX, 0, 0, 3, bd) >= 3) adx = bd[1];

      double score = TP_MarketScore(fast, slow, atr, adx, bbUp, bbLo, close1);

      if(CFG_InpMode == 4)
        {
         //CONTROL: the same splits, chosen at random instead of by the score
         int pick = (int)(MathRand() % 5);
         if(pick == 0)      { wantBuy = 3; wantSell = 0; }
         else if(pick == 1) { wantBuy = 2; wantSell = 1; }
         else if(pick == 2) { wantBuy = 2; wantSell = 2; }
         else if(pick == 3) { wantBuy = 1; wantSell = 2; }
         else               { wantBuy = 0; wantSell = 3; }
        }
      else
         TP_CountsFromScore(score, wantBuy, wantSell);
     }
   else
     {
      //HYBRID: range -> hedge cycling, trend -> the directional scalp entry
      double adx = 0.0;
      double bd[3];
      if(CopyBuffer(hADX, 0, 0, 3, bd) >= 3) adx = bd[1];

      if(adx < 22.0)
        {
         double score = TP_MarketScore(fast, slow, atr, adx, bbUp, bbLo, close1);
         TP_CountsFromScore(score, wantBuy, wantSell);
        }
      else
        {
         int dir = TP_SignalDir(fast, slow, atr, bbUp, bbLo, rsi, close1, low1, high1);
         if(dir > 0) { wantBuy = 1; wantSell = 0; }
         if(dir < 0) { wantBuy = 0; wantSell = 1; }
        }
     }

   //clamp to the margin cap
   while(wantBuy + wantSell > CFG_InpMaxPositions)
     {
      if(wantBuy >= wantSell) wantBuy--;
      else                   wantSell--;
     }

   //--- one leg per bar per side, never more than the target
   if(wantBuy > g_nBuy && TP_SideAllowed(1))
      TP_Open(1, atr, spread, InpHedgeTarget_ATR);

   TP_Sync();
   TP_RecountBook();

   if(wantSell > g_nSell && TP_SideAllowed(-1))
      TP_Open(-1, atr, spread, InpHedgeTarget_ATR);
  }


//==================================================================
//  closes
//==================================================================
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
  {
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;
   if(trans.deal == 0) return;
   if(!HistoryDealSelect(trans.deal)) return;
   if(HistoryDealGetInteger(trans.deal, DEAL_MAGIC) != InpMagic) return;

   long entry = HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
   if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_OUT_BY) return;

   double price  = HistoryDealGetDouble(trans.deal, DEAL_PRICE);
   double profit = HistoryDealGetDouble(trans.deal, DEAL_PROFIT);
   double swap   = HistoryDealGetDouble(trans.deal, DEAL_SWAP);
   double comm   = HistoryDealGetDouble(trans.deal, DEAL_COMMISSION);
   datetime when = (datetime)HistoryDealGetInteger(trans.deal, DEAL_TIME);
   ulong posId   = HistoryDealGetInteger(trans.deal, DEAL_POSITION_ID);

   //--- the side is a fact of the deal itself: closing with a SELL deal
   //--- means the position was long
   long dealType = HistoryDealGetInteger(trans.deal, DEAL_TYPE);
   int side = (dealType == DEAL_TYPE_SELL) ? 1 : -1;
   double entryPx = price;
   double atr = 0.0, spread = 0.0, stopDist = 0.0;
   bool trailOn = false;
   string leg = "POS";

   //--- find the leg: still tracked, or dropped by TP_Sync a moment ago
   ScalpPos rec;
   ZeroMemory(rec);
   bool found = false;
   int idx = TP_Idx(posId);
   if(idx >= 0)
     {
      rec = g_pos[idx];
      found = true;
      TP_RemoveIdx(idx);
     }
   else
     {
      int r = TP_RecentIdx(posId);
      if(r >= 0)
        {
         rec = g_recent[r];
         found = true;
         g_recent[r].ticket = 0;      // used once
        }
     }

   if(found)
     {
      entryPx  = rec.entry;
      atr      = rec.atr;
      spread   = rec.spread;
      stopDist = rec.stopDist;
      trailOn  = rec.trailOn;
      leg      = StringFormat("E%d", CFG_InpEntryMode);
      if(rec.nBuyAtOpen + rec.nSellAtOpen > 0)
        {
         g_rowSplit = StringFormat("%dB%dS", rec.nBuyAtOpen, rec.nSellAtOpen);
         g_rowLegs  = rec.nBuyAtOpen + rec.nSellAtOpen;
        }
      else
        {
         // a leg adopted after a restart has no snapshot; the live book is
         // the best we can say, and the row is marked by its own count
         g_rowSplit = StringFormat("%dB%dS", g_nBuy, g_nSell);
         g_rowLegs  = g_nBuy + g_nSell;
        }
     }

   //--- classify the exit from the broker's own reason, not from price
   //--- proximity (which needed the slot that was often already gone)
   long dr = HistoryDealGetInteger(trans.deal, DEAL_REASON);
   string reason = "close";
   if(dr == DEAL_REASON_TP)      reason = "target";
   else if(dr == DEAL_REASON_SL) reason = trailOn ? "trail" : "stop";
   else if(dr == DEAL_REASON_SO) reason = "stopout";
   else if(g_closingAll || TimeCurrent() <= g_closeAllUntil) reason = "daily_exit";

   TP_CsvRow(when, leg, side, HistoryDealGetDouble(trans.deal, DEAL_VOLUME),
             entryPx, price, reason, profit, swap, comm, atr, spread, stopDist);

   g_dayNet += profit + swap + comm;
  }

//==================================================================
//  lifecycle
//==================================================================
int OnInit(void)
  {
   //--- the preset must land before the first handle or parameter read
   TP_ApplyPreset();

   if(!InpAllowLive && (ENUM_ACCOUNT_TRADE_MODE)AccountInfoInteger(ACCOUNT_TRADE_MODE) == ACCOUNT_TRADE_MODE_REAL)
     {
      Print("TwinPulseScalp refuses to run on a REAL account (AllowLive=false)");
      return INIT_FAILED;
     }

   //--- every multi-position variant assumes separate tickets per leg. On a
   //--- NETTING account a SELL would close the BUY instead of hedging it and
   //--- a second BUY would merge into the first, so the book is fiction.
   long marginMode = AccountInfoInteger(ACCOUNT_MARGIN_MODE);
   if((ENUM_ACCOUNT_MARGIN_MODE)marginMode != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING &&
      (CFG_InpMode != 0 || CFG_InpMaxPositions > 1))
     {
      PrintFormat("TwinPulse needs a HEDGING account for mode=%d maxpos=%d (this account margin mode=%d). "
                  "Use a hedging account, or mode 0 with MaxPositions 1.",
                  CFG_InpMode, CFG_InpMaxPositions, (int)marginMode);
      return INIT_FAILED;
     }

   hFast = iMA(_Symbol, g_tf, InpFastEMA, 0, MODE_EMA, PRICE_CLOSE);
   hSlow = iMA(_Symbol, g_tf, InpSlowEMA, 0, MODE_EMA, PRICE_CLOSE);
   hATR  = iATR(_Symbol, g_tf, InpATRPeriod);
   hBB   = iBands(_Symbol, g_tf, InpBBPeriod, 0, InpBBDev, PRICE_CLOSE);
   hRSI  = iRSI(_Symbol, g_tf, InpRSIPeriod, PRICE_CLOSE);
   hADX  = iADX(_Symbol, g_tf, InpAdxPeriod);

   if(hFast == INVALID_HANDLE || hSlow == INVALID_HANDLE || hATR == INVALID_HANDLE ||
      hBB == INVALID_HANDLE || hRSI == INVALID_HANDLE || hADX == INVALID_HANDLE)
     {
      Print("indicator handle failed");
      return INIT_FAILED;
     }

   if(CFG_InpHTFFilter)
     {
      hHTF = iMA(_Symbol, PERIOD_H1, InpHTFPeriod, 0, MODE_EMA, PRICE_CLOSE);
      if(hHTF == INVALID_HANDLE)
        {
         Print("H1 trend filter handle failed");
         return INIT_FAILED;
        }
     }

   trade.SetExpertMagicNumber((ulong)InpMagic);
   trade.SetDeviationInPoints(50);
   trade.SetTypeFillingBySymbol(_Symbol);
   trade.SetAsyncMode(false);

   //mode 4 (random split) draws too: seed it as well, or the control
   //is not reproducible from run to run
   if(CFG_InpEntryMode == 3 || CFG_InpMode == 4 || CFG_InpPulseRandom) MathSrand(InpRandomSeed);

   TP_LoadSessions();
   g_dayAnchor      = TP_DayStart(TimeCurrent());
   g_runStart       = TimeCurrent();
   g_dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   g_nPos = 0;

   if(InpPreset == TP_CUSTOM)
      g_csvName = "TwinPulse_legs.csv";
   else
      g_csvName = "TwinPulse_legs_" + TP_PresetLabel() + ".csv";

   if(InpWriteCsv)
     {
      g_csv = FileOpen(g_csvName,
                       FILE_WRITE | FILE_CSV | FILE_ANSI | FILE_COMMON, ',', CP_ACP);
      if(g_csv != INVALID_HANDLE) TP_CsvHeader();
     }
   if(InpVerboseLog)
      g_log = FileOpen("TwinPulse_scalp.log",
                       FILE_WRITE | FILE_CSV | FILE_ANSI | FILE_COMMON, ',', CP_ACP);

   TP_Log(StringFormat("TPS 1.20 ONE start %s tf=%s preset=%s htf=%d mode=%d entry=%d lots=%.2f maxpos=%d session %d-%d tp=%.2fATR sl=%.2fATR minTP=%.1fxspread dailyTarget=%.0f dailyLoss=%.0f",
                       _Symbol, EnumToString(g_tf), TP_PresetLabel(), (int)CFG_InpHTFFilter, CFG_InpMode, CFG_InpEntryMode, InpLots, CFG_InpMaxPositions,
                       CFG_InpSessionStart, CFG_InpSessionEnd, CFG_InpTP_ATR, CFG_InpSL_ATR, InpMinTPxSpread,
                       CFG_InpDailyTargetUSD, CFG_InpDailyLossUSD));

   //--- the margin facts the owner asked for, printed once per run
   double m1 = 0.0;
   if(!OrderCalcMargin(ORDER_TYPE_BUY, _Symbol, InpLots, TP_Ask(), m1))
      m1 = 0.0;                  // the log then says 0.00 and the caps are 0
   long   mmode = AccountInfoInteger(ACCOUNT_MARGIN_MODE);
   double e = AccountInfoDouble(ACCOUNT_EQUITY);
   double hedgeRate = SymbolInfoDouble(_Symbol, SYMBOL_MARGIN_HEDGED);
   int    cap300 = (m1 > 0.0) ? (int)MathFloor(e / (m1 * 3.0)) : 0;
   int    cap250 = (m1 > 0.0) ? (int)MathFloor(e / (m1 * 2.5)) : 0;
   TP_Log(StringFormat("TPS margin: account mode=%d (0=netting 1=exchange 2=hedging) marginPer0.01=%.2f USD hedgedRate=%.2f equity=%.2f -> max legs %d at 300%%, %d at 250%%; using cap %d at %.0f%%",
                       (int)mmode, m1, hedgeRate, e, cap300, cap250, CFG_InpMaxPositions, CFG_InpMinMarginLevel));
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   TP_Log(StringFormat("RUN SUMMARY preset=%s from %s: %d trading days (today not included), net %.2f, "
                       "%d winning days, %d day-loss stops, %d opens, today so far %.2f",
                       TP_PresetLabel(), TimeToString(g_runStart, TIME_DATE), g_runDays, g_runNet,
                       g_runWinDays, g_runStopDays, g_runOpens, g_dayNet));
   Comment("");
   if(g_csv != INVALID_HANDLE) { FileClose(g_csv); g_csv = INVALID_HANDLE; }
   if(g_log != INVALID_HANDLE) { FileClose(g_log); g_log = INVALID_HANDLE; }
   if(hFast != INVALID_HANDLE) IndicatorRelease(hFast);
   if(hSlow != INVALID_HANDLE) IndicatorRelease(hSlow);
   if(hATR  != INVALID_HANDLE) IndicatorRelease(hATR);
   if(hBB   != INVALID_HANDLE) IndicatorRelease(hBB);
   if(hRSI  != INVALID_HANDLE) IndicatorRelease(hRSI);
   if(hADX  != INVALID_HANDLE) IndicatorRelease(hADX);
   if(hHTF  != INVALID_HANDLE) IndicatorRelease(hHTF);
  }

//--- on-chart status, at most once a second
void TP_Panel(void)
  {
   if(!InpShowPanel) return;
   if(MQLInfoInteger(MQL_TESTER) && !MQLInfoInteger(MQL_VISUAL_MODE)) return;
   if(TimeCurrent() == g_lastPanel) return;
   g_lastPanel = TimeCurrent();
   string st = "-";
   if(CFG_InpMode == 6)
     {
      if(g_pulseState == PULSE_IDLE)         st = "IDLE (waiting for the next bar)";
      else if(g_pulseState == PULSE_PROBE)   st = "PROBE (1B+1S, waiting for a winner)";
      else if(g_pulseState == PULSE_RIDE)    st = StringFormat("RIDE (%s winning, trailing)", g_pulseWin > 0 ? "BUY" : "SELL");
      else if(g_pulseState == PULSE_RECOVER) st = "RECOVER (holding the loser)";
      else if(g_pulseState == PULSE_VPROBE)  st = "VIRTUAL PROBE";
     }
   Comment(StringFormat("TwinPulse %s | preset %s\n"
                        "state: %s\n"
                        "legs: %dB %dS   floating: %.2f\n"
                        "today: net %.2f   opens %d   %s\n"
                        "spread now: %.3f   day loss stop: %.0f\n"
                        "run: %d days, net %.2f, %d winning days",
                        "1.20", TP_PresetLabel(), st, g_nBuy, g_nSell, g_dayFloating,
                        g_dayNet, g_dayTrades, g_dayLocked ? "STOPPED for today" : "trading",
                        TP_Spread(), CFG_InpDailyLossUSD,
                        g_runDays, g_runNet, g_runWinDays));
  }

//--- PULSE holds losers on purpose; never carry them over a weekend gap
void TP_WeekendClose(void)
  {
   if(CFG_InpMode != 6 || !InpWeekendClose || g_nPos <= 0) return;
   MqlDateTime d;
   TimeToStruct(TimeCurrent(), d);
   if(d.day_of_week != 5 || d.hour < InpWeekendHour) return;
   if((long)TimeCurrent() - (long)g_lastCloseTry < 5) return;
   g_lastCloseTry = TimeCurrent();
   g_dayLocked = true;
   TP_CloseAll("FRIDAY WEEKEND CLOSE");
  }

void OnTick(void)
  {
   TP_UpdateDay();
   TP_Sync();
   TP_RecountBook();
   TP_ManagePositions();
   TP_WeekendClose();
   TP_Panel();

   //the daily stop looks at closed AND floating P/L, so it is checked on
   //every tick - not only on a new bar
   if(TP_DayLocked()) return;

   if(CFG_InpMode == 6) TP_PulseTick();   // the cycle is managed on every tick

   datetime bar = (datetime)SeriesInfoInteger(_Symbol, g_tf, SERIES_LASTBAR_DATE);
   if(bar == 0) return;
   if(bar == g_lastBarM5) return;
   g_lastBarM5 = bar;
   TP_OnNewBar();
  }
//+------------------------------------------------------------------+

//==================================================================
//  OnTester: the honest number, computed by the EA itself
//==================================================================
//--- Per closed trade, from the deal history (commission and swap included):
//--- mean, 95% CI, win rate vs break-even, and each half of the run.
//--- Printed to the journal, written to TwinPulse_summary_<preset>.txt in the
//--- common Files folder, and returned as "OnTester result" (mean x 100,
//--- so the report shows it without a CSV). No CSV parsing needed any more.
double OnTester(void)
  {
   if(!HistorySelect(0, TimeCurrent())) return 0.0;

   double nets[];
   datetime times[];
   int n = 0;
   int total = HistoryDealsTotal();
   ArrayResize(nets, total);
   ArrayResize(times, total);
   for(int i = 0; i < total; i++)
     {
      ulong d = HistoryDealGetTicket(i);
      if(d == 0) continue;
      if(HistoryDealGetInteger(d, DEAL_MAGIC) != InpMagic) continue;
      long e = HistoryDealGetInteger(d, DEAL_ENTRY);
      if(e != DEAL_ENTRY_OUT && e != DEAL_ENTRY_OUT_BY) continue;
      times[n] = (datetime)HistoryDealGetInteger(d, DEAL_TIME);
      nets[n++] = HistoryDealGetDouble(d, DEAL_PROFIT) +
                  HistoryDealGetDouble(d, DEAL_SWAP) +
                  HistoryDealGetDouble(d, DEAL_COMMISSION);
     }
   if(n < 2)
     {
      PrintFormat("TPS SUMMARY preset=%s trades=%d (too few)", TP_PresetLabel(), n);
      return 0.0;
     }

   double sum = 0.0, sq = 0.0, sumW = 0.0, sumL = 0.0;
   int nW = 0, nL = 0;
   for(int i = 0; i < n; i++)
     {
      sum += nets[i];
      sq  += nets[i] * nets[i];
      if(nets[i] > 0.0) { sumW += nets[i]; nW++; }
      else              { sumL -= nets[i]; nL++; }
     }
   double mean = sum / n;
   double var  = (sq - n * mean * mean) / (n - 1);
   double ci   = (var > 0.0) ? 1.96 * MathSqrt(var / n) : 0.0;
   double avgW = (nW > 0) ? sumW / nW : 0.0;
   double avgL = (nL > 0) ? sumL / nL : 0.0;
   double winPct = 100.0 * nW / n;
   double bePct  = (avgW + avgL > 0.0) ? 100.0 * avgL / (avgW + avgL) : 0.0;

   //--- the two halves BY CALENDAR TIME (the tester window split at its
   //--- midpoint). 1.15-1.18 split by trade order, so a burst of trades in
   //--- one good month filled half 1 by itself and "both halves positive"
   //--- said nothing about the rest of the year (P3 in 1.18: Jan-Feb made
   //--- +4196 of +4194, yet both "halves" were positive).
   datetime tFrom = times[0];
   datetime tTo = TimeCurrent();
   datetime tMid = (datetime)(((long)tFrom + (long)tTo) / 2);
   int n1 = 0, n2 = 0;
   double m1 = 0.0, m2 = 0.0, q1 = 0.0, q2 = 0.0;
   for(int i = 0; i < n; i++)
     {
      if(times[i] < tMid) { m1 += nets[i]; q1 += nets[i] * nets[i]; n1++; }
      else                { m2 += nets[i]; q2 += nets[i] * nets[i]; n2++; }
     }
   if(n1 > 0) m1 /= n1;
   if(n2 > 0) m2 /= n2;
   double c1 = (n1 > 1) ? 1.96 * MathSqrt(MathMax(0.0, (q1 - n1 * m1 * m1) / (n1 - 1)) / n1) : 0.0;
   double c2 = (n2 > 1) ? 1.96 * MathSqrt(MathMax(0.0, (q2 - n2 * m2 * m2) / (n2 - 1)) / n2) : 0.0;

   //--- months: how many calendar months made money, and the best month's
   //--- share of the total (one lucky month must not carry a "pass")
   int months = 0, posMonths = 0;
   double bestMonth = 0.0, curMonth = 0.0;
   int curKey = -1;
   for(int i = 0; i <= n; i++)
     {
      int key = -1;
      if(i < n)
        {
         MqlDateTime md;
         TimeToStruct(times[i], md);
         key = md.year * 12 + md.mon;
        }
      if(key != curKey)
        {
         if(curKey >= 0)
           {
            months++;
            if(curMonth > 0.0) posMonths++;
            if(curMonth > bestMonth) bestMonth = curMonth;
           }
         curKey = key;
         curMonth = 0.0;
        }
      if(i < n) curMonth += nets[i];
     }
   double bestShare = (sum > 0.0) ? 100.0 * bestMonth / sum : 0.0;

   string verdict = "NO EDGE";
   bool halvesOk = (n1 > 0 && n2 > 0 && m1 - c1 > 0.0 && m2 - c2 > 0.0);
   bool monthsOk = (months > 0 && posMonths * 3 >= months * 2 && bestShare <= 50.0);
   if(mean - ci > 0.0 && halvesOk && monthsOk)
      verdict = "CANDIDATE (CI>0, both calendar halves CI>0, >=2/3 months positive, best month <=50%)";
   else if(mean - ci > 0.0 && !halvesOk) verdict = "CI above 0 but a calendar half is not - regime, not edge";
   else if(mean - ci > 0.0 && !monthsOk) verdict = "CI above 0 but carried by few months - not consistent";
   else if(mean + ci < 0.0) verdict = "LOSES (CI below 0)";

   string line = StringFormat("TPS SUMMARY preset=%s trades=%d net=%.2f mean=%.3f CI=[%.3f, %.3f] "
                              "win=%.1f%% breakeven=%.1f%% avgW=%.2f avgL=%.2f "
                              "half1=%.3f[%.3f,%.3f] n=%d half2=%.3f[%.3f,%.3f] n=%d "
                              "months=%d positive=%d bestMonthShare=%.0f%% -> %s",
                              TP_PresetLabel(), n, sum, mean, mean - ci, mean + ci,
                              winPct, bePct, avgW, avgL,
                              m1, m1 - c1, m1 + c1, n1, m2, m2 - c2, m2 + c2, n2,
                              months, posMonths, bestShare, verdict);
   Print(line);

   int f = FileOpen("TwinPulse_summary_" + TP_PresetLabel() + ".txt",
                    FILE_WRITE | FILE_TXT | FILE_ANSI | FILE_COMMON);
   if(f != INVALID_HANDLE)
     {
      FileWriteString(f, line + "\r\n");
      FileClose(f);
     }
   return NormalizeDouble(mean * 100.0, 2);
  }
//+------------------------------------------------------------------+

