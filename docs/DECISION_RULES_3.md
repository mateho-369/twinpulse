# DECISION RULES - round 4 (TwinPulse Scalp)

**Frozen 2026-10-20, before the first scalp report exists.** The hedge round
(`DECISION_RULES.md`) and the trend/reversal round (`DECISION_RULES_2.md`) stay
frozen and historical.

## The question

Can an M5 gold scalper in the London-New York overlap earn **~50 USD/day on a
100 USD account at a fixed 0.01 lot**?

## The run

* symbol `XAUUSDm`, chart `M5`, tester model `Model=1` (1-minute OHLC) for the
  fast loop
* **deposit 100 USD**, leverage 1:500
* period **2026.08.01 .. 2026.10.19**, split BACK `2026.08.01 .. 2026.09.21`
  and FWD `2026.09.22 .. 2026.10.19`
* seven presets in `tester/scalp/`: three entry families, two exit variants,
  a **random control** (`S5_Random`, identical exits) and a **session control**
  (`S7_AllDay`, same entry outside the overlap)

## Hard constraints (not gates - the EA does not run without them)

* fixed 0.01 lot, never increased; no martingale, no grid, no averaging down
* **every position carries a broker stop loss from the moment it is opened**
* at most **3 simultaneous positions** (margin level >= 300% on 100 USD)
* take profit never below **5 x spread**; below that the trade is refused
* `AllowLive=false`; on a REAL account the EA refuses to start

## Gates (all on the FORWARD half)

| # | gate |
|---|---|
| 1 | net > 0 |
| 2 | **win rate above the break-even win rate** implied by its own avg win / avg loss |
| 3 | at least **100 closed trades** |
| 4 | equity drawdown <= 35% (a 100 USD scalper needs room, but not unlimited) |
| 5 | beats `S5_Random` by >= **0.20 USD/day**, so the entry is not luck |
| 6 | `sum(pos_net)` and the report net differ only by the tester's own end-of-test closes |

## The target and the honest gap

The target is **50 USD/day**. Every SUMMARY prints the gap:
`best net/day = X vs 50`. Gate 5 is what protects the project from a result
that looks good only because the exits are lucky.

## Stop rules

1. Ten rounds without a variant clearing gates 1-5: **stop and say so**.
2. No parameter is changed after seeing a result without a new dated entry in
   the change log below.
3. No gate is lowered, no date range moved, no forward half reused for tuning.
4. A variant that passes the bar-based test may NOT be called demo-ready until
   the same forward window is reproduced with `Model=4` (real ticks, available
   from 2026.09.22) with the same or better net/day.

## CHANGE LOG

Empty at the start of round 1. Every later change gets its own dated entry,
written before the round it affects.

### 2026-10-20 - tester closes positions at end of test
Observed on this machine: `OnDeinit` close-all does **not** execute under the
tester; MT5 closes the remaining positions itself and the report shows those
deals. Therefore the money check prints `report net - sum(pos_net)` and the
number of end-of-test closes, instead of pretending the CSV is complete.
