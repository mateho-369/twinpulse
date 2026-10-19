# ANALYSIS_1 - first decision batch (XAUUSDm, 2026.08.01 .. 2026.10.19)

**Status: the batch is NOT VALID FOR GATES (data limitation, see 2) and the
decision rules land on rule 3 - stop the hedge idea (see 5).**

> Forward-period figures are deliberately **not** written into this file
> (owner rule: no forward results in the repo). The numbers below are whole
> period or back period only, plus the legs/CSV accounting, which is identical
> for both halves.

---

## 1. What was run

- Symbol **XAUUSDm**, M5, Model 4 (real ticks), deposit 1000 USD, 1:500.
- Period **2026.08.01 .. 2026.10.19** (~2.5 months - deliberately a smoke
  period, not the 4.5-year decision period).
- 8 variants (V1..V8, `tools/run_batch.ps1`), **back and forward as two
  separate tester runs** each (`b26f822`), so both halves have a real tester
  report: 16 runs, `report_back` / `report_fwd` + `TwinPulse_legs_back` /
  `TwinPulse_legs_fwd` per variant.
- 13,462 closed legs in total across the 8 variants.

## 2. Data quality - the blocker

| half | period | History Quality |
|---|---|---|
| back | 2026.08.01 .. 2026.09.21 | **0% real ticks** |
| forward | 2026.09.22 .. 2026.10.19 | **62% real ticks** |

The MT5 `Symbols -> Ticks` dialog for XAUUSDm, asking for 2022.01.03 ..
2026.10.20, returns **2,816,350 ticks from 2026.10.02 to 2026.10.19 only**.
The broker therefore has **no real tick history before 2026.10.02**; every
earlier bar is filled with ticks generated from M1 data.

`docs/DECISION_RULES.md`: *"History Quality below 90% makes the whole batch
NOT VALID FOR GATES"*. That is the case here, so **no gate in this batch may
be used to claim a PASS**. This is a data-source problem, not a code problem:
no amount of rerunning changes it. Real ticks have to be imported from
another source (custom symbol) or a different broker/server used.

## 3. What the batch did verify (independent of tick quality)

The accounting fixes are confirmed:

- `sum(pos_net)` equals the tester report net profit **to the cent for all 16
  runs** (e.g. V1 back `-264.60 = -264.60`, V1 forward `-165.04 = -165.04`).
  This is the end-to-end proof of the bank fix (BUG 1) and of the `pos_net`
  column (BUG 2).
- `spread_cost` is populated on every leg (BUG 3 regression `20281a6` fixed);
  the run's own spread reads median 0.260 / p90 0.260 (legs.csv
  `spread_open`), against the 0.200 reference.
- 0 `bank delta mismatch` warnings.

## 4. Cost structure - the economics, whole period (8 variants)

| variant | gross before spread | spread paid | net |
|---|---|---|---|
| V1_Full | +89.32 | 518.96 | -429.64 |
| V2_FullRollover | +88.30 | 515.24 | -426.94 |
| V3_Pure | +170.08 | 1001.94 | -831.86 |
| V4_OneSide | -64.48 | 210.76 | -275.24 |
| V5_LegB | +18.98 | 212.02 | -193.04 |
| V6_LegA | +6.03 | 310.32 | -304.29 |
| V7_Random1 (control) | +114.26 | 281.52 | -167.26 |
| V8_Random2 (control) | -110.06 | 333.08 | -443.14 |

- **Gross-before-spread PF: 0.95 .. 1.07** for every variant - none reaches
  the 1.10 that `DECISION_RULES.md` requires before a cost round is allowed.
- The spread paid is **3 to 6 times** the whole raw edge: on V1 the strategy
  makes +89.32 before costs over 2.5 months and pays 518.96 in spread. At
  0.01 lot the position size cannot be lowered further to compensate.
- Every variant is **negative in both halves** of the period.
- **The strategy does not beat its own RANDOM control:** the RANDOM variant
  V7 has the highest gross PF of the whole batch (1.07) while the actual
  logic (V1) is at 1.03, and in the only real-tick window V1 loses more than
  V7 in absolute terms. The entry logic is therefore not adding anything
  measurable over random entry; the little the batch shows is consistent
  with cost noise.

## 5. Decision (docs/DECISION_RULES.md)

1. *Any valid PASS* - **no**. The batch is not valid for gates (2), and no
   variant is anywhere near forward PF 1.20, RF 2, both halves positive.
2. *No PASS, but gross-before-spread PF >= 1.10 -> ONE cost round* - **no**.
   The best gross PF in the batch is 1.07 and it belongs to a RANDOM control
   variant; every real variant is <= 1.03.
3. *Otherwise -> stop the hedge idea and say so plainly.*

**=> STOP the hedge idea.**

The honest wording of the caveat: the gates could not be evaluated on this
data, so this is not "the gates failed" - it is "there is no evidence the
idea works, the raw edge is smaller than the spread it has to pay under every
variant, and the logic is indistinguishable from random entry". Getting valid
tick data would be needed to overturn that, and the observed margin is far
too small to expect it to.

## 6. What is worth keeping either way

- The execution/bank/accounting layer is now trustworthy: 16/16 runs match
  the tester reports to the cent, zero bank warnings, no close/modify
  failure floods.
- The batch tooling (`run_batch.ps1` / `summarize_batch.py`) produces a
  valid, resume-safe, two-half measurement with real reports on both sides -
  it can be pointed at another symbol / broker / period without changes.
