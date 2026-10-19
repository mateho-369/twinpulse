//+------------------------------------------------------------------+
//|                                                 Logger.mqh        |
//|  TwinPulse Hedge EA                                                 |
//|  Console output + rotating text log in Common\Files                |
//|                                                                    |
//|  Performance: every file keeps ONE open handle (opened once in     |
//|  OnInit, closed in OnDeinit). Lines are appended with              |
//|  FileWriteString, FileFlush runs at most once per 60 s (plus once  |
//|  in OnDeinit) and the size rotation is checked at most once per    |
//|  minute - a FileOpen/FileClose per line is far too slow in the     |
//|  tester and wakes up the antivirus on every call.                  |
//+------------------------------------------------------------------+
#ifndef TP_LOGGER_MQH
#define TP_LOGGER_MQH

#include "Config.mqh"
#include "Utils.mqh"

#define TP_LOG_MAX_BYTES  2097152     // 2 MB, then the log file is recycled

#define TP_LOG_HEADER     "time,level,symbol,magic,message"
#define TP_LEGS_HEADER    "time,cycle,leg,side,volume,open_price,close_price,reason,profit,bank,regime,spread,atr5,spread_open,spread_cost,gross"
#define TP_CYCLES_HEADER  "time,cycle_id,start_time,end_time,regime,legs_opened,legs_closed,realized,bank,shredded,reason,spread,atr5"

#define TP_FLUSH_INTERVAL_MS   60000  // FileFlush at most once per 60 s
#define TP_ROTATE_INTERVAL_MS  60000  // size rotation check at most once per minute

//--- one persistent handle per file ---------------------------------
int    g_logHandle   = INVALID_HANDLE;   // TwinPulse.log
int    g_legsHandle  = INVALID_HANDLE;   // TwinPulse_legs.csv
int    g_cycleHandle = INVALID_HANDLE;   // TwinPulse_cycles.csv
uint   g_lastFlushMs  = 0;
uint   g_lastRotateMs = 0;

//+------------------------------------------------------------------+
//| TP_LogOpenFile - open one log file in Common\Files and append to  |
//| the end. Writes the header when the file is new.                  |
//+------------------------------------------------------------------+
int TP_LogOpenFile(const string fileName, const string header)
  {
   //--- FILE_COMMON is a FLAG of open_flags: FileOpen(name, flags,
   //--- delimiter, codepage). A misplaced FILE_COMMON as the 4th
   //--- argument is used as the codepage and the file lands in the
   //--- local MQL5\Files instead of Common\Files (empty in the tester).
   //--- NOTE: FILE_READ|FILE_WRITE already CREATES a missing file, so
   //--- "open failed" never tells us the file is new - the header is
   //--- written whenever the file is empty instead.
   int handle = FileOpen(fileName, FILE_READ | FILE_WRITE | FILE_CSV | FILE_ANSI | FILE_SHARE_READ | FILE_COMMON, ',', CP_ACP);
   if(handle == INVALID_HANDLE)
      handle = FileOpen(fileName, FILE_WRITE | FILE_CSV | FILE_ANSI | FILE_SHARE_READ | FILE_COMMON, ',', CP_ACP);
   if(handle == INVALID_HANDLE) return INVALID_HANDLE;

   if(FileSize(handle) == 0)
      FileWriteString(handle, header + "\n");

   FileSeek(handle, 0, SEEK_END);
   return handle;
  }

//+------------------------------------------------------------------+
//| TP_LogFilesOpen - open every log file once (call from OnInit)     |
//+------------------------------------------------------------------+
void TP_LogFilesOpen(void)
  {
   if(g_logHandle == INVALID_HANDLE && EnableFileLog)
      g_logHandle = TP_LogOpenFile(TP_LOG_FILE, TP_LOG_HEADER);
   if(g_legsHandle == INVALID_HANDLE && WriteCsvLogs)
      g_legsHandle = TP_LogOpenFile(TP_LEGS_CSV, TP_LEGS_HEADER);
   if(g_cycleHandle == INVALID_HANDLE && WriteCsvLogs)
      g_cycleHandle = TP_LogOpenFile(TP_CYCLES_CSV, TP_CYCLES_HEADER);
   g_lastFlushMs  = GetTickCount();
   g_lastRotateMs = GetTickCount();
  }

//+------------------------------------------------------------------+
//| TP_LogFilesFlush - flush every handle, at most once per 60 s      |
//| (call from OnTimer).                                              |
//+------------------------------------------------------------------+
void TP_LogFilesFlush(void)
  {
   uint nowMs = GetTickCount();
   if(nowMs - g_lastFlushMs < TP_FLUSH_INTERVAL_MS) return;
   g_lastFlushMs = nowMs;
   if(g_logHandle   != INVALID_HANDLE) FileFlush(g_logHandle);
   if(g_legsHandle  != INVALID_HANDLE) FileFlush(g_legsHandle);
   if(g_cycleHandle != INVALID_HANDLE) FileFlush(g_cycleHandle);
  }

//+------------------------------------------------------------------+
//| TP_LogFilesClose - flush and close every handle (call from OnDeinit) |
//+------------------------------------------------------------------+
void TP_LogFilesClose(void)
  {
   if(g_logHandle   != INVALID_HANDLE) { FileFlush(g_logHandle);   FileClose(g_logHandle);   g_logHandle   = INVALID_HANDLE; }
   if(g_legsHandle  != INVALID_HANDLE) { FileFlush(g_legsHandle);  FileClose(g_legsHandle);  g_legsHandle  = INVALID_HANDLE; }
   if(g_cycleHandle != INVALID_HANDLE) { FileFlush(g_cycleHandle); FileClose(g_cycleHandle); g_cycleHandle = INVALID_HANDLE; }
  }

//+------------------------------------------------------------------+
//| TP_LogFileWrite - append one line to Common\Files\TwinPulse.log   |
//+------------------------------------------------------------------+
void TP_LogFileWrite(const string line)
  {
   if(!EnableFileLog) return;
   if(g_logHandle == INVALID_HANDLE)
      g_logHandle = TP_LogOpenFile(TP_LOG_FILE, TP_LOG_HEADER);   // lazy fallback
   if(g_logHandle == INVALID_HANDLE) return;

   //--- size rotation, checked at most once per minute ---------------
   uint nowMs = GetTickCount();
   if(nowMs - g_lastRotateMs >= TP_ROTATE_INTERVAL_MS)
     {
      g_lastRotateMs = nowMs;
      if(FileSize(g_logHandle) > TP_LOG_MAX_BYTES)
        {
         FileClose(g_logHandle);
         FileDelete(TP_LOG_FILE, FILE_COMMON);
         g_logHandle = TP_LogOpenFile(TP_LOG_FILE, TP_LOG_HEADER);
         if(g_logHandle == INVALID_HANDLE) return;
        }
     }

   FileWriteString(g_logHandle, line + "\n");
   g_logLinesWritten++;   // TwinPulse.log lines only (see Utils.mqh)
  }

//+------------------------------------------------------------------+
//| TP_Log - central log function                                      |
//+------------------------------------------------------------------+
void TP_Log(const string level, const string message)
  {
   bool isInfo = (level == "INFO");

   //--- in the Strategy Tester the journal stays clean: INFO goes to  |
   //--- the file only, WARN / ERROR are printed as before.            |
   bool toJournal = !isInfo || VerboseLog;
   if(isInfo && (bool)MQLInfoInteger(MQL_TESTER))
      toJournal = false;

   if(!toJournal)
     {
      // info messages are only written to the file, not to the journal
      TP_LogFileWrite(StringFormat("%s,%s,%s,%d,%s",
                                   TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS),
                                   level, g_symbol, (int)g_magic, message));
      return;
     }

   string line = StringFormat("%s | %s | %s | %d | %s",
                              TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS),
                              level, g_symbol, (int)g_magic, message);
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
//| (one persistent handle per file, opened on first use)              |
//+------------------------------------------------------------------+
void TP_CsvAppend(const string fileName, const string header, const string line)
  {
   if(!WriteCsvLogs) return;

   int handle = INVALID_HANDLE;
   if(fileName == TP_LEGS_CSV) handle = g_legsHandle;
   else if(fileName == TP_CYCLES_CSV) handle = g_cycleHandle;

   if(handle == INVALID_HANDLE)
     {
      handle = TP_LogOpenFile(fileName, header);   // lazy fallback
      if(handle == INVALID_HANDLE) return;
      if(fileName == TP_LEGS_CSV) g_legsHandle = handle;
      else if(fileName == TP_CYCLES_CSV) g_cycleHandle = handle;
     }

   FileWriteString(handle, line + "\n");
   g_csvRowsWritten++;   // CSV rows only (see Utils.mqh)
  }

//+------------------------------------------------------------------+
//| TP_LogLegCSV - one row for every closed leg                       |
//+------------------------------------------------------------------+
void TP_LogLegCSV(const int legIndex, const int cycleId, const double volume,
                  const double openPrice, const double closePrice, const double profit,
                  const string reason, const double bank, const string regime,
                  const double spread, const double atr5,
                  const double spreadOpen, const double spreadCost, const double gross)
  {
   string line = StringFormat("%s,%d,%s,%s,%.2f,%s,%s,%s,%.2f,%.2f,%s,%.3f,%.3f,%.3f,%.2f,%.2f",
                              TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS),
                              cycleId, TP_LegName(legIndex),
                              TP_LegIsBuy(legIndex) ? "BUY" : "SELL",
                              volume,
                              TP_Str(openPrice, 3), TP_Str(closePrice, 3),
                              reason, profit, bank, regime, spread, atr5,
                              spreadOpen, spreadCost, gross);
   TP_CsvAppend(TP_LEGS_CSV, TP_LEGS_HEADER, line);
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
   TP_CsvAppend(TP_CYCLES_CSV, TP_CYCLES_HEADER, line);
  }

#endif // TP_LOGGER_MQH
