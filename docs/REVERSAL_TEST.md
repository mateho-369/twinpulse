# The reversal rule - what the mathematics says before we run it

The owner's rule (2026-10-20), written down exactly:

> buy and sell the same, if one is in profit close it, and if the other one is
> not yet closed, wait until it goes back to profit and close it too. Add a
> trailer that cuts 30%, 60%, 90% to save profit. Stronger, faster.

It is testable, so it is tested - but three things are true before any backtest
runs, and they are worth stating because they decide the outcome.

## 1. Closing the winner destroys the hedge

Open BUY and SELL at the same price P with the same lot. Net exposure: **zero**,
minus the spread.

Price rises to P+X.

* the BUY is closed at **+X** (realised);
* the SELL is still open, entered at P, price now P+X, floating **-X**.

The account now holds **one naked short from P**. There is no hedge any more.
The profit of +X is not a profit from a hedged structure; it is the *entry
price of a new directional trade that someone else chose for us* - and it was
chosen at the worst possible moment, after a move of X in the wrong direction.

So the rule is not "hedge, take the winner". It is:

> win X if the price comes back, lose everything if it does not.

The hedge was an illusion created by the two tickets. Economically the strategy
is: **sell a lottery ticket that pays X, and pay out -infinity when gold keeps
going.** That is why every hedge-and-hold system in existence ends the same
way, and it is why this repo's standing rules forbid it.

## 2. The arithmetic of the bounded version

If we add a real guard L (cut the orphan at -L), each cycle has only two ends:

| outcome | net |
|---|---|
| the orphan returns to break-even | **+X - 0.52** |
| the orphan is cut at -L | **X - L - 0.52** |

Break-even win rate: `p = 1 - (X - 0.52) / L`

| X (winner) | L (guard) | share of cycles that must return |
|---|---|---|
| 3 | 8 | 69% |
| 3 | 15 | 84% |
| 5 | 15 | 70% |
| 8 | 15 | 50% |
| 12 | 15 | 24% |

The wider the guard, the *more* mean reversion is required - a counter-intuitive
result that kills the "just give it room" idea: room costs exactly as much as it
buys.

## 3. What the real gold path says

Reconstructed from the 1,367 legs of the round-2 run (1,044 distinct price
observations of XAUUSDm over 2026.08-2026.10, 4,037 -> 4,673 -> 4,173): after a
move of X away from an entry, how often does the price return to that entry?

| X | returned | worst give-back |
|---|---|---|
| 2 | 90.3% | 636 |
| 5 | 86.9% | 636 |
| 8 | 83.2% | 636 |
| 12 | 76.7% | 636 |
| 20 | 70.3% | 636 |

A 90% hit rate sounds wonderful. It is not, because the losses are unbounded:

* the orphan went more than **100 USD** against a 1,000 USD account in
  **9.7%** of the trials at X=2 and **30.2%** at X=12;
* the worst orphan ran **636 price units = 636 USD on a single 0.01 lot**, i.e.
  **64% of a 1,000 USD account from one leg**;
* with no guard the strategy freezes after **two cycles** - it never gets a
  third, because it is still holding the second orphan.

Running the cycle sequentially with realistic fills (the cut fills at the price
actually seen, not at the ideal level) over the same 2.5 months:

| X | guard | cycles | net on 0.01 lot |
|---|---|---|---|
| 3 | 8 | 174 | **-1,814.85** |
| 5 | 15 | 92 | **-1,460.86** |
| 8 | 30 | 57 | **-1,504.78** |
| 12 | 60 | 33 | **-1,042.41** |
| any | none | 2 | freezes, orphan still open |

Every configuration loses. The loss is not from a bad parameter - it is the
structure.

## 4. The 30/60/90 lock makes it worse, not better

Taking a third at 30% of the target, a third at 60% and the rest at 100%
realises `0.633 X` per winner instead of `X`. The orphan is unchanged.

| X | L | needed without lock | needed with lock | extra |
|---|---|---|---|---|
| 5 | 4 | 50% | 63% | +13 points |
| 8 | 4 | 38% | 50% | +12 points |
| 3 | 3 | 59% | 72% | +13 points |

Locking profit early is not free: it lowers the only thing that pays while the
thing that costs stays the same.

## 5. So why build it at all

Because *measured* beats *argued*. `TwinPulseReversal.mq5` implements the rule
exactly as stated, plus the guard and the ladder as switches, and
`tester/reversal/R1..R6.set` runs it:

| preset | what it is |
|---|---|
| `R1_UserExact` | winner at 3 ATR, orphan held to break-even, guard 15 ATR |
| `R2_Guard5` | the orphan cut at 5 ATR |
| `R3_NoGuard` | **the pure idea** - orphan held forever (the ruin control) |
| `R4_Ladder` | R1 plus the 30/60/90 lock |
| `R5_SmallTarget` | winner at 1.5 ATR |
| `R6_BigTarget` | winner at 6 ATR |

The prediction, written here before the run so it cannot be rewritten
afterwards: **R3 will show a large open loss or a margin stop-out, and no
preset will finish positive on the forward half.** If that is wrong, the
report will say so and I will say so.

## 6. What is *not* wrong with the idea

The instinct behind it is sound: gold ranges most of the time, and taking the
winner in a range is profitable. The mistake is doing it with **two positions
and no stop**, which converts a range strategy into a trend suicide. A range
strategy only works when the loss is capped and the exit is on a signal, not
on hope. That is what the round-3 trend EA tests from the other side: cap the
loss, let the winner run.

`DECISION_RULES_2.md` still governs round 3. This document is a separate,
clearly-labelled experiment; no gate in it is relaxed.
