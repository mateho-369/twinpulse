# TwinPulse Hedge EA - decision rules

**These rules are fixed BEFORE the decision batch results exist and must NOT
be changed after the results are in.** They are the contract for the go / no-go
decision on the hedge idea.

## The batch (tools/run_batch.ps1)

- Symbol / dates / deposit are parameters of `tools/run_batch.ps1`
  (defaults: XAUUSDm, 2022.01.01, 2026.09.30, 1000). Use the broker / symbol
  with REAL tick history - History Quality below 90% makes the whole batch
  **NOT VALID FOR GATES**.
- M5, Model 4 (every tick based on real ticks), `ForwardMode=2`
  (forward = the last 1/3 of the period; forward_start = from + (to-from)*2/3).
- File log OFF, legs/cycles CSV logs ON.
- Exactly 8 variants, no optimisation, no hand tuning:

| variant | settings |
|---|---|
| V1_Full | FULL mode (control: current behaviour) |
| V2_FullRollover | FULL + FlattenBeforeRollover=true |
| V3_Pure | Mode=1 (PURE_IDEA, regime filter off) |
| V4_OneSide | Mode=2 (ONE_SIDE) |
| V5_LegB | FULL + LegSet=2 (only the B runner legs) |
| V6_LegA | FULL + LegSet=1 (only the A scalp legs) |
| V7_Random1 | FULL + EntryMode=1 (RANDOM control), seed 1 |
| V8_Random2 | FULL + EntryMode=1 (RANDOM control), seed 2 |

## Gates (per variant)

| gate | threshold | source |
|---|---|---|
| forward profit factor | >= 1.20 | report, FORWARD column |
| forward max equity drawdown | <= 20% | report, FORWARD column |
| forward recovery factor | >= 2 | report, FORWARD column |
| legs | >= 200 | legs.csv, whole period |
| both halves positive | first AND second half of from..to net > 0 | legs.csv |
| beats the RANDOM control | forward PF - better of V7/V8 forward PF >= 0.15 | report (n/a for V7/V8) |

A variant PASSES when all its gates pass.

## Decision

1. **Any valid PASS** -> trade the SIMPLEST passing variant (order:
   V1, V2, V3, V4, V6, V5, V7, V8) on a **4-week demo**, then stop tuning.
2. **No PASS, but gross-before-spread PF >= 1.10** (legs.csv `gross` column)
   -> **ONE cost round**: at most 3 changes (spread handling / transaction
   costs), rerun the batch ONCE. No other tuning.
3. **Otherwise** -> stop the hedge idea and say so plainly.

`tools/summarize_batch.py` writes these rules into
`reports/decision/SUMMARY.md` automatically (verdict section).
