# DECISION RULES - round 3 (TwinPulse Trend)

**Frozen 2026-10-20, before any round-3 result exists.** Nothing in this file
may change once the first report of this round has been produced. Round 2 was
decided under `DECISION_RULES.md`, which stays frozen and historical; this
file governs the new, independent idea.

## The question

Does a trend follower on XAUUSD H1 have an edge that survives a forward test
and beats a random entry with identical exits?

## The experiment

Eight presets in `tester/trend/`, one change at a time around a baseline:

| preset | what it is |
|---|---|
| `T1_Trend` | baseline: EMA 50/200, ADX >= 22, stop 1.5 ATR, target 4 ATR |
| `T2_Fast` | EMA 20/100, ADX 20 |
| `T3_Slow` | EMA 100/300, ADX 25 |
| `T4_WideStop` | stop 2.5 ATR, target 6 ATR |
| `T5_NearTarget` | target 2 ATR |
| `T6_NoADX` | the ADX filter removed |
| **`T7_RandomCtl`** | **control: random entry, identical exits to T1** |
| **`T8_LongCtl`** | **control: always long, identical exits to T1** |

Risk is 0.5% of equity per trade, one position, no hedge, no averaging, no
martingale. The stop is placed with the order and is never widened.

## The run (fixed before any result)

* symbol `XAUUSDm`, chart `H1`, tester model `Model=1` (1-minute OHLC)
* **deposit 10,000 USD**, leverage 1:500
* period **2026.01.01 .. 2026.10.19**, split
  BACK `2026.01.01 .. 2026.07.11` and FWD `2026.07.12 .. 2026.10.19`
* the reversal experiment (`tester/reversal`) runs the same dates and deposit

## Pass gates (all must hold, on the FORWARD half only)

| # | gate | why |
|---|---|---|
| 1 | net profit > 0 | a strategy that loses is not a strategy |
| 2 | profit factor >= 1.10 | a margin of at least 10% over the cost of trading |
| 3 | PF beats `T7_RandomCtl` by >= **0.15** | proves the *signal* earns the money, not the exit mechanics |
| 4 | at least **30** closed trades | fewer than 30 is luck, not a sample |
| 5 | equity drawdown <= **20%** | survivable without a margin call |
| 6 | largest single win <= **40%** of gross profit | the result must not rest on one lucky trade |
| 7 | `sum(pos_net)` equals the report net within 1.00, in **both** halves | the accounting must be provably exact |

Failing any single gate = **FAIL**. There is no "close enough", no partial
pass, no re-run with better dates.

## Data model (stated before the results)

This EA decides on **H1 bar close** and exits at ATR multiples, so it is run
with `Model=1` (1-minute OHLC), not `Model=4` (every tick).

> Correction, made before the first round-3 run and recorded here so it
> cannot look like a post-result change: the first draft of this file said
> `Model=2`. In the MT5 `.ini` `Model=2` is **Open prices only** - it would
> feed the EA one price per bar. The intended model is `Model=1`.

That is deliberate and it is not a lowered gate. The tick-realism gate in
`DECISION_RULES.md` existed because the hedge EA resolved every leg on a
sub-second price - wrong ticks changed the answer. Here the entries are bar
closes and the exits are bar-based, so the model that matters is M1 bars, and
M1 OHLC is the *conservative* choice (it fills stops at the worst price inside
each minute).

What replaces the tick gate:

* **M1 bar coverage >= 95%** of the expected minutes over the tested period.
  The report's bar count is checked against the calendar. Below 95% the run is
  **NOT VALID FOR GATES**.
* A variant that passes may be described as **"passed the bar-based test"**.
  It may **not** be called profitable, live-ready or demo-ready until a
  `Model=4` real-tick re-run of the forward half reproduces a positive net.
  That second run is required before any demo account is touched.

## Stop rules

1. If no variant passes all seven gates: the trend idea is **stopped**. No
   demo, no merge to `main`, no further parameter rounds on it.
2. Parameters may not be changed after seeing a result. A new round needs a
   new frozen document written before its first run.
3. No gate is ever lowered, and no date range is moved to flatter a report.
4. Every claim must name the control: "T1 beat the random control by X" is a
   claim we can make; "T1 is profitable" is not, without the tick re-run.
5. The forward half is never re-used as a tuning set. If we tune on it, it
   stops being a forward test and the round is void.

## Reporting

Results are reported as a table with, for every variant: forward net, forward
PF, forward trades, forward equity DD, the gap to `T7_RandomCtl`, and the
`pos_net` check. Nothing is reported that is not in a pasted report or CSV.
