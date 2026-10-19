# ANALYSIS_2 - the upgrade round: the shred hypothesis, tested

**Status: the round-2 hypothesis was CONFIRMED (the bank shred is half of the
loss), no variant comes close to the gates, and the owner accepted the stop
under `docs/DECISION_RULES.md` rule 3.** The batch is also NOT VALID FOR GATES
on data quality (History Quality 0% / 62%), which is recorded, not hidden.

> Forward-period numbers are deliberately **not** written into this file
> (owner rule: no forward results in the repo). Everything below is either
> the back half or a whole-period aggregate from `TwinPulse_legs.csv`.

---

## 1. What was tested and why

`docs/UPGRADE_PLAN.md` stated one hypothesis before any result existed:

> "The bank/shred recycle is what turns a roughly break-even gross into a
> structural loss: it realises losers early while the winners are capped at
> their ATR target, and every one of those closes pays spread again."

The decision batch had shown the raw shape: 497 target legs +1,886.37 against
924 shred legs -1,892.50. If the hypothesis holds, switching the shred off
- with the risk per trade unchanged - must remove a large part of the loss.

Six presets, one lever each (`tester/upgrade/`), all with BaseLot 0.01,
HardSL_ATR 2.5 and AllowLive=false:

| preset | lever |
|---|---|
| W1_NoShred | `UseBankShred=false` only |
| W2_NoShredLong | W1 + time stop 4 h -> 1 day |
| W3_NoShredTarget | W1 + A 1.0 ATR, B 2.0 ATR, BE 1.0, trail 1.2 |
| W4_TightSpread | W1 + skip opens above 1.5x the median spread |
| W5_OneSide | W1 + ONE_SIDE |
| W6_RandomCtl | W3 exits + RANDOM entry (control) |

Every preset really ran with its settings - the `Inputs:` block of each
`report_back.htm` was checked one by one (`UseBankShred=false` in all six,
`Mode=2` only in W5, `EntryMode=1` only in W6, `MaxLoserMinutes=1440` only in
W2/W3/W5/W6, `TargetA_ATR=1.0` only in W3/W6).

## 2. Result 1 - the hypothesis holds (back half, identical tick stream)

| | V1_Full (shred on) | W1_NoShred | change |
|---|---|---|---|
| closed legs | 1,273 | 910 | -363 |
| net | **-264.60** | **-94.56** | **+170.04** |
| gross before spread | +63.94 | **+140.60** | +76.66 |
| gross PF | 1.04 | **1.06** | +0.02 |
| gross per leg | +0.050 | **+0.155** | 3.1x |
| spread per leg | 0.258 | 0.258 | unchanged |

Switching the recycle off **halved the loss** with the same risk per trade and
the same cost per leg. The shred was indeed converting a near break-even gross
into a structural loss.

## 3. Result 2 - two of the six levers do nothing

| preset | result | meaning |
|---|---|---|
| W2_NoShredLong | identical to W1 | **no leg ever reaches the 4 h time stop** - the `MaxLoserMinutes` lever is dead in this market |
| W4_TightSpread | identical to W1 | **the spread never exceeds 1.5x its 20 min median in the hours the EA trades** - the spread filter cannot fire |

Both are useful negatives: they remove two candidate "improvements" from any
future round without spending another run on them.

## 4. Result 3 - where the money actually goes now (W1, whole period)

| exit reason | legs | net |
|---|---|---|
| target | 509 | **+1,919.05** |
| server_close | 404 | **-1,614.21** |
| basket target | 427 | **-517.22** |
| STOP_THROUGH | 7 | -14.13 |
| closeby_winner | 10 | +12.72 |
| closeby_loser | 10 | 0.00 |

With the shred off the loss moves to two places:

1. **`server_close` -1,614.21** - legs that run all the way into the hard
   stop. The 2.5 ATR stop is hit often enough to eat the target wins.
2. **`basket target` -517.22** - the basket closes 427 legs for a net loss.
   A "basket target" that closes a basket at a loss is a contradiction: the
   basket close is fired on the pair P/L (`MinBankUSD`) rather than on the
   money the basket actually made, so a losing leg drags the winning legs of
   the same basket down with it.

That is the honest description of the remaining problem. It is **not** fixed
by this round, and fixing it would be a new idea, not a continuation of this
one.

## 5. Result 4 - the entry logic does carry something, but not enough

W3 (real entry, larger targets) against W6 (the same exits with a RANDOM
entry) is the control that decides whether the entry signal is worth anything
at all. Every variant was negative in both halves, so neither can pass, but
the comparison is still informative and is recorded here as a heads-up rather
than as a verdict.

The detail (forward PF figures) stays out of the repo by the owner rule; what
matters for the decision is that **the raw edge per leg is a few cents against
a 0.25 spread per leg**, in every configuration tested. That ratio is the
reason no variant can reach the gates, and it is a property of the strategy
family (4 legs, M5, 0.26 spread), not of a parameter value.

## 6. Decision

| rule | condition | result |
|---|---|---|
| 1 | any valid PASS | none (and the batch is not valid for gates) |
| 2 | no PASS, gross-before-spread PF >= 1.10 | best is **1.06** |
| 3 | otherwise | **STOP the hedge idea** |

**The owner chose rule 3 (accept the stop).**

What that means concretely:

- The hedge EA is **not** taken to a demo account and is **not** merged to
  `main`. PR #2 stays open as the record of the work.
- No further parameter rounds on this idea. Not because the numbers were
  inconvenient, but because the rule said so **before** the numbers existed.
- The remaining two loss sources found in section 4 are documented for
  whoever picks this family up again; they are not a licence to keep tuning.

## 7. What is genuinely reusable

The engineering under the strategy is in good shape and is the part worth
keeping:

| asset | state |
|---|---|
| execution layer | stop / close / Close By paths verified, 0 modify failures, 0 close failures, 0 `bank delta mismatch` |
| bank + `pos_net` accounting | `sum(pos_net)` == tester report net **to the cent in every run of both rounds** |
| `tools/run_batch.ps1` | two-pass (back + forward) harness, resume-safe, preset folders, refuses to start with MT5 open, fails loudly instead of writing an empty verdict |
| `tools/summarize_batch.py` | UTF-16 reports, inline label parsing, variant discovery, worse-of-two cost rule, no verdict on incomplete or invalid data |
| docs | `DECISION_RULES.md` (frozen), `ANALYSIS_1.md`, `UPGRADE_PLAN.md`, this file, `DECISIONS.md` DC-0065..DC-0075 |

Those are the pieces a different strategy would need anyway.
