# UPGRADE_PLAN - round 2: attack the measured killer (the shred recycle)

**Owner ask: "make it profitable in every month and every day".**

That cannot be promised, and I will not pretend it can. A backtest that shows
a profit in *every* month and *every* day of a multi-year period is, with an
M5 strategy on a 0.26-spread instrument, almost certainly a curve fit: the
parameters get shaped until the noise looks like an edge. It then fails on
live data. So this round is not "tune until green" - it is **one hypothesis,
stated before the run, tested with the same frozen gates**.

---

## 1. What the first batch actually measured (the diagnosis)

From `docs/ANALYSIS_1.md`, whole period, 8 variants, 13,462 legs:

| fact | value |
|---|---|
| gross before spread, V1 | **+89.32 USD** over 2.5 months |
| spread paid, V1 | **518.96 USD** |
| gross edge per leg | **+0.043 USD** |
| spread cost per leg | **~0.25 USD** |
| target legs | 497 legs, **+1,886.37** |
| shred legs | 924 legs, **-1,892.50** |
| server_close legs | 347 legs, -743.89 |

Two numbers are the whole story:

1. **The shred exactly cancels the wins.** +1,886.37 from the legs that reach
   target vs -1,892.50 from the legs the bank shreds. The cycle is a
   zero-sum machine that pays spread on every turn.
2. **The edge per leg is 17% of the cost per leg.** Even with zero shredding,
   +0.043/leg cannot pay 0.25/leg. And the best gross PF of the batch (1.07)
   belonged to the **RANDOM entry control**, not to the strategy (V1 1.03).

So there is no evidence of a directional edge at the M5/4-leg hedge scale.
What can still be fixed is the **structure**: how often we pay the spread, and
who decides when a loser is closed.

## 2. The hypothesis for this round

> The bank/shred recycle is what turns a roughly break-even gross into a
> structural loss: it realises losers early (924 legs, -1,892) while the
> winners are capped at their ATR target (497 legs, +1,886), and every one of
> those 1,421 closes pays spread again.

If that is right, then **turning the shred off** - letting every leg resolve
on its own TP / SL - removes a large part of the loss *without changing the
risk per trade*. That is a testable, single-variable claim.

If the shred is not the problem, the counts above say the strategy has no edge
at this timeframe and the honest answer is to stop (rule 3), not to keep
tuning.

## 3. What was added (code)

| change | why |
|---|---|
| new input `UseBankShred` (**default `true`**) | tests the hypothesis above. Default keeps today's behaviour byte for byte; any existing `.set` runs exactly as before. |
| `TP_Bank_TryShred` returns immediately when it is `false` | the whole recycle path (partial shred, full shred, re-open after shred) is skipped; legs keep their own TP / BE / trail / hard SL / time stop. |
| `tools/run_batch.ps1 -Preset <folder>` | run any folder of `.set` files with the same two-pass (back + forward) harness; the reports go to `<DATA>\reports\<folder name>` so a new round never overwrites the decision batch. |

Nothing else changed. No new lot sizing, no martingale, no wider stop, no
parameter of the decision batch touched.

## 4. The six presets (`tester/upgrade/`)

All six keep **BaseLot = 0.01, HardSL_ATR = 2.5, AllowLive = false** - the
risk per trade is identical to the decision batch. Each one changes **one**
lever, so the result is readable.

| preset | change vs V1 | question it answers |
|---|---|---|
| `W1_NoShred` | `UseBankShred=false` only | is the recycle the killer? |
| `W2_NoShredLong` | W1 + time stop 4 h -> 1 day | do losers need time to come back? |
| `W3_NoShredTarget` | W1 + A 1.0 ATR, B 2.0 ATR, BE 1.0, trail 1.2 | do fewer, larger wins fix the ratio? |
| `W4_TightSpread` | W1 + spread <= 1.5x its 20 min median, max 0.35 | does a cost filter pay for itself? |
| `W5_OneSide` | W1 + `Mode=ONE_SIDE` | half the legs = half the spread: better or worse? |
| `W6_RandomCtl` | W3 exits + **RANDOM entry** | does the entry beat coin-flipping? (control) |

## 5. Rules for round 2 - fixed NOW, before any result exists

They are copied from `docs/DECISION_RULES.md` and are not changed by this
round:

1. Same batch harness: back + forward as two separate runs, Model 4 real
   ticks, 1:1 split of the period at 2/3.
2. Same gates: forward PF >= 1.20, forward max equity DD <= 20%, forward
   recovery factor >= 2, legs >= 200, both halves > 0, and **beats `W6`
   (RANDOM) by >= 0.15 forward PF**.
3. Worse-of-two rule: every net / PF gate is evaluated both as recorded and
   at the 0.20 reference spread; the worse one decides.
4. `History Quality` must be >= 90% in **both** halves or the round is
   **NOT VALID FOR GATES**.
5. One round only. If nothing passes, the answer is rule 3 of
   `DECISION_RULES.md` - stop - and it is not re-run with tweaked parameters.

## 6. The blocker that comes first: real ticks

The broker currently has real ticks only from **2026.10.02** (2,816,350 ticks;
History Quality 0% for the back half, 62% for the forward half). **Running
round 2 on the current data would repeat the same invalid measurement.**

Before `run_batch.ps1 -Preset tester\upgrade` is worth 40 minutes, one of:

- **A.** a broker / server that serves real XAUUSD ticks back to 2022, or
- **B.** imported tick history as a custom symbol (Dukascopy `.csv` ->
  `Import Ticks` in the Symbols dialog, symbol created with the same contract
  size 100, digits 3), or
- **C.** accept a much shorter, **honest** window: only the real-tick part
  (2026.10.02 onwards) - but that is ~2.5 weeks and cannot support a 4.5-year
  decision, only a sanity check.

## 7. Honest expectation

- The strategy currently makes **+0.043 USD per leg before cost** and pays
  **0.25** in spread. Removing the recycle may recover part of the -1,892
  that the shred realises, but it does not create a directional edge.
- My expectation: **W1..W5 will still be negative or flat, and W6 (RANDOM)
  will be close to them.** If that is what the batch shows, the correct
  action is to stop the hedge idea, not to widen a stop or add a filter.
- If, and only if, a W variant beats `W6` by >= 0.15 forward PF with HQ >= 90%
  on both halves, there is something real to take to a 4-week demo.

That is the "best" I can honestly build here: remove a known structural loss,
measure it once, against a control, with the rules frozen before the numbers.
