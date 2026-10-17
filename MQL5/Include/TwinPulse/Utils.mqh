//+------------------------------------------------------------------+
//|                                                  Utils.mqh        |
//|  TwinPulse Hedge EA                                                 |
//|  Pure helper functions + shared terminal objects.                  |
//|  Everything in here is side effect free so the self test can use  |
//|  it on synthetic data.                                             |
//+------------------------------------------------------------------+
#ifndef TP_UTILS_MQH
#define TP_UTILS_MQH

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\AccountInfo.mqh>

//--- shared terminal objects (one EA instance per symbol / magic) -----
CTrade       g_trade;
CPositionInfo g_pos;
CSymbolInfo  g_sym;
CAccountInfo g_acc;

//--- EA wide identifiers ----------------------------------------------
string g_symbol = "";
long   g_magic  = TP_MAGIC_DEFAULT;
int    g_legsPerSide = 2;
int    g_digits = 3;
double g_point  = 0.001;

//+------------------------------------------------------------------+
//| TP_Clamp - clamp a value into a range                             |
//+------------------------------------------------------------------+
double TP_Clamp(const double value, const double lo, const double hi)
  {
   if(value < lo) return lo;
   if(value > hi) return hi;
   return value;
  }

//+------------------------------------------------------------------+
//| TP_SafeDiv - division that never divides by zero                  |
//+------------------------------------------------------------------+
double TP_SafeDiv(const double num, const double den, const double fallback)
  {
   if(MathAbs(den) < 1e-12) return fallback;
   return num / den;
  }

//+------------------------------------------------------------------+
//| TP_NormalizeVolume - snap a volume to the broker step and clamp   |
//|  vmin/vmax : symbol volume limits, vstep : volume step,           |
//|  vlimit    : maximum total volume per side (0 = not used)         |
//+------------------------------------------------------------------+
double TP_NormalizeVolume(const double rawVolume,
                           const double vmin,
                           const double vmax,
                           const double vstep,
                           const double vlimit)
  {
   double v = rawVolume;
   if(v <= 0.0) return 0.0;

   if(vstep > 0.0)
      v = MathRound(v / vstep) * vstep;
   v = MathRound(v * 1.0e8) / 1.0e8;

   double hi = vmax;
   if(vlimit > 0.0 && vlimit < hi) hi = vlimit;
   if(vstep > 0.0 && hi > 0.0)
     {
      double snapped = MathFloor(hi / vstep + 1.0e-9) * vstep;
      if(snapped > 0.0) hi = snapped;
     }

   if(vmin > 0.0 && v < vmin) v = vmin;
   if(hi > 0.0 && v > hi)   v = hi;
   if(vmin > 0.0 && v < vmin) v = vmin;

   v = MathRound(v * 1.0e8) / 1.0e8;
   return v;
  }

//+------------------------------------------------------------------+
//| TP_Median - median value, the input array is sorted in place       |
//+------------------------------------------------------------------+
double TP_Median(double &values[])
  {
   int n = ArraySize(values);
   if(n <= 0) return 0.0;
   ArraySort(values);
   if((n % 2) == 1) return values[n / 2];
   return (values[n / 2 - 1] + values[n / 2]) * 0.5;
  }

//+------------------------------------------------------------------+
//| TP_ComputeER - Kaufman efficiency ratio on M15 close prices       |
//|  prices[count-1] is the newest bar, prices[0] the oldest.         |
//+------------------------------------------------------------------+
double TP_ComputeER(const double &prices[], const int count, const int period)
  {
   if(period < 2) return 0.0;
   if(count < period + 1) return 0.0;

   double change = MathAbs(prices[count - 1] - prices[count - 1 - period]);
   double path   = 0.0;
   for(int i = count - period; i < count; i++)
      path += MathAbs(prices[i] - prices[i - 1]);

   if(path <= 0.0) return 0.0;
   return TP_Clamp(change / path, 0.0, 1.0);
  }

//+------------------------------------------------------------------+
//| TP_ComputeCHOP - choppiness index on M15                           |
//|  all arrays are chronological, index count-1 is the newest bar.    |
//+------------------------------------------------------------------+
double TP_ComputeCHOP(const double &highs[],
                      const double &lows[],
                      const double &closes[],
                      const int count,
                      const int period)
  {
   if(period < 2) return 50.0;
   if(count < period + 1) return 50.0;

   double sumTR = 0.0;
   double maxH  = highs[count - period];
   double minL  = lows[count - period];

   for(int i = count - period; i < count; i++)
     {
      double tr = highs[i] - lows[i];
      if(i > 0)
        {
         double pc = closes[i - 1];
         double t1 = MathAbs(highs[i] - pc);
         double t2 = MathAbs(lows[i]  - pc);
         tr = MathMax(tr, MathMax(t1, t2));
        }
      sumTR += tr;
      if(highs[i] > maxH) maxH = highs[i];
      if(lows[i]  < minL) minL = lows[i];
     }

   double range = maxH - minL;
   if(range <= 0.0) return 50.0;

   double v = MathLog10(TP_SafeDiv(sumTR, range, 1.0)) / MathLog10((double)period) * 100.0;
   return TP_Clamp(v, 0.0, 100.0);
  }

//+------------------------------------------------------------------+
//| TP_TickMoneyPerUnit - money (USD) for a 1.00 price move           |
//+------------------------------------------------------------------+
double TP_TickMoneyPerUnit(const string symbol, const double volume)
  {
   if(volume <= 0.0) return 0.0;
   double tickValue = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickSize <= 0.0) tickSize = SymbolInfoDouble(symbol, SYMBOL_POINT);
   if(tickSize <= 0.0 || tickValue <= 0.0) return 0.0;
   return (tickValue / tickSize) * volume;
  }

//+------------------------------------------------------------------+
//| TP_ScaledUSD - scale a "per 0.01 lot" USD threshold to a volume   |
//+------------------------------------------------------------------+
double TP_ScaledUSD(const double perHundredthLot, const double volume)
  {
   if(volume <= 0.0) return 0.0;
   return perHundredthLot * (volume / 0.01);
  }

//+------------------------------------------------------------------+
//| TP_PriceToMoney - money for a price distance                       |
//+------------------------------------------------------------------+
double TP_PriceToMoney(const string symbol, const double volume, const double priceDistance)
  {
   if(volume <= 0.0) return 0.0;
   return MathAbs(priceDistance) * TP_TickMoneyPerUnit(symbol, volume);
  }

//+------------------------------------------------------------------+
//| TP_LegName - readable name of a leg index                         |
//+------------------------------------------------------------------+
string TP_LegName(const int legIndex)
  {
   switch(legIndex)
     {
      case TP_LEG_BUY_A:  return "BUY_A";
      case TP_LEG_BUY_B:  return "BUY_B";
      case TP_LEG_SELL_A: return "SELL_A";
      case TP_LEG_SELL_B: return "SELL_B";
     }
   return "UNKNOWN";
  }

//+------------------------------------------------------------------+
//| TP_LegIndexFromName - leg index from its name, -1 when unknown     |
//+------------------------------------------------------------------+
int TP_LegIndexFromName(const string name)
  {
   string n = name;
   StringTrimLeft(n);
   StringTrimRight(n);
   if(n == "BUY_A")  return TP_LEG_BUY_A;
   if(n == "BUY_B")  return TP_LEG_BUY_B;
   if(n == "SELL_A") return TP_LEG_SELL_A;
   if(n == "SELL_B") return TP_LEG_SELL_B;
   return -1;
  }

//+------------------------------------------------------------------+
//| TP_LegIsBuy - true for the two buy legs                            |
//+------------------------------------------------------------------+
bool TP_LegIsBuy(const int legIndex)
  {
   return (legIndex == TP_LEG_BUY_A || legIndex == TP_LEG_BUY_B);
  }

//+------------------------------------------------------------------+
//| TP_LegMirror - the opposite leg of the same slot                   |
//+------------------------------------------------------------------+
int TP_LegMirror(const int legIndex)
  {
   switch(legIndex)
     {
      case TP_LEG_BUY_A:  return TP_LEG_SELL_A;
      case TP_LEG_BUY_B:  return TP_LEG_SELL_B;
      case TP_LEG_SELL_A: return TP_LEG_BUY_A;
      case TP_LEG_SELL_B: return TP_LEG_BUY_B;
     }
   return -1;
  }

//+------------------------------------------------------------------+
//| TP_LegSlot - slot index (0 = A, 1 = B)                             |
//+------------------------------------------------------------------+
int TP_LegSlot(const int legIndex)
  {
   return (legIndex % TP_SLOT_COUNT);
  }

//+------------------------------------------------------------------+
//| TP_SideName - readable side name                                  |
//+------------------------------------------------------------------+
string TP_SideName(const int side)
  {
   if(side == TP_SIDE_BUY)  return "BUY";
   if(side == TP_SIDE_SELL) return "SELL";
   return "MIXED";
  }

//+------------------------------------------------------------------+
//| TP_MakeComment - "TP|<cycle>|<leg>"                                |
//+------------------------------------------------------------------+
string TP_MakeComment(const int cycleId, const int legIndex)
  {
   return StringFormat("%s|%d|%s", TP_COMMENT_PREFIX, cycleId, TP_LegName(legIndex));
  }

//+------------------------------------------------------------------+
//| TP_IsDigits - true when a string contains one or more decimal digits|
//+------------------------------------------------------------------+
bool TP_IsDigits(const string text)
  {
   int length = StringLen(text);
   if(length <= 0) return false;
   for(int i = 0; i < length; i++)
     {
      ushort ch = StringGetCharacter(text, i);
      if(ch < '0' || ch > '9') return false;
     }
   return true;
  }

//+------------------------------------------------------------------+
//| TP_ParseComment - read cycle id and leg index from a comment       |
//+------------------------------------------------------------------+
bool TP_ParseComment(const string comment, int &cycleId, int &legIndex)
  {
   cycleId = -1;
   legIndex = -1;
   if(StringLen(comment) < 3) return false;
   if(StringSubstr(comment, 0, 2) != TP_COMMENT_PREFIX) return false;

   string rest = StringSubstr(comment, 3);
   int sep = StringFind(rest, "|");
   if(sep <= 0) return false;

   string cycStr = StringSubstr(rest, 0, sep);
   string legStr = StringSubstr(rest, sep + 1);

   if(!TP_IsDigits(cycStr)) return false;
   legIndex = TP_LegIndexFromName(legStr);
   if(legIndex < 0) return false;
   cycleId = (int)StringToInteger(cycStr);
   return true;
  }

//+------------------------------------------------------------------+
//| TP_DayStamp - YYYYMMDD integer of a server timestamp               |
//+------------------------------------------------------------------+
int TP_DayStamp(const datetime t)
  {
   MqlDateTime dt;
   TimeToStruct(t, dt);
   return dt.year * 10000 + dt.mon * 100 + dt.day;
  }

//+------------------------------------------------------------------+
//| TP_Str - short numeric to string                                   |
//|  MQL5 StringFormat does not support the "*" width, so the number   |
//|  of digits is selected with a small table.                          |
//+------------------------------------------------------------------+
string TP_Str(const double value, const int digits)
  {
   if(digits <= 0) return StringFormat("%.0f", value);
   if(digits == 1) return StringFormat("%.1f", value);
   if(digits == 2) return StringFormat("%.2f", value);
   if(digits == 3) return StringFormat("%.3f", value);
   if(digits == 4) return StringFormat("%.4f", value);
   if(digits == 5) return StringFormat("%.5f", value);
   if(digits == 6) return StringFormat("%.6f", value);
   return StringFormat("%.8f", value);
  }

//+------------------------------------------------------------------+
//| TP_TimeStr - server time as "YYYY.MM.DD HH:MI"                     |
//+------------------------------------------------------------------+
string TP_TimeStr(const datetime t)
  {
   return TimeToString(t, TIME_DATE | TIME_MINUTES);
  }

//+------------------------------------------------------------------+
//| TP_ServerHour / TP_ServerMinute / TP_ServerDayOfWeek              |
//+------------------------------------------------------------------+
int TP_ServerHour(const datetime t)
  {
   MqlDateTime dt;
   TimeToStruct(t, dt);
   return dt.hour;
  }

int TP_ServerMinute(const datetime t)
  {
   MqlDateTime dt;
   TimeToStruct(t, dt);
   return dt.min;
  }

int TP_ServerDayOfWeek(const datetime t)
  {
   MqlDateTime dt;
   TimeToStruct(t, dt);
   return dt.day_of_week;
  }

//+------------------------------------------------------------------+
//| TP_IsWeekend - Saturday or Sunday                                  |
//+------------------------------------------------------------------+
bool TP_IsWeekend(const datetime t)
  {
   int dow = TP_ServerDayOfWeek(t);
   return (dow == 0 || dow == 6);
  }

//+------------------------------------------------------------------+
//| TP_IsFriday - Friday of the week                                   |
//+------------------------------------------------------------------+
bool TP_IsFriday(const datetime t)
  {
   return (TP_ServerDayOfWeek(t) == 5);
  }

#endif // TP_UTILS_MQH
