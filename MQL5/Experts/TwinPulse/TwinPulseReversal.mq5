//+------------------------------------------------------------------+
//|                                          TwinPulseReversal.mq5   |
//|  The owner's rule, tested exactly as he described it:             |
//|                                                                   |
//|    open BUY and SELL together, close the one that is in profit,    |
//|    then wait for the other one to come back to break-even and      |
//|    close it too. Optionally lock profit in thirds at 30/60/90%.    |
//|                                                                   |
//|  This EA exists to MEASURE that rule, not to endorse it. The       |
//|  structural problem is stated in docs/REVERSAL_TEST.md: once the   |
//|  winner is closed the account is no longer hedged - it holds a     |
//|  naked position from the original entry, already at -X.            |
//|                                                                   |
//|  GuardATR is the only thing standing between that and ruin, so it  |
//|  defaults to a real number, never to "off". Setting it to 0 is     |
//|  allowed and will be run as an explicit control.                   |
//+------------------------------------------------------------------+
#property copyright "TwinPulse"
#property version   "1.00"

#include <Trade\Trade.mqh>

//--- identity
input long   InpMagic          = 26101703;  // Magic
input string InpComment        = "TPR";     // Comment

//--- sizing
input double InpLots           = 0.01;      // Lots PER SIDE (buy and sell get the same)
input double InpMaxLots        = 1.00;      // Hard ceiling per side

//--- the rule
input double InpTarget_ATR     = 3.00;      // Close the winner at +X ATR (0 = off)
input double InpTargetPoints   = 0.00;      // ...or a fixed distance in price units
input bool   InpLockLadder     = false;     // Lock in thirds at 30/60/90% of the target
input double InpGuard_ATR      = 15.00;     // Cut the orphan at -L ATR (0 = hold forever)
input int    InpATRPeriod      = 14;        // ATR period (H1)

//--- optional stop on the winner (a losing cycle has no winner)
input double InpWinnerStop_ATR = 0.00;      // Cut BOTH if neither ever profits, x ATR (0 = off)

//--- protection
input double InpMaxSpread      = 0.60;      // Max spread at entry
input double InpMaxDrawdownPct = 25.00;     // Halt the EA at this drawdown
input int    InpMaxHoldHours   = 0;         // Force-close the cycle after N hours (0 = off)

//--- logging
input bool   InpWriteCsv       = true;
input bool   InpVerboseLog     = true;

CTrade trade;
int    hATR = INVALID_HANDLE;

//--- state
int    g_phase = 0;          // 0 = flat, 1 = two legs open, 2 = orphan only
int    g_cycle = 0;
double g_atr   = 0.0;

double g_buyEntry = 0.0, g_sellEntry = 0.0;
double g_buyVol   = 0.0, g_sellVol   = 0.0;
double g_buyLeft  = 0.0, g_sellLeft  = 0.0;
ulong  g_buyTicket = 0, g_sellTicket = 0;
int    g_buyStage = 0,  g_sellStage = 0;
double g_target    = 0.0;
double g_guard     = 0.0;
datetime g_cycleStart = 0;
double g_peakEquity = 0.0;
bool   g_halted = false;

int    g_csv = INVALID_HANDLE;
int    g_log = INVALID_HANDLE;

//+------------------------------------------------------------------+
double TP_Ask(void) { return SymbolInfoDouble(_Symbol, SYMBOL_ASK); }
double TP_Bid(void) { return SymbolInfoDouble(_Symbol, SYMBOL_BID); }
double TP_Spread(void)
  {
   double a = TP_Ask(), b = TP_Bid();
   if(a <= 0.0 || b <= 0.0) return 0.0;
   return (a - b);
  }
double TP_Point(void)
  {
   double p = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   if(p <= 0.0) p = 0.01;
   return p;
  }
int TP_Digits(void) { return (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS); }

double TP_NormPrice(double price) { return NormalizeDouble(price, TP_Digits()); }

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

//+------------------------------------------------------------------+

void TP_Log(string msg)
  {
   if(!InpVerboseLog || g_log == INVALID_HANDLE) return;
   FileWrite(g_log, TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS), msg);
   FileFlush(g_log);
  }

void TP_CsvHeader(void)
  {
   if(!InpWriteCsv || g_csv == INVALID_HANDLE) return;
   FileWrite(g_csv, "time", "cycle", "leg", "side", "volume", "open_price",
             "close_price", "reason", "profit", "pos_net", "bank", "regime",
             "spread", "atr5", "spread_open", "spread_cost", "gross", "stop_dist");
  }

void TP_CsvRow(string leg, string side, double vol, double openPx, double closePx,
               string reason, double profit, double swap, double comm)
  {
   if(!InpWriteCsv || g_csv == INVALID_HANDLE) return;
   FileWrite(g_csv,
             TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS),
             IntegerToString(g_cycle),
             leg,
             side,
             DoubleToString(vol, 2),
             DoubleToString(openPx, TP_Digits()),
             DoubleToString(closePx, TP_Digits()),
             reason,
             DoubleToString(profit, 2),
             DoubleToString(profit + swap + comm, 2),
             "0",
             "",
             DoubleToString(TP_Spread(), 3),
             DoubleToString(g_atr, 3),
             DoubleToString(TP_Spread(), 3),
             "0",
             DoubleToString(profit, 2),
             DoubleToString(g_guard, 3));
   FileFlush(g_csv);
  }

//+------------------------------------------------------------------+
double TP_ReadATR(void)
  {
   double b[3];
   if(CopyBuffer(hATR, 0, 0, 3, b) < 3) return 0.0;
   return b[1];
  }

bool TP_Halted(void)
  {
   if(g_halted) return true;
   if(InpMaxDrawdownPct <= 0.0) return false;
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   if(eq > g_peakEquity) g_peakEquity = eq;
   if(g_peakEquity <= 0.0) return false;
   if(eq <= g_peakEquity * (1.0 - InpMaxDrawdownPct / 100.0))
     {
      g_halted = true;
      TP_Log("MAX DRAWDOWN - halted");
      return true;
     }
   return false;
  }

//+------------------------------------------------------------------+
//| open the pair                                                    |
//+------------------------------------------------------------------+
bool TP_OpenPair(void)
  {
   if(TP_Halted()) return false;

   double spread = TP_Spread();
   if(InpMaxSpread > 0.0 && spread > InpMaxSpread) return false;

   double atr = TP_ReadATR();
   if(atr <= 0.0) return false;

   double lots = TP_NormLots(InpLots);

   //margin: two positions at once
   double marginOne = 0.0;
   if(OrderCalcMargin(ORDER_TYPE_BUY, _Symbol, lots, TP_Ask(), marginOne))
     {
      if(marginOne * 2.0 > AccountInfoDouble(ACCOUNT_MARGIN_FREE) * 0.60)
        {
         TP_Log("not enough free margin for the pair");
         return false;
        }
     }

   g_cycle++;
   string tag = StringFormat("%s|%d", InpComment, g_cycle);

   double ask = TP_Ask(), bid = TP_Bid();

   if(!trade.Buy(lots, _Symbol, ask, 0.0, 0.0, tag + "|B"))
     {
      TP_Log(StringFormat("buy failed rc=%d", trade.ResultRetcode()));
      return false;
     }
   double buyFill = trade.ResultPrice();
   if(buyFill <= 0.0) buyFill = ask;

   if(!trade.Sell(lots, _Symbol, bid, 0.0, 0.0, tag + "|S"))
     {
      TP_Log(StringFormat("sell failed rc=%d - closing the buy back", trade.ResultRetcode()));
      //never leave a single naked leg by accident
      for(int i = 0; i < PositionsTotal(); i++)
        {
         ulong t = PositionGetTicket(i);
         if(t == 0) continue;
         if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
         if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
         trade.PositionClose(t);
        }
      return false;
     }
   double sellFill = trade.ResultPrice();
   if(sellFill <= 0.0) sellFill = bid;

   g_buyEntry = buyFill;   g_sellEntry = sellFill;
   g_buyVol   = lots;      g_sellVol   = lots;
   g_buyLeft  = lots;      g_sellLeft  = lots;
   g_buyStage = 0;         g_sellStage = 0;
   g_buyTicket = 0;        g_sellTicket = 0;
   g_atr      = atr;
   g_target   = InpTarget_ATR * atr;
   if(InpTargetPoints > 0.0) g_target = InpTargetPoints;
   if(g_target <= 0.0) g_target = 2.0 * atr;

   g_guard = 0.0;
   if(InpGuard_ATR > 0.0) g_guard = InpGuard_ATR * atr;

   g_cycleStart = TimeCurrent();
   g_phase = 1;

   TP_Log(StringFormat("cycle %d OPEN pair lots=%.2f buy=%.3f sell=%.3f atr=%.2f target=%.2f guard=%.2f spread=%.3f",
                       g_cycle, lots, buyFill, sellFill, atr, g_target, g_guard, spread));
   return true;
  }

//+------------------------------------------------------------------+
ulong TP_FindTicket(string want)
  {
   for(int i = 0; i < PositionsTotal(); i++)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      long type = PositionGetInteger(POSITION_TYPE);
      bool isBuy = (type == POSITION_TYPE_BUY);
      if(want == "B" && isBuy)  return t;
      if(want == "S" && !isBuy) return t;
     }
   return 0;
  }

double TP_PosProfit(ulong ticket)
  {
   if(ticket == 0) return 0.0;
   if(!PositionSelectByTicket(ticket)) return 0.0;
   return PositionGetDouble(POSITION_PROFIT) +
          PositionGetDouble(POSITION_SWAP);
  }

double TP_PosVolume(ulong ticket)
  {
   if(ticket == 0) return 0.0;
   if(!PositionSelectByTicket(ticket)) return 0.0;
   return PositionGetDouble(POSITION_VOLUME);
  }

//+------------------------------------------------------------------+
//| close a side, fully or one third of the original volume          |
//+------------------------------------------------------------------+
bool TP_ClosePart(ulong ticket, double volume, string leg, string side,
                  double entry, string reason)
  {
   if(ticket == 0) return false;
   if(!PositionSelectByTicket(ticket)) return false;

   double have = PositionGetDouble(POSITION_VOLUME);
   double px   = PositionGetDouble(POSITION_PRICE_CURRENT);
   double prof = PositionGetDouble(POSITION_PROFIT);
   double swap = PositionGetDouble(POSITION_SWAP);
   double comm = 0.0;

   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double step   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(step <= 0.0) step = 0.01;

   double send = volume;
   //a ladder step of a 0.01 lot is 0.0033 - below the broker minimum, so
   //PositionClosePartial would fail and the step would silently never run.
   //Close the WHOLE leg instead and say so, never fail quietly.
   if(send < minLot - 0.0000001)
     {
      TP_Log(StringFormat("ladder step %.4f < broker min %.2f - closing the whole leg %s",
                          send, minLot, leg));
      send = have;
     }
   if(send >= have - 0.0000001) send = have;

   bool ok = false;
   if(send >= have - 0.0000001)
      ok = trade.PositionClose(ticket);
   else
      ok = trade.PositionClosePartial(ticket, send);

   if(!ok)
     {
      TP_Log(StringFormat("close %s failed rc=%d", leg, trade.ResultRetcode()));
      return false;
     }

   //the realised part is proportional to the volume that left
   double frac = send / have;
   TP_CsvRow(leg, side, send, entry, px, reason, prof * frac, swap * frac, comm);
   TP_Log(StringFormat("CLOSE %s %s %.2f of %.2f at %.3f reason=%s net~%.2f",
                       leg, side, send, have, px, reason, (prof + swap) * frac));
   return true;
  }

//+------------------------------------------------------------------+
//| TRADE SESSION                                                    |
//|                                                                  |
//| The tester keeps generating ticks while the symbol's trade       |
//| session is closed, so every order this EA sends is rejected with  |
//| MARKET_CLOSED (10018) and the log fills with retries.             |
//|                                                                  |
//| This only decides whether to SEND anything. A rejected order had  |
//| no effect, so skipping it leaves the book exactly where it was    |
//| and the same rule is evaluated again on the first tick after the  |
//| session opens. No entry or exit rule is changed.                  |
//+------------------------------------------------------------------+
#define TP_MAX_SESSIONS 8

bool     g_sessLoaded       = false;
bool     g_sessValid        = false;
datetime g_sessFrom[7][TP_MAX_SESSIONS];
datetime g_sessTo[7][TP_MAX_SESSIONS];
int      g_sessCount[7];
bool     g_sessClosedLogged = false;
int      g_sessSuppressed   = 0;

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
   if(!g_sessValid) return true;          // no schedule -> never block

   int secs = TP_SecOfDay(t);
   MqlDateTime d;
   TimeToStruct(t, d);
   int dow = d.day_of_week;

   for(int i = 0; i < g_sessCount[dow]; i++)
     {
      int f = TP_SecOfDay(g_sessFrom[dow][i]);
      int e = TP_SecOfDay(g_sessTo[dow][i]);
      if(e == 0) e = 86400;               // "to 00:00" means end of day
      if(f <= e)
        {
         if(secs >= f && secs < e) return true;
        }
      else
        {
         if(secs >= f) return true;       // session wraps into tomorrow
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

void TP_SessionLogOnce(void)
  {
   if(g_sessClosedLogged) return;
   g_sessClosedLogged = true;
   datetime next = TP_NextSessionOpen(TimeCurrent());
   if(next <= TimeCurrent()) next = TimeCurrent() + 300;
   TP_Log(StringFormat("trade session closed - EA idle until %s (logged once per closure)",
                       TimeToString(next, TIME_DATE | TIME_MINUTES)));
  }

//+------------------------------------------------------------------+
//| the rule                                                         |
//+------------------------------------------------------------------+
void TP_RunRule(void)
  {
   //--- nothing can execute while the market is shut; the tester keeps
   //--- ticking, so sending here only produces rejected orders
   if(!TP_MarketOpen())
     {
      g_sessSuppressed++;
      TP_SessionLogOnce();
      return;
     }
   g_sessClosedLogged = false;

   if(g_phase == 0)
     {
      if(PositionsTotal() == 0) { TP_OpenPair(); return; }
      //adopt whatever is there after a restart
      g_phase = 1;
     }

   if(TP_Halted()) return;

   //max hold
   if(InpMaxHoldHours > 0 && g_cycleStart > 0)
     {
      if((TimeCurrent() - g_cycleStart) >= (long)InpMaxHoldHours * 3600)
        {
         for(int i = 0; i < PositionsTotal(); i++)
           {
            ulong t = PositionGetTicket(i);
            if(t == 0) continue;
            if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
            if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
            trade.PositionClose(t);
           }
         g_phase = 0;
         return;
        }
     }

   ulong tb = TP_FindTicket("B");
   ulong ts = TP_FindTicket("S");

   int open = 0;
   if(tb != 0) open++;
   if(ts != 0) open++;

   if(open == 0)
     {
      g_phase = 0;
      return;
     }

   double pb = TP_PosProfit(tb);
   double ps = TP_PosProfit(ts);

   //--- the winner takes its target (optionally in three locked steps) --
   if(tb != 0)
     {
      if(InpLockLadder)
        {
         if(g_buyStage == 0 && pb >= g_target * 0.30)
           {
            if(TP_ClosePart(tb, g_buyVol / 3.0, "BUY", "long", g_buyEntry, "lock30"))
               g_buyStage = 1;
           }
         else if(g_buyStage == 1 && pb >= g_target * 0.60)
           {
            if(TP_ClosePart(tb, g_buyVol / 3.0, "BUY", "long", g_buyEntry, "lock60"))
               g_buyStage = 2;
           }
         else if(g_buyStage == 2 && pb >= g_target)
           {
            if(TP_ClosePart(tb, 1e9, "BUY", "long", g_buyEntry, "target"))
               g_buyStage = 3;
           }
        }
      else if(g_buyStage == 0 && pb >= g_target)
        {
         if(TP_ClosePart(tb, 1e9, "BUY", "long", g_buyEntry, "target"))
            g_buyStage = 3;
        }
     }

   if(ts != 0)
     {
      if(InpLockLadder)
        {
         if(g_sellStage == 0 && ps >= g_target * 0.30)
           {
            if(TP_ClosePart(ts, g_sellVol / 3.0, "SELL", "short", g_sellEntry, "lock30"))
               g_sellStage = 1;
           }
         else if(g_sellStage == 1 && ps >= g_target * 0.60)
           {
            if(TP_ClosePart(ts, g_sellVol / 3.0, "SELL", "short", g_sellEntry, "lock60"))
               g_sellStage = 2;
           }
         else if(g_sellStage == 2 && ps >= g_target)
           {
            if(TP_ClosePart(ts, 1e9, "SELL", "short", g_sellEntry, "target"))
               g_sellStage = 3;
           }
        }
      else if(g_sellStage == 0 && ps >= g_target)
        {
         if(TP_ClosePart(ts, 1e9, "SELL", "short", g_sellEntry, "target"))
            g_sellStage = 3;
        }
     }

   //--- the orphan: wait for break-even, or take the guard ----------
   tb = TP_FindTicket("B");
   ts = TP_FindTicket("S");
   if(tb == 0 || ts == 0)
     {
      ulong orphan = tb;
      string oleg  = "BUY";
      string oside = "long";
      double oent  = g_buyEntry;
      if(orphan == 0) { orphan = ts; oleg = "SELL"; oside = "short"; oent = g_sellEntry; }
      if(orphan == 0) { g_phase = 0; return; }

      double po = TP_PosProfit(orphan);

      if(po >= 0.0)
        {
         TP_ClosePart(orphan, 1e9, oleg, oside, oent, "breakeven");
         tb = TP_FindTicket("B"); ts = TP_FindTicket("S");
         if(tb == 0 && ts == 0) { g_phase = 0; TP_Log("cycle flat"); }
         return;
        }

      if(g_guard > 0.0 && po <= -g_guard)
        {
         TP_ClosePart(orphan, 1e9, oleg, oside, oent, "guard");
         tb = TP_FindTicket("B"); ts = TP_FindTicket("S");
         if(tb == 0 && ts == 0) { g_phase = 0; TP_Log("cycle flat"); }
         return;
        }
      g_phase = 2;
      return;
     }

   //--- both still open: no winner yet ------------------------------
   g_phase = 1;
   if(InpWinnerStop_ATR > 0.0 && g_atr > 0.0)
     {
      double lim = InpWinnerStop_ATR * g_atr;
      if(pb <= -lim && ps <= -lim)
        {
         TP_ClosePart(tb, 1e9, "BUY",  "long",  g_buyEntry,  "no_winner");
         TP_ClosePart(ts, 1e9, "SELL", "short", g_sellEntry, "no_winner");
         g_phase = 0;
        }
     }
  }


//+------------------------------------------------------------------+
int OnInit(void)
  {
   hATR = iATR(_Symbol, PERIOD_H1, InpATRPeriod);
   if(hATR == INVALID_HANDLE) { Print("ATR handle failed"); return INIT_FAILED; }

   trade.SetExpertMagicNumber((ulong)InpMagic);
   trade.SetDeviationInPoints(50);
   trade.SetTypeFillingBySymbol(_Symbol);
   trade.SetAsyncMode(false);

   TP_LoadSessions();
   g_peakEquity = AccountInfoDouble(ACCOUNT_EQUITY);

   if(InpWriteCsv)
     {
      g_csv = FileOpen("TwinPulse_legs.csv",
                       FILE_WRITE | FILE_CSV | FILE_ANSI | FILE_COMMON, ',', CP_ACP);
      if(g_csv != INVALID_HANDLE) TP_CsvHeader();
     }
   if(InpVerboseLog)
      g_log = FileOpen("TwinPulse_reversal.log",
                       FILE_WRITE | FILE_CSV | FILE_ANSI | FILE_COMMON, ',', CP_ACP);

   TP_Log(StringFormat("TPR 1.00 start %s lots=%.2f target=%.1fATR guard=%.1fATR ladder=%d",
                       _Symbol, InpLots, InpTarget_ATR, InpGuard_ATR, (int)InpLockLadder));
   return INIT_SUCCEEDED;
  }

void TP_CloseAllAtEnd(void)
  {
   int closed = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;

      double vol  = PositionGetDouble(POSITION_VOLUME);
      double px   = PositionGetDouble(POSITION_PRICE_CURRENT);
      double prof = PositionGetDouble(POSITION_PROFIT);
      double swp  = PositionGetDouble(POSITION_SWAP);
      double ent  = PositionGetDouble(POSITION_PRICE_OPEN);
      bool   isBuy = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);

      if(!trade.PositionClose(t)) continue;
      closed++;

      string leg = "SELL";
      string side = "short";
      if(isBuy) { leg = "BUY"; side = "long"; }
      TP_CsvRow(leg, side, vol, ent, px, "end_of_test", prof, swp, 0.0);
     }

   if(closed > 0)
      TP_Log(StringFormat("END OF TEST: closed %d position(s) that were still open", closed));
   if(g_sessSuppressed > 0)
      TP_Log(StringFormat("END OF TEST: %d rule cycle(s) were skipped while the session was closed",
                          g_sessSuppressed));
   g_phase = 0;
  }

void OnDeinit(const int reason)
  {
   if(MQLInfoInteger(MQL_TESTER)) TP_CloseAllAtEnd();
   if(g_csv != INVALID_HANDLE) { FileClose(g_csv); g_csv = INVALID_HANDLE; }
   if(g_log != INVALID_HANDLE) { FileClose(g_log); g_log = INVALID_HANDLE; }
   if(hATR != INVALID_HANDLE) IndicatorRelease(hATR);
  }

void OnTick(void)
  {
   TP_RunRule();
  }
//+------------------------------------------------------------------+
