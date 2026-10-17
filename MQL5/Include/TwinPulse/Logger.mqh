//+------------------------------------------------------------------+
//|                                                 Logger.mqh        |
//|  TwinPulse Hedge EA                                                 |
//|  Console output + rotating text log in Common\Files                |
//+------------------------------------------------------------------+
#pragma once

#include "Config.mqh"
#include "Utils.mqh"

#define TP_LOG_MAX_BYTES  2097152     // 2 MB, then the log file is recycled

//+------------------------------------------------------------------+
//| TP_LogFileWrite - append one line to Common\Files\TwinPulse.log   |
//+------------------------------------------------------------------+
void TP_LogFileWrite(const string line)
  {
   if(!EnableFileLog) return;

   int handle = FileOpen(TP_LOG_FILE, FILE_READ | FILE_WRITE | FILE_CSV | FILE_ANSI | FILE_SHARE_READ, 0, FILE_COMMON);
   bool created = (handle == INVALID_HANDLE);
   if(created)
      handle = FileOpen(TP_LOG_FILE, FILE_WRITE | FILE_CSV | FILE_ANSI | FILE_SHARE_READ, 0, FILE_COMMON);
   if(handle == INVALID_HANDLE) return;

   if(created)
      FileWriteString(handle, "time,level,symbol,magic,message\n");

   if(FileSize(handle) > TP_LOG_MAX_BYTES)
     {
      FileClose(handle);
      FileDelete(TP_LOG_FILE, FILE_COMMON);
      handle = FileOpen(TP_LOG_FILE, FILE_WRITE | FILE_CSV | FILE_ANSI | FILE_SHARE_READ, 0, FILE_COMMON);
      if(handle == INVALID_HANDLE) return;
      FileWriteString(handle, "time,level,symbol,magic,message\n");
     }

   FileSeek(handle, 0, SEEK_END);
   FileWriteString(handle, line + "\n");
   FileClose(handle);
  }

//+------------------------------------------------------------------+
//| TP_Log - central log function                                      |
//+------------------------------------------------------------------+
void TP_Log(const string level, const string message)
  {
   bool isInfo  = (level == "INFO");
   bool isWarn  = (level == "WARN");
   bool isError = (level == "ERROR");

   if(isInfo && !VerboseLog && !isWarn && !isError)
     {
      // info messages are only written to the file, not to the journal
      TP_LogFileWrite(StringFormat("%s,%s,%s,%d,%s",
                                   TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS),
                                   level, g_symbol, (int)g_magic, message));
      return;
     }

   string line = StringFormat("%s | %s | %s | %s | %s",
                              TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS),
                              level, g_symbol, g_magic, message);
   Print(line);
   TP_LogFileWrite(StringFormat("%s,%s,%s,%d,%s",
                                TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS),
                                level, g_symbol, (int)g_magic, message));
  }

//+------------------------------------------------------------------+
//| convenience wrappers                                              |
//+------------------------------------------------------------------+
void TP_LogInfo(const string message)
  {
   TP_Log("INFO", message);
  }

void TP_LogWarn(const string message)
  {
   TP_Log("WARN", message);
  }

void TP_LogError(const string message)
  {
   TP_Log("ERROR", message);
  }

//+------------------------------------------------------------------+
//| TP_CsvAppend - append one line to a CSV file in Common\Files      |
//+------------------------------------------------------------------+
void TP_CsvAppend(const string fileName, const string header, const string line)
  {
   if(!WriteCsvLogs) return;

   int handle = FileOpen(fileName, FILE_READ | FILE_WRITE | FILE_CSV | FILE_ANSI | FILE_SHARE_READ, 0, FILE_COMMON);
   bool created = (handle == INVALID_HANDLE);
   if(created)
      handle = FileOpen(fileName, FILE_WRITE | FILE_CSV | FILE_ANSI | FILE_SHARE_READ, 0, FILE_COMMON);
   if(handle == INVALID_HANDLE) return;

   if(created)
      FileWriteString(handle, header + "\n");

   FileSeek(handle, 0, SEEK_END);
   FileWriteString(handle, line + "\n");
   FileClose(handle);
  }

//+------------------------------------------------------------------+
//| TP_LogLegCSV - one row for every closed leg                       |
//+------------------------------------------------------------------+
void TP_LogLegCSV(const int legIndex, const int cycleId, const double volume,
                  const double openPrice, const double closePrice, const double profit,
                  const string reason, const double bank, const string regime,
                  const double spread, const double atr5)
  {
   string line = StringFormat("%s,%d,%s,%s,%.2f,%s,%s,%s,%.2f,%.2f,%s,%.3f,%.3f",
                              TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS),
                              cycleId, TP_LegName(legIndex),
                              TP_LegIsBuy(legIndex) ? "BUY" : "SELL",
                              volume,
                              TP_Str(openPrice, 3), TP_Str(closePrice, 3),
                              reason, profit, bank, regime, spread, atr5);
   TP_CsvAppend(TP_LEGS_CSV,
                "time,cycle,leg,side,volume,open_price,close_price,reason,profit,bank,regime,spread,atr5",
                line);
  }

//+------------------------------------------------------------------+
//| TP_LogCycleCSV - one row for every finished cycle                  |
//+------------------------------------------------------------------+
void TP_LogCycleCSV(const int cycleId, const datetime startTime, const datetime endTime,
                    const string regime, const int legsOpened, const int legsClosed,
                    const double realized, const double bank, const double shredded,
                    const string reason, const double spread, const double atr5)
  {
   string line = StringFormat("%s,%d,%s,%s,%s,%d,%d,%.2f,%.2f,%.2f,%s,%.3f,%.3f",
                              TimeToString(endTime, TIME_DATE | TIME_SECONDS),
                              cycleId,
                              TimeToString(startTime, TIME_DATE | TIME_SECONDS),
                              TimeToString(endTime, TIME_DATE | TIME_SECONDS),
                              regime, legsOpened, legsClosed,
                              realized, bank, shredded, reason, spread, atr5);
   TP_CsvAppend(TP_CYCLES_CSV,
                "time,cycle_id,start_time,end_time,regime,legs_opened,legs_closed,realized,bank,shredded,reason,spread,atr5",
                line);
  }
