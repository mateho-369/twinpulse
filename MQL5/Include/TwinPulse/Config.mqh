//+------------------------------------------------------------------+
//|                                                  Config.mqh       |
//|  TwinPulse Hedge EA                                                 |
//|  Constants, enumerations and every user input of the EA.          |
//|  This header is included FIRST by the EA and by the self-test.     |
//+------------------------------------------------------------------+
#pragma once

//--- identity --------------------------------------------------------
#define TP_NAME              "TwinPulse Hedge EA"
#define TP_VER               "1.00"
#define TP_COMMENT_PREFIX    "TP"
#define TP_MAGIC_DEFAULT     26101701
#define TP_LEG_COUNT         4          // BUY_A, BUY_B, SELL_A, SELL_B
#define TP_SLOT_COUNT        2          // slot A, slot B
#define TP_SPREAD_SAMPLES    240        // rolling buffer for the median spread
#define TP_PANEL_PREFIX      "TPP_"
#define TP_LOG_FILE          "TwinPulse.log"
#define TP_LEGS_CSV          "TwinPulse_legs.csv"
#define TP_CYCLES_CSV        "TwinPulse_cycles.csv"
#define TP_NEWS_CSV          "TwinPulse_news.csv"
#define TP_GV_PREFIX         "TwinPulse_"

//--- leg indices -----------------------------------------------------
#define TP_LEG_BUY_A         0
#define TP_LEG_BUY_B         1
#define TP_LEG_SELL_A        2
#define TP_LEG_SELL_B        3

//--- sides -----------------------------------------------------------
#define TP_SIDE_BUY          0
#define TP_SIDE_SELL         1

//--- regimes ---------------------------------------------------------
enum ENUM_TP_REGIME
  {
   TP_REG_RANGE      = 0,   // range  -> full hedge cycling
   TP_REG_TREND_UP   = 1,   // trend up
   TP_REG_TREND_DOWN = 2,   // trend down
   TP_REG_NEUTRAL    = 3,   // neutral -> no new cycles
   TP_REG_CHAOS      = 4    // chaos  -> no opens at all
  };

//--- operating modes -------------------------------------------------
enum ENUM_TP_MODE
  {
   TP_FULL       = 0,   // FULL     : everything enabled
   TP_PURE_IDEA  = 1,   // PURE_IDEA: owner rule only
   TP_ONE_SIDE   = 2    // ONE_SIDE : with-H1-trend side only, no hedge
  };

//--- position sizing mode --------------------------------------------
enum ENUM_TP_RISKMODE
  {
   TP_RISK_FIXED   = 0, // FIXED   : fixed lot per leg
   TP_RISK_PERCENT = 1, // PERCENT : lot from % of equity over SL distance
   TP_RISK_OFF     = 2  // OFF     : no new trades
  };

//+------------------------------------------------------------------+
//| GROUP: general                                                    |
//+------------------------------------------------------------------+
input group "=== TwinPulse - general ==="

input long   Magic              = TP_MAGIC_DEFAULT; // EA magic number (1..999999999)
input ENUM_TP_MODE Mode          = TP_FULL;         // Mode: FULL / PURE_IDEA / ONE_SIDE
input bool   AllowLive          = false;           // Allow trading on a REAL account
input bool   ShowPanel          = true;            // Show the on-chart panel
input bool   EnableFileLog      = true;            // Write TwinPulse.log in Common\Files
input bool   VerboseLog         = false;           // Print info level messages
input int    TimerSeconds       = 1;               // Panel / management timer (1..10)
input int    DeviationPoints    = 30;              // Max deviation for market orders (0..100)
input int    MaxOrderRetries    = 3;               // Retries for requote / price changed

//+------------------------------------------------------------------+
//| GROUP: legs and sizing                                            |
//+------------------------------------------------------------------+
input group "=== TwinPulse - legs and sizing ==="

input int    LegsPerSide        = 2;               // Legs per side (1..2, MaxLegs=4)
input double BaseLot            = 0.01;            // Lot per leg (0.01..1.00)
input double LotMultiplier      = 1.0;             // Re-open lot escalation (1.0..1.5, >1 needs the risk flag)
input bool   IUnderstandMartingaleRisk = false;     // I understand >1.0 multiplier is martingale-like
input ENUM_TP_RISKMODE RiskMode = TP_RISK_FIXED;   // RiskMode: FIXED / PERCENT / OFF
input double LegRiskPct         = 0.5;             // PERCENT: risk per leg in % of equity (0.1..2.0)
input double MaxTotalLots       = 0.08;            // Hard cap of all open lots (default 8 x BaseLot)

//+------------------------------------------------------------------+
//| GROUP: targets and exits                                          |
//+------------------------------------------------------------------+
input group "=== TwinPulse - targets and exits ==="

input double TargetA_ATR        = 0.6;             // Leg A (scalp) target in ATR5 (0.3..1.5)
input double TargetB_ATR        = 1.5;             // Leg B (runner) hard target in ATR5 (1.0..3.0)
input double BE_ATR            = 0.6;             // Leg B break-even trigger in ATR5 (0.4..1.0)
input double Trail_ATR         = 0.8;             // Leg B trailing distance in ATR5 (0.5..1.2)
input double HardSL_ATR        = 2.5;             // Hard stop for every leg in ATR5 (1.5..3.5)
input double CostFloorSpreadMult = 3.0;            // Every target is at least N x current spread (1..10)
input double CycleTargetUSD    = 2.0;             // Basket target in USD per 0.01 lot (1..4)
input double MinBankUSD        = 0.30;            // Minimum combined pair P/L for Close By, USD per 0.01 lot (0.1..2)
input double RebalanceTolUSD   = 0.10;            // Re-balance tolerance, USD per 0.01 lot (0.05..0.5)
input double ShredStepLot      = 0.01;            // Lot step used when shredding a loser (0.01..0.05)
input int    MaxLoserMinutes   = 240;             // Time stop for a losing leg, minutes (30..1440)

//+------------------------------------------------------------------+
//| GROUP: regime detection                                           |
//+------------------------------------------------------------------+
input group "=== TwinPulse - regime ==="

input int    RegimeERPeriod     = 20;              // Efficiency Ratio period on M15 (10..40)
input double ErRange            = 0.30;            // RANGE if ER below this (0.15..0.45)
input double ErTrend            = 0.40;            // TREND if ER above this (0.25..0.60)
input double ChopRange          = 55.0;           // RANGE if CHOP above this (50..62)
input double AdxRange           = 22.0;           // RANGE if ADX below this (15..30)
input double AdxTrend           = 28.0;           // TREND if ADX above this (20..40)
input double AtrSpikeRatio      = 2.0;            // CHAOS if ATR5 / median ATR5 above this (1.5..3.0)
input int    SlopeBars          = 10;             // EMA50 slope lookback in bars on M15 (5..20)
input double BBPeriod           = 20;             // Bollinger period on M15 (10..40)
input double BBDev              = 2.0;            // Bollinger deviation on M15 (1.5..2.5)
input double BBRangeATR         = 0.5;            // New cycle only within N x ATR14(M15) of the middle line (0.2..1.5)

//+------------------------------------------------------------------+
//| GROUP: brakes and risk                                           |
//+------------------------------------------------------------------+
input group "=== TwinPulse - brakes ==="

input double BasketStopPct      = 10.0;           // Basket stop in % of equity (2..30)
input double DailyStopPct       = 5.0;            // Daily loss stop in % of start-of-day equity (1..20)
input double MinMarginLevelPct  = 300.0;          // Minimum margin level for new opens (100..1000)
input double MaxSpreadPrice     = 0.60;           // Absolute max spread in price (0.20..1.00)
input double SpreadMedianMult   = 2.0;            // Max spread = N x rolling median spread (1.2..4.0)
input int    SpreadSampleSec    = 5;              // Spread sampling period, seconds (2..30)
input int    SpreadWindowMin    = 20;             // Rolling median window, minutes (5..60)

//+------------------------------------------------------------------+
//| GROUP: sessions                                                   |
//+------------------------------------------------------------------+
input group "=== TwinPulse - sessions ==="

input int    SessionStartHour   = 0;              // First hour (server) where cycles may start (0..23)
input int    SessionEndHour     = 21;             // Last hour (server) where cycles may start (1..24)
input int    RolloverStartHour  = 21;             // No new cycle / re-open from this hour (server)
input int    RolloverEndHour    = 24;             // ... until this hour (server, exclusive)
input int    FridayStopHour     = 20;             // Friday: no new cycle from this hour (server)
input int    FridayFlattenHour  = 20;             // Friday: flatten everything at this hour (server)
input int    FridayFlattenMinute= 45;             // Friday: flatten everything at this minute
input bool   FlattenBeforeWeekend = true;         // Close everything before the weekend
input int    ReopenCooldownSec  = 60;             // Cooldown between two re-opens, seconds (10..600)

//+------------------------------------------------------------------+
//| GROUP: news filter                                               |
//+------------------------------------------------------------------+
input group "=== TwinPulse - news ==="

input bool   UseNewsFilter      = true;            // Block trading around high impact USD news
input int    NewsMinutesBefore  = 15;             // Block N minutes before the event (0..60)
input int    NewsMinutesAfter   = 15;             // Block N minutes after the event (0..60)
input string NewsCsvFile        = TP_NEWS_CSV;    // CSV file with exported events (Common\Files)
input double ServerUTCOffsetHours= 0.0;           // Offset of the server clock vs UTC in hours (-12..12)

//+------------------------------------------------------------------+
//| GROUP: display                                                   |
//+------------------------------------------------------------------+
input group "=== TwinPulse - display ==="

input int    PanelFontSize      = 9;               // Panel font size (7..14)
input bool   WriteCsvLogs       = true;            // Write TwinPulse_legs.csv / TwinPulse_cycles.csv
input double FeePerLotRoundTurn = 0.0;            // Manual commission per lot round turn, USD (0 = use broker data)

//+------------------------------------------------------------------+
//| helpers                                                          |
//+------------------------------------------------------------------+

//--- returns true when the martingale escalation may be used ----------
bool TP_MartingaleAllowed(void)
  {
   if(LotMultiplier <= 1.0) return true;
   if(!IUnderstandMartingaleRisk) return false;
   return (LotMultiplier <= 1.5);
  }

//--- effective lot multiplier (hard capped at 1.5) --------------------
double TP_EffectiveLotMultiplier(void)
  {
   double m = LotMultiplier;
   if(m < 1.0) m = 1.0;
   if(m > 1.5) m = 1.5;
   if(!IUnderstandMartingaleRisk) m = 1.0;
   return m;
  }

//--- mode helpers ----------------------------------------------------
bool TP_IsPureIdea(void)
  {
   return (Mode == TP_PURE_IDEA);
  }

bool TP_IsOneSide(void)
  {
   return (Mode == TP_ONE_SIDE);
  }

bool TP_IsFull(void)
  {
   return (Mode == TP_FULL);
  }

//--- the regime filter is used in FULL and in ONE_SIDE mode ------------
//--- PURE_IDEA runs the owner rule without any regime filter ---------
bool TP_UseRegime(void)
  {
   return (Mode != TP_PURE_IDEA);
  }

bool TP_UseBank(void)
  {
   return (Mode == TP_FULL);
  }

//+------------------------------------------------------------------+
//| end of file                                                       |
//+------------------------------------------------------------------+
