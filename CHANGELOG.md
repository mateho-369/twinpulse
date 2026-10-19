# Changelog

All notable changes of the TwinPulse Hedge EA.
The format follows `Keep a Changelog`, the project uses semantic versioning.

## [Unreleased]

### Fixed

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

### Added

* `OnDeinit` prints an `exec summary` with the counters for the smoke test:
  modify attempts / failures, closes / failures, Close By count and
  `STOP_THROUGH` exits.
* SelfTest cases for the new pure stop helpers (`TP_StopMinDistance`,
  `TP_ClampStop`, `TP_StopThroughMarket`, `TP_StopIsBetter`,
  `TP_StopFrozen`), including the exact "Invalid stops" scenario of the
  smoke test log.
* `docs/WINDOWS_RUNBOOK.md` (English). The Khmer runbook
  `docs/WINDOWS_RUNBOOK_KM.md` now states the two hard preconditions of
  every tester run: run `TwinPulseNewsExport` once on a live chart first
  (missing file prints "TwinPulse_news.csv not found in Common\Files -
  news filter OFF"), and create `<DATA>\reports` before any tester `.ini`.

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
