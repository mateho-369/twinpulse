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
* **eleven** presets in `tester/scalp/`, each written twice - once with the
  50 USD daily target and once with it switched off (`_N` suffix):
  three entry families, two exit variants, a **random entry control**
  (`S5_Random`), a **session control** (`S7_AllDay`), the fixed 2+2 book
  (`S8_Hedge4`), the hybrid (`S9_Hybrid`), the adaptive book (`S10_Adaptive`)
  and the **random-split control** (`S11_AdaptiveRnd`)

## Hard constraints (not gates - the EA does not run without them)

* fixed 0.01 lot, never increased; no martingale, no grid, no averaging down
* **every position carries a broker stop loss from the moment it is opened**
* at most **3 simultaneous positions** in single mode (margin level >= 300% on
  100 USD: 9.00 USD of margin per 0.01 lot of gold, 27 USD for three legs)
* the four-leg presets (`S8`-`S11`) use `InpMaxPositions=4` and
  `InpMinMarginLevel=250`: four legs need 36 USD of margin, which is 278% of a
  100 USD account. They are the only presets allowed under 300%, the reason is
  written in their `.set` header, and a fourth leg is still refused if the
  broker charges full margin for the hedged side
* take profit never below **5 x spread**; below that the trade is refused
* `AllowLive=false`; on a REAL account the EA refuses to start

## Gates (all on the FORWARD half)

| # | gate |
|---|---|
| 1 | net > 0 |
| 2 | **win rate above the break-even win rate** implied by its own avg win / avg loss |
| 3 | at least **100 closed trades** |
| 4 | equity drawdown <= 35% (a 100 USD scalper needs room, but not unlimited) |
| 5 | beats `S5_Random` by >= **0.20 USD/day**, so the entry is not luck. A `_N` variant is compared with `S5_Random_N`, never with the target-on control |
| 7 | **both halves non-negative**: the BACK net/day must be > 0 too. Added 2026-10-20 after round 1 measured a **-0.40** correlation between the halves across 22 variants - a forward-only pass on 19 days is noise |
| 5b | `S10_Adaptive` must also beat `S11_AdaptiveRnd` by >= **0.20 USD/day**, otherwise the market score does not beat a coin toss and the score is removed |
| 6 | `sum(pos_net)` and the report net differ only by the tester's own end-of-test closes |

## The target and the honest gap

The target is **50 USD/day**. Every SUMMARY prints the gap:
`best net/day = X vs 50`. Gate 5 is what protects the project from a result
that looks good only because the exits are lucky.

## Daily stop semantics (2026-10-20)

The daily stop is measured on **closed plus floating** P/L. On breach the EA
**closes every leg**, writes those rows with reason `daily_exit` and opens
nothing until the next server day. `InpDailyTargetUSD=0` disables it. Both
settings are run for every preset, so the effect of the stop is measured
instead of assumed.

## Round 2 - the exit, and its own control (written 2026-10-20, before the run)

Round 1 found that the **take profit never fired** in 44 runs: every preset
carried the 1.2/1.0 trail, so S1 was not the plain TP/SL test it claimed to be.
Round 2 changes the exit only, and gives every exit its own random twin:

| preset | TP / SL | trail | purpose |
|---|---|---|---|
| X1_TP20_SL20 | 2.0 / 2.0 | off | clean 1:1 |
| X2_TP13_SL20 | 1.3 / 2.0 | off | target at the 5x-spread floor |
| X3_TP20_SL13 | 2.0 / 1.3 | off | tight stop, ~40% needed |
| X4_TP15_SL15 | 1.5 / 1.5 | off | 1:1 smaller |
| X5_TP30_SL15 | 3.0 / 1.5 | off | 2:1, ~34% needed |
| X1..X5 `_Random` | same | off | **the twin**: same exit, coin entry |
| X6_Trail | 2.0 / 2.0 | 1.2/1.0 | the round-1 engine, anchor |
| X7_TP20_NoDayStop | 2.0 / 2.0 | off | is the 10 USD daily lock helping? |
| S7_AllDay | 2.0 / 2.0 | 1.2/1.0 | round-1 anchor |

**The stopping rule for this direction.** If no exit beats its own random twin
by >= 0.20 USD/day on **both halves**, the M5 scalper family is finished: we
say so plainly instead of tuning a coin, and the next work is either a
different timeframe or a different market.

## Round 3 - a measurement round on 1000 USD (written 2026-10-20, before the run)

Rounds 1 and 2 could not answer the question they were asked, because the
account died first: at 100 USD a 6 USD stop is 6% and a 10 USD daily stop is
10%, so 9 of 22 variants in round 1 and 8 of 13 in round 2 stopped trading
inside 7-9 days. A 7-day sample cannot separate an edge from a coin.

Round 3 therefore changes **the account size and the window, and nothing else**:
20 presets that each answer a distinct question, the same inputs, the same lot
of **0.01**, the same stops in price units, over **2025.10.20 .. 2026.10.19** -
twelve months, split 2/3 back / 1/3 forward. At 1000 USD the daily stop is 1%
and the daily target 5%, which is a sane risk profile, and the whole year can
run to the end instead of dying in week two.

This is a **measurement**, not a tuning round and not a demo:

* no gate moves; gate 7 (both halves non-negative) still decides
* a result here is not a licence to trade - it is the first honest sample
* if no variant is positive on both halves and beats its own control, the M5
  scalper family is finished and ANALYSIS_5 says so in one paragraph

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

### 2026-10-20 - gate 7 added after round 1
Round 1: 22 variants, cross-half correlation **-0.40**, random control beat the
strategies on the back half (+4.24 vs -4.55 USD/day). A forward-only gate on 19
days cannot separate an edge from a coin, so **gate 7** now requires the back
half to be non-negative as well. This makes S7_AllDay's +7.83/-3.23 a fail; it
was the only variant that passed before. The gate is stricter, never looser,
and it is written here before round 2 runs.

### 2026-10-20 - the round-1 extension (BUY/SELL book + daily stop)
Added before any report was seen: `InpMode` 0-5, the adaptive split
(`3/0, 2/1, 2/2, 1/2, 0/3` from EMA slope + ADX + Bollinger position),
the close-all daily stop, the `split` and `open_legs` CSV columns, and the
eleven presets in both target settings. Nothing above was loosened: gate 5
still needs +0.20 USD/day over the entry control, and gate 5b now protects the
score itself from being a coin toss.

### 2026-10-20 - tester closes positions at end of test
Observed on this machine: `OnDeinit` close-all does **not** execute under the
tester; MT5 closes the remaining positions itself and the report shows those
deals. Therefore the money check prints `report net - sum(pos_net)` and the
number of end-of-test closes, instead of pretending the CSV is complete.
