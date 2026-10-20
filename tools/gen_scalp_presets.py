#!/usr/bin/env python3
"""Generate the round-1 scalper presets (tester/scalp/*.set).

Every preset is written twice:
  S<n>_Name      the daily target is ON  (InpDailyTargetUSD = 50)
  S<n>_Name_N    the daily target is OFF (InpDailyTargetUSD = 0)

The key order below must match the `input` order in TwinPulseScalp.mq5,
otherwise a stale .ex5 silently ignores everything after the first key it
does not know.
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
    "InpTrailStart_ATR": "1.20", "InpTrail_ATR": "1.00",
    "InpSessionStart": "13", "InpSessionEnd": "17", "InpFridayStop": "20",
    "InpMaxSpread": "0.60", "InpUseNews": "false", "InpNewsMinutes": "15",
    "InpDailyLossUSD": "10.00", "InpDailyTargetUSD": "50.00",
    "InpWriteCsv": "true", "InpVerboseLog": "true",
}

# name, one-line description, overrides
VARIANTS = [
    ("S1_Pullback", "EMA 9/21 pullback, TP 2.0 ATR, SL 2.0 ATR, 13-17", {}),
    ("S2_WideTP", "S1 entry, TP widened to 3.5 ATR - do the winners run?", {"InpTP_ATR": "3.50"}),
    ("S3_MeanRev", "Bollinger + RSI fade, TP 2.5 ATR", {"InpEntryMode": "1", "InpTP_ATR": "2.50"}),
    ("S4_Breakout", "20-bar range break, TP 2.5 / SL 2.5 ATR", {"InpEntryMode": "2", "InpTP_ATR": "2.50", "InpSL_ATR": "2.50"}),
    ("S5_Random", "RANDOM entries, TP 3.5 ATR - the control", {"InpEntryMode": "3", "InpTP_ATR": "3.50"}),
    ("S6_Trail", "S1 entry, TP 5.0 ATR + trail from 1.2 ATR", {"InpTP_ATR": "5.00"}),
    ("S7_AllDay", "S1 entry, session 01-20 - does the 13-17 filter pay?", {"InpSessionStart": "1", "InpSessionEnd": "20"}),

    # round-1 extension: the BUY/SELL book
    ("S8_Hedge4", "fixed 2 BUY + 2 SELL, TP 2.0 ATR each", {"InpMode": "1", "InpMaxPositions": "4", "InpMinMarginLevel": "250.00"}),
    ("S9_Hybrid", "ADX<22 hedge book, ADX>=22 one directional leg", {"InpMode": "5", "InpMaxPositions": "4", "InpMinMarginLevel": "250.00"}),
    ("S10_Adaptive", "score picks the split: 3/0, 2/1, 2/2, 1/2, 0/3", {"InpMode": "3", "InpMaxPositions": "4", "InpMinMarginLevel": "250.00"}),
    ("S11_AdaptiveRnd", "same splits as S10, drawn at RANDOM - the control", {"InpMode": "4", "InpMaxPositions": "4", "InpMinMarginLevel": "250.00", "InpRandomSeed": "29"}),
]

HDR = """; ==========================================================================
;  TwinPulse Scalp - round 1, {name}
;  {desc}
;  Fixed 0.01 lot, every position carries a broker stop from the open,
;  no grid, no averaging, no lot increase. AllowLive=false.
;  Daily target: {tgt}{note}
;  Run:  powershell -File tools\\run_batch.ps1 -Preset tester\\scalp
;        -Expert TwinPulse\\TwinPulseScalp -Period M5 -Model 1
; ==========================================================================

"""


def write(path, name, desc, vals, target_on):
    body = "".join("%s=%s\n" % (k, vals[k]) for k in ORDER)
    tgt = "ON  (close all at +50 USD, stop for the day)" if target_on else "OFF (no daily profit stop)"
    note = ""
    if vals["InpMaxPositions"] == "4":
        note = ("\n;  FOUR legs = 36 USD of margin = 278% of a 100 USD account, so\n"
                ";  InpMinMarginLevel is 250 here. This is the only place it drops\n"
                ";  below 300, and only because the owner asked for a 2+2 book.")
    with open(path, "w", newline="\r\n") as f:
        f.write(HDR.format(name=name, desc=desc, tgt=tgt, note=note))
        f.write(body)


def main():
    out = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                       "tester", "scalp")
    if not os.path.isdir(out):
        os.makedirs(out)
    n = 0
    for name, desc, over in VARIANTS:
        vals = dict(BASE)
        vals.update(over)
        write(os.path.join(out, name + ".set"), name, desc, vals, True)
        n += 1
        off = dict(vals)
        off["InpDailyTargetUSD"] = "0.00"
        write(os.path.join(out, name + "_N.set"), name + " (no daily target)",
              desc, off, False)
        n += 1
    print("wrote %d presets to %s" % (n, out))


if __name__ == "__main__":
    main()
