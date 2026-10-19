//+------------------------------------------------------------------+
//|                                                 TwinPulse.mq5     |
//|                                                                  |
//|  TwinPulse Hedge EA  v1.00                                       |
//|  Exness MT5, XAUUSDm, HEDGING account                            |
//|                                                                  |
//|  A cycle holds 2 BUY + 2 SELL legs. The winning side is closed   |
//|  with a small profit, the losing side keeps running until it is   |
//|  back at break even, then the closed side is re-opened so the     |
//|  hedge is balanced again.                                        |
//|                                                                  |
//|  All decisions live in the headers of MQL5\Include\TwinPulse.     |
//+------------------------------------------------------------------+
#property copyright "TwinPulse Hedge EA"
#property version   "1.00"
#property description "TwinPulse Hedge EA - 2 BUY + 2 SELL hedge cycle for XAUUSDm on a hedging account."
#property description "Full / PureIdea / OneSide research modes, regime filter, profit bank, hard brakes."

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
#include <TwinPulse/Panel.mqh>

//--- bar trackers -----------------------------------------------------
datetime g_lastM5Bar  = 0;
datetime g_lastM15Bar = 0;
datetime g_lastSyncSec = 0;
bool     g_initialised = false;

//+------------------------------------------------------------------+
//| OnInit - validate the environment and build the runtime state      |
//+------------------------------------------------------------------+
int OnInit()
  {
   g_symbol = _Symbol;
   g_magic  = Magic;
   g_legsPerSide = LegsPerSide;

   if(!SymbolSelect(g_symbol, true))
     {
      Print("TwinPulse: cannot select ", g_symbol);
      return INIT_FAILED;
     }

   g_point  = SymbolInfoDouble(g_symbol, SYMBOL_POINT);
   g_digits = (int)SymbolInfoInteger(g_symbol, SYMBOL_DIGITS);
   if(g_point <= 0.0 || g_digits <= 0)
     {
      Print("TwinPulse: invalid symbol properties for ", g_symbol);
      return INIT_FAILED;
     }

   //--- the martingale escalation needs an explicit confirmation -----
   if(LotMultiplier > 1.0 && !IUnderstandMartingaleRisk)
     {
      Print("TwinPulse: LotMultiplier > 1.0 needs IUnderstandMartingaleRisk = true, the multiplier is reset to 1.0.");
      }

   if(g_legsPerSide < 1) g_legsPerSide = 1;
   if(g_legsPerSide > 2) g_legsPerSide = 2;

   //--- deterministic RANDOM entry (EntryMode = 1) --------------------
   int seed = RandomSeed;
   if(seed < 1) seed = 1;
   MathSrand(seed);

   //--- trade objects -------------------------------------------------
   g_trade.SetExpertMagicNumber((ulong)g_magic);
   g_trade.SetDeviationInPoints(DeviationPoints);
   g_trade.SetTypeFillingBySymbol(g_symbol);
   g_trade.SetAsyncMode(false);

   //--- one open file handle per log file (closed in OnDeinit) ---------
   TP_LogFilesOpen();

   //--- state ---------------------------------------------------------
   TP_State_Init();
   TP_State_Load();

   //--- the environment checks decide if we may trade -----------------
   g_tp.tradeAllowed = true;
   g_tp.blockReason  = "";

   long marginMode = AccountInfoInteger(ACCOUNT_MARGIN_MODE);
   if(marginMode != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
     {
      g_tp.tradeAllowed = false;
      g_tp.blockReason  = "This is not a hedging account (ACCOUNT_MARGIN_MODE), the EA does not trade.";
     }

   if(AccountInfoInteger(ACCOUNT_TRADE_MODE) == ACCOUNT_TRADE_MODE_REAL && !AllowLive)
     {
      g_tp.tradeAllowed = false;
      g_tp.blockReason  = "Real account and AllowLive = false, the EA does not trade.";
     }

   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
     {
      g_tp.tradeAllowed = false;
      g_tp.blockReason  = "Algo Trading is disabled in the terminal.";
     }

   if(!AccountInfoInteger(ACCOUNT_TRADE_ALLOWED))
     {
      g_tp.tradeAllowed = false;
      g_tp.blockReason  = "Trading is not allowed for this account.";
     }

   if(!AccountInfoInteger(ACCOUNT_TRADE_EXPERT))
     {
      g_tp.tradeAllowed = false;
      g_tp.blockReason  = "Trading with expert advisors is not allowed for this account.";
     }

   int tradeMode = (int)SymbolInfoInteger(g_symbol, SYMBOL_TRADE_MODE);
   if(tradeMode == SYMBOL_TRADE_MODE_DISABLED || tradeMode == SYMBOL_TRADE_MODE_CLOSEONLY)
     {
      g_tp.tradeAllowed = false;
      g_tp.blockReason  = StringFormat("%s is not open for trading (SYMBOL_TRADE_MODE = %d).", g_symbol, tradeMode);
     }

   //--- indicators ----------------------------------------------------
   if(!TP_Regime_Init())
      return INIT_FAILED;

   //--- news ----------------------------------------------------------
   TP_News_Init();

   //--- spread statistics ---------------------------------------------
   TP_Risk_InitSpreadSamples();

   //--- rebuild the state from the open positions ---------------------
   TP_State_SyncPositions();
   for(int i = 0; i < TP_LEG_COUNT; i++)
      g_tp.legs[i].wasOpen = g_tp.legs[i].open;

   if(TP_State_OpenLegCount() > 0)
     {
      TP_LogInfo(StringFormat("Restart: %d open legs found, cycle %d.",
                              TP_State_OpenLegCount(), g_tp.cycleId));
      TP_State_Save();
     }

   //--- panel and timer ------------------------------------------------
   TP_Panel_Init();
   TP_Panel_Update();

   if(!EventSetTimer(TimerSeconds))
     {
      TP_LogError("EventSetTimer failed, the EA will not manage the cycle.");
      return INIT_FAILED;
     }

   g_lastM5Bar  = iTime(g_symbol, PERIOD_M5, 0);
   g_lastM15Bar = iTime(g_symbol, PERIOD_M15, 0);
   TP_Regime_Update();

   TP_LogInfo(StringFormat("%s %s started on %s, magic %d, mode %d, lot %.2f, %s",
                           TP_NAME, TP_VER, g_symbol, (int)g_magic, (int)Mode,
                           BaseLot, g_tp.tradeAllowed ? "trading enabled" : g_tp.blockReason));

   g_initialised = true;
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
//| OnDeinit - clean up and print the execution summary               |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   EventKillTimer();
   TP_State_Save();
   TP_Regime_Release();
   TP_Panel_Release();
   TP_LogInfo(StringFormat("TwinPulse stopped, reason %d.", reason));

   //--- execution counters: the smoke test proof for the stop / close -
   //--- fixes. Print() so the lines land in the tester journal.       --
   //--- "log lines written" counts TwinPulse.log lines exactly (the   --
   //--- file can hold less after a 2 MB rotation), "csv rows" the     --
   //--- legs / cycles CSV rows. "gross before spread" / "spread paid" --
   //--- come from pos_net (the full realised P/L of each position).   --
   string execSummary = StringFormat(
      "exec summary: modify attempts %d, modify failures %d, closes %d, close failures %d, Close By %d, STOP_THROUGH %d, log lines written %d, csv rows written %d, duplicates suppressed %d, gross before spread %.2f, spread paid %.2f",
      g_stats.modifyAttempts, g_stats.modifyFailures,
      g_stats.closeAttempts, g_stats.closeFailures,
      g_stats.closeByCount, g_stats.stopThrough,
      (int)g_logLinesWritten, (int)g_csvRowsWritten, (int)g_logDupSuppressed,
      g_stats.grossBeforeSpread, g_stats.spreadPaid);
   Print("TwinPulse | ", execSummary);
   TP_LogInfo(execSummary);

   //--- flush and close every log file handle -------------------------
   TP_LogFilesClose();
  }

//+------------------------------------------------------------------+
//| OnTick - fast path: exits, trailing, brakes                        |
//+------------------------------------------------------------------+
void OnTick()
  {
   if(!g_initialised) return;
   if(!g_tp.tradeAllowed) return;

   //--- the position scan is throttled to one second, the timer does a
   //    full synchronisation every second anyway -----------------------
   if(TimeCurrent() != g_lastSyncSec)
     {
      g_lastSyncSec = TimeCurrent();
      TP_State_SyncPositions();
     }
   TP_Legs_DetectClosedLegs();

   //--- exits and trailing --------------------------------------------
   TP_Legs_Update();

   //--- basket target --------------------------------------------------
   double totalVolume = TP_State_TotalVolume();
   if(totalVolume > 0.0)
     {
      double target = TP_ScaledUSD(CycleTargetUSD, totalVolume);
      if(target > 0.0 && TP_MoneyGE(TP_State_CycleTotal(), target))
        {
         TP_LogInfo(StringFormat("Basket target reached: cycle total %.2f >= %.2f.",
                                 TP_State_CycleTotal(), target));
         TP_Legs_CloseCycle("basket target");
        }
     }

   //--- brakes ----------------------------------------------------------
   if(!g_tp.basketLocked && TP_Risk_BasketStopHit())
     {
      TP_Legs_CloseCycle("basket stop");
      g_tp.basketLocked = true;
      TP_State_Save();
      TP_LogError(StringFormat("Basket stop triggered (%.2f%% of equity), no new cycle until the next server day.",
                               BasketStopPct));
     }

   if(!g_tp.dailyLocked && TP_Risk_DailyStopHit())
     {
      TP_Legs_CloseCycle("daily loss stop");
      g_tp.dailyLocked = true;
      TP_State_Save();
      TP_LogError(StringFormat("Daily loss stop triggered (%.2f%% of the start of day equity), trading pauses until the next server day.",
                               DailyStopPct));
     }
  }

//+------------------------------------------------------------------+
//| OnTimer - slow path: regime, starts, re-balance, shredding        |
//+------------------------------------------------------------------+
void OnTimer()
  {
   if(!g_initialised) return;

   //--- push the log buffers to disk, at most once per 60 s -----------
   TP_LogFilesFlush();

   TP_Risk_UpdateSpreadSample();
   TP_Risk_UpdateDayEquity();
   TP_News_Update();

   datetime now = TimeCurrent();

   //--- new M5 bar: refresh the ATR ------------------------------------
   datetime barM5 = iTime(g_symbol, PERIOD_M5, 0);
   if(barM5 != g_lastM5Bar)
     {
      g_lastM5Bar = barM5;
      TP_Regime_UpdateAtr();
     }

   //--- new M15 bar: full regime detection -----------------------------
   datetime barM15 = iTime(g_symbol, PERIOD_M15, 0);
   if(barM15 != g_lastM15Bar)
     {
      g_lastM15Bar = barM15;
      TP_Regime_Update();
     }

   if(!g_tp.tradeAllowed)
     {
      TP_Panel_Update();
      return;
     }

   TP_State_SyncPositions();
   TP_Legs_DetectClosedLegs();

   //--- new cycle or re-balance ----------------------------------------
   if(TP_State_OpenLegCount() == 0)
     {
      TP_Legs_TryStartCycle();
     }
   else
     {
      TP_Legs_TryRebalance();
      TP_Bank_TryShred();
     }

   //--- flatten before the weekend --------------------------------------
   if(FlattenBeforeWeekend && TP_IsFriday(now))
     {
      int hour   = TP_ServerHour(now);
      int minute = TP_ServerMinute(now);
      if((hour > FridayFlattenHour) || (hour == FridayFlattenHour && minute >= FridayFlattenMinute))
        {
         if(TP_State_OpenLegCount() > 0)
           {
            TP_LogInfo("Friday flatten: closing every open leg.");
            TP_Legs_CloseCycle("friday flatten");
           }
        }
     }

   //--- flatten before the rollover window (FlattenBeforeRollover) ------
   //--- closes the legs N minutes before RolloverStartHour; the re-opens
   //--- stay blocked until RolloverEndHour by the session filter --------
   if(FlattenBeforeRollover &&
      TP_Risk_InRolloverBlock(now, RolloverFlattenMinutes, RolloverStartHour, RolloverEndHour))
     {
      if(TP_State_OpenLegCount() > 0)
        {
         TP_LogInfo("Rollover flatten: closing every open leg before the rollover window.");
         TP_Legs_CloseCycle("rollover flatten");
        }
     }

   TP_Panel_Update();
  }

//+------------------------------------------------------------------+
//| OnTradeTransaction - keep the state in sync with the server        |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
  {
   if(!g_initialised) return;
   if(trans.symbol != g_symbol) return;

   if(trans.type == TRADE_TRANSACTION_DEAL_ADD)
     {
      if(trans.deal == 0 || !HistoryDealSelect(trans.deal)) return;
      long dealMagic = HistoryDealGetInteger(trans.deal, DEAL_MAGIC);
      if(dealMagic != g_magic) return;

      TP_LogInfo(StringFormat("Deal: order %I64u, deal %I64u, type %d, volume %.2f @ %s",
                              trans.order, trans.deal, (int)trans.type,
                              result.volume, TP_Str(result.price, g_digits)));
     }
   else if(trans.type == TRADE_TRANSACTION_POSITION)
     {
      if(trans.position == 0 || !PositionSelectByTicket(trans.position)) return;
      long positionMagic = PositionGetInteger(POSITION_MAGIC);
      if(positionMagic != g_magic) return;
     }
   else
      return;

   TP_State_SyncPositions();
  }

//+------------------------------------------------------------------+
//| OnTester - the custom optimisation criterion                        |
//+------------------------------------------------------------------+
double OnTester()
  {
   double trades = TesterStatistics(STAT_TRADES);
   double pf     = TesterStatistics(STAT_PROFIT_FACTOR);
   double rf     = TesterStatistics(STAT_RECOVERY_FACTOR);
   double dd     = TesterStatistics(STAT_EQUITY_DDREL_PERCENT);

   if(trades < 200.0 || dd > 25.0)
      return 0.0;

   if(pf > 3.0) pf = 3.0;
   if(pf < 0.0) pf = 0.0;
   if(rf < 0.0) rf = 0.0;

   return rf * pf * MathSqrt(trades / 100.0);
  }
