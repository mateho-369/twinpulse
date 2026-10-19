# TwinPulse Hedge EA - Windows Runbook (English)

Step by step guide to install, compile and test the EA on a Windows PC.
The full Khmer version is `docs/WINDOWS_RUNBOOK_KM.md`.

**Two preconditions before ANY Strategy Tester run** (see sections 4 and 5):

1. Run `TwinPulseNewsExport` once on a **live** chart so that
   `Common\Files\TwinPulse_news.csv` exists. Without it the tester prints
   `TwinPulse_news.csv not found in Common\Files - news filter OFF` and the
   news filter is silently disabled for the whole run.
2. The folder `<DATA>\reports` must **exist** before any tester `.ini` is
   started (`mkdir "<DATA>\reports"`), because every `.ini` writes its report
   to `Report=reports\...`.

---

## 0. Paths

| Name | Path |
|---|---|
| `REPO` | the folder that contains `MQL5`, `dist`, `tester`, `docs` |
| `<INSTALL>` | the MetaTrader 5 install folder, e.g. `C:\Program Files\MetaTrader 5` |
| `<DATA>` | the terminal data folder - `File -> Open Data Folder`, then copy the path |

Typical values:

```
REPO    = C:\TwinPulse
INSTALL = C:\Program Files\MetaTrader 5
DATA    = C:\Users\<user>\AppData\Roaming\MetaQuotes\Terminal\<HASH>
```

> Always use the data folder opened by **Open Data Folder** of the running
> terminal, the `<HASH>` differs between terminals.

---

## 1. Copy the files into the terminal

### 1.1 MQL5 sources

```
xcopy "<REPO>\MQL5\*" "<DATA>\MQL5\" /E /I /Y
```

This copies `MQL5\Experts\TwinPulse\TwinPulse.mq5`, the headers
`MQL5\Include\TwinPulse\*.mqh` and the scripts `MQL5\Scripts\TwinPulse\`
(`TwinPulseSelfTest.mq5`, `TwinPulseNewsExport.mq5`).

### 1.2 Tester profiles

```
xcopy "<REPO>\MQL5\Profiles\Tester\*.set" "<DATA>\MQL5\Profiles\Tester\" /Y
xcopy "<REPO>\MQL5\Profiles\Tester\*.set" "<INSTALL>\MQL5\Profiles\Tester\" /Y
```

### 1.3 Optional: single file build

```
copy "<REPO>\dist\TwinPulse_single.mq5" "<DATA>\MQL5\Experts\"
```

---

## 2. Compile (0 errors required)

```
"<INSTALL>\metaeditor64.exe" /compile:"<DATA>\MQL5\Experts\TwinPulse\TwinPulse.mq5" /log
"<INSTALL>\metaeditor64.exe" /compile:"<DATA>\MQL5\Scripts\TwinPulse\TwinPulseSelfTest.mq5" /log
"<INSTALL>\metaeditor64.exe" /compile:"<DATA>\MQL5\Scripts\TwinPulse\TwinPulseNewsExport.mq5" /log
"<INSTALL>\metaeditor64.exe" /compile:"<DATA>\MQL5\Experts\TwinPulse_single.mq5" /log
```

The compile log is written next to each source. **0 errors** are required
(warnings are allowed but must be read).

---

## 3. Self test (every line must be PASS)

1. Open any chart (e.g. EURUSD M1).
2. Drag `TwinPulseSelfTest` from `Navigator -> Expert Advisors` onto the chart.
3. Click **OK** (no Algo Trading needed for a script).
4. The **Expert** tab must show `PASS` on every line and `ALL TESTS PASSED`.

If any `FAIL` appears, do **not** use the EA and send the full output back.

---

## 4. News export - run ONCE on a live chart BEFORE any tester run

> **Required before every tester run.** The Strategy Tester has no economic
> calendar data. If `Common\Files\TwinPulse_news.csv` is missing, the tester
> prints `TwinPulse_news.csv not found in Common\Files - news filter OFF`
> and the news filter is switched off for the whole run, so the result does
> not include the news blocks.

1. Open a **XAUUSDm** chart on a live (or demo) account.
2. Drag `TwinPulseNewsExport` from `Navigator -> Scripts` onto the chart.
3. The script writes `Common\Files\TwinPulse_news.csv` (high impact USD
   events from 2018 to now, server times).
4. Verify the file exists: `File -> Open Data Folder -> MQL5\Files`, or
   `<DATA>\..\Common\Files\TwinPulse_news.csv`.
5. Re-run the script from time to time to refresh the event list.

---

## 4b. Symbol info - run once on the batch symbol

1. Open a chart of the batch symbol (e.g. **XAUUSDm**) on a live (or demo)
   account.
2. Drag `TwinPulseSymbolInfo` from `Navigator -> Scripts` onto the chart.
3. The script prints digits, point, contract size, volume min / step / max,
   stops / freeze level, swap long / short, filling modes, hedging
   yes / no, the server UTC offset (`TimeTradeServer - TimeGMT`) and the
   median / 90th percentile spread of the last 5 trading days
   (`CopyTicksRange` real ticks) into the journal, and writes the same
   text to `Common\Files\TwinPulseSymbolInfo.txt`.
4. Keep that file: `tools/summarize_batch.py` shows it as the symbol specs
   at the top of `SUMMARY.md`. Use the printed `server UTC offset` as the
   `-ServerUtcOffset` parameter of `tools\run_batch.ps1` (Exness = 0), so
   the session / rollover / Friday hours of the `.set` files describe the
   same UTC windows on any broker.

---

## 5. Strategy Tester with the `.ini` files

0. **Create the folder `<DATA>\reports` first** - every `.ini` writes its
   report to `Report=reports\...` and the tester cannot save the report
   (or does not start correctly) when the folder is missing:

   ```
   mkdir "<DATA>\reports"
   ```

   Also confirm that `Common\Files\TwinPulse_news.csv` exists (section 4).

1. Open one **XAUUSDm M5** chart first (downloads the history).
2. Run one of:

   ```
   "<INSTALL>\terminal64.exe" /config:"<REPO>\tester\backtest_full.ini"
   "<INSTALL>\terminal64.exe" /config:"<REPO>\tester\backtest_pure.ini"
   "<INSTALL>\terminal64.exe" /config:"<REPO>\tester\backtest_oneside.ini"
   "<INSTALL>\terminal64.exe" /config:"<REPO>\tester\optimize_full.ini"
   ```

3. Wait for the terminal to finish (`ShutdownTerminal=1` closes it).
4. The reports are written to `<DATA>\reports\`.

> `ToDate=2026.09.30` in the `.ini` files is the last day of the month
> before the build date. Update it when a newer period is wanted.

After a smoke test, open the `Expert` journal of the tester and check the
`exec summary` line printed by the EA in `OnDeinit`:

```
exec summary: modify attempts N, modify failures N, closes N, close failures N, Close By N, STOP_THROUGH N
```

With the stop/close fixes the modify failures and close failures must be
near zero, and no `Invalid stops` flood may appear in the log.

---

## 5b. Decision batch (V1..V8) - `tools\run_batch.ps1`

> **MetaTrader 5 must be completely closed** (tray icon too) before the
> batch starts. `terminal64.exe /config:` is ignored while a terminal is
> already open: the new process only forwards the command line to the
> running instance and exits with code 0 without running anything (all 8
> variants "succeed" in a second and write nothing). The script now
> refuses to start when a `terminal64` process exists.

1. Check the pipeline once with a single variant (~2 minutes) before the
   overnight run:

   ```powershell
   powershell -ExecutionPolicy Bypass -File tools\run_batch.ps1 -Symbol XAUUSDm `
       -FromDate 2026.08.01 -ToDate 2026.10.19 -Deposit 1000 `
       -InstallDir "C:\Program Files\MetaTrader 5" `
       -DataDir "<DATA>" -Only V1_Full
   ```

   A healthy run prints `report + 2 CSV copied to ...`. A variant without
   a report stops the batch and dumps the last lines of the tester log
   (the tester writes no report when it never started).

2. Run the whole batch (resume-safe, the finished variants are skipped):

   ```powershell
   powershell -ExecutionPolicy Bypass -File tools\run_batch.ps1
   ```

3. Summarize:

   ```powershell
   python tools\summarize_batch.py --data "<DATA>" --from <from> --to <to> `
       --symbol XAUUSDm --contract-size 100 --ref-spread 0.20
   ```

   When no variant has any data, `summarize_batch.py` prints
   **NO DATA** and writes nothing - an empty folder never produces a
   verdict.

---

## 6. Demo account (Exness)

1. Open a **XAUUSDm M5** chart.
2. Enable `Algo Trading` and `Allow live trading` in the EA dialog.
3. Drag `TwinPulse` onto the chart and load `Default.set`.
4. The red panel appears at the bottom left with the full state.

Stay on the **Demo** account until every gate is confirmed.

---

## 7. Troubleshooting

| Sign | Cause | Action |
|---|---|---|
| `TwinPulse_news.csv not found in Common\Files - news filter OFF` | news file missing in the tester | run `TwinPulseNewsExport` once on a live chart **before** the tester run (section 4) |
| tester writes no report | `<DATA>\reports` missing | `mkdir "<DATA>\reports"` before running any `.ini` (section 5, step 0) |
| **10030** (invalid fill) | filling mode mismatch | the EA picks the mode from `SYMBOL_FILLING_MODE` and retries with the next one; check the log with `VerboseLog=true` |
| **10019** (no money) | not enough free margin | lower `BaseLot` / `MaxTotalLots`, `MinMarginLevelPct` also protects |
| **"not hedging account"** | `ACCOUNT_MARGIN_MODE` is not `RETAIL_HEDGING` | open a hedging account; the EA never trades on netting |
| **"Market closed"** | weekend or market close | the EA retries at the next open |
| **"too many requests"** | too many orders | do not raise `MaxOrderRetries` / `TimerSeconds`; do not run several EAs on the same account |
| tester does not start | history / `.ini` | open XAUUSDm M5 once, download history (`View -> Symbols`), check `ExpertParameters`, never use `Visual=1` with `/config` |
| batch: all variants `exit code 0` in a second, no report / no CSV | MetaTrader 5 was still open, `/config` was ignored | close MT5 completely; the script now refuses to start in that state (section 5b) |
| `summarize_batch.py`: **NO DATA** | the batch produced nothing | do not read a verdict into it - fix the batch first (section 5b) |
| many `Invalid stops` / `SL modify ... failed` lines | this must not happen after the stop fixes | send the log back: it proves an unfixed execution bug |

---

## 8. Files to keep after a run

| Folder | Content |
|---|---|
| `<DATA>\MQL5\Experts\TwinPulse\TwinPulse.ex5` | compiled EA |
| `<DATA>\MQL5\Scripts\TwinPulse\TwinPulseSelfTest.ex5` | compiled self test |
| `<DATA>\MQL5\Scripts\TwinPulse\TwinPulseNewsExport.ex5` | compiled news export |
| `<DATA>\MQL5\Experts\TwinPulse_single.ex5` | compiled single file build |
| `Common\Files\TwinPulse.log` | text log (includes the `exec summary`) |
| `Common\Files\TwinPulse_legs.csv` | closed legs |
| `Common\Files\TwinPulse_cycles.csv` | cycles |
| `Common\Files\TwinPulse_news.csv` | exported news |
| `<DATA>\reports\*.htm` | tester reports |
