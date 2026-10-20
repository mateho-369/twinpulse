//+------------------------------------------------------------------+
//|                                              TwinPulseTrend.mq5  |
//|  TwinPulse Trend - a single-position trend follower for XAUUSD    |
//|                                                                   |
//|  Why this EA exists (docs/RESEARCH_NOTES.md):                      |
//|  the hedge EA lost for a structural reason - 1,367 legs in two     |
//|  months paid 0.258 of spread each while earning ~0.18 of gross     |
//|  edge. A trend follower does the opposite: few trades, each one    |
//|  must cover the spread many times over.                            |
//|                                                                   |
//|  Deliberate properties, each one a lesson from round 2:            |
//|   * risk is a PERCENT of equity, never a fixed lot, so the EA       |
//|     behaves the same on 100 and on 100,000 (ANALYSIS_3);           |
//|   * ONE position, no hedge, no averaging, no martingale;           |
//|   * the stop is placed before the position exists and is never     |
//|     widened;                                                       |
//|   * every exit is classified and written to a CSV whose pos_net    |
//|     column must sum to the tester's net profit to the cent.        |
//+------------------------------------------------------------------+
#property copyright "TwinPulse"
#property version   "1.00"

#include <Trade\Trade.mqh>

//--- identity -----------------------------------------------------------
input long   InpMagic            = 26101702;   // Magic number
input string InpComment          = "TPT";      // Order comment

//--- sizing -------------------------------------------------------------
input double InpRiskPct          = 0.50;       // Risk per trade, % of equity (0.05..5)
input double InpFixedLots        = 0.00;       // Fixed lots (0 = use RiskPct)
input double InpMaxLots          = 1.00;       // Hard lot ceiling (0 = broker max)

//--- signal -------------------------------------------------------------
input int    InpFastEMA          = 50;         // Fast EMA on H1
input int    InpSlowEMA          = 200;        // Slow EMA on H1
input int    InpADXPeriod        = 14;         // ADX period
input double InpMinADX           = 22.0;       // Minimum ADX to trade (0 = off)
input int    InpATRPeriod        = 14;         // ATR period
input int    InpEntryMode        = 0;          // 0=trend 1=random 2=always long (controls)
input int    InpRandomSeed       = 1;          // Seed for the random control
input bool   InpAllowLong        = true;       // Allow long entries
input bool   InpAllowShort       = true;       // Allow short entries

//--- exits --------------------------------------------------------------
input double InpSL_ATR           = 1.50;       // Initial stop, x ATR
input double InpTP_ATR           = 4.00;       // Take profit, x ATR
input double InpBE_ATR           = 1.00;       // Move to break-even at +x ATR (0 = off)
input double InpBE_LockPrice     = 0.00;       // Extra price locked at break-even
input double InpTrailStart_ATR   = 2.00;       // Start trailing at +x ATR (0 = off)
input double InpTrail_ATR        = 2.50;       // Trail distance, x ATR
input int    InpMaxBarsInTrade   = 0;          // Time stop in H1 bars (0 = off)

//--- protection ---------------------------------------------------------
input double InpMaxSpread        = 0.60;       // Max spread in price units (0 = off)
input double InpDailyStopPct     = 3.00;       // Daily loss stop, % of day-start equity
input double InpMaxDrawdownPct   = 20.00;      // Halt the EA at this drawdown, % of peak
input int    InpSessionStartHour = 1;          // First server hour to open (0..23)
input int    InpSessionEndHour   = 20;         // Last server hour to open (1..24)
input int    InpFridayStopHour   = 20;         // No new trades after this hour on Friday

//--- logging ------------------------------------------------------------
input bool   InpWriteCsv         = true;       // Write TwinPulse_legs.csv
input bool   InpVerboseLog       = true;       // Write TwinPulse_trend.log

//--- internals ----------------------------------------------------------
CTrade   trade;
int      hFast = INVALID_HANDLE;
int      hSlow = INVALID_HANDLE;
int      hADX  = INVALID_HANDLE;
int      hATR  = INVALID_HANDLE;

datetime g_lastBarTime = 0;
double   g_dayStartEquity = 0.0;
int      g_dayStamp = -1;
double   g_peakEquity = 0.0;
bool     g_halted = false;
int      g_cycle = 0;

//--- the one open position we are responsible for -----------------------
bool     g_hasPos      = false;
ulong    g_posId       = 0;
int      g_posSide     = 0;        // +1 long, -1 short
double   g_posEntry    = 0.0;
double   g_posLots     = 0.0;
double   g_posSL       = 0.0;
double   g_posTP       = 0.0;
double   g_posATR      = 0.0;
double   g_posStopDist = 0.0;   // stop distance used at entry, price units
double   g_posSpread   = 0.0;
datetime g_posOpenTime = 0;
datetime g_posOpenBar  = 0;
bool     g_beDone      = false;
bool     g_trailOn     = false;

//--- csv / log handles --------------------------------------------------
int      g_csv = INVALID_HANDLE;
int      g_log = INVALID_HANDLE;

//+------------------------------------------------------------------+
//| helpers                                                          |
//+------------------------------------------------------------------+
double TP_Ask(void) { return SymbolInfoDouble(_Symbol, SYMBOL_ASK); }
double TP_Bid(void) { return SymbolInfoDouble(_Symbol, SYMBOL_BID); }

double TP_Spread(void)
  {
   double a = TP_Ask();
   double b = TP_Bid();
   if(a <= 0.0 || b <= 0.0) return 0.0;
   return (a - b);
  }

double TP_Point(void)
  {
   double p = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   if(p <= 0.0) p = 0.01;
   return p;
  }

double TP_TickSize(void)
  {
   double t = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(t <= 0.0) t = TP_Point();
   return t;
  }

double TP_NormPrice(double price)
  {
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   return NormalizeDouble(price, digits);
  }

double TP_NormLots(double lots)
  {
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(step <= 0.0) step = 0.01;

   lots = MathFloor(lots / step + 0.0000001) * step;
   if(lots < minLot) lots = minLot;
   if(lots > maxLot) lots = maxLot;
   if(InpMaxLots > 0.0 && lots > InpMaxLots) lots = InpMaxLots;
   return NormalizeDouble(lots, 2);
  }

double TP_StopsLevelPrice(void)
  {
   long lvl = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   if(lvl < 0) lvl = 0;
   return ((double)lvl) * TP_Point();
  }

int TP_DayStamp(datetime t)
  {
   MqlDateTime d;
   TimeToStruct(t, d);
   return (d.year * 10000 + d.mon * 100 + d.day);
  }

//+------------------------------------------------------------------+
//| logging                                                          |
//+------------------------------------------------------------------+
void TP_Log(string msg)
  {
   if(!InpVerboseLog) return;
   if(g_log == INVALID_HANDLE) return;
   FileWrite(g_log,
             TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS),
             msg);
   FileFlush(g_log);
  }

void TP_CsvHeader(void)
  {
   if(!InpWriteCsv) return;
   if(g_csv == INVALID_HANDLE) return;
   FileWrite(g_csv,
             "time", "cycle", "leg", "side", "volume", "open_price", "close_price",
             "reason", "profit", "pos_net", "bank", "regime", "spread", "atr5",
             "spread_open", "spread_cost", "gross", "stop_dist");
  }

void TP_CsvRow(datetime closeTime, double closePrice, string reason,
               double profit, double swap, double commission, double spreadCost)
  {
   if(!InpWriteCsv) return;
   if(g_csv == INVALID_HANDLE) return;

   double posNet = profit + swap + commission;
   string side   = "long";
   if(g_posSide < 0) side = "short";

   FileWrite(g_csv,
             TimeToString(closeTime, TIME_DATE | TIME_SECONDS),
             IntegerToString(g_cycle),
             "0",
             side,
             DoubleToString(g_posLots, 2),
             DoubleToString(g_posEntry, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS)),
             DoubleToString(closePrice, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS)),
             reason,
             DoubleToString(profit, 2),
             DoubleToString(posNet, 2),
             "0",
             "",
             DoubleToString(g_posSpread, 3),
             DoubleToString(g_posATR, 3),
             DoubleToString(g_posSpread, 3),
             DoubleToString(spreadCost, 2),
             DoubleToString(profit, 2),
             DoubleToString(g_posStopDist, 3));
   FileFlush(g_csv);
  }

//+------------------------------------------------------------------+
//| equity guards                                                    |
//+------------------------------------------------------------------+
void TP_UpdateDayEquity(void)
  {
   int stamp = TP_DayStamp(TimeCurrent());
   if(stamp == g_dayStamp) return;
   g_dayStamp       = stamp;
   g_dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   TP_Log(StringFormat("new day %d, start equity %.2f", stamp, g_dayStartEquity));
  }

bool TP_DailyStopHit(void)
  {
   if(InpDailyStopPct <= 0.0) return false;
   if(g_dayStartEquity <= 0.0) return false;
   double eq    = AccountInfoDouble(ACCOUNT_EQUITY);
   double floorLevel = g_dayStartEquity * (1.0 - InpDailyStopPct / 100.0);
   return (eq <= floorLevel);
  }

bool TP_DrawdownHalt(void)
  {
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   if(eq > g_peakEquity) g_peakEquity = eq;
   if(InpMaxDrawdownPct <= 0.0) return false;
   if(g_peakEquity <= 0.0) return false;
   double dl = g_peakEquity * (1.0 - InpMaxDrawdownPct / 100.0);
   return (eq <= dl);
  }

//+------------------------------------------------------------------+
//| session                                                          |
//+------------------------------------------------------------------+
bool TP_SessionOpen(void)
  {
   MqlDateTime d;
   TimeToStruct(TimeCurrent(), d);
   if(d.day_of_week == 0 || d.day_of_week == 6) return false;
   if(d.day_of_week == 5 && d.hour >= InpFridayStopHour) return false;

   if(InpSessionStartHour <= InpSessionEndHour)
     {
      if(d.hour < InpSessionStartHour) return false;
      if(d.hour >= InpSessionEndHour)  return false;
     }
   else
     {
      //window wraps midnight
      if(d.hour >= InpSessionEndHour && d.hour < InpSessionStartHour) return false;
     }
   return true;
  }

//+------------------------------------------------------------------+
//| indicators                                                       |
//+------------------------------------------------------------------+
bool TP_ReadIndicators(double &fast, double &slow, double &adx, double &atr)
  {
   double bf[3];
   double bs[3];
   double ba[3];

   if(CopyBuffer(hFast, 0, 0, 3, bf) < 3) return false;
   if(CopyBuffer(hSlow, 0, 0, 3, bs) < 3) return false;
   if(CopyBuffer(hATR,  0, 0, 3, ba) < 3) return false;

   //index 0 = the bar that is still forming, 1 = the last closed bar
   fast = bf[1];
   slow = bs[1];
   atr  = ba[1];

   adx = 0.0;
   if(InpMinADX > 0.0)
     {
      double bd[3];
      if(CopyBuffer(hADX, 0, 0, 3, bd) < 3) return false;
      adx = bd[1];
     }
   return (atr > 0.0);
  }

//+------------------------------------------------------------------+
//| position bookkeeping                                             |
//+------------------------------------------------------------------+
void TP_SyncPosition(void)
  {
   if(g_hasPos)
     {
      if(!PositionSelectByTicket(g_posId))
        {
         g_hasPos = false;
         return;
        }
      g_posSL = PositionGetDouble(POSITION_SL);
      g_posTP = PositionGetDouble(POSITION_TP);
      return;
     }

   //adopt a position of ours that we do not know about (terminal restart)
   for(int i = 0; i < PositionsTotal(); i++)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;

      g_hasPos      = true;
      g_posId       = ticket;
      g_posEntry    = PositionGetDouble(POSITION_PRICE_OPEN);
      g_posLots     = PositionGetDouble(POSITION_VOLUME);
      g_posSL       = PositionGetDouble(POSITION_SL);
      g_posTP       = PositionGetDouble(POSITION_TP);
      g_posOpenTime = (datetime)PositionGetInteger(POSITION_TIME);
      long type     = PositionGetInteger(POSITION_TYPE);
      g_posSide     = 1;
      if(type == POSITION_TYPE_SELL) g_posSide = -1;
      g_posATR      = 0.0;
      g_posStopDist = 0.0;
      g_posSpread   = 0.0;
      g_beDone      = false;
      g_trailOn     = false;
      return;
     }
  }

//+------------------------------------------------------------------+
//| exits that we manage ourselves                                   |
//+------------------------------------------------------------------+
void TP_ManagePosition(void)
  {
   if(!g_hasPos) return;

   double bid = TP_Bid();
   double ask = TP_Ask();
   if(bid <= 0.0 || ask <= 0.0) return;

   double atr = g_posATR;
   if(atr <= 0.0)
     {
      double bf, bs, ba2, bd;
      if(!TP_ReadIndicators(bf, bs, bd, ba2)) return;
      atr = ba2;
     }
   if(atr <= 0.0) return;

   double cur   = bid;
   double entry = g_posEntry;
   if(g_posSide < 0) cur = ask;

   double prof = cur - entry;
   if(g_posSide < 0) prof = entry - cur;

   double stopsLvl = TP_StopsLevelPrice();
   double minDist  = stopsLvl + TP_Point();

   double newSL = g_posSL;

   //--- break even ---------------------------------------------------
   if(!g_beDone && InpBE_ATR > 0.0 && prof >= InpBE_ATR * atr)
     {
      double bePrice = entry + InpBE_LockPrice;
      if(g_posSide < 0) bePrice = entry - InpBE_LockPrice;

      if(g_posSide > 0 && (newSL <= 0.0 || bePrice > newSL)) newSL = bePrice;
      if(g_posSide < 0 && (newSL <= 0.0 || bePrice < newSL)) newSL = bePrice;
      g_beDone = true;
      TP_Log(StringFormat("break-even armed at %.3f (profit %.3f)", newSL, prof));
     }

   //--- trailing -----------------------------------------------------
   if(InpTrailStart_ATR > 0.0 && InpTrail_ATR > 0.0 && prof >= InpTrailStart_ATR * atr)
     {
      double trailPrice = cur - InpTrail_ATR * atr;
      if(g_posSide < 0) trailPrice = cur + InpTrail_ATR * atr;

      if(g_posSide > 0 && (newSL <= 0.0 || trailPrice > newSL)) newSL = trailPrice;
      if(g_posSide < 0 && (newSL <= 0.0 || trailPrice < newSL)) newSL = trailPrice;
      if(!g_trailOn) TP_Log("trailing started");
      g_trailOn = true;
     }

   //--- time stop ----------------------------------------------------
   if(InpMaxBarsInTrade > 0 && g_posOpenBar > 0)
     {
      datetime nowBar = (datetime)SeriesInfoInteger(_Symbol, PERIOD_H1, SERIES_LASTBAR_DATE);
      int bars = 0;
      if(nowBar > g_posOpenBar)
         bars = (int)((nowBar - g_posOpenBar) / 3600);
      if(bars >= InpMaxBarsInTrade)
        {
         TP_Log(StringFormat("time stop after %d H1 bars", bars));
         trade.PositionClose(g_posId);
         return;
        }
     }

   //--- only send a modification when it really changes --------------
   if(newSL <= 0.0) return;
   if(g_posSide > 0 && newSL <= entry && !g_beDone) return;

   newSL = TP_NormPrice(newSL);

   //never widen: only improve
   if(g_posSL > 0.0)
     {
      if(g_posSide > 0 && newSL <= g_posSL + TP_Point() * 0.5) return;
      if(g_posSide < 0 && newSL >= g_posSL - TP_Point() * 0.5) return;
     }

   //keep the stop a legal distance from the market
   if(g_posSide > 0 && newSL > bid - minDist)
     {
      if(g_posSL > 0.0) return;
      newSL = bid - minDist;
     }
   if(g_posSide < 0 && newSL < ask + minDist)
     {
      if(g_posSL > 0.0) return;
      newSL = ask + minDist;
     }
   newSL = TP_NormPrice(newSL);
   if((newSL <= 0.0) || (newSL == g_posSL)) return;

   if(!trade.PositionModify(g_posId, newSL, g_posTP))
      TP_Log(StringFormat("modify failed retcode=%d sl=%.3f", trade.ResultRetcode(), newSL));
   else
      g_posSL = newSL;
  }

//+------------------------------------------------------------------+
//| entry                                                            |
//+------------------------------------------------------------------+
bool TP_RiskLots(double stopDist, double &lots)
  {
   lots = 0.0;
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   if(eq <= 0.0) return false;

   if(InpFixedLots > 0.0)
     {
      lots = TP_NormLots(InpFixedLots);
      return (lots > 0.0);
     }

   if(stopDist <= 0.0) return false;
   double tickVal = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSz  = TP_TickSize();
   if(tickVal <= 0.0 || tickSz <= 0.0) return false;

   double lossPerLot = (stopDist / tickSz) * tickVal;
   if(lossPerLot <= 0.0) return false;

   double riskMoney = eq * InpRiskPct / 100.0;
   lots = TP_NormLots(riskMoney / lossPerLot);
   return (lots > 0.0);
  }

bool TP_Open(int dir, double atr, double spread)
  {
   double stopsLvl = TP_StopsLevelPrice();
   double minDist  = stopsLvl + TP_Point() * 2.0;

   double stopDist = InpSL_ATR * atr;
   if(stopDist < minDist) stopDist = minDist;

   double targetDist = 0.0;
   if(InpTP_ATR > 0.0)
     {
      targetDist = InpTP_ATR * atr;
      if(targetDist < minDist) targetDist = minDist;
     }

   double lots = 0.0;
   if(!TP_RiskLots(stopDist, lots)) return false;

   double price = TP_Ask();
   double sl    = price - stopDist;
   double tp    = 0.0;
   if(dir > 0 && targetDist > 0.0) tp = price + targetDist;

   if(dir < 0)
     {
      price = TP_Bid();
      sl    = price + stopDist;
      if(targetDist > 0.0) tp = price - targetDist;
     }

   price = TP_NormPrice(price);
   sl    = TP_NormPrice(sl);
   if(tp > 0.0) tp = TP_NormPrice(tp);

   //margin guard: never open what the account cannot carry
   double marginNeeded = 0.0;
   ENUM_ORDER_TYPE ot = ORDER_TYPE_BUY;
   if(dir < 0) ot = ORDER_TYPE_SELL;
   if(OrderCalcMargin(ot, _Symbol, lots, price, marginNeeded))
     {
      double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
      if(marginNeeded > freeMargin * 0.80)
        {
         double scale = (freeMargin * 0.80) / marginNeeded;
         if(scale < 1.0) lots = TP_NormLots(lots * scale);
         if(lots <= 0.0) return false;
        }
     }

   g_cycle++;
   string comment = StringFormat("%s|%d", InpComment, g_cycle);

   bool ok = false;
   if(dir > 0) ok = trade.Buy(lots, _Symbol, price, sl, tp, comment);
   else        ok = trade.Sell(lots, _Symbol, price, sl, tp, comment);

   if(!ok || trade.ResultRetcode() != TRADE_RETCODE_DONE)
     {
      TP_Log(StringFormat("open failed dir=%d retcode=%d", dir, trade.ResultRetcode()));
      return false;
     }

   double fill = trade.ResultPrice();
   if(fill <= 0.0) fill = price;

   g_hasPos      = true;
   g_posSide     = dir;
   g_posEntry    = fill;
   g_posLots     = lots;
   g_posSL       = sl;
   g_posTP       = tp;
   g_posATR      = atr;
   g_posStopDist = stopDist;
   g_posSpread   = spread;
   g_posOpenTime = TimeCurrent();
   g_posOpenBar  = (datetime)SeriesInfoInteger(_Symbol, PERIOD_H1, SERIES_LASTBAR_DATE);
   g_beDone      = false;
   g_trailOn     = false;

   //the ticket the terminal gave us
   g_posId = trade.ResultOrder();
   if(PositionSelectByTicket(g_posId))
      g_posId = (ulong)PositionGetInteger(POSITION_TICKET);
   else
     {
      //fall back to whatever our magic owns
      for(int i = 0; i < PositionsTotal(); i++)
        {
         ulong ticket = PositionGetTicket(i);
         if(ticket == 0) continue;
         if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
         if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
         g_posId = ticket;
         break;
        }
     }

   string dirName = "SELL";
   if(dir > 0) dirName = "BUY";
   TP_Log(StringFormat("OPEN %s %s lots=%.2f at %.3f sl=%.3f tp=%.3f atr=%.3f spread=%.3f",
                       dirName, InpComment, lots, fill, sl, tp, atr, spread));
   return true;
  }

//+------------------------------------------------------------------+
//| one decision per closed H1 bar                                   |
//+------------------------------------------------------------------+
void TP_OnNewBar(void)
  {
   if(g_hasPos) return;
   if(g_halted) return;

   TP_UpdateDayEquity();
   if(TP_DailyStopHit()) { TP_Log("daily loss stop - no new trades today"); return; }
   if(TP_DrawdownHalt())  { g_halted = true; TP_Log("MAX DRAWDOWN - EA halted"); return; }
   if(!TP_SessionOpen())  return;

   double spread = TP_Spread();
   if(InpMaxSpread > 0.0 && spread > InpMaxSpread) return;

   double fast = 0.0, slow = 0.0, adx = 0.0, atr = 0.0;
   if(!TP_ReadIndicators(fast, slow, adx, atr)) return;

   int dir = 0;

   if(InpEntryMode == 1)
     {
      //random control: same exits, no signal
      if((int)(MathRand() % 100) < 50) dir = 1;
      else dir = -1;
     }
   else if(InpEntryMode == 2)
     {
      dir = 1;
     }
   else
     {
      double close1 = iClose(_Symbol, PERIOD_H1, 1);
      if(close1 <= 0.0) return;
      bool trending = true;
      if(InpMinADX > 0.0 && adx < InpMinADX) trending = false;

      if(trending && fast > slow && close1 > fast) dir = 1;
      if(trending && fast < slow && close1 < fast) dir = -1;
     }

   if(dir > 0 && !InpAllowLong)  return;
   if(dir < 0 && !InpAllowShort) return;
   if(dir == 0) return;

   TP_Open(dir, atr, spread);
  }

//+------------------------------------------------------------------+
//| trade events: the only exact source of a realised P/L            |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
  {
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;
   if(trans.deal == 0) return;
   if(!HistoryDealSelect(trans.deal)) return;

   long magic = HistoryDealGetInteger(trans.deal, DEAL_MAGIC);
   if(magic != InpMagic) return;

   long entry = HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
   if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_OUT_BY) return;

   double price  = HistoryDealGetDouble(trans.deal, DEAL_PRICE);
   double profit = HistoryDealGetDouble(trans.deal, DEAL_PROFIT);
   double swap   = HistoryDealGetDouble(trans.deal, DEAL_SWAP);
   double comm   = HistoryDealGetDouble(trans.deal, DEAL_COMMISSION);
   datetime when = (datetime)HistoryDealGetInteger(trans.deal, DEAL_TIME);

   //which of our levels did the market take out?
   string reason = "close";
   double tol = TP_Point() * 20.0;

   if(g_posTP > 0.0 && MathAbs(price - g_posTP) <= tol)
      reason = "target";
   else if(g_posSL > 0.0 && MathAbs(price - g_posSL) <= tol)
     {
      if(g_beDone && g_posSide > 0 && g_posSL >= g_posEntry) reason = "break-even";
      else if(g_beDone && g_posSide < 0 && g_posSL <= g_posEntry) reason = "break-even";
      else reason = "stop";
     }
   else if(g_trailOn)
      reason = "trail";

   double spreadCost = 0.0;
   double tickVal = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSz  = TP_TickSize();
   if(tickVal > 0.0 && tickSz > 0.0 && g_posSpread > 0.0)
      spreadCost = (g_posSpread / tickSz) * tickVal * g_posLots;

   TP_CsvRow(when, price, reason, profit, swap, comm, spreadCost);

   string sideName = "SHORT";
   if(g_posSide > 0) sideName = "LONG";
   TP_Log(StringFormat("CLOSE %s %s %.2f reason=%s net=%.2f",
                       sideName,
                       DoubleToString(price, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS)),
                       profit + swap + comm, reason, profit + swap + comm));

   g_hasPos = false;
   g_posId  = 0;
  }

//+------------------------------------------------------------------+
//| lifecycle                                                        |
//+------------------------------------------------------------------+
int OnInit(void)
  {
   hFast = iMA(_Symbol, PERIOD_H1, InpFastEMA, 0, MODE_EMA, PRICE_CLOSE);
   hSlow = iMA(_Symbol, PERIOD_H1, InpSlowEMA, 0, MODE_EMA, PRICE_CLOSE);
   hATR  = iATR(_Symbol, PERIOD_H1, InpATRPeriod);
   hADX  = iADX(_Symbol, PERIOD_H1, InpADXPeriod);

   if(hFast == INVALID_HANDLE || hSlow == INVALID_HANDLE ||
      hATR  == INVALID_HANDLE || hADX  == INVALID_HANDLE)
     {
      Print("indicator handle failed");
      return INIT_FAILED;
     }

   trade.SetExpertMagicNumber((ulong)InpMagic);
   trade.SetDeviationInPoints(50);
   trade.SetTypeFillingBySymbol(_Symbol);
   trade.SetAsyncMode(false);

   if(InpEntryMode == 1) MathSrand(InpRandomSeed);

   g_dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   g_peakEquity     = g_dayStartEquity;
   g_dayStamp       = TP_DayStamp(TimeCurrent());

   if(InpWriteCsv)
     {
      g_csv = FileOpen("TwinPulse_legs.csv",
                       FILE_WRITE | FILE_CSV | FILE_ANSI | FILE_COMMON, ',', CP_ACP);
      if(g_csv != INVALID_HANDLE) TP_CsvHeader();
     }
   if(InpVerboseLog)
     {
      g_log = FileOpen("TwinPulse_trend.log",
                       FILE_WRITE | FILE_CSV | FILE_ANSI | FILE_COMMON, ',', CP_ACP);
     }

   TP_Log(StringFormat("TPT 1.00 start %s mode=%d risk=%.2f%% fast=%d slow=%d adx=%.1f sl=%.2f tp=%.2f",
                       _Symbol, InpEntryMode, InpRiskPct, InpFastEMA, InpSlowEMA,
                       InpMinADX, InpSL_ATR, InpTP_ATR));
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
//| End of a tester run: never leave a position open, because a leg  |
//| still open at the last bar has no closing deal, so its floating   |
//| P/L appears in the legs.csv neither - the report would then say   |
//| "net -40" while the account still carries an unknown exposure.    |
//+------------------------------------------------------------------+
void TP_CloseAllAtEnd(void)
  {
   int closed = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;

      //read the money BEFORE the close: after it the position is gone and
      //OnTradeTransaction may not run again during deinitialisation
      double vol  = PositionGetDouble(POSITION_VOLUME);
      double px   = PositionGetDouble(POSITION_PRICE_CURRENT);
      double prof = PositionGetDouble(POSITION_PROFIT);
      double swp  = PositionGetDouble(POSITION_SWAP);
      double ent  = PositionGetDouble(POSITION_PRICE_OPEN);
      bool   isBuy = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);

      if(!trade.PositionClose(t)) continue;
      closed++;

      g_posLots  = vol;
      g_posEntry = ent;
      g_posSide  = -1;
      if(isBuy) g_posSide = 1;
      TP_CsvRow(TimeCurrent(), px, "end_of_test", prof, swp, 0.0, 0.0);
     }

   if(closed > 0)
      TP_Log(StringFormat("END OF TEST: closed %d position(s) that were still open", closed));
   g_hasPos = false;
   g_posId  = 0;
  }

void OnDeinit(const int reason)
  {
   if(MQLInfoInteger(MQL_TESTER)) TP_CloseAllAtEnd();
   if(g_csv != INVALID_HANDLE) { FileClose(g_csv); g_csv = INVALID_HANDLE; }
   if(g_log != INVALID_HANDLE) { FileClose(g_log); g_log = INVALID_HANDLE; }
   if(hFast != INVALID_HANDLE) IndicatorRelease(hFast);
   if(hSlow != INVALID_HANDLE) IndicatorRelease(hSlow);
   if(hADX  != INVALID_HANDLE) IndicatorRelease(hADX);
   if(hATR  != INVALID_HANDLE) IndicatorRelease(hATR);
  }

void OnTick(void)
  {
   TP_SyncPosition();
   TP_ManagePosition();

   datetime barTime = (datetime)SeriesInfoInteger(_Symbol, PERIOD_H1, SERIES_LASTBAR_DATE);
   if(barTime == 0) return;
   if(barTime == g_lastBarTime) return;
   g_lastBarTime = barTime;
   TP_OnNewBar();
  }
//+------------------------------------------------------------------+
