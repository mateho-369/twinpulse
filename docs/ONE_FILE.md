# ONE file, every variant - run it by hand

`MQL5/Experts/TwinPulse/TwinPulseONE.mq5`

* compile **1 file**, nothing else
* **38 variants** inside it, chosen with one input, `InpPreset`
* `InpPreset = custom` (the default) = the EA exactly as the inputs say, so
  every old `.set` file still loads and still means the same thing
* fixed 0.01 lot, broker stop on every leg, no grid, no averaging down,
  `AllowLive=false` - unchanged from the measured code

`InpPreset` overrides **11** inputs: mode, entry, TP, SL, trail start, trail
distance, session start, session end, max positions, min margin level, daily
target. Everything else (0.01 lot, spread cap, session hours, news filter,
daily loss 10 USD) is what you see in the inputs.

Generated, not hand-written: `python3 tools/build_one_file.py` reads
`TwinPulseScalp.mq5` + `tester/scalp3/*.set`. Edit those, rerun the tool,
never edit `TwinPulseONE.mq5` (the next build overwrites it).

## The 38 presets

17 variants, each with the 50 USD daily target **on** and **off** (`_N`).
Every round has to answer "does the daily stop help or hide?" so the pair is
always available.

| preset | what it tests |
|---|---|
| `S1_Pullback` | EMA 9/21 pullback, TP 2.0 / SL 2.0 ATR, trail on - the baseline |
| `S2_WideTP` | baseline with TP 3.5 - is the 2.0 target too tight? |
| `S3_MeanRev` | RSI 30/70 reversion, TP 2.5 |
| `S4_Breakout` | 20-bar breakout, TP 2.5 / SL 2.5 |
| `S5_Random` | **control**: coin-flip entry, exits of S2 |
| `S6_Trail` | TP 5.0, the trail does the exiting |
| `S7_Session` | **control**: session filter removed (01-20) |
| `S8_Hedge4` | 2 BUY + 2 SELL, 4 legs, same TP as the baseline |
| `S9_Hybrid` | hedge in the range, directional scalp in the trend |
| `S10_Adaptive` | 3/0, 2/1, 2/2 split from an EMA+ADX+BB score |
| `S11_AdaptiveRnd` | **control**: the same splits, drawn at random |
| `X1_TP20_SL20` | exit pair 2.0/2.0, trail off |
| `X2_TP13_SL20` | 1.3 / 2.0 |
| `X3_TP20_SL13` | 2.0 / 1.3 |
| `X4_TP15_SL15` | 1.5 / 1.5 |
| `X5_TP30_SL15` | 3.0 / 1.5 |
| `X6_MaxPos1` | one leg at a time - do the extra legs pay for themselves? |

Then four more that vary the **daily loss stop** instead of the target. This is
the biggest hole in every earlier round: the 10 USD loss stop was in **all 34**
presets, it fired on **85.7% of days** in the 12-month run, and the worst day of
the entire year was -10.58. Against a 6 USD per-trade stop, 10 USD ends the day
after about two losers - and this EA once had 20 in a row. The strategy has
never actually been measured without that rule.

| preset | day control |
|---|---|
| `Y1_LossOff` | **no day controls at all** - the strategy alone |
| `Y2_LossOff_T50` | no loss stop, 50 USD target kept |
| `Y3_Loss30` | loss stop 30 (5 stops), no target |
| `Y4_Loss30_T50` | loss stop 30, 50 USD target kept |

`S1_Pullback` (loss 10 / target 50) and `S1_Pullback_N` (loss 10 / no target)
are the reference cells of the same 2x2.

## Run it by hand - 5 steps

1. **Pull the repo** on the Windows machine:
   `git pull --ff-only origin arena/7d00bffc-twinpulse`
2. **Copy and compile one file** - in MetaEditor open
   `...\MQL5\Experts\TwinPulse\TwinPulseONE.mq5` and press **F7**.
   Expect **0 errors**. (If the file is not there, copy the whole
   `MQL5\Experts\TwinPulse` folder from the repo into the MT5 data folder.)
3. **Strategy Tester** (Ctrl+R), then:

   | field | value |
   |---|---|
   | Expert | `TwinPulse\TwinPulseONE` |
   | Symbol | `XAUUSDm` |
   | Period | `M5` |
   | Date | `2025.10.20` - `2026.10.19` (12 months) |
   | Model | **1 minute OHLC** (`Every tick` only for the final confirmation) |
   | Deposit | `1000`, currency USD, leverage as on the demo |
   | Input `InpPreset` | the variant, e.g. `S1_Pullback` |

   Everything else stays at its default. Do **not** load a `.set` when you
   pick a preset - the preset writes the values itself.
4. **Run**, then read the report. Repeat with the next `InpPreset`.
5. Each run writes its own CSV in the common folder:
   `TwinPulse_legs_<preset>.csv` - nothing is overwritten between variants.

**Next 4 runs, in this order** - they answer the one open question:
`S1_Pullback` (reference), then `Y1_LossOff`, `Y3_Loss30`, `Y2_LossOff_T50`.
Same symbol, same dates, same 10 000 deposit. If a Y variant is still negative
with the day stop out of the way, there is no edge left to find in these exits.

Then the control set: `S5_Random`, `S11_AdaptiveRnd`, `X1_TP20_SL20`,
`S10_Adaptive`. All 38 is the full survey.

## If the tester is too slow

12 months of M5 is ~74,000 bars per run and each run reloads history. The
batch script does the same work without clicking:
`tools\run_batch.ps1 ... -Expert TwinPulse\TwinPulseONE` - it loads each
`.set` and keeps `InpPreset = custom`, so the two paths give identical runs.

## What to send back

The MT5 report (Save as Report / HTML) or just these numbers per variant:

```
Total Net Profit | Profit Factor | Equity Drawdown Maximal | Total Trades |
Short Trades (won %) | Long Trades (won %)
```

and, if you want the tables built for you, the `TwinPulse_legs_*.csv` files.

Nothing here changes the target debate: this file measures, it does not make
50 USD/day reachable at 0.01 lot. `docs/ANALYSIS_5.md` has the arithmetic.
