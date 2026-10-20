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
#property copyright "TwinPulse"
#property version   "1.00"

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
input int    InpMode            = 0;         // 0=single 1=hedge 2=2+2 3=adaptive 4=adaptive-random 5=hybrid
input int    InpAdxPeriod       = 14;        // ADX period (market score)
input double InpScoreStrong     = 0.60;      // |score| >= this -> 3 on one side, 0 on the other
input double InpScoreMild       = 0.20;      // |score| >= this -> 2/1 split
input double InpReopenTolUSD    = 0.10;      // re-open only when the opposite side is >= -this
input double InpHedgeTarget_ATR = 3.00;      // hedge legs: take profit, x ATR

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

//--- exits
input double InpTP_ATR          = 2.00;      // Take profit, x ATR
input double InpSL_ATR          = 2.00;      // Stop loss, x ATR
input double InpMinTPxSpread    = 5.0;       // TP must be at least this many spreads
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

//==================================================================
CTrade   trade;
int      hFast = INVALID_HANDLE;
int      hSlow = INVALID_HANDLE;
int      hATR  = INVALID_HANDLE;
int      hBB   = INVALID_HANDLE;
int      hRSI  = INVALID_HANDLE;
int      hADX  = INVALID_HANDLE;

int      g_csv = INVALID_HANDLE;
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
   double   stopDist;
   double   trailStart;
   double   trailDist;
   datetime openTime;
   bool     trailOn;
  };
ScalpPos g_pos[MAXPOS];
int      g_nPos = 0;

//--- multi-leg bookkeeping
bool     g_closingAll = false;   // a daily stop is closing everything
datetime g_closeAllUntil = 0;    // classify deals until this moment as daily_exit
int      g_nBuy  = 0;            // open legs by side
int      g_nSell = 0;
double   g_dayFloating = 0.0;    // floating P/L of our open legs
string   g_splitTag = "0B0S";    // e.g. 2B1S, written into every CSV row
int      g_legsAtOpen = 0;

//--- adaptive statistics
long     g_legSum = 0;           // sum of open-leg counts sampled every tick
long     g_legSamples = 0;
int      g_legMax = 0;

//--- day state
datetime g_dayAnchor    = 0;
double   g_dayStartEquity = 0.0;
double   g_dayNet       = 0.0;
bool     g_dayLocked    = false;

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
             g_splitTag,
             IntegerToString(g_nBuy + g_nSell));
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

void TP_RemoveIdx(int idx)
  {
   for(int i = idx; i < g_nPos - 1; i++) g_pos[i] = g_pos[i + 1];
   if(g_nPos > 0) g_nPos--;
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
      g_pos[k].stopDist   = 0.0;   // 0 = not initialised by TP_Open yet
      g_pos[k].trailStart = 0.0;
      g_pos[k].trailDist  = 0.0;
      g_pos[k].trailOn    = false;
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

//--- total P/L of one side, in USD
double TP_SideProfit(int side)
  {
   double sum = 0.0;
   for(int i = 0; i < g_nPos; i++)
     {
      if(g_pos[i].side != side) continue;
      if(!PositionSelectByTicket(g_pos[i].ticket)) continue;
      sum += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
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
      double p = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      if(p < 0.0) return true;
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
      double d = (f3[0] - f3[2]) / atr;          // f3[0] = bar 1
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

   if(nBuy + nSell > InpMaxPositions)
     {
      if(nBuy >= nSell) nBuy = InpMaxPositions - nSell;
      else              nSell = InpMaxPositions - nBuy;
      if(nBuy + nSell > InpMaxPositions)
        {
         nBuy = InpMaxPositions / 2;
         nSell = InpMaxPositions - nBuy;
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
      if(g_pos[i].atr <= 0.0) continue;

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
   if(g_dayAnchor != 0)
      TP_Log(StringFormat("day closed: net %.2f USD, equity %.2f",
                          g_dayNet, AccountInfoDouble(ACCOUNT_EQUITY)));
   g_dayAnchor      = anchor;
   g_dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   g_dayNet         = 0.0;
   g_dayLocked      = false;
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
   if(g_dayLocked) return true;

   double total = TP_DayTotal();

   if(InpDailyLossUSD > 0.0 && total <= -InpDailyLossUSD)
     {
      g_dayLocked = true;
      TP_CloseAll("DAILY LOSS STOP - closing all");
      TP_Log(StringFormat("daily loss stop: %.2f USD - no entries until tomorrow", total));
      return true;
     }
   if(InpDailyTargetUSD > 0.0 && total >= InpDailyTargetUSD)
     {
      g_dayLocked = true;
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

   if(InpSessionStart <= InpSessionEnd)
     {
      if(d.hour < InpSessionStart) return false;
      if(d.hour >= InpSessionEnd)   return false;
     }
   else
     {
      if(d.hour >= InpSessionEnd && d.hour < InpSessionStart) return false;
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

   if(g_nPos >= InpMaxPositions) return false;
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
   if(InpMinMarginLevel > 0.0 && lvl < InpMinMarginLevel) return false;

   return true;
  }

bool TP_Open(int dir, double atr, double spread, double tpAtr)
  {
   double slDist = InpSL_ATR * atr;
   if(InpMaxSL_Price > 0.0 && slDist > InpMaxSL_Price) slDist = InpMaxSL_Price;

   double minDist = TP_StopsLevel() + TP_Point() * 2.0;
   if(slDist < minDist) slDist = minDist;

   double tpDist = tpAtr * atr;

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
   ulong newest = 0;
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
      g_pos[idx].stopDist   = slDist;
      g_pos[idx].trailStart = InpTrailStart_ATR * atr;
      g_pos[idx].trailDist  = InpTrail_ATR * atr;
      g_pos[idx].trailOn    = false;
     }

   g_opens++;
   g_legsAtOpen = g_nBuy + g_nSell + 1;

   //an "open" row carries zero money: it exists so the summary can measure how
   //many legs were open at the moment of the decision (average / max legs)
   TP_CsvRow(TimeCurrent(), StringFormat("E%d", InpEntryMode), dir, lots, fill,
             0.0, "open", 0.0, 0.0, 0.0, atr, spread, slDist);

   TP_Log(StringFormat("OPEN dir=%d lots=%.2f fill=%.3f sl=%.3f tp=%.3f atr=%.2f spread=%.3f split=%s",
                       dir, lots, fill, sl, tp, atr, spread, g_splitTag));
   return true;
  }

//==================================================================
//  the signal, once per closed M5 bar
//==================================================================
//--- the single-position entry rules (S1..S7)
int TP_SignalDir(double fast, double slow, double atr, double bbUp, double bbLo,
                 double rsi, double close1, double low1, double high1)
  {
   int dir = 0;

   if(InpEntryMode == 0)
     {
      //pullback continuation: trend up, price dips to the fast EMA and closes above it
      if(fast > slow && close1 > fast && low1 <= fast + 0.25 * atr) dir = 1;
      if(fast < slow && close1 < fast && high1 >= fast - 0.25 * atr) dir = -1;
     }
   else if(InpEntryMode == 1)
     {
      //mean reversion at the Bollinger band
      if(close1 < bbLo && rsi < InpRSIBuy)  dir = 1;
      if(close1 > bbUp && rsi > InpRSISell) dir = -1;
     }
   else if(InpEntryMode == 2)
     {
      //range breakout
      int hi = iHighest(_Symbol, PERIOD_M5, MODE_HIGH, InpBreakBars, 2);
      int lo = iLowest(_Symbol, PERIOD_M5, MODE_LOW, InpBreakBars, 2);
      if(hi >= 0 && lo >= 0)
        {
         double hh = iHigh(_Symbol, PERIOD_M5, hi);
         double ll = iLow(_Symbol, PERIOD_M5, lo);
         if(close1 > hh) dir = 1;
         if(close1 < ll) dir = -1;
        }
     }
   return dir;
  }

void TP_OnNewBar(void)
  {
   double fast, slow, atr, bbUp, bbLo, rsi;
   if(!TP_Ind(fast, slow, atr, bbUp, bbLo, rsi)) return;

   double slDist = 0.0;
   if(!TP_CanOpen(slDist)) return;

   double close1 = iClose(_Symbol, PERIOD_M5, 1);
   double low1   = iLow(_Symbol, PERIOD_M5, 1);
   double high1  = iHigh(_Symbol, PERIOD_M5, 1);
   if(close1 <= 0.0) return;

   double spread = TP_Spread();

   //-----------------------------------------------------------------
   //  single-position scalp (S1..S7)
   //-----------------------------------------------------------------
   if(InpMode == 0)
     {
      int dir = TP_SignalDir(fast, slow, atr, bbUp, bbLo, rsi, close1, low1, high1);
      if(InpEntryMode == 3)
        {
         if((int)(MathRand() % 100) < 50) dir = 1;
         else dir = -1;
        }
      if(dir == 0) return;
      if(!TP_SideAllowed(dir)) return;
      TP_Open(dir, atr, spread, InpTP_ATR);
      return;
     }

   //-----------------------------------------------------------------
   //  multi-leg modes: how many legs of each side do we want now?
   //-----------------------------------------------------------------
   int wantBuy = 0;
   int wantSell = 0;

   if(InpMode == 1)
     {
      //fixed 2 BUY + 2 SELL - the owner's original hedge idea
      wantBuy = 2;
      wantSell = 2;
     }
   else if(InpMode == 2)
     {
      //fixed counts from the inputs, default 2/2
      wantBuy = 2;
      wantSell = 2;
     }
   else if(InpMode == 3 || InpMode == 4)
     {
      double adx = 0.0;
      double bd[3];
      if(CopyBuffer(hADX, 0, 0, 3, bd) >= 3) adx = bd[1];

      double score = TP_MarketScore(fast, slow, atr, adx, bbUp, bbLo, close1);

      if(InpMode == 4)
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
   while(wantBuy + wantSell > InpMaxPositions)
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

   int idx = TP_Idx(posId);
   int side = 1;
   double entryPx = price;
   double atr = 0.0, spread = 0.0, stopDist = 0.0;
   double tp = 0.0, sl = 0.0;
   bool trailOn = false;
   string leg = "POS";

   if(idx >= 0)
     {
      side     = g_pos[idx].side;
      entryPx  = g_pos[idx].entry;
      atr      = g_pos[idx].atr;
      spread   = g_pos[idx].spread;
      stopDist = g_pos[idx].stopDist;
      tp       = g_pos[idx].tp;
      sl       = g_pos[idx].sl;
      trailOn  = g_pos[idx].trailOn;
      leg      = StringFormat("E%d", InpEntryMode);
      TP_RemoveIdx(idx);
     }

   //--- classify the exit
   double tol = TP_Point() * 20.0;
   string reason = "close";
   if(g_closingAll || TimeCurrent() <= g_closeAllUntil) reason = "daily_exit";
   else if(tp > 0.0 && MathAbs(price - tp) <= tol) reason = "target";
   else if(sl > 0.0 && MathAbs(price - sl) <= tol)
     {
      if(trailOn) reason = "trail";
      else reason = "stop";
     }
   else if(trailOn) reason = "trail";
   else reason = "stop";

   TP_CsvRow(when, leg, side, HistoryDealGetDouble(trans.deal, DEAL_VOLUME),
             entryPx, price, reason, profit, swap, comm, atr, spread, stopDist);

   g_dayNet += profit + swap + comm;
  }

//==================================================================
//  lifecycle
//==================================================================
int OnInit(void)
  {
   if(!InpAllowLive && (ENUM_ACCOUNT_TRADE_MODE)AccountInfoInteger(ACCOUNT_TRADE_MODE) == ACCOUNT_TRADE_MODE_REAL)
     {
      Print("TwinPulseScalp refuses to run on a REAL account (AllowLive=false)");
      return INIT_FAILED;
     }

   hFast = iMA(_Symbol, PERIOD_M5, InpFastEMA, 0, MODE_EMA, PRICE_CLOSE);
   hSlow = iMA(_Symbol, PERIOD_M5, InpSlowEMA, 0, MODE_EMA, PRICE_CLOSE);
   hATR  = iATR(_Symbol, PERIOD_M5, InpATRPeriod);
   hBB   = iBands(_Symbol, PERIOD_M5, InpBBPeriod, 0, InpBBDev, PRICE_CLOSE);
   hRSI  = iRSI(_Symbol, PERIOD_M5, InpRSIPeriod, PRICE_CLOSE);
   hADX  = iADX(_Symbol, PERIOD_M5, InpAdxPeriod);

   if(hFast == INVALID_HANDLE || hSlow == INVALID_HANDLE || hATR == INVALID_HANDLE ||
      hBB == INVALID_HANDLE || hRSI == INVALID_HANDLE || hADX == INVALID_HANDLE)
     {
      Print("indicator handle failed");
      return INIT_FAILED;
     }

   trade.SetExpertMagicNumber((ulong)InpMagic);
   trade.SetDeviationInPoints(50);
   trade.SetTypeFillingBySymbol(_Symbol);
   trade.SetAsyncMode(false);

   if(InpEntryMode == 3) MathSrand(InpRandomSeed);

   TP_LoadSessions();
   g_dayAnchor      = TP_DayStart(TimeCurrent());
   g_dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   g_nPos = 0;

   if(InpWriteCsv)
     {
      g_csv = FileOpen("TwinPulse_legs.csv",
                       FILE_WRITE | FILE_CSV | FILE_ANSI | FILE_COMMON, ',', CP_ACP);
      if(g_csv != INVALID_HANDLE) TP_CsvHeader();
     }
   if(InpVerboseLog)
      g_log = FileOpen("TwinPulse_scalp.log",
                       FILE_WRITE | FILE_CSV | FILE_ANSI | FILE_COMMON, ',', CP_ACP);

   TP_Log(StringFormat("TPS 1.11 start %s mode=%d entry=%d lots=%.2f maxpos=%d session %d-%d tp=%.2fATR sl=%.2fATR minTP=%.1fxspread dailyTarget=%.0f dailyLoss=%.0f",
                       _Symbol, InpMode, InpEntryMode, InpLots, InpMaxPositions,
                       InpSessionStart, InpSessionEnd, InpTP_ATR, InpSL_ATR, InpMinTPxSpread,
                       InpDailyTargetUSD, InpDailyLossUSD));

   //--- the margin facts the owner asked for, printed once per run
   double m1 = 0.0;
   OrderCalcMargin(ORDER_TYPE_BUY, _Symbol, InpLots, TP_Ask(), m1);
   long   mmode = AccountInfoInteger(ACCOUNT_MARGIN_MODE);
   double e = AccountInfoDouble(ACCOUNT_EQUITY);
   double hedgeRate = SymbolInfoDouble(_Symbol, SYMBOL_MARGIN_HEDGED);
   int    cap300 = (m1 > 0.0) ? (int)MathFloor(e / (m1 * 3.0)) : 0;
   int    cap250 = (m1 > 0.0) ? (int)MathFloor(e / (m1 * 2.5)) : 0;
   TP_Log(StringFormat("TPS margin: account mode=%d (0=netting 1=exchange 2=hedging) marginPer0.01=%.2f USD hedgedRate=%.2f equity=%.2f -> max legs %d at 300%%, %d at 250%%; using cap %d at %.0f%%",
                       (int)mmode, m1, hedgeRate, e, cap300, cap250, InpMaxPositions, InpMinMarginLevel));
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   if(g_csv != INVALID_HANDLE) { FileClose(g_csv); g_csv = INVALID_HANDLE; }
   if(g_log != INVALID_HANDLE) { FileClose(g_log); g_log = INVALID_HANDLE; }
   if(hFast != INVALID_HANDLE) IndicatorRelease(hFast);
   if(hSlow != INVALID_HANDLE) IndicatorRelease(hSlow);
   if(hATR  != INVALID_HANDLE) IndicatorRelease(hATR);
   if(hBB   != INVALID_HANDLE) IndicatorRelease(hBB);
   if(hRSI  != INVALID_HANDLE) IndicatorRelease(hRSI);
   if(hADX  != INVALID_HANDLE) IndicatorRelease(hADX);
  }

void OnTick(void)
  {
   TP_UpdateDay();
   TP_Sync();
   TP_RecountBook();
   TP_ManagePositions();

   //the daily stop looks at closed AND floating P/L, so it is checked on
   //every tick - not only on a new bar
   if(TP_DayLocked()) return;

   datetime bar = (datetime)SeriesInfoInteger(_Symbol, PERIOD_M5, SERIES_LASTBAR_DATE);
   if(bar == 0) return;
   if(bar == g_lastBarM5) return;
   g_lastBarM5 = bar;
   TP_OnNewBar();
  }
//+------------------------------------------------------------------+
