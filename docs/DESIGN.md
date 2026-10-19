# TwinPulse Hedge EA - Design

Version 1.00 - pure MQL5, no DLL, no WebRequest, no Python inside the EA.

---

## 1. What the EA does

A **cycle** is a set of four positions on one symbol with one cycle id:

| Leg | Slot | Side |
|-----|------|------|
| `BUY_A`  | A | BUY  |
| `BUY_B`  | B | BUY  |
| `SELL_A` | A | SELL |
| `SELL_B` | B | SELL |

* The side that reaches its target is closed with a small profit (**banked**).
* The opposite leg of the same slot keeps running.
* When the surviving side is back at break even (within `RebalanceTolUSD`),
  the closed leg is re-opened, so the hedge is balanced again (2 BUY + 2 SELL).
* The same rule is applied to BUY and to SELL, the logic is symmetric.

Everything else (regime filter, profit bank, loss shredding, brakes, sessions,
news, time stop) is an addition on top of that owner rule.

---

## 2. State machine (text)

```
                         ┌───────────────────────────────────────────────┐
                         │                 IDLE                         │
                         │  no open leg of this magic on this symbol     │
                         └───────────────┬───────────────────────────────┘
                                         │  timer (1 s)
                                         │  • regime = RANGE (FULL mode)
                                         │  • price within 0.5 x ATR14(M15)
                                         │    of the Bollinger(20,2) middle line
                                         │  • spread ≤ min(2 x median, 0.60)
                                         │  • session allowed, brakes clear
                                         ▼
                         ┌───────────────────────────────────────────────┐
                         │             CYCLE OPENED                     │
                         │  4 legs, one cycle id, one SL per leg         │
                         │  bank = 0, realized = 0                       │
                         └───────────────┬───────────────────────────────┘
                                         │  OnTick
      ┌──────────────────────────────────┼───────────────────────────────────┐
      │                                  │                                   │
      ▼                                  ▼                                   ▼
┌───────────────┐            ┌────────────────────┐              ┌────────────────────┐
│ TARGET HIT    │            │ RUNNER MANAGEMENT  │              │ TIME STOP          │
│ leg A or B    │            │ BE → trail (leg B) │              │ loser > 240 min    │
└───────┬───────┘            └────────────────────┘              └─────────┬──────────┘
        │                                                                │
        │  mirror open, same volume,                                    │ shred if the bank
        │  combined P/L ≥ MinBankUSD ?                                   │ covers it, else close
        ▼                    │                                           │
   ┌─────────┐               │                                           │
   │ CLOSE BY │───────────────┴───────────────────────────────────────────┘
   └────┬────┘
        │
        ▼
┌──────────────────────┐   winner closed alone   ┌──────────────────────┐
│ LEG CLOSED           │────────────────────────►│ LEG CLOSED           │
│ bank += realised     │                         │ bank += realised     │
└──────────┬───────────┘                         └──────────┬───────────┘
           │                                                │
           └────────────────────┬───────────────────────────┘
                                │  timer (1 s)
                                │  RE-BALANCE CHECK
                                │  • a leg of the cycle is flat
                                │  • the surviving side ≥ -RebalanceTolUSD
                                │  • the mirror leg ≥ -RebalanceTolUSD
                                │  • regime allows the side (RANGE → both,
                                │    TREND → with trend side only)
                                │  • spread ok, brakes ok, 60 s cooldown
                                ▼
                        ┌───────────────────────────┐
                        │ RE-OPEN THE MISSING LEG   │──► back to CYCLE OPENED
                        └───────────────────────────┘

CYCLE CLOSED (all legs) happens when:
  • basket target  : realized + floating ≥ CycleTargetUSD (per 0.01 lot)
  • basket stop    : realized + floating ≤ -10 % of equity
  • daily stop     : equity ≤ 95 % of the start of day equity   → pause until next day
  • friday flatten : Friday 20:45 server time
  • mode ONE_SIDE  : the trend side is flat and the trend flipped
```

### Leg level state

Every leg runs through this small state machine:

```
OPEN ──target──► CLOSED (reason "target" or "closeby_winner")
 │  │
 │  └── time stop ─► CLOSED (reason "time_stop")
 │
 ├── break even (leg B, +0.6 x ATR5)  ─► SL = entry + spread
 ├── trailing    (leg B, 0.8 x ATR5)   ─► SL follows the best price, never widened
 └── hard SL (2.5 x ATR5, broker side) ─► CLOSED (reason "server_close")
```

---

## 3. Inputs

All inputs are in `MQL5/Include/TwinPulse/Config.mqh`.
`Mode`: `0 = TP_FULL`, `1 = TP_PURE_IDEA`, `2 = TP_ONE_SIDE`.
`RiskMode`: `0 = TP_RISK_FIXED`, `1 = TP_RISK_PERCENT`, `2 = TP_RISK_OFF`.

### General

| Input | Default | Range / comment |
|---|---|---|
| Magic | 26101701 | 1..999999999, must be unique per chart |
| Mode | TP_FULL | FULL / PURE_IDEA / ONE_SIDE |
| AllowLive | false | real accounts do not trade while this is false |
| ShowPanel | true | on chart panel |
| EnableFileLog | true | `Common\Files\TwinPulse.log` |
| VerboseLog | false | print INFO lines in the journal |
| TimerSeconds | 1 | 1..10 |
| DeviationPoints | 30 | 0..100, max deviation of market orders |
| MaxOrderRetries | 3 | retries for requote / price changed / off quotes |

### Legs and sizing

| Input | Default | Range / comment |
|---|---|---|
| LegsPerSide | 2 | 1..2 (MaxLegs = 4) |
| BaseLot | 0.01 | 0.01..1.00, normalised to the volume step |
| LotMultiplier | 1.0 | 1.0..1.5, > 1.0 only with `IUnderstandMartingaleRisk` |
| IUnderstandMartingaleRisk | false | must be true for any escalation |
| RiskMode | TP_RISK_FIXED | FIXED / PERCENT / OFF |
| LegRiskPct | 0.5 | 0.1..2.0 % of equity per leg (PERCENT only) |
| MaxTotalLots | 0.08 | 8 x BaseLot, hard cap of all open lots |

### Targets and exits

| Input | Default | Range / comment |
|---|---|---|
| TargetA_ATR | 0.6 | 0.3..1.5, leg A target in ATR5 |
| TargetB_ATR | 1.5 | 1.0..3.0, leg B hard target in ATR5 |
| BE_ATR | 0.6 | 0.4..1.0, break even trigger of leg B |
| Trail_ATR | 0.8 | 0.5..1.2, trailing distance of leg B |
| HardSL_ATR | 2.5 | 1.5..3.5, broker side stop of every leg |
| CostFloorSpreadMult | 3.0 | 1..10, every target is at least N x spread |
| CycleTargetUSD | 2.0 | 1..4, basket target per 0.01 lot |
| MinBankUSD | 0.30 | 0.1..2, minimum combined P/L for Close By per 0.01 lot |
| RebalanceTolUSD | 0.10 | 0.05..0.5, re-balance tolerance per 0.01 lot |
| ShredStepLot | 0.01 | 0.01..0.05, lot step used when shredding |
| MaxLoserMinutes | 240 | 30..1440, time stop of a losing leg |

### Regime

| Input | Default | Range / comment |
|---|---|---|
| RegimeERPeriod | 20 | 10..40, efficiency ratio period on M15 |
| ErRange | 0.30 | 0.15..0.45, RANGE if ER below |
| ErTrend | 0.40 | 0.25..0.60, TREND if ER above |
| ChopRange | 55.0 | 50..62, RANGE if CHOP above |
| AdxRange | 22.0 | 15..30, RANGE if ADX below |
| AdxTrend | 28.0 | 20..40, TREND if ADX above |
| AtrSpikeRatio | 2.0 | 1.5..3.0, CHAOS if ATR5 / median ATR5 above |
| SlopeBars | 10 | 5..20, EMA50 slope lookback on M15 |
| BBPeriod | 20 | 10..40, Bollinger period on M15 |
| BBDev | 2.0 | 1.5..2.5, Bollinger deviation |
| BBRangeATR | 0.5 | 0.2..1.5, distance to the middle line for a new cycle |

### Brakes

| Input | Default | Range / comment |
|---|---|---|
| BasketStopPct | 10.0 | 2..30, basket stop in % of equity |
| DailyStopPct | 5.0 | 1..20, daily stop in % of the start of day equity |
| MinMarginLevelPct | 300.0 | 100..1000, minimum margin level for new opens |
| MaxSpreadPrice | 0.60 | 0.20..1.00, absolute spread limit in price |
| SpreadMedianMult | 2.0 | 1.2..4.0, limit = N x rolling median spread |
| SpreadSampleSec | 5 | 2..30, spread sampling period |
| SpreadWindowMin | 20 | 5..60, rolling median window |

### Sessions, news, display

| Input | Default | Range / comment |
|---|---|---|
| SessionStartHour | 0 | 0..23 server time |
| SessionEndHour | 21 | 1..24 server time |
| RolloverStartHour | 21 | no new cycle / re-open from this hour |
| RolloverEndHour | 24 | ... to this hour (exclusive) |
| FridayStopHour | 20 | no new cycle from this hour on Friday |
| FridayFlattenHour | 20 | flatten hour on Friday |
| FridayFlattenMinute | 45 | flatten minute on Friday |
| FlattenBeforeWeekend | true | close everything before the weekend |
| FlattenBeforeRollover | false | close all legs before the rollover window (owner tests true vs false) |
| RolloverFlattenMinutes | 10 | 1..60, flatten N minutes before RolloverStartHour, blocks re-opens until RolloverEndHour |
| ReopenCooldownSec | 60 | 10..600, cooldown between two re-opens |
| UseNewsFilter | true | block around high impact USD news |
| NewsMinutesBefore | 15 | 0..60 |
| NewsMinutesAfter | 15 | 0..60 |
| NewsCsvFile | TwinPulse_news.csv | file in `Common\Files` |
| ServerUTCOffsetHours | 0.0 | -12..12, offset of the server clock versus UTC |
| PanelFontSize | 9 | 7..14 |
| WriteCsvLogs | true | `TwinPulse_legs.csv`, `TwinPulse_cycles.csv` |
| FeePerLotRoundTurn | 0.0 | manual commission estimate, 0 = broker data |

---

## 4. The regime (FULL mode only)

Evaluated on every **closed** M15 bar, the direction comes from H1.

| Regime | Condition | Behaviour |
|---|---|---|
| CHAOS | ATR5 / median(ATR5,100) > `AtrSpikeRatio`, or spread > 2 x median, or inside a news block | no open of any kind |
| RANGE | CHOP(14) > `ChopRange` and ER(20) < `ErRange` and ADX(14) < `AdxRange` | full hedge cycling, this is the owner idea |
| TREND_UP | (ER > `ErTrend` or ADX > `AdxTrend`) and EMA50(M15) slope > 0 and price > EMA50(H1) | only the BUY side is re-opened |
| TREND_DOWN | (ER > `ErTrend` or ADX > `AdxTrend`) and EMA50(M15) slope < 0 and price < EMA50(H1) | only the SELL side is re-opened |
| NEUTRAL | everything else | no new cycle, open legs are managed only |

* ER (efficiency ratio) = |P(t) - P(t-n)| / sum(|P(i) - P(i-1)|) over 20 closed M15 bars.
* CHOP (choppiness index) = 100 x log10(sum TR / (max high - min low)) / log10(n) over 20 bars.
* EMA50 slope = (EMA50 now - EMA50 10 bars ago) / ATR(14, M15), the unit is ATR per 10 bars.
* `ServerUTCOffsetHours` is only used to convert the calendar times (UTC) into server time.
  The session logic always uses the **server** time of the terminal.

---

## 5. Risk example, XAUUSDm, 0.01 lot

Gold on Exness: contract size 100 oz per lot, tick 0.01, tick value 1.00 USD per lot.
Therefore **0.01 lot = 1 oz = 1.00 USD per 1.00 price move** (0.001 USD per point).
The EA always uses the broker values (`SYMBOL_TRADE_TICK_VALUE`,
`SYMBOL_TRADE_TICK_SIZE`), so the money is correct on any broker.

Assume a median spread of 0.20 (the owner's research) and ATR(14) on M5 = 0.35.

| Item | Formula | Value |
|---|---|---|
| Hard stop distance | 2.5 x ATR5 | 0.875 price = 0.88 USD per 0.01 lot |
| Worst loss of one leg (stop + spread) | 0.875 + 0.20 | 1.075 USD per leg |
| Worst basket, all four legs stopped | 4 x 1.075 | **4.30 USD** |
| Net loss of a fast one way move (hedge works) | 4 x spread | 0.80 USD |
| Target of leg A | max(0.6 x ATR5, 3 x spread) | max(0.21, 0.60) = 0.60 USD |
| Target of leg B | max(1.5 x ATR5, 3 x spread) | 0.60 USD |
| Break even of leg B | 0.6 x ATR5 | 0.21 USD |
| Basket target (4 x 0.01) | 4 x 2.00 | 8.00 USD |

### Account of 1000 USD (deposit 1000, leverage 1:500, price 2400)

| Item | Value |
|---|---|
| Margin per 0.01 leg | 2400 x 0.01 x 100 / 500 = **4.80 USD** |
| Margin of the full hedge (4 legs) | 19.20 USD (the broker may charge less for the hedged side, `OrderCalcMargin` decides) |
| Margin level | 1000 / 19.20 = 5208 % (the brake is 300 %) |
| Basket stop 10 % | 100 USD |
| Daily stop 5 % | 50 USD |
| Worst basket (4 stops) | 4.30 USD = 0.43 % of the equity |
| Consecutive losing cycles before the daily stop | about 11 (50 / 4.30) |
| Consecutive losing cycles before the basket stop | about 23 (100 / 4.30) |

### Account of 10000 USD (RiskMode = PERCENT, LegRiskPct = 0.5)

| Item | Value |
|---|---|
| Risk per leg | 50 USD |
| Lot per leg | 50 / (0.875 x 100) = 0.571 → 0.57 (volume step 0.01) |
| Margin per leg | 0.57 x 100 x 2400 / 500 = 273.60 USD |
| Margin of the full hedge | 1094.40 USD, margin level 914 % |
| Worst loss of one leg | 0.57 x 0.875 = 49.90 + spread 0.20 x 57 = 11.40 → 61.30 USD |
| Worst basket (4 legs) | 245 USD = 2.45 % of the equity |
| Basket stop 10 % | 1000 USD (the basket stop is not reached before the daily stop) |
| Daily stop 5 % | 500 USD |

> **Important:** `MaxTotalLots` defaults to 0.08 (8 x BaseLot). In PERCENT mode the
> lot of 0.57 is far above that cap, the EA then refuses to open the leg
> ("max total lots" in the log). Either keep `RiskMode = FIXED` (the default) or
> raise `MaxTotalLots` to at least `4 x lot` before using PERCENT mode.

---

## 6. Safety brakes (all are ON by default)

| Brake | Rule | Action |
|---|---|---|
| Real account | `ACCOUNT_TRADE_MODE = REAL` and `AllowLive = false` | no order at all, red panel with the reason |
| Hedging account | `ACCOUNT_MARGIN_MODE != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING` | no order, red panel |
| Terminal / account | `TERMINAL_TRADE_ALLOWED`, `ACCOUNT_TRADE_ALLOWED`, `ACCOUNT_TRADE_EXPERT` | no order, red panel |
| Symbol | `SYMBOL_TRADE_MODE` disabled or close only | no order, red panel |
| No martingale | `LotMultiplier > 1.0` without the risk flag | the multiplier is forced back to 1.0 |
| Max legs | 4 legs (2 per side) | a leg is never opened twice |
| Max total lots | `MaxTotalLots` | no open above the cap |
| Broker side stop | every leg gets an SL at open | the SL is never widened afterwards |
| Basket stop | cycle loss > 10 % of equity | close the cycle, no new cycle until the next day |
| Daily stop | equity < 95 % of the start of day equity | close everything, pause until the next server day |
| Margin level | < 300 % | no new open |
| Spread | spread > min(2 x rolling median, 0.60) | no new open |
| Time stop | a losing leg is older than 240 min | shred with the bank, otherwise close |
| Sessions | no new cycle and no re-open 21:00..23:59 server time | no order |
| Weekend | Friday 20:00 no new cycle, Friday 20:45 flatten everything | no order / all closed |
| News | +-15 min around high impact USD events | no open |
| Market checks | `OrderCheck` before every order, filling mode from `SYMBOL_FILLING_MODE`, deviation 30, 3 retries | order is rejected instead of sent blind |

---

## 7. Files, logs and the panel

```
MQL5/Experts/TwinPulse/TwinPulse.mq5        event handlers
MQL5/Include/TwinPulse/Config.mqh            every input, enums, constants
MQL5/Include/TwinPulse/Utils.mqh             pure helpers, shared trade objects
MQL5/Include/TwinPulse/Logger.mqh            journal, text log, CSV writers
MQL5/Include/TwinPulse/State.mqh             runtime state, rebuild from positions
MQL5/Include/TwinPulse/Regime.mqh            indicators and regime classification
MQL5/Include/TwinPulse/Legs.mqh              the four legs, targets, re-balance
MQL5/Include/TwinPulse/Bank.mqh              profit bank and loss shredding
MQL5/Include/TwinPulse/Risk.mqh              brakes, sessions, spread, margin
MQL5/Include/TwinPulse/Execution.mqh         orders, closes, Close By, retries
MQL5/Include/TwinPulse/News.mqh              calendar and CSV news filter
MQL5/Include/TwinPulse/Panel.mqh             on chart panel
MQL5/Scripts/TwinPulse/TwinPulseSelfTest.mq5 pure function tests
MQL5/Scripts/TwinPulse/TwinPulseNewsExport.mq5   calendar export
dist/TwinPulse_single.mq5                    single file build
```

CSV logs (in `Common\Files`):

* `TwinPulse_legs.csv` - one row per closed leg:
  `time, cycle, leg, side, volume, open_price, close_price, reason, profit, bank, regime, spread, atr5`
* `TwinPulse_cycles.csv` - one row per finished cycle:
  `time, cycle_id, start_time, end_time, regime, legs_opened, legs_closed, realized, bank, shredded, reason, spread, atr5`

Panel (top left, can be switched off): mode, regime, cycle id, the four legs with
their floating P/L, bank, shredded, floating, daily P/L, equity, the brake state,
the margin level, the swap estimate, the news state and the re-open cooldown.

---

## 8. Tester configurations

| File | Mode | Set file |
|---|---|---|
| `tester/backtest_full.ini` | FULL | `MQL5\Profiles\Tester\Default.set` |
| `tester/backtest_pure.ini` | PURE_IDEA | `MQL5\Profiles\Tester\PureIdea.set` |
| `tester/backtest_oneside.ini` | ONE_SIDE | `MQL5\Profiles\Tester\OneSide.set` |
| `tester/optimize_full.ini` | FULL, genetic | `MQL5\Profiles\Tester\OptimizeFull.set` |

Common keys: `Symbol=XAUUSDm`, `Period=M5`, `Model=4` (every tick based on real
ticks), `ExecutionMode=150`, `Deposit=1000`, `Currency=USD`, `Leverage=1:500`,
`FromDate=2022.01.01`, `ToDate=2026.09.30` (last day of the previous month),
`ForwardMode=2` (1/3 forward), `ReplaceReport=1`, `ShutdownTerminal=1`, `Visual=0`.
The optimisation uses `Optimization=2` (genetic) and `OptimizationCriterion=6`
(the custom criterion of `OnTester`).

`OnTester()` returns `RecoveryFactor x min(ProfitFactor, 3) x sqrt(trades / 100)`
and 0 when there are less than 200 trades or the equity drawdown is above 25 %.

The optimiser touches only 8 inputs: `TargetA_ATR`, `TargetB_ATR`, `BE_ATR`,
`Trail_ATR`, `HardSL_ATR`, `ChopRange`, `ErRange`, `CycleTargetUSD`.

---

## 9. Gates before the owner uses real money

**Gate 1 - demo forward test.** On the FORWARD period (the last 1/3 of the test
range) and after all costs, the FULL mode must show:

| Metric | Requirement |
|---|---|
| Profit factor | >= 1.2 |
| Max equity drawdown | <= 20 % |
| Recovery factor | >= 2 |
| Closed legs | >= 200 |
| Worst day | not worse than the daily stop (5 % of the start of day equity) |
| Comparison | FULL beats PURE_IDEA and ONE_SIDE on the recovery factor |

**Gate 2 - demo.** At least 4 weeks on the Exness demo with the same inputs as
the tester. Compare the live weekly result with the tester week, and write both
numbers down every week. A live week that is much worse than the tester week
means the fill model of the tester is too optimistic.

**Gate 3 - real money.** Only after gate 1 and gate 2 are green, with
`AllowLive = true` set by hand and a small account.

If a gate fails, change one thing at a time (the 8 optimised inputs) and run the
backtest again. Never change the brakes to make a result look better.
