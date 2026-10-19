# Why a trend follower after the hedge failed

## What actually killed the hedge

From `ANALYSIS_2.md`, per leg over the whole round-2 period:

| | per leg |
|---|---|
| gross (before cost) | +1.490 |
| spread paid | -0.253 |
| everything else (stop slippage, basket exits, swap) | -1.394 |
| **net** | **-0.156** |

The spread was not the only problem, but it sets the bar: **every leg must
earn 0.253 before it earns anything for us**. With 1,367 legs in two months
the strategy had to beat that 1,367 times, on an instrument whose median
spread is 0.26 and whose 5-minute moves are often smaller.

The lesson is not "find a better hedge". It is: **fewer trades, each one big
enough that the spread is a rounding error.**

## The arithmetic a trend trade answers

Take the target of the baseline preset, 4 x ATR on H1 gold:

| ATR (H1) | stop (1.5 ATR) | target (4 ATR) | spread as % of target |
|---|---|---|---|
| 10.0 | 15.0 | 40.0 | 0.7% |
| 15.0 | 22.5 | 60.0 | 0.4% |
| 20.0 | 30.0 | 80.0 | 0.3% |

Where the hedge paid 0.26 of spread to chase a ~1.5 gross move (17%), the
trend trade pays 0.26 to chase 40-80 (0.3-0.7%). One winner covers the costs
of several losers, so the strategy needs a win rate far below 50% to be
positive.

That is the entire hypothesis, and it is falsifiable: **T1 vs T7_RandomCtl**
with identical exits. If the trend signal cannot beat coin-flipping entries
with the same stops and targets, then the entries add nothing and the idea is
dead - which is exactly what the gates in `DECISION_RULES_2.md` test.

## Sized in risk, not in lots

`ANALYSIS_3.md` showed the hedge EA behaves differently on 100 USD and on
1,000 USD because it trades a fixed 0.01 lot against percentage-based stops.
This EA sizes **0.5% of equity** per trade instead, so the same run means the
same thing at any account size.

There is still a floor, and it is worth stating plainly: on XAUUSD the minimum
lot is 0.01 = 1 ounce, so **one dollar of price move is one dollar of P/L**.
A 20 point stop is therefore **20 USD of risk at the smallest possible size**.
On a 100 USD account that is 20% per trade - there is no way to run this
strategy on 100 USD. The test deposit is **10,000 USD**, where 0.5% is 50 USD
and a 20 point stop sizes to 0.02 lots.

## What would make this fail

* Gold trend-following is crowded and well known; the edge may be small or
  absent in the tested window.
* The test data is M1-built (no real ticks before 2026.10.02), so intrabar
  fills are approximations. Hence the gate requiring a real-tick re-run before
  any live claim.
* A 22-month window can be dominated by one regime. That is why the forward
  half is separate, why the random control exists, and why gate 6 refuses a
  result that rests on a single trade.

If it fails, the honest report is that it failed, and the hedge idea stays
closed.
