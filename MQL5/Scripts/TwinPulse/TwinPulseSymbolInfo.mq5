//+------------------------------------------------------------------+
//|                                  TwinPulseSymbolInfo.mq5         |
//|                                                                  |
//|  Prints the symbol / account specs needed for the decision       |
//|  documentation and the spread statistics of the last 5 trading   |
//|  days (median / 90th percentile from real ticks).                 |
//|                                                                  |
//|  digits, point, contract size, volume min/step/max, stops and     |
//|  freeze level, swap long/short, filling modes, hedging yes/no,   |
//|  server UTC offset (TimeTradeServer - TimeGMT), spread stats.    |
//|                                                                  |
//|  The same text is written to Common\Files\TwinPulseSymbolInfo.txt |
//|  so tools/summarize_batch.py can show the specs in SUMMARY.md.   |
//|  Run it on a live chart of the batch symbol before the batch.    |
//+------------------------------------------------------------------+
#property copyright "TwinPulse Hedge EA"
#property version   "1.00"
#property description "Prints symbol specs and the 5-day spread stats (median / p90)"
#property script_show_inputs

//+------------------------------------------------------------------+
//| append one output line (printed and collected for the file)      |
//+------------------------------------------------------------------+
string g_out = "";

void AddLine(const string line)
  {
   Print(line);
   g_out += line + "\n";
  }

//+------------------------------------------------------------------+
//| spread statistics of the last 5 trading days (real ticks)        |
//+------------------------------------------------------------------+
void SpreadStats(const string symbol, const int digits)
  {
   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   double spreads[];
   ArrayResize(spreads, 0);
   int    capacity = 0;
   int    tradingDays = 0;
   int    ticksTotal = 0;

   //--- walk the last 7 calendar days, keep the newest 5 that traded -
   datetime midnight = TimeTradeServer();
   midnight = midnight - (midnight % 86400);

   for(int d = 0; d < 7 && tradingDays < 5; d++)
     {
      datetime to   = midnight - (datetime)(d * 86400);
      datetime from = to - 86400;
      MqlTick  ticks[];
      int copied = CopyTicksRange(symbol, ticks, COPY_TICKS_INFO, from, to);
      if(copied <= 0) continue;   // weekend / no tick history for the day

      tradingDays++;
      if(capacity < ticksTotal + copied)
        {
         capacity = ticksTotal + copied;
         ArrayResize(spreads, capacity);
        }
      for(int i = 0; i < copied; i++)
        {
         if(ticks[i].bid <= 0.0 || ticks[i].ask <= 0.0) continue;
         double s = ticks[i].ask - ticks[i].bid;
         if(s < 0.0) s = 0.0;
         spreads[ticksTotal++] = s;
        }
     }

   if(ticksTotal < 1)
     {
      AddLine("spread of the last 5 trading days: no tick history (CopyTicksRange), GetLastError=" +
              IntegerToString(GetLastError()));
      return;
     }

   ArraySort(spreads);
   double median = spreads[ticksTotal / 2];
   double p90    = spreads[(int)((ticksTotal - 1) * 0.9)];
   double pSpread = (point > 0.0) ? (1.0 / point) : 0.0;

   AddLine(StringFormat("spread of the last %d trading days (%d ticks): median %s (%s points), p90 %s (%s points)",
                        tradingDays, ticksTotal,
                        DoubleToString(median, digits),
                        DoubleToString(median * pSpread, 1),
                        DoubleToString(p90, digits),
                        DoubleToString(p90 * pSpread, 1)));
  }

//+------------------------------------------------------------------+
//| OnStart - print the specs                                        |
//+------------------------------------------------------------------+
void OnStart()
  {
   string symbol = _Symbol;
   int    digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   double point  = SymbolInfoDouble(symbol, SYMBOL_POINT);

   AddLine("=== TwinPulseSymbolInfo: " + symbol + " ===");
   AddLine(StringFormat("digits: %d, point: %s", digits, DoubleToString(point, 8)));
   AddLine(StringFormat("contract size: %s", DoubleToString(SymbolInfoDouble(symbol, SYMBOL_TRADE_CONTRACT_SIZE), 2)));
   AddLine(StringFormat("volume: min %s, step %s, max %s",
                        DoubleToString(SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN), 2),
                        DoubleToString(SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP), 2),
                        DoubleToString(SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX), 2)));
   AddLine(StringFormat("stops level: %d points, freeze level: %d points",
                        (int)SymbolInfoInteger(symbol, SYMBOL_TRADE_STOPS_LEVEL),
                        (int)SymbolInfoInteger(symbol, SYMBOL_TRADE_FREEZE_LEVEL)));
   AddLine(StringFormat("swap: long %s, short %s (mode %d)",
                        DoubleToString(SymbolInfoDouble(symbol, SYMBOL_SWAP_LONG), 2),
                        DoubleToString(SymbolInfoDouble(symbol, SYMBOL_SWAP_SHORT), 2),
                        (int)SymbolInfoInteger(symbol, SYMBOL_SWAP_MODE)));

   //--- filling modes: SYMBOL_FILLING_MODE is a bit flag:            ---
   //--- bit 0 (1) = FOK allowed, bit 1 (2) = IOC allowed (the enum   ---
   //--- values SYMBOL_FILLING_FOK/IOC are 0/1 and are NOT the bits) ---
   int filling = (int)SymbolInfoInteger(symbol, SYMBOL_FILLING_MODE);
   string fillText = "";
   if((filling & 1) != 0) fillText += "FOK ";
   if((filling & 2) != 0) fillText += "IOC ";
   if(fillText == "") fillText = "exchange / none ";
   AddLine("filling modes: " + fillText + "(flags " + IntegerToString(filling) + ")");

   //--- hedging (account margin mode) --------------------------------
   long marginMode = AccountInfoInteger(ACCOUNT_MARGIN_MODE);
   string hedgeText = "no (netting)";
   if(marginMode == ACCOUNT_MARGIN_MODE_RETAIL_HEDGING) hedgeText = "yes (hedging)";
   else
      if(marginMode == ACCOUNT_MARGIN_MODE_EXCHANGE) hedgeText = "no (exchange)";
   AddLine("hedging: " + hedgeText);

   //--- server clock vs UTC ------------------------------------------
   long offsetSec = (long)TimeTradeServer() - (long)TimeGMT();
   AddLine(StringFormat("server UTC offset: %d seconds (%.2f hours)",
                        offsetSec, offsetSec / 3600.0));

   SpreadStats(symbol, digits);

   //--- the same text to Common\Files for tools/summarize_batch.py ----
   //--- FILE_COMMON is a FLAG of open_flags (see the runbook) ---------
   int handle = FileOpen("TwinPulseSymbolInfo.txt", FILE_WRITE | FILE_ANSI | FILE_SHARE_READ | FILE_COMMON, ',', CP_ACP);
   if(handle == INVALID_HANDLE)
      Print("TwinPulseSymbolInfo: cannot write Common\\Files\\TwinPulseSymbolInfo.txt, error ", GetLastError());
   else
     {
      FileWriteString(handle, g_out);
      FileClose(handle);
      Print("TwinPulseSymbolInfo: written to Common\\Files\\TwinPulseSymbolInfo.txt");
     }
  }
//+------------------------------------------------------------------+
