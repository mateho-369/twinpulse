# ANALYSIS 5 - the 1000 USD run: the first sample nobody died in

Read from `round3.zip.txt` (34 presets, back + forward, `Model=1`).

**What was actually run** - the zip's own `runinfo.txt`:
`sym=XAUUSDm; from=2026.08.01; to=2026.10.19; dep=1000; preset=tester\scalp3`.
So this is the **old 2.6-month window on a 1000 USD account**, not the 12-month
measurement of `docs/ROUND3_PROMPT.md`. The preset folder also holds the 34
variants of `e407018`, not the trimmed 20 of `d277a71` - the machine pulled
before that commit. Both facts matter for what the numbers can say.

## Why this run is worth more than the last two

At 1000 USD nothing died: every variant traded all **19 forward** and **35
back** days, and every final balance sits between 880 and 1149. That is the
first complete 54-day sample in the whole project - the earlier rounds divided
by 7-9 days of a dead account.

## The answer

**best average USD/day = 7.83 vs target 50** (S7_AllDay, forward half).
Over the **whole 54 days** that variant is **+2.57 USD/day**, and its 95%
confidence interval is **[-4.15, +9.28]** - it includes zero.

| variant | 54-day USD/day | 95% CI | forward | back |
|---|---|---|---|---|
| S7_AllDay | **+2.57** | [-4.15, +9.28] | +7.83 | -0.29 |
| S5_Random (coin) | +0.95 | [-5.23, +7.13] | -5.11 | +4.24 |
| S1_Pullback | -3.83 | [-8.54, +0.88] | +1.50 | -6.73 |
| S6_Trail | -2.51 | [-7.97, +2.95] | +3.53 | -5.79 |
| S10_Adaptive | -2.23 | [-6.44, +1.98] | -5.06 | -0.69 |

Across the 34 variants: mean **-3.71 back / -2.13 forward**, and the
**correlation between the halves is -0.40 again**. The back-half winner is the
**random control** (+4.24), the forward-half winner is S7 (-0.29 back). Both
rounds now agree: what wins one half loses the other.

## What that means for 50 USD/day

At 0.01 lot, 50 USD/day needs **50 price units of net capture every day**. The
measured median daily range of XAUUSDm is 17.5; the best day in this entire
54-day sample was 67.95 and it happened once.

| the target on an account of | is this much return |
|---|---|
| 100 USD | 50% per day |
| 1000 USD | **5% per day ≈ 179% per month** |
| 10 000 USD | 0.5% per day ≈ 11% per month |

The best variant, if its edge is real, earns **0.26% per day ≈ 5.5% per month**
on 1000 USD. The target is **20 times that**. It is not a parameter problem and
it is not a backtest-length problem: a 12-month window can narrow the error
bars around +2.57, it cannot move the mean to +50.

To make 50 USD/day at a defensible risk you need roughly **0.10-0.20 lot and a
10 000-20 000 USD account**, i.e. 100-200x the capital, with the same 6% stop
per trade that the last three rounds show losing money more often than not.

## What was broken and is now fixed

The split column was written **after** the leg left the book: 178 of S1's 336
rows and 141 of S8's 650 said `0B0S` - every last-leg trade. "Money per split"
and "average legs" in this round are therefore not usable. `TPS 1.13` stores
the book each leg was opened into and stamps the close row with it. The money
columns were never affected: `pos_net` reconciles with the report to the cent.


## The 12-month run - the answer, measured (2026-10-20)

The owner compiled `TwinPulseONE.mq5` and ran it **visually (every tick)** on
XAUUSDm M5 from `2025.10.20` to `2026.10.19`, **deposit 10 000**, `InpPreset=0`
(`custom` = the baseline pullback, mode 0, entry 0, TP/SL 2.0 ATR, trail on).
The visual test was stopped at `2026.06.18 14:45` and restarted from
`2026.06.19` with a **fresh 10 000**, so the year arrived as two accounts. Both
are read from the saved report and the tester graph:

| segment | days | net USD | USD/day | median | 95% CI | losing days | days >= 50 | worst | best |
|---|---|---|---|---|---|---|---|---|---|
| A 2025.10.20 - 2026.06.18 | 171 | -497.21 | **-2.91** | -10.03 | [-5.69, -0.13] | 86.5% | 9.4% | -10.38 | +51.12 |
| B 2026.06.19 - 2026.10.18 | 88 | -425.06 | **-4.83** | -10.04 | [-7.70, -1.96] | 84.1% | 2.3% | -10.58 | +50.63 |
| **A+B, one 10 000 account** | **259** | **-922.27** | **-3.56** | -10.04 | **[-5.64, -1.48]** | 85.7% | 6.9% | -10.58 | +51.12 |

Final balance as one account: **9 077.73 (-9.22% in a year)**.

Run A's report, 8 months and 866 trades: win rate **36.03%**, average win
**+7.41**, average loss **-5.07**, profit factor **0.82**, expected payoff
**-0.57/trade**, maximal equity drawdown **742.96 (7.38%)**, average holding
time 11 minutes.

**This is the first sample in the project whose confidence interval excludes
zero - and it excludes zero on the wrong side.** The baseline pullback does not
"fail to show an edge"; on 259 days and 866 trades it loses money at a rate
that is statistically distinguishable from zero.

Why it loses, in one line each:

* with +7.41 winners and -5.07 losers the break-even win rate is **40.6%**;
  the entry delivers **36.03%**.
* with a 50 USD daily target and a 10 USD daily loss the day breaks even at
  **16.7%** winning days; the year delivered **6.9%**, and hit the loss stop on
  **85.7%** of days (median day -10.04, i.e. the stop, not the market).

Nothing about that is a parameter problem: the exits are symmetric, the lot is
fixed, and 866 trades is a large sample. **50 USD/day is not reachable by
scaling a negative expectancy.**

The history behind the numbers is 4% real ticks - MT5 generates the ticks from
M1 before 2026.10.02 - so "every tick" here is stricter than M1 OHLC but is not
real-tick truth. That changes the size of the losses, not their sign: the M1-OHLC
runs of the same family lost in the same direction.

## Decision

The M5 scalper family has now been measured on 54 complete days, on an account
that cannot die, with a random control in every cell:

* best expectation **+2.57/day**, CI includes zero
* the coin flip is **+0.95/day**, CI includes zero
* **no separation between strategy and random entry**
* the 50 USD/day target is **20x** the best observed return

That is the stopping rule of `docs/DECISION_RULES_3.md`, met. The direction is
finished as a 100 USD / 0.01 lot plan. What survives is the measurement loop:
the same 34 presets on 12 months and 1000 USD would tighten the error bars; it
will not change the answer.
