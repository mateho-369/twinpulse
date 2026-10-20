# What 50 USD a day means at 0.01 lot

Written before round 1. All numbers are arithmetic, not opinion.

## The unit

`0.01` lot of XAUUSD is **1 ounce**, so **1.00 of price movement = 1.00 USD**.
There is no leverage on the P/L, only on the margin.

**50 USD/day therefore needs 50.00 price units of NET capture, every day.**

## Against the market

Measured on our own 48 days of XAUUSDm samples (the round-2 legs):

| | price units |
|---|---|
| median daily range | **17.5** |
| average daily range | 23.5 |
| p90 daily range | 42.7 |
| largest day | 85.7 |

Requirement as a share of the **median** day: **286%**.

A scalper can extract more than the daily range because it can win on both
sides of an oscillation - but not 2.9x the range, every day, with no losing
days. This is the honest frame for every round: the target is a measurement
of ambition, not a forecast.

## Against the payoff (the real trap)

Symmetric take profit and stop `T`, spread `0.26` paid once per position:

| T | break-even win rate | net per win | net per loss |
|---|---|---|---|
| 1.0 | **63.0%** | +0.74 | -1.26 |
| 1.3 | **60.0%** | +1.04 | -1.56 |
| 2.0 | 56.5% | +1.74 | -2.26 |
| 3.0 | 54.3% | +2.74 | -3.26 |
| 5.0 | 52.6% | +4.74 | -5.26 |
| 8.0 | 51.6% | +7.74 | -8.26 |

A target of `1.0` price unit is **63% win rate just to break even**. That is
the public-gold-EA trap in the owner's notes: 76% winners, losing account.

**This is why the EA refuses a take profit below `5 x spread`** (~1.30 at the
measured 0.26). Below that the broker owns the trade.

## Against the size

| SL (price units) | loss at 0.01 lot | share of a 100 USD account |
|---|---|---|
| 1.5 | 1.50 | 1.5% |
| 2.0 | 2.00 | 2.0% |
| 3.0 | 3.00 | 3.0% |
| 6.0 | 6.00 | 6.0% |

Margin per 0.01 lot of gold at 1:500: **9.00 USD** (4500 / 500).
Keeping the margin level at or above 300% leaves **3.7** positions on 100 USD,
so the cap is **3** (`InpMaxPositions=3`). At 4 positions the margin level is
278%: one ordinary losing sequence triggers a stop-out.

With 3 positions the worst simultaneous loss at a 2.0 stop is 6 USD = 6% of
the account. That is the risk budget the whole design has to live inside.

**The one exception, and its price.** The owner asked for a fixed 2 BUY + 2 SELL
book, which is 4 legs and 36 USD of margin - a 278% margin level on 100 USD.
Those four presets (`S8`-`S11`) therefore run at `InpMinMarginLevel=250`
instead of 300. The worst simultaneous loss at a 2.0 stop becomes 4 x 6 = 24
USD, 24% of the account, and that is the real cost of the fourth leg - not the
margin, the stop-out distance. If `SYMBOL_MARGIN_HEDGED` is 0 on this account
the hedged side costs no margin at all and the fourth leg is free; the EA
prints that number at startup, so the first run settles it.

## What the rounds have to show

Per round, these four numbers decide whether to continue:

1. `net/day` - the gap to 50 is printed every round.
2. `win%` vs `req%` - if the win rate is below its own break-even rate, the
   exits lose before the entry matters, and the fix is the payoff, not the signal.
3. `gross` vs `spread/day` - how much of the gross the broker takes.
4. the **random control** - if random is within noise of the signal, the entry
   adds nothing.

If several rounds leave `net/day` under ~2 USD, the honest conclusion is that
50 USD/day on 100 USD needs far more capital or far more risk than a 100 USD
account can carry - and that will be said, not hidden.
