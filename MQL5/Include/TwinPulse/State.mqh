//+------------------------------------------------------------------+
//|                                                  State.mqh        |
//|  TwinPulse Hedge EA                                                 |
//|  Runtime state of the EA plus rebuild from the open positions.     |
//+------------------------------------------------------------------+
#ifndef TP_STATE_MQH
#define TP_STATE_MQH

#include "Config.mqh"
#include "Utils.mqh"

//--- state of one leg of the current cycle ----------------------------
struct TpLegState
  {
   bool               used;         // leg belongs to the running cycle
   bool               open;         // position is open
   ulong              ticket;       // position ticket
   ulong              positionId;   // POSITION_IDENTIFIER
   ENUM_POSITION_TYPE type;
   double             volume;
   double             openPrice;
   double             sl;
   double             tp;
   double             profit;       // floating profit incl. swap
   datetime           openTime;
   int                generation;   // number of re-opens of this leg
   bool               beDone;       // break-even already applied
   double             peakPrice;    // best price seen, used for the trailing
   double             realized;     // realized money of this leg
   bool               wasOpen;      // previous snapshot, used to detect closes
   datetime           lastModify;   // last stop modification ATTEMPT (success or failure)
   int                modifyFails;  // consecutive failed stop modifications
   datetime           modifyBackoff; // no stop modification before this time
  };

//--- global EA state --------------------------------------------------
struct TpState
  {
   int       cycleId;
   datetime  cycleStart;
   int       cycleRegime;        // regime when the cycle was started
   int       regime;             // current regime
   double    bank;               // realized profit of the cycle not used yet
   double    cycleRealized;      // realized money of the cycle
   double    cycleShredded;      // money spent on shredding losers
   int       closedLegs;         // number of closed legs in this cycle
   int       openedLegs;         // number of opened legs in this cycle
   datetime  lastReopen;
   datetime  lastOpen;
   double    dayStartEquity;
   int       dayStamp;
   bool      dailyLocked;
   bool      basketLocked;
   double    peakEquity;
   double    atr5;               // ATR(14) on M5, price units
   double    atrM15;             // ATR(14) on M15, price units
   double    regimeEr;           // efficiency ratio M15
   double    regimeChop;         // choppiness index M15
   double    regimeAdx;          // ADX(14) M15
   double    regimeSlope;        // EMA50 slope on M15 in ATR units per SlopeBars
   double    regimeBbMid;        // Bollinger middle line M15
   double    regimeAtrMed;       // median of ATR5 over the last 100 bars
   bool      regimeAboveH1;      // price above the EMA50 on H1
   double    medianSpread;       // rolling median spread, price units
   double    spreadSamples[TP_SPREAD_SAMPLES];
   int       spreadCount;
   int       spreadHead;
   datetime  lastSpreadSample;
   datetime  lastM15Bar;
   bool      newsBlock;
   bool      tradeAllowed;       // trading is possible on this account
   string    blockReason;        // why trading is not possible
   TpLegState legs[TP_LEG_COUNT];
  };

//--- execution counters for the tester summary in OnDeinit ------------
struct TpStats
  {
   int       modifyAttempts;  // stop modifications that really sent a request
   int       modifyFailures;  // failed stop modifications
   int       closeAttempts;   // close / partial close / Close By requests sent
   int       closeFailures;   // failed close requests
   int       closeByCount;    // executed Close By nettings
   int       stopThrough;     // legs closed with the exit reason STOP_THROUGH
  };

//--- the single global state object ----------------------------------
TpState g_tp;
TpStats g_stats;

//+------------------------------------------------------------------+
//| TP_State_Init - reset the volatile state                          |
//+------------------------------------------------------------------+
void TP_State_Init(void)
  {
   g_tp.cycleId       = 0;
   g_tp.cycleStart    = 0;
   g_tp.cycleRegime   = TP_REG_NEUTRAL;
   g_tp.regime        = TP_REG_NEUTRAL;
   g_tp.bank          = 0.0;
   g_tp.cycleRealized = 0.0;
   g_tp.cycleShredded = 0.0;
   g_tp.closedLegs    = 0;
   g_tp.openedLegs    = 0;
   g_tp.lastReopen    = 0;
   g_tp.lastOpen      = 0;
   g_tp.dayStartEquity= 0.0;
   g_tp.dayStamp      = 0;
   g_tp.dailyLocked   = false;
   g_tp.basketLocked  = false;
   g_tp.peakEquity    = AccountInfoDouble(ACCOUNT_EQUITY);
   g_tp.atr5          = 0.0;
   g_tp.atrM15        = 0.0;
   g_tp.regimeEr      = 0.0;
   g_tp.regimeChop    = 0.0;
   g_tp.regimeAdx     = 0.0;
   g_tp.regimeSlope   = 0.0;
   g_tp.regimeBbMid   = 0.0;
   g_tp.regimeAtrMed  = 0.0;
   g_tp.regimeAboveH1 = false;
   g_tp.medianSpread  = 0.0;
   g_tp.spreadCount   = 0;
   g_tp.spreadHead    = 0;
   g_tp.lastSpreadSample = 0;
   g_tp.lastM15Bar    = 0;
   g_tp.newsBlock     = false;
   g_tp.tradeAllowed  = true;
   g_tp.blockReason   = "";

   g_stats.modifyAttempts = 0;
   g_stats.modifyFailures = 0;
   g_stats.closeAttempts  = 0;
   g_stats.closeFailures  = 0;
   g_stats.closeByCount   = 0;
   g_stats.stopThrough    = 0;

   for(int i = 0; i < TP_LEG_COUNT; i++)
     {
      g_tp.legs[i].used       = false;
      g_tp.legs[i].open       = false;
      g_tp.legs[i].ticket     = 0;
      g_tp.legs[i].positionId = 0;
      g_tp.legs[i].type       = POSITION_TYPE_BUY;
      g_tp.legs[i].volume     = 0.0;
      g_tp.legs[i].openPrice  = 0.0;
      g_tp.legs[i].sl         = 0.0;
      g_tp.legs[i].tp         = 0.0;
      g_tp.legs[i].profit     = 0.0;
      g_tp.legs[i].openTime   = 0;
      g_tp.legs[i].generation = 0;
      g_tp.legs[i].beDone     = false;
      g_tp.legs[i].peakPrice  = 0.0;
      g_tp.legs[i].realized   = 0.0;
      g_tp.legs[i].wasOpen    = false;
      g_tp.legs[i].lastModify = 0;
      g_tp.legs[i].modifyFails = 0;
      g_tp.legs[i].modifyBackoff = 0;
     }
  }

//+------------------------------------------------------------------+
//| TP_State_GlobalName - build the name of a global variable         |
//+------------------------------------------------------------------+
string TP_State_GlobalName(const string key)
  {
   return StringFormat("%s%s_%s_%d", TP_GV_PREFIX, key, g_symbol, (int)g_magic);
  }

//+------------------------------------------------------------------+
//| TP_State_Save - persist the state that must survive a restart     |
//+------------------------------------------------------------------+
void TP_State_Save(void)
  {
   GlobalVariableSet(TP_State_GlobalName("Cycle"),    (double)g_tp.cycleId);
   GlobalVariableSet(TP_State_GlobalName("CycleStart"),(double)g_tp.cycleStart);
   GlobalVariableSet(TP_State_GlobalName("Bank"),     g_tp.bank);
   GlobalVariableSet(TP_State_GlobalName("Realized"), g_tp.cycleRealized);
   GlobalVariableSet(TP_State_GlobalName("Shredded"), g_tp.cycleShredded);
   GlobalVariableSet(TP_State_GlobalName("Opened"),   (double)g_tp.openedLegs);
   GlobalVariableSet(TP_State_GlobalName("Closed"),   (double)g_tp.closedLegs);
   GlobalVariableSet(TP_State_GlobalName("DayEq"),    g_tp.dayStartEquity);
   GlobalVariableSet(TP_State_GlobalName("DayStamp"), (double)g_tp.dayStamp);
   GlobalVariableSet(TP_State_GlobalName("DayLock"),  g_tp.dailyLocked ? 1.0 : 0.0);
   GlobalVariableSet(TP_State_GlobalName("Basket"),   g_tp.basketLocked ? 1.0 : 0.0);
  }

//+------------------------------------------------------------------+
//| TP_State_Load - restore the persisted state                       |
//+------------------------------------------------------------------+
void TP_State_Load(void)
  {
   string k = TP_State_GlobalName("Cycle");
   if(GlobalVariableCheck(k))
      g_tp.cycleId = (int)GlobalVariableGet(k);

   k = TP_State_GlobalName("CycleStart");
   if(GlobalVariableCheck(k))
      g_tp.cycleStart = (datetime)GlobalVariableGet(k);

   k = TP_State_GlobalName("Bank");
   if(GlobalVariableCheck(k))
      g_tp.bank = GlobalVariableGet(k);

   k = TP_State_GlobalName("Realized");
   if(GlobalVariableCheck(k))
      g_tp.cycleRealized = GlobalVariableGet(k);

   k = TP_State_GlobalName("Shredded");
   if(GlobalVariableCheck(k))
      g_tp.cycleShredded = GlobalVariableGet(k);

   k = TP_State_GlobalName("Opened");
   if(GlobalVariableCheck(k))
      g_tp.openedLegs = (int)GlobalVariableGet(k);

   k = TP_State_GlobalName("Closed");
   if(GlobalVariableCheck(k))
      g_tp.closedLegs = (int)GlobalVariableGet(k);

   k = TP_State_GlobalName("DayEq");
   if(GlobalVariableCheck(k))
      g_tp.dayStartEquity = GlobalVariableGet(k);

   k = TP_State_GlobalName("DayStamp");
   if(GlobalVariableCheck(k))
      g_tp.dayStamp = (int)GlobalVariableGet(k);

   k = TP_State_GlobalName("DayLock");
   if(GlobalVariableCheck(k))
      g_tp.dailyLocked = (GlobalVariableGet(k) > 0.5);

   k = TP_State_GlobalName("Basket");
   if(GlobalVariableCheck(k))
      g_tp.basketLocked = (GlobalVariableGet(k) > 0.5);
  }

//+------------------------------------------------------------------+
//| TP_State_SyncPositions - rebuild the leg map from the open         |
//| positions of our symbol and magic. The comment carries the cycle   |
//| id and the leg name, so the state survives a terminal restart.    |
//+------------------------------------------------------------------+
void TP_State_SyncPositions(void)
  {
   for(int i = 0; i < TP_LEG_COUNT; i++)
     {
      // the ticket, the position id, the volume and the open time are
      // kept so that a closed leg can still be logged
      g_tp.legs[i].open       = false;
      g_tp.legs[i].profit     = 0.0;
     }

   int total = PositionsTotal();
   for(int p = 0; p < total; p++)
     {
      ulong ticket = PositionGetTicket(p);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != g_symbol) continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != g_magic) continue;

      int cycleId = -1;
      int legIdx  = -1;
      if(!TP_ParseComment(PositionGetString(POSITION_COMMENT), cycleId, legIdx)) continue;
      if(legIdx < 0 || legIdx >= TP_LEG_COUNT) continue;

      g_tp.legs[legIdx].open       = true;
      g_tp.legs[legIdx].ticket     = ticket;
      g_tp.legs[legIdx].positionId = (ulong)PositionGetInteger(POSITION_IDENTIFIER);
      g_tp.legs[legIdx].type       = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      g_tp.legs[legIdx].volume     = PositionGetDouble(POSITION_VOLUME);
      g_tp.legs[legIdx].openPrice  = PositionGetDouble(POSITION_PRICE_OPEN);
      g_tp.legs[legIdx].sl         = PositionGetDouble(POSITION_SL);
      g_tp.legs[legIdx].tp         = PositionGetDouble(POSITION_TP);
      g_tp.legs[legIdx].profit     = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      g_tp.legs[legIdx].openTime   = (datetime)PositionGetInteger(POSITION_TIME);
      g_tp.legs[legIdx].used       = true;
      if(cycleId > 0 && cycleId > g_tp.cycleId) g_tp.cycleId = cycleId;
     }
  }

//+------------------------------------------------------------------+
//| TP_State_CountOpenLegs - number of open legs of one side          |
//+------------------------------------------------------------------+
int TP_State_CountOpenLegs(const int side)
  {
   int n = 0;
   for(int i = 0; i < TP_LEG_COUNT; i++)
     {
      if(!g_tp.legs[i].open) continue;
      bool isBuy = TP_LegIsBuy(i);
      if((side == TP_SIDE_BUY && isBuy) || (side == TP_SIDE_SELL && !isBuy)) n++;
     }
   return n;
  }

//+------------------------------------------------------------------+
//| TP_State_OpenVolume - total open volume of one side                |
//+------------------------------------------------------------------+
double TP_State_OpenVolume(const int side)
  {
   double v = 0.0;
   for(int i = 0; i < TP_LEG_COUNT; i++)
     {
      if(!g_tp.legs[i].open) continue;
      bool isBuy = TP_LegIsBuy(i);
      if((side == TP_SIDE_BUY && isBuy) || (side == TP_SIDE_SELL && !isBuy)) v += g_tp.legs[i].volume;
     }
   return v;
  }

//+------------------------------------------------------------------+
//| TP_State_SideFloating - floating P/L of one side                  |
//+------------------------------------------------------------------+
double TP_State_SideFloating(const int side)
  {
   double p = 0.0;
   for(int i = 0; i < TP_LEG_COUNT; i++)
     {
      if(!g_tp.legs[i].open) continue;
      bool isBuy = TP_LegIsBuy(i);
      if((side == TP_SIDE_BUY && isBuy) || (side == TP_SIDE_SELL && !isBuy)) p += g_tp.legs[i].profit;
     }
   return p;
  }

//+------------------------------------------------------------------+
//| TP_State_AllFloating - floating P/L of every open leg             |
//+------------------------------------------------------------------+
double TP_State_AllFloating(void)
  {
   double p = 0.0;
   for(int i = 0; i < TP_LEG_COUNT; i++)
      if(g_tp.legs[i].open) p += g_tp.legs[i].profit;
   return p;
  }

//+------------------------------------------------------------------+
//| TP_State_OpenLegCount - number of open legs in total              |
//+------------------------------------------------------------------+
int TP_State_OpenLegCount(void)
  {
   int n = 0;
   for(int i = 0; i < TP_LEG_COUNT; i++) if(g_tp.legs[i].open) n++;
   return n;
  }

//+------------------------------------------------------------------+
//| TP_State_TotalVolume - all open lots of this EA                   |
//+------------------------------------------------------------------+
double TP_State_TotalVolume(void)
  {
   double v = 0.0;
   for(int i = 0; i < TP_LEG_COUNT; i++) if(g_tp.legs[i].open) v += g_tp.legs[i].volume;
   return v;
  }

//+------------------------------------------------------------------+
//| TP_State_CycleTotal - realized + floating money of the cycle      |
//+------------------------------------------------------------------+
double TP_State_CycleTotal(void)
  {
   return g_tp.cycleRealized + TP_State_AllFloating();
  }

//+------------------------------------------------------------------+
//| TP_State_RealizedForPosition - money realised when a position was  |
//| closed. Sums profit, commission and swap of the exit deals.       |
//+------------------------------------------------------------------+
double TP_State_RealizedForPosition(const ulong positionId, const datetime fromTime, double &closePrice)
  {
   closePrice = 0.0;
   if(positionId == 0) return 0.0;

   datetime to = TimeCurrent() + 60;
   datetime from = fromTime - 1;
   if(from < 60) from = TimeCurrent() - 3600;

   double sum = 0.0;
   bool found = false;

   //--- the history can lag a tick behind a fresh order, retry a few times
   for(int attempt = 0; attempt < 3; attempt++)
     {
      if(attempt > 0) Sleep(30);
      if(!HistorySelect(from, to)) continue;

      sum = 0.0;
      closePrice = 0.0;
      found = false;
      int deals = HistoryDealsTotal();
      for(int i = 0; i < deals; i++)
        {
         ulong deal = HistoryDealGetTicket(i);
         if(deal == 0) continue;
         if((ulong)HistoryDealGetInteger(deal, DEAL_POSITION_ID) != positionId) continue;
         int entry = (int)HistoryDealGetInteger(deal, DEAL_ENTRY);
         if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_OUT_BY) continue;
         sum  += HistoryDealGetDouble(deal, DEAL_PROFIT);
         sum  += HistoryDealGetDouble(deal, DEAL_COMMISSION);
         sum  += HistoryDealGetDouble(deal, DEAL_SWAP);
         closePrice = HistoryDealGetDouble(deal, DEAL_PRICE);
         found = true;
        }
      if(found) break;
     }

   return sum;
  }

#endif // TP_STATE_MQH
