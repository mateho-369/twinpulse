# ANALYSIS 4 - round 1, the scalper (read from the round-1 zip, not from a claim)

22 presets, 44 tester runs (back + forward), `Model=1` (M1 OHLC), XAUUSDm,
deposit 100 USD, fixed 0.01 lot, 2026.08.01 .. 2026.10.19.
BACK = 2026.08.01 .. 2026.09.21, FWD = 2026.09.22 .. 2026.10.19.

Every number below was recomputed from `TwinPulse_legs_back.csv` /
`TwinPulse_legs_fwd.csv` (`pos_net`, the deal's own money), not read off a
summary line.

## The answer

**Best average USD/day = 7.83 vs target 50** - `S7_AllDay`, forward half, 19
days. Its back half is **-3.23 USD/day**, so it is not a result.

The mean over all 22 variants is **-4.55 USD/day back, -3.16 forward**. The
random-entry control made **+4.24/day back and -1.11/day forward**. The
correlation between a variant's back-half and forward-half result is
**-0.40**: the ones that did better on one half did worse on the other. That is
noise, not an edge.

## The one table (forward), verbatim from SUMMARY.md

| variant | net/day | median day | best | worst | %days>=50 | %losing | days | trades | win% | req% | DD | final |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| S7_AllDay | 7.83 | -10.21 | 51.64 | -11.91 | 26.3% | 68.4% | 19 | 184 | 58.7% | 50.9% | 20.3% | 248.70 |
| S6_Trail | 3.83 | -10.27 | 62.40 | -14.49 | 15.8% | 73.7% | 19 | 112 | 47.3% | 42.0% | 37.5% | 172.68 |
| S2_WideTP | 3.08 | -10.27 | 56.93 | -14.49 | 15.8% | 73.7% | 19 | 109 | 45.9% | 41.5% | 40.0% | 158.55 |
| S1_Pullback | 1.93 | -10.22 | 54.30 | -14.49 | 10.5% | 73.7% | 19 | 122 | 44.3% | 41.8% | 47.5% | 136.58 |
| S5_Random | -1.11 | -10.24 | 61.49 | -14.84 | 10.5% | 78.9% | 19 | 138 | 41.3% | 42.4% | 47.3% | 78.83 |
| S10_Adaptive | -8.89 | -10.11 | -1.75 | -11.81 | 0.0% | 100.0% | 9 | 37 | 32.4% | 52.3% | 81.7% | 20.00 |
| S8_Hedge4 | -9.11 | -10.18 | -1.75 | -11.81 | 0.0% | 100.0% | 9 | 38 | 31.6% | 51.7% | 83.5% | 17.98 |

(The full 22-row table is in `round1.zip.txt` -> `SUMMARY.md`.)

## Four things the round proved

**1. The take profit never fired.** Exit reasons over all 44 runs: `stop` and
`daily_exit` only, **0 `target` rows**. Every preset carried
`InpTrailStart_ATR=1.20`, including S1, so the trail always closed the leg
before the 2 ATR target. S1 was never the plain TP/SL test it was named after.

**2. The daily loss stop is the typical day.** S7's median day is -10.21 with a
10 USD limit: 21 of 24 back days and 13 of 19 forward days ended at the lock.
The distribution is two spikes - "stop out at -10" and "jackpot at +50" - and
the average is the difference between their frequencies.

**3. Most variants died and the summary used to hide it.** `days` = 9 instead of
19 means the balance fell to ~20 USD, where 0.01 lot can no longer be opened at
250-300% margin level, and the EA stopped taking trades. The old table divided
by whatever days had trades, so a 9-day bust looked like a 19-day result.

**4. The spread is a fixed tax and the stop is a fixed cost.** 0.26 per leg at
0.01 lot; 6-10 legs a day is 1.6-2.6 USD/day = 1.6-2.6% of the account, before
any loss. Average win ~7.1, average loss ~5.1, win rate 41-45%, break-even
41-52%. Everything sits within a few percent of break-even - which is exactly
what a coin flip with a 0.26 tax looks like.

## What this does to the target

50 USD/day at 0.01 lot means **50 price units of net capture per day**. The
median XAUUSDm daily range over the measured 48 days is **17.5**. The best
single day in the whole round was 67.95, and it happened once. The target is
therefore not a tuning problem: at this lot size it needs 286% of the daily
range, every day.

## What round 2 has to answer

One question: **is there any exit that beats its own random twin on both
halves?** Five (TP, SL) pairs with the trail off, each with a random-entry twin
on the identical exit, plus the round-1 anchor and one probe with the daily
stop removed. If nothing beats its twin on both halves, the M5 scalper family
is finished and we say so instead of tuning a coin.
