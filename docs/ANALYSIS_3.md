# ANALYSIS 3 - the same variant on a 100 USD account

**Question asked by the owner (2026-10-20):** start with 100 USD and make
50 USD a day.

**What was run:** `W1_NoShred` (the best variant of round 2), unchanged -
`XAUUSDm`, `0.01` lot per leg, `UseBankShred=false`, leverage 1:500,
deposit **100 USD**, same dates as round 2:

* BACK  2026.08.01 - 2026.09.21
* FWD   2026.09.22 - 2026.10.19

Every number below comes from the MT5 report and the two legs CSVs. The
`sum(pos_net)` of each CSV equals the report's net profit **to the cent**
(-8.47 and -19.84), so the accounting is exact.

`TwinPulse.log` from `Common\Files` was **not** used: it is a leftover from an
older shred-on run (it contains 924 `Shred done` lines, impossible with
`UseBankShred=false`, and 2,081 opens against 86 legs). The tester writes to
its own sandboxed Common folder, so that file says nothing about this run.

## Result

| | BACK | FWD |
|---|---|---|
| deposit | 100.00 | 100.00 |
| net profit | **-8.47** | **-19.84** |
| gross profit / loss | +55.05 / -63.52 | +54.13 / -73.97 |
| profit factor | 0.87 | 0.73 |
| equity drawdown maximal | 16.61% | 22.94% |
| balance drawdown maximal | 19.62% | 28.30% |
| closed legs | 40 | 46 |
| profit trades | 26 (65.00%) | 31 (67.39%) |
| average win / loss | 2.12 / -4.54 | - |
| history quality | 0% real ticks | 62% real ticks |

Final balance of the forward run: **80.16 USD**. Over the two and a half
months the idea lost **28.31 USD on a 100 USD account (-28.3%)**.

There is no day in which the account made 50 USD. The best day of the whole
period was **+4.02 USD**, the worst **-5.21 USD**.

## Why 100 USD behaves worse than 1,000 USD

The same variant, same dates, only the deposit changed:

| | 1,000 USD | 100 USD |
|---|---|---|
| closed legs | 1,367 | **86** (16x fewer) |
| net | -213.79 (-21.4%) | -28.31 (-28.3%) |
| active days | 48 | **11** |
| target (wins) | 509 legs +1,919.05 | 30 legs +97.48 |
| server_close (hard SL) | 404 legs -1,614.21 | 20 legs -35.68 |
| basket target | 427 legs -517.22 | 14 legs -10.30 |
| **daily loss stop** | **0** | **14 legs -44.47** |
| **basket stop** | **0** | **4 legs -36.94** |
| closeby winner / loser | 10 / 10 | 2 / 2 |

**The EA is not scale-free.** `DailyStopPct = 5.0` and `BasketStopPct = 10.0`
are percentages of equity, but the risk per leg is a fixed `0.01` lot. On
1,000 USD a losing leg costs ~0.9% and the buffers are never reached; on
100 USD the same leg costs ~9%, so:

* one stop-out locks the whole trading day (`daily loss stop`, 14 legs);
* a normal hedged basket trips the 10% basket stop before the hedge can work
  (`basket stop`, 4 legs).

Those two exits alone cost **-81.41 USD** - the entire loss and more. The
remaining legs were profitable on their own (`target` +97.48), so on this
account the risk controls, not the entries, produced the loss.

Worst realised day was -5.21 USD = 5.2% of equity, just above the 5% cap: the
day locked on its first bad leg.

**Minimum deposit at which the 5% daily stop would not have fired** (worst
realised day of the 1,000 USD run was 35.05 USD): `35.05 / 0.05 = 701 USD`.
Add the 22% drawdown of round 2 and the practical floor for this EA is
**~1,100 USD**, not 100.

## What 50 USD a day actually requires

50 USD a day over ~22 trading days is ~1,100 USD a month. At realistic,
verifiable returns that needs this much capital:

| monthly return | capital needed for 50 USD/day |
|---|---|
| 1% | 110,000 USD |
| 2% | 55,000 USD |
| 5% | 22,000 USD |
| 10% (excellent, rare) | 11,000 USD |

On 100 USD, 50 USD a day is **50% per day**, i.e. 150% a *week* compounded
(1.5^5 = 7.6x), 5,767 USD after ten trading days and 19 million USD after
thirty. No strategy does this; an EA that "shows" it in a backtest is
curve-fitted and fails live.

## Conclusion

* The hedge idea loses on 100 USD as well, and loses a **larger percentage**
  than on 1,000 USD because the fixed lot meets percentage-based stops.
* 50 USD a day from 100 USD is arithmetically impossible, not merely
  difficult. No parameter change, no lot increase and no new variant of this
  idea changes that - increasing the lot multiplies both sides equally and
  only makes the account die sooner.
* This does not reopen round 2. `DECISION_RULES.md` rule 3 still stands: the
  hedge idea is stopped, no demo, no merge to `main`.
* What the round did produce is a measured number for the future: **this EA
  needs ~1,100 USD to behave as designed, and even then it loses money** -
  the problem is the edge, not the account size.
