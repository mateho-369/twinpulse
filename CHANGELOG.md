# Changelog

All notable changes of the TwinPulse Hedge EA.
The format follows `Keep a Changelog`, the project uses semantic versioning.

## [Unreleased]

### Fixed

* **The forward half was never measured:** a tester run with `ForwardMode=2`
  saves the BACKTEST report only - the trade list of the saved `report.htm`
  ends at the forward boundary (V1: 2026.09.21 20:16) while the CSVs go on
  to 2026.10.18. `summarize_batch.py` then filled the forward gates from a
  single-column report (BACK PF == FWD PF) or printed `n/a`. The tester
  report also cannot be read when it is UTF-16 (a NUL between every
  character made every label unmatched, so every report field was `n/a`).
  `tools/run_batch.ps1` now runs **backtest and forward as two separate
  tester runs** per variant (`back` = `FromDate .. floor(2/3)`, `fwd` = the
  rest, both `ForwardMode=0`), writes `report_back.htm` /
  `report_fwd.htm` and `TwinPulse_legs_back.csv` / `TwinPulse_legs_fwd.csv`;
  `summarize_batch.py` reads that layout (and still reads the old one),
  decodes UTF-16 reports / CSVs, never copies a single column into the
  forward side, and refuses to give a verdict when the history quality is
  below 90% or the forward report is missing.
* **`sum(pos_net)` vs the report net:** the check compared the whole CSV
  (back + forward) with a backtest-only report, so 5 of 8 variants showed a
  false `**MISMATCH**`. The check now uses only the rows the report covers
  (up to its last trade) - on the owner batch all 8 variants then match to
  the cent (V1 -283.47 = -283.47), which confirms the `pos_net`
  accounting of the bank fix.

* **The batch failed silently (first owner batch: every variant "exit code
  0" in a second, no report, no CSV - `SUMMARY.md` was written from an
  empty folder and even printed "STOP the hedge idea"):**
  `terminal64.exe /config:` is ignored while a terminal is already open,
  so `tools/run_batch.ps1` now refuses to start when a `terminal64`
  process exists, prints the elapsed time of every variant, verifies that
  a report really appeared (the variant folder and both `reports` roots
  are searched) and stops the batch with the last lines of the tester log
  when a variant produced nothing. New `-Only V1_Full` runs a single
  variant. `tools/summarize_batch.py` refuses to write any verdict when
  no variant has a report or CSV rows (**NO DATA**, exit code 3, no
  `SUMMARY*.md` written) instead of judging an empty batch. A partial
  batch (some variants with no data - an interrupted overnight run or
  `-Only`) writes the tables with a **BATCH INCOMPLETE** banner and
  **no verdict**.
* Stop modifications ("Invalid stops" flood): every trailing / break-even
  stop is now validated before it is sent. The new pure helper
  `TP_ClampStop` clamps the stop into the legal region
  (`SYMBOL_TRADE_STOPS_LEVEL` / `SYMBOL_TRADE_FREEZE_LEVEL`), a stop that
  does not improve the current one is not sent at all, and when the price
  already came back through the desired stop the leg is closed at the
  market with the exit reason `STOP_THROUGH` instead of sending an invalid
  modify. `FREEZE_LEVEL` is respected (no modify inside the freeze zone).
* `beDone` is set only after a **successful** stop modification (it was set
  before the request, so a failed modify was never retried correctly).
  The break-even trigger is latched on the peak profit, so a pull back does
  not disarm it.
* Every stop modify attempt (success or failure) is throttled to one per
  two seconds; after `TP_MODIFY_MAX_FAILS` (3) consecutive failures of a
  ticket the EA backs off for `TP_MODIFY_BACKOFF_SEC` (60) seconds and logs
  it once (the old code retried a failing modify on every tick).
* Wrong retcodes in the logs ("failed: 10009 (done)"): after
  `g_trade.OrderSend(request, result)` the code read
  `g_trade.ResultRetcode()`, which is not filled by that overload and
  always showed the stale code of the previous operation. Every `OrderSend`
  now reads `result.retcode` / `result.comment` (with a `GetLastError()`
  fallback) and `g_trade.ResultRetcode()` is only used when a request was
  really sent (`ClearStructures()` + non-zero retcode check).
* Ghost close failures ("Close of ticket ... failed: 10009 (done)",
  "Close By ... failed"): `CTrade::PositionClose/PositionCloseBy/...`
  return `false` without sending anything when the position is already
  gone (server SL/TP or an earlier Close By). Every close / partial close /
  Close By now checks `PositionSelectByTicket` first; a vanished ticket
  marks the leg closed, resyncs the state (`TP_State_SyncPositions`) and is
  booked by `TP_Legs_DetectClosedLegs` as `server_close` - **no failure is
  logged**. Before a Close By both tickets are verified (both exist,
  opposite types, same symbol, same magic), otherwise the winner is closed
  normally.
* `CTrade::ClearStructures()` is a **protected** member of the standard
  library: `g_trade.ClearStructures()` did not compile. `Utils.mqh` now
  declares `CTPTrade : public CTrade` with a public `ResetResult()` that
  wraps `ClearStructures()`, and every close path calls
  `g_trade.ResetResult()`. As a second safety net, when a close / partial
  close / Close By returns `false` the tickets are re-checked with
  `PositionSelectByTicket`: gone -> `TP_CLOSE_GONE`, still there ->
  `TP_CLOSE_FAIL` with the real retcode.
* Break-even arming with a small ATR: the trigger was `BE_ATR * ATR`
  alone, so the price could arm while still below the break even level
  (`entry +/- spread`) and `TP_StopThroughMarket` closed the leg
  immediately as `STOP_THROUGH` at a small loss. The trigger is now
  `TP_BreakEvenArmDistance` = `max(BE_ATR * ATR, spread + min stop
  distance + spread)`: the break even stop must be placeable with room
  the moment it arms.
* Floating point noise at the exact boundary of a stop rule: a raw
  comparison like `MathAbs(market - level) <= freeze * point` failed at
  the exact boundary (`0.030000000000654836 > 0.03`), so a legal modify
  was wrongly refused. Every stop / freeze / stops-level boundary
  decision is now taken in **integer points** (`TP_PointsDelta` /
  `TP_PointsBetween` = `MathRound` of the price difference in points):
  `TP_StopFrozen` (boundary = frozen), `TP_StopThroughMarket` (boundary =
  through), `TP_StopIsBetter` (within one point = not better),
  `TP_ClampStop` (exactly the minimum distance = legal, kept), the
  break-even arm decision `TP_BreakEvenArmed` (boundary = armed), the
  stops-level check of `TP_Exec_OpenLeg` and the never-widen /
  nothing-to-do checks of `TP_Exec_ModifySL`. A 1e-12 difference can
  never flip one of these decisions again.
* Logging performance (a 2-month real-tick backtest went from ~3 minutes
  to 84): every log line did a full `FileOpen` -> `FileSize` -> `FileSeek`
  -> write -> `FileClose` cycle (hundreds of thousands of open/close per
  run) and the timer re-logged unchanged block reasons every second. Now
  every file keeps **one open handle** (`TP_LogFilesOpen` in `OnInit`,
  `FileWriteString`, `TP_LogFilesClose` in `OnDeinit`), `FileFlush` runs
  at most once per 60 s (plus once on close), the size rotation is
  checked at most once per minute, and repeating timer messages are
  logged **once per state change** (`TP_DedupShouldLog` with one
  `lastReason` string per leg: "not re-opened", "not opened",
  "Shred skipped", "MaxTotalLots reached", "Cycle start aborted",
  free margin / OrderSend errors). In the Strategy Tester the INFO level
  is no longer printed to the journal (WARN / ERROR are), the legs /
  cycles CSV logs stay on. The OnDeinit summary counts the written log
  lines and the suppressed duplicates.
* `FILE_COMMON` was passed as the **4th** `FileOpen` argument (the codepage!)
  instead of OR-ed into `open_flags` in `TwinPulseNewsExport.mq5`,
  `Logger.mqh` and `News.mqh`: the signature is
  `FileOpen(name, open_flags, delimiter, codepage)`, so every file went to
  the **local** `MQL5\Files` (and the log / CSV files came out 0 bytes in
  the tester agent folder) instead of `Common\Files`. Every call is now
  `FileOpen(name, FILE_... | FILE_COMMON, ',', CP_ACP)`; `FileDelete` and
  `FileIsExist` already took `FILE_COMMON` as their 2nd argument. The news
  CSV reader now reads real CSV fields (`datetime,impact,currency,event`)
  with the ',' delimiter. The news export flushes every chunk and prints
  the progress per year, so the run can be followed on screen.

### Fixed

* **Spread columns wiped on every open (regression of the bank fix above,
  found in the first owner smoke run: `sum spread_cost = 0`):**
  `TP_Exec_OpenLeg` now records `ticket` / `positionId` from the open
  result, so the next `TP_State_SyncPositions` no longer treats the new
  position as a fresh session and resets `spreadOpen` / `spreadCost`
  that were just captured at the open. Runs made with `05d34d6` have
  `spread_cost = 0` and `gross = pos_net` in `TwinPulse_legs.csv` and
  must be re-run for the cost columns (the bank checks are unaffected).
* **Bank accounting (the bank bug):** `legs[i].realized` was reset to 0
  only at cycle start, so a RE-OPENED leg kept the realised money of its
  previous position and `RegisterClose` booked
  `delta = cumulative(new) - realized(old + new)` - the old money went
  into the bank a second time (84 of 507 shreds in the smoke test; the
  "bank 0.49 -> 3.00 on a realised -0.43" line). Every per-position
  field (`realized`, `booked`, break-even / modify state) now restarts
  with the new position (`TP_State_NewPositionSession`, called from
  `TP_Legs_OpenOne` and from `TP_State_SyncPositions` when the position
  id changes). A runtime WARN `bank delta mismatch` fires when a close
  books more than the position ever moved, and the SelfTest simulates
  close -> re-open -> shred -> close and asserts that the bank equals
  the sum of the realised money. **Earlier test results (smoke3_A /
  smoke4_A) were produced with the bank bug and will not reproduce -
  the shred and basket-target decisions change with the corrected
  bank.**
* "gross before spread" was computed from the bank delta, which is 0 for
  legs closed by a full shred: `TwinPulse_legs.csv` now has a `pos_net`
  column (the full realised P/L of the position from the deal history,
  all OUT deals including partial shreds, plus commission and swap),
  `gross = pos_net + spread_cost`, the OnDeinit totals come from
  `pos_net`, and `tools/summarize_batch.py` uses `pos_net` for every
  net and checks `sum(pos_net)` against the report net profit
  (`**MISMATCH**` in SUMMARY.md when they disagree by more than 1.00).
* `tools/run_batch.ps1` no longer touches tracked files (the run `.ini`
  files are generated into `<DATA>\tester_local\decision\`) and the
  INSTALL `.set` copy is optional (try/catch + warning; the tester
  reads DATA, so a `PermissionDenied` in Program Files is no longer
  fatal). The Close By race ("failed close position #0 buy 0 by
  position #110", one per long run) is confirmed benign in the code:
  the vanished ticket ends as `TP_CLOSE_GONE` + resync and is not
  counted as a failure.
* Every closed leg now appears in `TwinPulse_legs.csv` **exactly once**
  with its real exit reason: `RegisterClose` books a leg only once per
  position (a `booked` flag per leg, cleared when a new position appears),
  the `reason` is taken from the real exit (`cycle_close`, `cycle_closeby`,
  `server_close`, `STOP_THROUGH`, `rollover_flatten`, ...) instead of the
  hardcoded "cycle_close", and a full "Bank Shred" books its own row with
  the reason `shred` (before, those legs were closed but never written to
  the CSV).
* A Close By request is never sent with ticket 0 again: every call checks
  both tickets with the pure `TP_CloseByTicketsOk` (a vanished leg keeps
  its stale ticket and the request went to the server as
  `#0 ... by position #...` -> "Invalid request"). SelfTest covers it.
* `TwinPulse.log`, `TwinPulse_legs.csv` and `TwinPulse_cycles.csv` now get
  a header line when the file is empty (the open call creates a missing
  file, so "the file was created" never told the truth and no header was
  ever written).
* The `exec summary` counters count exactly what is written:
  `log lines written` = `TwinPulse.log` lines, a new `csv rows written` =
  legs / cycles CSV rows (the old one number counted both, and the log
  FILE can hold fewer lines after the 2 MB rotation - a comment says so).

### Added

* `OnDeinit` prints an `exec summary` with the counters for the smoke test:
  modify attempts / failures, closes / failures, Close By count and
  `STOP_THROUGH` exits.
* New inputs `FlattenBeforeRollover` (default **false**, so the existing
  defaults stay comparable) and `RolloverFlattenMinutes` (default 10):
  when enabled, every open leg is closed N minutes before
  `RolloverStartHour` and re-opens / new cycles stay blocked until
  `RolloverEndHour` (the legs held into the rollover were stopped by the
  rollover spread spike). Test `true` vs `false`.
* SelfTest cases for the new pure stop helpers (`TP_StopMinDistance`,
  `TP_ClampStop`, `TP_StopThroughMarket`, `TP_StopIsBetter`,
  `TP_StopFrozen`), including the exact "Invalid stops" scenario of the
  smoke test log, for the rollover window (`TP_Risk_InRolloverBlock`) and
  a `Common\Files` write / read / delete round trip that guards the
  `FileOpen` flag placement.
* `docs/WINDOWS_RUNBOOK.md` (English). The Khmer runbook
  `docs/WINDOWS_RUNBOOK_KM.md` now states the two hard preconditions of
  every tester run: run `TwinPulseNewsExport` once on a live chart first
  (missing file prints "TwinPulse_news.csv not found in Common\Files -
  news filter OFF"), and create `<DATA>\reports` before any tester `.ini`.
* Decision batch (the go / no-go experiment): new inputs `EntryMode`
  (0 = normal, 1 = RANDOM control - starts cycles on one `MathRand` roll
  per new M5 bar with `RandomStartProb`, skipping the entry trigger and
  the regime filter for STARTING only; exits / brakes / session / lot
  management unchanged), `RandomStartProb` (0.02), `RandomSeed` (1) and
  `LegSet` (0 = A+B, 1 = only the A scalp legs, 2 = only the B runners).
  All defaults keep the current behaviour.
* Spread accounting per closed leg: `TwinPulse_legs.csv` has the new
  columns `spread_open`, `spread_cost` (spread x volume x contract size at
  open) and `gross` (net + spread cost), and the `exec summary` prints the
  totals `gross before spread` / `spread paid`.
* Server-time honesty for the batch: `tools/run_batch.ps1` gets
  `-ServerUtcOffset` (Exness = 0) and generates the session / rollover /
  Friday hours in every `.set` from fixed UTC values (rollover 21-24 UTC,
  Friday stop 20 UTC, session as before), so the same UTC windows are
  used on any broker. The hour windows in `Risk.mqh` are midnight-wrap
  aware now (`TP_Risk_InHourWindow`; identical behaviour whenever
  start <= end, SelfTest covers the wrap).
* Cost realism in `tools/summarize_batch.py`: `--ref-spread` (default
  0.20 = the Exness XAUUSDm median) computes `net@ref` from the
  legs.csv `spread_open` column - shown next to every net, and the gates
  use the **worse of the two** cost series (docs/DECISION_RULES.md).
  `SUMMARY.md` starts with the symbol specs and the median / p90 spread
  of the run.
* `MQL5/Scripts/TwinPulse/TwinPulseSymbolInfo.mq5`: prints digits,
  point, contract size, volume min/step/max, stops/freeze level, swap
  long/short, filling modes, hedging yes/no, the server UTC offset
  (`TimeTradeServer - TimeGMT`) and the median / p90 spread of the last
  5 trading days (`CopyTicksRange`), and writes the same text to
  `Common\Files\TwinPulseSymbolInfo.txt` (picked up by the summarizer).
  Both runbooks describe it.
* `tester/decision/` with the 8 fixed variants V1..V8 (FULL, rollover
  flatten, PURE, ONE_SIDE, LegSet B / A, RANDOM seed 1 / 2 - no
  optimisation), `tools/run_batch.ps1` (symbol / dates / deposit are
  parameters, resume-safe overnight runner), `tools/summarize_batch.py`
  (SUMMARY.md with History Quality, BACK + FORWARD net / PF / equity DD /
  recovery factor, legs, gross PF, spread paid, per year / month / exit
  reason / leg, the gate table and the verdict) and the frozen decision
  contract `docs/DECISION_RULES.md`. The Khmer runbook explains the
  overnight run.

## [1.00] - 2026-10-17

### Added

* Modular EA source: `MQL5/Experts/TwinPulse/TwinPulse.mq5` and eleven headers
  in `MQL5/Include/TwinPulse/` (Config, Utils, Logger, State, Regime, Legs,
  Bank, Risk, Execution, News, Panel).
* The four leg hedge cycle (2 BUY + 2 SELL) with the owner rule:
  close the winner, keep the loser, re-open the closed side when the surviving
  side is back at break even.
* `Close By` netting of a winner and its opposite leg when the combined
  result reaches `MinBankUSD` (saves one spread).
* Deterministic regime filter (ER 20, CHOP 14, ADX 14, EMA50 slope on M15,
  EMA50 on H1, ATR5 spike, spread spike, news block) with the five states
  RANGE, TREND_UP, TREND_DOWN, NEUTRAL and CHAOS.
* Profit bank with loss shredding by partial close of the oldest losing leg.
* Hard brakes: real account protection, hedging account check, no martingale,
  broker side stop that is never widened, basket stop 10 %, daily stop 5 %,
  max total lots, margin level 300 %, spread limit, time stop, sessions,
  weekend flatten, high impact news block.
* Three research modes: `TP_FULL`, `TP_PURE_IDEA`, `TP_ONE_SIDE`.
* On chart panel with the mode, the regime, the cycle id, the four legs, the
  bank, the floating and the daily result, the brakes, the margin level, the
  swap estimate and the news state.
* CSV logs in `Common\Files`: `TwinPulse_legs.csv` and `TwinPulse_cycles.csv`,
  plus the text log `TwinPulse.log`.
* `TwinPulseSelfTest.mq5` with 60 checks over the pure functions (lot
  normalisation, cost floor, ER and CHOP on synthetic data, regime
  classification, bank and shred math, re-balance condition, time filters,
  order comment, median).
* `TwinPulseNewsExport.mq5` that exports the high impact USD events of the
  economic calendar from 2018 to now into `Common\Files\TwinPulse_news.csv`.
* Single file build `dist/TwinPulse_single.mq5`, generated by
  `tools/build_single.py` (the only Python of the project, a build helper).
* Tester profiles `Default.set`, `Conservative.set`, `PureIdea.set`,
  `OneSide.set` and `OptimizeFull.set`.
* Tester configurations `tester/backtest_full.ini`, `backtest_pure.ini`,
  `backtest_oneside.ini` and `optimize_full.ini`.
* Documentation: `docs/DESIGN.md`, `docs/DECISIONS.md`, `docs/COMPILE_CHECKLIST.md`,
  `docs/USER_GUIDE_KM.md`, `docs/WINDOWS_RUNBOOK_KM.md`, `README.md`.

### Known limitations

* The EA was **not** compiled in the build environment. MetaEditor 64 was
  installed under Wine, but the compiler aborts under Wine (it fails on a
  trivial test file too), so the compile step has to be done on the owner's
  Windows PC. The sources were statically reviewed against
  `docs/COMPILE_CHECKLIST.md`.
* No backtest was run, therefore **no performance number is claimed**.
* The news filter needs `Common\Files\TwinPulse_news.csv` in the Strategy
  Tester, the MQL5 calendar returns no data there.
* The exchange calendar times are UTC, they are converted with
  `ServerUTCOffsetHours` (default 0.0) into the server time. The value has to
  be checked once on the demo with a known event.
* `ExecutionMode=150` in the tester `.ini` files comes from the specification
  and has to be confirmed in the Strategy Tester dialog.
* In `TP_RISK_PERCENT` mode `MaxTotalLots` has to be raised by hand, it is not
  lifted automatically (see `docs/DECISIONS.md` DC-0012).
