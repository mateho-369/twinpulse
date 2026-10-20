#!/usr/bin/env python3
"""Round-2 presets: the exit, and its own random twin.

Round 1 showed the entry does nothing (the random control beat the strategies
on the back half and lost on the forward half, and the cross-half correlation
was -0.40). It also showed the **take profit never fired once in 44 runs**:
every leg ended at the broker stop or at the daily close-all, because the trail
was on in every single preset - S1 was never a plain TP/SL test.

So round 2 changes one thing only: the exit. Five (TP, SL) pairs, trail off,
each with a random-entry twin on the identical exit, plus the two anchors from
round 1 and one probe of the daily stop itself.

Every file is written in the exact input order of the EA.
"""
import os

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
    "InpHedgeTarget_ATR": "2.00", "InpEntryMode": "0",
    "InpFastEMA": "9", "InpSlowEMA": "21", "InpATRPeriod": "14",
    "InpBBPeriod": "20", "InpBBDev": "2.00", "InpRSIPeriod": "14",
    "InpRSIBuy": "30.00", "InpRSISell": "70.00", "InpBreakBars": "20",
    "InpRandomSeed": "11", "InpTP_ATR": "2.00", "InpSL_ATR": "2.00",
    "InpMinTPxSpread": "5.00", "InpMaxSL_Price": "6.00",
    "InpTrailStart_ATR": "0.00", "InpTrail_ATR": "0.00",
    "InpSessionStart": "13", "InpSessionEnd": "17", "InpFridayStop": "20",
    "InpMaxSpread": "0.60", "InpUseNews": "false", "InpNewsMinutes": "15",
    "InpDailyLossUSD": "10.00", "InpDailyTargetUSD": "50.00",
    "InpWriteCsv": "true", "InpVerboseLog": "true",
}

TRAIL = {"InpTrailStart_ATR": "1.20", "InpTrail_ATR": "1.00"}

# name, description, overrides
VARIANTS = [
    ("X1_TP20_SL20", "TP 2.0 / SL 2.0, no trail - a clean 1:1, needs 56.5%",
     {"InpTP_ATR": "2.00", "InpSL_ATR": "2.00"}),
    ("X2_TP13_SL20", "TP 1.3 / SL 2.0, no trail - takes profit at the 5x spread floor",
     {"InpTP_ATR": "1.30", "InpSL_ATR": "2.00"}),
    ("X3_TP20_SL13", "TP 2.0 / SL 1.3, no trail - tight stop, needs only ~40%",
     {"InpTP_ATR": "2.00", "InpSL_ATR": "1.30"}),
    ("X4_TP15_SL15", "TP 1.5 / SL 1.5, no trail - 1:1 at a smaller size",
     {"InpTP_ATR": "1.50", "InpSL_ATR": "1.50"}),
    ("X5_TP30_SL15", "TP 3.0 / SL 1.5, no trail - 2:1, needs only ~34%",
     {"InpTP_ATR": "3.00", "InpSL_ATR": "1.50"}),
]

ANCHORS = [
    ("X6_Trail", "round-1 behaviour: TP 2.0 / SL 2.0 with the 1.2/1.0 trail",
     dict({"InpTP_ATR": "2.00", "InpSL_ATR": "2.00"}, **TRAIL)),
    ("X7_TP20_NoDayStop", "X1 with no daily loss and no daily target - does the "
                          "10 USD lock help or hurt?",
     {"InpTP_ATR": "2.00", "InpSL_ATR": "2.00",
      "InpDailyLossUSD": "0.00", "InpDailyTargetUSD": "0.00"}),
    ("S7_AllDay", "round-1 anchor: 01-20 session, TP 2.0 / SL 2.0 with trail",
     dict({"InpTP_ATR": "2.00", "InpSL_ATR": "2.00",
           "InpSessionStart": "1", "InpSessionEnd": "20"}, **TRAIL)),
]

HDR = """; ==========================================================================
;  TwinPulse Scalp - round 2, {name}
;  {desc}
;  Fixed 0.01 lot, broker stop on every leg, no grid, no averaging,
;  AllowLive=false. Round 2 tests the EXIT: the entry is unchanged.
;  Daily target: {tgt}
;  Run:  powershell -File tools\\run_batch.ps1 -Preset tester\\scalp2
;        -Expert TwinPulse\\TwinPulseScalp -Period M5 -Model 1
; ==========================================================================

"""


def write(path, name, desc, vals):
    body = "".join("%s=%s\n" % (k, vals[k]) for k in ORDER)
    tgt = ("ON  (close all at +50 USD, stop for the day)"
           if vals["InpDailyTargetUSD"] != "0.00" else "OFF (measured, not assumed)")
    with open(path, "w", newline="\r\n") as f:
        f.write(HDR.format(name=name, desc=desc, tgt=tgt))
        f.write(body)


def main():
    out = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                       "tester", "scalp2")
    if not os.path.isdir(out):
        os.makedirs(out)
    n = 0
    for name, desc, over in VARIANTS:
        vals = dict(BASE)
        vals.update(over)
        write(os.path.join(out, name + ".set"), name, desc, vals)
        n += 1
        # the twin: the same exit, the entry replaced by a coin
        rnd = dict(vals)
        rnd["InpEntryMode"] = "3"
        rnd["InpRandomSeed"] = str(71 + n)
        write(os.path.join(out, name + "_Random.set"), name + " (random entry)",
              desc + " - RANDOM entry, the control", rnd)
        n += 1
    for name, desc, over in ANCHORS:
        vals = dict(BASE)
        vals.update(over)
        write(os.path.join(out, name + ".set"), name, desc, vals)
        n += 1
    print("wrote %d presets to %s" % (n, out))


if __name__ == "__main__":
    main()
