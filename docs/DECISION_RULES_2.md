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

What replaces the tick gate (see CHANGE LOG below - the "M1 coverage >= 95%"
gate was REMOVED on 2026-10-20 before any round-3 report existed, because the
number cannot be measured from the artifacts a tester run leaves behind):

* every SUMMARY prints a **coverage probe**: how many distinct days produced a
  closed leg, against the weekdays in the window. It is printed, not gated -
  a trend EA legitimately goes two weeks without a trade, so a gap count would
  fail a healthy run.
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

## Reversal experiment gates (frozen before its first report)

`tester/reversal/R1..R7` is a **falsification** experiment, not a candidate
strategy. Its gates are the minimum that would make it worth a second look,
all on the **FORWARD** half:

| # | gate |
|---|---|
| 1 | net profit > 0 |
| 2 | PF >= 1.10 (worse of the recorded and reference-spread series) |
| 3 | at least **30 closed cycles** |
| 4 | equity drawdown <= 20% |
| 5 | **no position left open at the end of the run** |
| 6 | no single cycle may carry more than **25%** of the net |
| 7 | `sum(pos_net)` equals the report net within 1.00 in **both** halves |

`R3_NoGuard` (orphan held forever) is the ruin control. It is expected to end
with an open position or a margin stop-out; that outcome is a result, not a
crash, and it is reported as such.

## CHANGE LOG - every rule change, with the time it was made

All entries below were written **before the first round-3 / reversal report
existed on this machine**. If a later report contradicts one of them, the
report wins and this file is not edited to match.

### 2026-10-20 ~17:10 (Asia/Bangkok) - `Model=2` corrected to `Model=1`
The first draft said `Model=2`. In the MT5 `.ini` `Model=2` is **Open prices
only**, which feeds the EA one price per bar and would have made every ATR
stop untestable. Corrected to `Model=1` (1 minute OHLC) and the mapping
(0/1/2/3/4) written into `tools/run_batch.ps1`. No result existed.

### 2026-10-20 ~18:05 (Asia/Bangkok) - the "M1 coverage >= 95%" gate is REMOVED
**Reason:** it cannot be measured. The tester report's `Bars:` field is the
*chart* timeframe (H1), not M1, so neither the report nor the legs CSV carries
the M1 bar count. Implementing it as a guess would have produced a gate that
either always passes or always fails.
**Replacement:** a printed coverage probe in every SUMMARY (days with a closed
leg vs weekdays in the window) plus the standing rule that no demo or live
claim is allowed without the `Model=4` real-tick re-run of the forward half.
This is a *weaker* guarantee than the original gate and it is recorded as such.

### 2026-10-20 ~18:05 (Asia/Bangkok) - `R4_Ladder` runs at 0.03 lot, with a new control `R7_LadderCtl`
**Reason:** a third of 0.01 lot is 0.0033, below the broker minimum step of
0.01, so `PositionClosePartial` fails and the 30/60/90 ladder would silently
never run - a preset that looks like it tests the ladder while testing
nothing.
**Decision:** `R4_Ladder` runs at **0.03** lot (three real 0.01 steps) and a
matched control `R7_LadderCtl` runs at **0.03** lot with the ladder OFF.
R4 is judged against **R7**, never against R1 (0.01 lot) - comparing different
lot sizes would answer the wrong question.
**Code guard:** `TwinPulseReversal` now closes the whole leg and says so if a
ladder step ever falls below the broker minimum. Partial closes can no longer
fail silently.

### 2026-10-20 ~18:05 (Asia/Bangkok) - `summarize_batch.py` is family-aware
**Reason:** it carried the hedge gates (PF 1.20, RF 2, "STOP the hedge idea")
and would have printed a false verdict for a trend or reversal report.
**Decision:** `--rules {hedge|trend|reversal}`, or detection from the reports
folder name (`decision`/`upgrade` -> hedge, `trend` -> trend,
`reversal` -> reversal). **An unknown folder is a hard error**, never a guess.
Each family prints only its own rulebook's gates and its own verdict text.

### 2026-10-20 ~18:05 (Asia/Bangkok) - open positions at the end are reported, not assumed away
Both new EAs now close everything in `OnDeinit` when running in the tester, and
write that close into the legs CSV (`reason=end_of_test`). `summarize_batch.py`
additionally prints `report net - sum(pos_net)` for every variant, so a leg
left open is visible as a number instead of quietly shrinking the sample.

### 2026-10-20 ~18:05 (Asia/Bangkok) - minimum-deposit line added to every SUMMARY
Every SUMMARY now prints, per variant, the median stop distance of the run and
the account size at which a 0.01 lot (the broker minimum, 1 oz of gold = 1 USD
per 1.00 of price) equals the target risk of `--risk-pct` (default 0.50%):
`min_deposit = 100 x median_stop / risk_pct`. This answers "does this EA fit a
small account" with arithmetic instead of opinion.
