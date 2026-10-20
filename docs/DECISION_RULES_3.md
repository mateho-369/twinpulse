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
