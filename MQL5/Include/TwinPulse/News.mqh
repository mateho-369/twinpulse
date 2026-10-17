//+------------------------------------------------------------------+
//|                                                   News.mqh        |
//|  TwinPulse Hedge EA                                                 |
//|  High impact USD news filter.                                      |
//|   * Live  : MQL5 economic calendar (CalendarValueHistory)          |
//|   * Tester: Common\Files\TwinPulse_news.csv written by the        |
//|             script TwinPulseNewsExport.mq5                        |
//+------------------------------------------------------------------+
#pragma once

#include "Config.mqh"
#include "Utils.mqh"
#include "Logger.mqh"
#include "State.mqh"

//--- news cache -------------------------------------------------------
datetime g_newsTimes[];        // sorted event times (server time)
bool     g_newsLoaded    = false;
bool     g_newsCsvFound   = false;
bool     g_newsUseCalendar = false;
datetime g_newsLastRefresh = 0;
bool     g_newsWarned     = false;

//--- forward declaration ------------------------------------------------
bool TP_News_Blocked(const datetime t);

//+------------------------------------------------------------------+
//| TP_News_UTCOffsetSeconds - server clock offset versus UTC          |
//+------------------------------------------------------------------+
int TP_News_UTCOffsetSeconds(void)
  {
   return (int)MathRound(ServerUTCOffsetHours * 3600.0);
  }

//+------------------------------------------------------------------+
//| TP_News_UtcToServer - convert a UTC timestamp into server time     |
//+------------------------------------------------------------------+
datetime TP_News_UtcToServer(const datetime utcTime)
  {
   return utcTime - TP_News_UTCOffsetSeconds();
  }

//+------------------------------------------------------------------+
//| TP_News_LoadCsv - read the exported news file                       |
//+------------------------------------------------------------------+
bool TP_News_LoadCsv(void)
  {
   ArrayFree(g_newsTimes);
   g_newsLoaded    = false;
   g_newsCsvFound  = false;

   int handle = FileOpen(NewsCsvFile, FILE_READ | FILE_CSV | FILE_ANSI | FILE_SHARE_READ, 0, FILE_COMMON);
   if(handle == INVALID_HANDLE)
     {
      if(!g_newsWarned)
        {
         g_newsWarned = true;
         TP_LogWarn(StringFormat("News file '%s' not found in Common\\Files - news filter disabled%s",
                                 NewsCsvFile,
                                 (MQLInfoInteger(MQL_TESTER) ? " (Strategy Tester)" : "")));
        }
      return false;
     }

   bool firstLine = true;
   int rows = 0;
   while(!FileIsEnding(handle))
     {
      string line = FileReadString(handle);
      if(StringLen(line) == 0) continue;
      if(firstLine) { firstLine = false; if(StringFind(line, "datetime") == 0) continue; }

      string fields[];
      int n = StringSplit(line, ',', fields);
      if(n < 3) continue;

      string dtStr = fields[0];
      string imp   = fields[1];
      string cur   = fields[2];
      StringTrimLeft(dtStr); StringTrimRight(dtStr);
      StringTrimLeft(imp);   StringTrimRight(imp);
      StringTrimLeft(cur);   StringTrimRight(cur);

      if(imp != "HIGH") continue;
      if(StringLen(cur) > 0 && cur != NewsCurrency) continue;

      datetime t = StringToTime(dtStr);
      if(t == 0) continue;

      int size = ArraySize(g_newsTimes);
      ArrayResize(g_newsTimes, size + 1);
      g_newsTimes[size] = t;
      rows++;
     }
   FileClose(handle);

   g_newsCsvFound = true;
   g_newsLoaded   = true;
   if(ArraySize(g_newsTimes) > 1) ArraySort(g_newsTimes);

   TP_LogInfo(StringFormat("News CSV '%s' loaded: %d high impact %s events",
                           NewsCsvFile, rows, NewsCurrency));
   return true;
  }

//+------------------------------------------------------------------+
//| TP_News_RefreshCalendar - read the live economic calendar          |
//+------------------------------------------------------------------+
bool TP_News_RefreshCalendar(void)
  {
   ArrayFree(g_newsTimes);
   g_newsLoaded = false;

   datetime from = TimeCurrent() - 6 * 3600;
   datetime to   = TimeCurrent() + 7 * 86400;

   MqlCalendarValue values[];
   int count = CalendarValueHistory(values, from, to, NULL, NewsCurrency);
   if(count <= 0) return false;

   for(int i = 0; i < count; i++)
     {
      MqlCalendarEvent ev;
      if(!CalendarEventById(values[i].event_id, ev)) continue;
      if((int)ev.importance != (int)CALENDAR_IMPORTANCE_HIGH) continue;

      int size = ArraySize(g_newsTimes);
      ArrayResize(g_newsTimes, size + 1);
      g_newsTimes[size] = TP_News_UtcToServer(values[i].time);
     }

   if(ArraySize(g_newsTimes) > 1) ArraySort(g_newsTimes);
   g_newsLoaded = true;
   return true;
  }

//+------------------------------------------------------------------+
//| TP_News_Init - prepare the news source for this run                |
//+------------------------------------------------------------------+
void TP_News_Init(void)
  {
   g_newsWarned     = false;
   g_newsLoaded     = false;
   g_newsCsvFound   = false;
   g_newsUseCalendar = false;
   g_newsLastRefresh = 0;

   if(!UseNewsFilter)
     {
      TP_LogInfo("News filter disabled by input.");
      return;
     }

   if(MQLInfoInteger(MQL_TESTER))
     {
      g_newsUseCalendar = false;
      TP_News_LoadCsv();
      if(!g_newsCsvFound)
         TP_LogWarn("Strategy Tester: no news file found, news filter is OFF for this run.");
      return;
     }

   g_newsUseCalendar = true;
   if(TP_News_RefreshCalendar())
      TP_LogInfo(StringFormat("Economic calendar loaded: %d high impact %s events.",
                              ArraySize(g_newsTimes), NewsCurrency));
   else
     {
      g_newsUseCalendar = false;
      TP_LogWarn("Economic calendar not available, falling back to the news CSV file.");
      TP_News_LoadCsv();
     }
  }

//+------------------------------------------------------------------+
//| TP_News_Update - refresh the source when needed                    |
//+------------------------------------------------------------------+
void TP_News_Update(void)
  {
   if(!UseNewsFilter) { g_tp.newsBlock = false; return; }

   if(g_newsUseCalendar)
     {
      if(g_newsLastRefresh == 0 || (TimeCurrent() - g_newsLastRefresh) >= 900)
        {
         g_newsLastRefresh = TimeCurrent();
         if(!TP_News_RefreshCalendar())
           {
            // keep the previous cache, only flag it
            g_tp.newsBlock = TP_News_Blocked(TimeCurrent());
            return;
           }
        }
     }
   else if(!g_newsLoaded && !g_newsCsvFound)
     {
      // try once more, the file may appear later
      TP_News_LoadCsv();
     }

   g_tp.newsBlock = TP_News_Blocked(TimeCurrent());
  }

//+------------------------------------------------------------------+
//| TP_News_Blocked - true when the given time is inside a block       |
//+------------------------------------------------------------------+
bool TP_News_Blocked(const datetime t)
  {
   if(!UseNewsFilter) return false;
   if(!g_newsLoaded) return false;
   if(ArraySize(g_newsTimes) == 0) return false;

   datetime from = t - NewsMinutesBefore * 60;
   datetime to   = t + NewsMinutesAfter * 60;

   int lo = 0;
   int hi = ArraySize(g_newsTimes) - 1;
   while(lo <= hi)
     {
      int mid = (lo + hi) / 2;
      datetime ev = g_newsTimes[mid];
      if(ev < from)      { lo = mid + 1; }
      else if(ev > to)   { hi = mid - 1; }
      else               return true;
     }
   return false;
  }

//+------------------------------------------------------------------+
//| TP_News_Status - short status string for the panel                 |
//+------------------------------------------------------------------+
string TP_News_Status(void)
  {
   if(!UseNewsFilter) return "OFF";
   if(!g_newsLoaded)  return "NO DATA";
   if(g_tp.newsBlock) return "BLOCKED";
   return "CLEAR";
  }
