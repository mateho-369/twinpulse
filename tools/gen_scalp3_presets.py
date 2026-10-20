#!/usr/bin/env python3
"""
The 34 presets of the ONE-FILE survey.

Everything the project has learned is now measured in a single compile:
MQL5/Experts/TwinPulse/TwinPulseONE.mq5 carries all 34 variants as an
InpPreset enum, and these .set files are the same 34 for anyone who would
rather load a file. `tools/build_one_file.py` reads THIS folder, so the enum
and the .set files can never drift apart.

What changed against the 34 presets of round 3 (e407018):

* the multi-leg modes (S8 hedge4, S9 hybrid, S10 adaptive, S11 adaptive-random)
  now run the SAME 2.0 ATR take profit as the single-leg baseline instead of
  the 3.0 ATR hedge target, so "more legs" and "wider target" are no longer
  the same experiment;
* X6_Trail duplicated S1 and X7_TP20_NoDayStop is now covered by every `_N`
  twin, so they became X6_MaxPos1 (does capping at one leg help?) and the
  `_N` family itself;
* every variant exists twice - with the 50 USD daily target and without it
  (`_N`) - because the daily stop is the one rule that can hide an edge.

38 presets = 17 variants x {target on, target off} (34), plus the 4 Y
variants that vary the DAILY LOSS stop instead - the rule that fired on 85.7%
of days in the 12-month run and had never been switched off.
"""

import os

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(os.path.dirname(HERE), "tester", "scalp3")

ORDER = [
    "InpMagic", "InpComment", "InpAllowLive", "InpLots", "InpMaxPositions",
    "InpMinMarginLevel", "InpMode", "InpAdxPeriod", "InpScoreStrong",
    "InpScoreMild", "InpReopenTolUSD", "InpHedgeTarget_ATR", "InpEntryMode",
    "InpFastEMA", "InpSlowEMA", "InpATRPeriod", "InpBBPeriod", "InpBBDev",
    "InpRSIPeriod", "InpRSIBuy", "InpRSISell", "InpBreakBars", "InpRandomSeed",
    "InpTP_ATR", "InpSL_ATR", "InpMinTPxSpread", "InpMaxSL_Price",
    "InpTrailStart_ATR", "InpTrail_ATR", "InpSessionStart", "InpSessionEnd",
    "InpFridayStop", "InpMaxSpread", "InpUseNews", "InpNewsMinutes",
    "InpDailyLossUSD", "InpDailyTargetUSD", "InpWriteCsv", "InpVerboseLog",
]

BASE = {
    "InpMagic": "26101710", "InpComment": "TPS", "InpAllowLive": "false",
    "InpLots": "0.01", "InpMaxPositions": "3", "InpMinMarginLevel": "300.00",
    "InpMode": "0", "InpAdxPeriod": "14", "InpScoreStrong": "0.60",
    "InpScoreMild": "0.20", "InpReopenTolUSD": "0.10",
    "InpHedgeTarget_ATR": "2.00", "InpEntryMode": "0", "InpFastEMA": "9",
    "InpSlowEMA": "21", "InpATRPeriod": "14", "InpBBPeriod": "20",
    "InpBBDev": "2.00", "InpRSIPeriod": "14", "InpRSIBuy": "30.00",
    "InpRSISell": "70.00", "InpBreakBars": "20", "InpRandomSeed": "11",
    "InpTP_ATR": "2.00", "InpSL_ATR": "2.00", "InpMinTPxSpread": "5.00",
    "InpMaxSL_Price": "6.00", "InpTrailStart_ATR": "1.20",
    "InpTrail_ATR": "1.00", "InpSessionStart": "13", "InpSessionEnd": "17",
    "InpFridayStop": "20", "InpMaxSpread": "0.60", "InpUseNews": "false",
    "InpNewsMinutes": "15", "InpDailyLossUSD": "10.00",
    "InpDailyTargetUSD": "50.00", "InpWriteCsv": "true",
    "InpVerboseLog": "true",
}

MULTI = {"InpMaxPositions": "4", "InpMinMarginLevel": "250.00"}

# (name, description, overrides) - all 17 run twice, see emit()
VARIANTS = [
    ("S1_Pullback", "EMA 9/21 pullback, TP 2.0 / SL 2.0 ATR, trail on",
     {}),
    ("S2_WideTP", "pullback with TP 3.5 ATR - is the target too tight",
     {"InpTP_ATR": "3.50"}),
    ("S3_MeanRev", "RSI 30/70 mean reversion, TP 2.5 ATR",
     {"InpEntryMode": "1", "InpTP_ATR": "2.50"}),
    ("S4_Breakout", "20-bar breakout, TP 2.5 / SL 2.5 ATR",
     {"InpEntryMode": "2", "InpTP_ATR": "2.50", "InpSL_ATR": "2.50"}),
    ("S5_Random", "CONTROL: coin-flip entry, same exits as S2",
     {"InpEntryMode": "3", "InpTP_ATR": "3.50"}),
    ("S6_Trail", "pullback, TP 5.0 ATR, the trail does the exiting",
     {"InpTP_ATR": "5.00"}),
    ("S7_Session", "CONTROL: pullback with the session filter removed (01-20)",
     {"InpSessionStart": "1", "InpSessionEnd": "20"}),
    ("S8_Hedge4", "MODE 1: fixed 2 BUY + 2 SELL, 4 legs",
     dict(MULTI, InpMode="1")),
    ("S9_Hybrid", "MODE 5: hedge in the range, directional scalp in the trend",
     dict(MULTI, InpMode="5")),
    ("S10_Adaptive", "MODE 3: 3/0, 2/1, 2/2 split from an EMA+ADX+BB score",
     dict(MULTI, InpMode="3")),
    ("S11_AdaptiveRnd", "CONTROL: the same splits, drawn at random",
     dict(MULTI, InpMode="4")),
    ("X1_TP20_SL20", "exit pair 2.0/2.0, trail OFF",
     {"InpTrailStart_ATR": "0.00", "InpTrail_ATR": "0.00"}),
    ("X2_TP13_SL20", "exit pair 1.3/2.0, trail OFF - the rest is invisible",
     {"InpTP_ATR": "1.30", "InpTrailStart_ATR": "0.00", "InpTrail_ATR": "0.00"}),
    ("X3_TP20_SL13", "exit pair 2.0/1.3, trail OFF",
     {"InpSL_ATR": "1.30", "InpTrailStart_ATR": "0.00", "InpTrail_ATR": "0.00"}),
    ("X4_TP15_SL15", "exit pair 1.5/1.5, trail OFF",
     {"InpTP_ATR": "1.50", "InpSL_ATR": "1.50",
      "InpTrailStart_ATR": "0.00", "InpTrail_ATR": "0.00"}),
    ("X5_TP30_SL15", "exit pair 3.0/1.5, trail OFF - 2:1",
     {"InpTP_ATR": "3.00", "InpSL_ATR": "1.50",
      "InpTrailStart_ATR": "0.00", "InpTrail_ATR": "0.00"}),
    ("X6_MaxPos1", "one leg at a time - do the extra legs pay for themselves",
     {"InpMaxPositions": "1"}),

    # --- the daily-loss confound (added after the 12-month read) ---------
    # The 12-month run hit the 10 USD daily loss stop on 85.7% of days and its
    # worst day of the whole year was -10.58. A 10 USD day stop against a 6 USD
    # per-trade stop ends the day after ~two losers, and this EA had a streak
    # of 20. That rule is in EVERY preset above, so the survey never measured
    # the strategy without it. These four are the missing cells.
    ("Y1_LossOff", "no daily loss stop, no target - the strategy alone",
     {"InpDailyLossUSD": "0.00", "InpDailyTargetUSD": "0.00"}),
    ("Y2_LossOff_T50", "no daily loss stop, target 50 kept",
     {"InpDailyLossUSD": "0.00"}),
    ("Y3_Loss30", "daily loss 30 (5 stops), no target",
     {"InpDailyLossUSD": "30.00", "InpDailyTargetUSD": "0.00"}),
    ("Y4_Loss30_T50", "daily loss 30 (5 stops), target 50 kept",
     {"InpDailyLossUSD": "30.00"}),
]

NO_TARGET = {"InpDailyTargetUSD": "0.00"}

HEADER = """; ==========================================================================
;  TwinPulseONE survey - {name}
;  {desc}
;  Day control: {tgt}
;  Fixed 0.01 lot, broker stop on every leg, no grid, no averaging down,
;  AllowLive=false. Same 34 variants as the InpPreset enum of TwinPulseONE.mq5.
; ==========================================================================

"""


def emit(name, desc, values):
    body = "".join("%s=%s\n" % (key, values[key]) for key in ORDER)
    target = values["InpDailyTargetUSD"]
    loss = values["InpDailyLossUSD"]
    tgt = ("target OFF" if target == "0.00"
           else "target +%s USD" % target.split(".")[0])
    tgt += " | " + ("daily loss stop OFF" if loss == "0.00"
                    else "daily loss stop -%s USD" % loss.split(".")[0])
    with open(os.path.join(OUT, name + ".set"), "w", newline="\r\n") as handle:
        handle.write(HEADER.format(name=name, desc=desc, tgt=tgt))
        handle.write(body)


def main():
    if not os.path.isdir(OUT):
        os.makedirs(OUT)
    for old in os.listdir(OUT):
        if old.endswith(".set"):
            os.remove(os.path.join(OUT, old))

    count = 0
    for name, desc, overrides in VARIANTS:
        values = dict(BASE)
        values.update(overrides)
        emit(name, desc, values)
        count += 1

        # the Y family states its own target and loss settings; a second
        # _N copy would just repeat a cell of the 2x2
        if name.startswith("Y"):
            continue

        off = dict(values)
        off.update(NO_TARGET)
        emit(name + "_N", desc + "  [no daily target]", off)
        count += 1

    print("%d presets written to %s" % (count, OUT))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
