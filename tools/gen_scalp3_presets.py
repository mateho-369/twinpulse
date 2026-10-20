#!/usr/bin/env python3
"""Round-3 presets: the same 34 variants as rounds 1 and 2, measured on a
1000 USD account.

Why a bigger deposit and not a bigger lot: the lot stays 0.01 (the owner's
rule), the stops stay in price units, and every number stays in USD. What
changes is only survival. At 100 USD, a 6 USD stop is 6% of the account and a
10 USD daily stop is 10%, so the back half died after 7-8 days and could not be
measured at all (round 1: 22 variants, 9 of them under 10 days; round 2: 8 of
13). At 1000 USD the same 10 USD daily stop is 1% and 50 USD target is 5%, and
the full 52-day window can run to the end.

Nothing else changes: the inputs are byte-for-byte the round-1 / round-2 ones,
so the two rounds stay comparable and the only new variable is survival.
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import gen_scalp_presets as r1        # noqa: E402
import gen_scalp2_presets as r2       # noqa: E402

# the two round-2 presets that duplicate a round-1 name or role
SKIP_R2 = {"S7_AllDay"}               # identical to round 1's anchor

# A 12-month window costs about five times a 10-week one, so round 3 runs the
# variants that answer a distinct question instead of all 34: three entries,
# the random entry control, the session control, the 2+2 book, the adaptive
# book, five exit pairs with their twins, the trail anchor and the
# no-daily-stop probe.
KEEP_R1 = {"S1_Pullback", "S2_WideTP", "S3_MeanRev", "S4_Breakout",
           "S5_Random", "S7_AllDay", "S8_Hedge4", "S10_Adaptive"}

HEADER = """; ==========================================================================
;  TwinPulse Scalp - round 3 (measurement at 1000 USD), {name}
;  {desc}
;  Inputs are IDENTICAL to round 1/2 - only the account size changes, so the
;  strategy can survive the window and be measured on both halves.
;  Fixed 0.01 lot, broker stop on every leg, no grid, no averaging,
;  AllowLive=false.
;  Daily target: {tgt}
;  Run:  powershell -File tools\\run_batch.ps1 -Preset tester\\scalp3
;        -Expert TwinPulse\\TwinPulseScalp -Period M5 -Model 1 -Deposit 1000
; ==========================================================================

"""


def emit(out, name, desc, vals, tag):
    body = "".join("%s=%s\n" % (k, vals[k]) for k in r1.ORDER)
    tgt = ("ON  (close all at +50 USD = 5% of 1000, stop for the day)"
           if vals["InpDailyTargetUSD"] != "0.00" else "OFF")
    with open(os.path.join(out, name + ".set"), "w", newline="\r\n") as f:
        f.write(HEADER.format(name=name, desc=desc, tgt=tgt))
        f.write(body)


def main():
    out = os.path.join(os.path.dirname(HERE), "tester", "scalp3")
    if not os.path.isdir(out):
        os.makedirs(out)
    n = 0
    # round 1: every variant, with and without the daily target
    for name, desc, over in r1.VARIANTS:
        if name not in KEEP_R1:
            continue
        vals = dict(r1.BASE)
        vals.update(over)
        emit(out, name, desc, vals, "r1")
        n += 1
    # round 2: the exit pairs and their twins, minus the duplicate anchor.
    # The seeds reproduce round 2 exactly (71 + 2k - 1), so a twin's result can
    # be compared across the two rounds instead of being a new coin.
    k = 0
    for name, desc, over in r2.VARIANTS + r2.ANCHORS:
        if name in SKIP_R2:
            continue
        vals = dict(r2.BASE)
        vals.update(over)
        emit(out, name, desc, vals, "r2")
        n += 1
        if name.startswith("X") and "_Random" not in name and name not in (
                "X6_Trail", "X7_TP20_NoDayStop"):
            k += 1
            rnd = dict(vals)
            rnd["InpEntryMode"] = "3"
            rnd["InpRandomSeed"] = str(71 + 2 * k - 1)
            emit(out, name + "_Random", desc + " - RANDOM entry, the control", rnd, "r2")
            n += 1
    print("wrote %d presets to %s" % (n, out))


if __name__ == "__main__":
    main()
