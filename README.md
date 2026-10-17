# TwinPulse Hedge EA (MQL5)

A MetaTrader 5 Expert Advisor for **XAUUSDm on an Exness hedging account**.
A cycle holds **2 BUY + 2 SELL** legs: the winning side is closed with a small
profit, the losing side keeps running, and when it is back at break even the
closed side is re-opened so the hedge is balanced again.

Pure MQL5, no DLL, no WebRequest, no Python inside the EA.

## Quick start (10 lines)

1. Copy `MQL5\*` from this repo into the terminal data folder (`File → Open Data Folder`).
2. Copy `MQL5\Profiles\Tester\*.set` into `<data>\MQL5\Profiles\Tester\`.
3. Compile: `"<MT5>\metaeditor64.exe" /compile:"<data>\MQL5\Experts\TwinPulse\TwinPulse.mq5" /log` (0 errors).
4. Run `TwinPulseSelfTest` on any chart - every line must print `PASS`.
5. Run `TwinPulseNewsExport` once on a live XAUUSDm chart (writes `Common\Files\TwinPulse_news.csv`).
6. Open an XAUUSDm M5 chart once, then run `"<MT5>\terminal64.exe" /config:"<repo>\tester\backtest_full.ini"`.
7. Repeat step 6 for `backtest_pure.ini`, `backtest_oneside.ini` and `optimize_full.ini`.
8. Attach `TwinPulse` to XAUUSDm M5, switch **Algo Trading ON**, inputs = `Default.set`.
9. Keep the account on **Demo** until the gates in `docs/DESIGN.md` (section 9) are green.
10. Only then set `AllowLive = true` by hand, on a small account.

The full step by step guide is in `docs/WINDOWS_RUNBOOK_KM.md` (Khmer) and
`docs/USER_GUIDE_KM.md` (Khmer).

## What is in the box

```
MQL5/Experts/TwinPulse/TwinPulse.mq5        event handlers only
MQL5/Include/TwinPulse/Config.mqh            every input, enums, constants
MQL5/Include/TwinPulse/Utils.mqh             pure helpers + shared trade objects
MQL5/Include/TwinPulse/Logger.mqh            journal, text log, CSV writers
MQL5/Include/TwinPulse/State.mqh             runtime state, rebuild from the positions
MQL5/Include/TwinPulse/Regime.mqh            indicators and the regime classification
MQL5/Include/TwinPulse/Legs.mqh              the four legs, targets, re-balance, cycles
MQL5/Include/TwinPulse/Bank.mqh              profit bank and loss shredding
MQL5/Include/TwinPulse/Risk.mqh              brakes, sessions, spread, margin
MQL5/Include/TwinPulse/Execution.mqh         orders, closes, Close By, retries
MQL5/Include/TwinPulse/News.mqh              calendar and CSV news filter
MQL5/Include/TwinPulse/Panel.mqh             on chart panel
MQL5/Scripts/TwinPulse/TwinPulseSelfTest.mq5 pure function tests (PASS / FAIL)
MQL5/Scripts/TwinPulse/TwinPulseNewsExport.mq5  calendar export for the tester
MQL5/Profiles/Tester/*.set                   Default, Conservative, PureIdea, OneSide, OptimizeFull
dist/TwinPulse_single.mq5                    single file build (all headers inlined)
tester/*.ini                                 backtest_full, backtest_pure, backtest_oneside, optimize_full
tools/build_single.py                        the only Python, it builds dist/TwinPulse_single.mq5
docs/DESIGN.md                               state machine, every input, risk example, gates
docs/DECISIONS.md                            every decision and every ambiguity
docs/COMPILE_CHECKLIST.md                    the self review of every source file
docs/USER_GUIDE_KM.md                        user guide in Khmer
docs/WINDOWS_RUNBOOK_KM.md                   install and test runbook in Khmer
```

Rebuild the single file after every change of the modular sources:

```
python3 tools/build_single.py
```

## Modes

| Mode | Behaviour |
|---|---|
| `TP_FULL` (default) | everything: regime filter, profit bank, loss shredding, brakes |
| `TP_PURE_IDEA` | the owner rule only, the control group of the backtest |
| `TP_ONE_SIDE` | only the side that follows the H1 trend, no hedge |

## Brakes (all on by default)

Real account protection, hedging account check, no martingale (`LotMultiplier`
capped at 1.5 and only with the risk flag), broker side stop on every leg that
is never widened, basket stop 10 % of equity, daily stop 5 % of the start of
day equity, `MaxTotalLots` = 8 x `BaseLot`, minimum margin level 300 %,
maximum spread = min(2 x rolling median, 0.60), time stop 240 minutes,
session and weekend rules, high impact news block.

## Status of this build

* Built and statically reviewed in a sandbox **without MetaEditor**:
  145 functions, 471 call sites, no duplicated identifier, no use before the
  definition, no unbalanced bracket, no MQL4 call (see `docs/COMPILE_CHECKLIST.md`).
* **Not** verified here: the compilation, the Strategy Tester runs and the
  behaviour on a live account. Those need the owner's Windows PC.
* **No result is claimed.** The numbers in `docs/DESIGN.md` section 5 are
  calculations from the broker contract specification, not backtest results.
  Read the gates in `docs/DESIGN.md` section 9 after your own runs.
