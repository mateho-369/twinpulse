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
