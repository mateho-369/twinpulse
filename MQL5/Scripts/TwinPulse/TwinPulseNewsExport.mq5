//+------------------------------------------------------------------+
//|                                  TwinPulseNewsExport.mq5         |
//|                                                                  |
//|  Exports the high impact USD events of the MQL5 economic         |
//|  calendar into Common\Files\TwinPulse_news.csv.                  |
//|                                                                  |
//|  The Strategy Tester cannot read the calendar, so this file has  |
//|  to be created once on a live chart before a backtest is run.     |
//|                                                                  |
//|  Format: datetime,impact,currency,event   (server time)          |
//+------------------------------------------------------------------+
#property copyright "TwinPulse Hedge EA"
#property version   "1.00"
#property description "Exports high impact USD news events to Common\\Files\\TwinPulse_news.csv"

#include <TwinPulse/Config.mqh>
#include <TwinPulse/Utils.mqh>
#include <TwinPulse/News.mqh>

//+------------------------------------------------------------------+
//| OnStart - export the calendar                                     |
//+------------------------------------------------------------------+
void OnStart()
  {
   string fileName = TP_NEWS_CSV;

   int handle = FileOpen(fileName, FILE_WRITE | FILE_CSV | FILE_ANSI | FILE_SHARE_READ, 0, FILE_COMMON);
   if(handle == INVALID_HANDLE)
     {
      Print("TwinPulseNewsExport: cannot open ", fileName, " in Common\\Files, error ", GetLastError());
      return;
     }

   FileWriteString(handle, "datetime,impact,currency,event\n");

   datetime from = StringToTime("2018.01.01 00:00");
   datetime to   = TimeCurrent();
   if(to <= from)
     {
      Print("TwinPulseNewsExport: the end time is before the start time.");
      FileClose((int)handle);
      return;
     }

   int written = 0;
   int failed  = 0;
   const int chunkDays = 31;

   datetime cursor = from;
   while(cursor < to)
     {
      datetime chunkEnd = cursor + chunkDays * 86400;
      if(chunkEnd > to) chunkEnd = to;

      MqlCalendarValue values[];
      int count = CalendarValueHistory(values, cursor, chunkEnd, NULL, "USD");
      if(count <= 0)
        {
         failed++;
         Print("TwinPulseNewsExport: no calendar data between ",
               TimeToString(cursor, TIME_DATE), " and ", TimeToString(chunkEnd, TIME_DATE));
        }
      else
        {
         for(int i = 0; i < count; i++)
           {
            MqlCalendarEvent ev;
            if(!CalendarEventById(values[i].event_id, ev)) continue;
            if((int)ev.importance != (int)CALENDAR_IMPORTANCE_HIGH) continue;

            MqlCalendarCountry country;
            if(!CalendarCountryById((long)ev.country_id, country)) continue;

            string name = ev.name;
            string currency = country.currency;
            StringReplace(name, ",", " ");

            string line = StringFormat("%s,HIGH,%s,%s",
                                       TimeToString(TP_News_UtcToServer(values[i].time), TIME_DATE | TIME_MINUTES),
                                       currency, name);
            FileWriteString(handle, line + "\n");
            written++;
           }
        }

      cursor = chunkEnd + 60;
     }

   FileClose((int)handle);

   Print("=====================================================");
   Print("  TwinPulse news export finished");
   Print(StringFormat("  file   : Common\\Files\\%s", fileName));
   Print(StringFormat("  period : %s -> %s (server time)",
                       TimeToString(from, TIME_DATE), TimeToString(to, TIME_DATE)));
   Print(StringFormat("  events : %d high impact USD events written", written));
   if(failed > 0)
      Print(StringFormat("  warning: %d chunks returned no data", failed));
   Print("=====================================================");
  }
