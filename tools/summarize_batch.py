#!/usr/bin/env python3
# ==========================================================================
#  TwinPulse Hedge EA - decision batch summarizer
#
#  Reads the reports and CSV logs of the 8 decision variants produced by
#  tools/run_batch.ps1 and writes:
#     reports/decision/SUMMARY.md       - BACK + FORWARD, gate table, verdict
#     reports/decision/SUMMARY_BACK.md  - BACK numbers only (no forward data)
#
#  Usage:
#     python tools/summarize_batch.py --data "<DATA folder>" \
#             --from 2022.01.01 --to 2026.09.30
#     python tools/summarize_batch.py --reports "<DATA>\\reports\\decision"
#
#  Periods (frozen in docs/DECISION_RULES.md):
#     ForwardMode 2 = forward 1/3 of the period:
#        forward_start = from + (to - from) * 2/3
#     "both halves of the period" = first / second calendar half of from..to.
#  The gates PF / DD / RF use the FORWARD column of the report (the honest
#  out-of-sample numbers), leg counts and the halves use the whole period.
# ==========================================================================

import argparse
import csv
import os
import re
import sys
from datetime import datetime, timedelta

VARIANTS = ["V1_Full", "V2_FullRollover", "V3_Pure", "V4_OneSide",
            "V5_LegB", "V6_LegA", "V7_Random1", "V8_Random2"]
RANDOM = ["V7_Random1", "V8_Random2"]
# the decision order for "the simplest passing variant"
SIMPLENESS = ["V1_Full", "V2_FullRollover", "V3_Pure", "V4_OneSide",
              "V5_LegA", "V5_LegB", "V7_Random1", "V8_Random2"]

NA = "n/a"


def num(s):
    """parse '1 234.56', '-2.17', '87.3%', '1 234.00 (11.8%)' -> float or None"""
    if s is None:
        return None
    t = str(s).replace("\xa0", " ").strip()
    if not t:
        return None
    t = re.sub(r"[^0-9eE+.\-%()]", "", t.replace(" ", ""))
    if t in ("", "-", "%", "()"):
        return None
    m = re.match(r"^\(?([+-]?[0-9]*\.?[0-9]+(?:[eE][+-]?[0-9]+)?)\)?", t)
    if not m:
        return None
    try:
        return float(m.group(1))
    except ValueError:
        return None


def pct_in_parens(s):
    """'1 234.00 (11.8%)' -> 11.8"""
    if s is None:
        return None
    m = re.search(r"\(([-+]?[0-9]*\.?[0-9]+)\s*%\)", str(s))
    return float(m.group(1)) if m else None


def strip_tags(html):
    return re.sub(r"<[^>]+>", " ", html)


def parse_report(path):
    """extract the statistics rows of an MT5 tester report (tolerant)."""
    out = {"history_quality": None, "rows": {}, "raw_labels": []}
    if not os.path.isfile(path):
        return out
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        html = f.read()
    rows = re.findall(r"<tr[^>]*>(.*?)</tr>", html, re.S | re.I)
    for row in rows:
        cells = re.findall(r"<t[dh][^>]*>(.*?)</t[dh]>", row, re.S | re.I)
        cells = [strip_tags(c).replace("\xa0", " ").strip() for c in cells]
        cells = [c for c in cells if c != ""]
        if len(cells) < 2:
            continue
        label = cells[0].strip().lower()
        out["raw_labels"].append(label)
        out["rows"].setdefault(label, []).append(cells[1:])
    # history quality
    for label, valuerows in out["rows"].items():
        if "history quality" in label or "history quality" in label.replace("  ", " "):
            vals = valuerows[0]
            for v in vals:
                q = num(v)
                if q is not None:
                    out["history_quality"] = q
                    break
    return out


def pick(report, *needles):
    """find a statistics row by fuzzy label -> (all, back, fwd) floats"""
    for label, valuerows in report["rows"].items():
        if all(n in label for n in needles):
            vals = [num(v) for v in valuerows[0]]
            pct = None
            for v in valuerows[0]:
                pct = pct_in_parens(v) or pct
            vals = [v for v in vals] + [None, None, None]
            return vals, pct
    return [None, None, None], None


def pick_pair(report, needles, pct=False):
    """-> (back, fwd): 3 values = (all, back, fwd), 2 values = (back, fwd)"""
    vals, pctv = pick(report, *needles)
    if pct and pctv is not None:
        # drawdown percent is in parentheses - same columns as the values
        back = pctv if vals[1] is None else pctv
        return back, back
    if vals[1] is None and vals[0] is not None:
        return vals[0], vals[0]
    back, fwd = vals[1], vals[2]
    return back, fwd


class Legs(object):
    def __init__(self):
        self.rows = []

    def load(self, path):
        if not os.path.isfile(path):
            return
        with open(path, "r", encoding="utf-8", errors="replace", newline="") as f:
            for r in csv.DictReader(f):
                self.rows.append(r)

    @staticmethod
    def _close(r):
        try:
            return datetime.strptime(r["time"], "%Y.%m.%d %H:%M:%S")
        except Exception:
            return None

    @staticmethod
    def _f(r, key):
        try:
            return float(r.get(key, "") or 0.0)
        except ValueError:
            return 0.0

    def filter_to(self, upto):
        return [r for r in self.rows if self._close(r) and self._close(r) < upto]

    def net(self, rows=None):
        rows = self.rows if rows is None else rows
        return sum(self._f(r, "profit") for r in rows)

    def count(self, rows=None):
        rows = self.rows if rows is None else rows
        return len(rows)

    def gross_pf(self, rows=None):
        rows = self.rows if rows is None else rows
        g = sum(self._f(r, "gross") for r in rows if self._f(r, "gross") > 0)
        l = sum(self._f(r, "gross") for r in rows if self._f(r, "gross") < 0)
        return (g / abs(l)) if l < 0 else None

    def spread_paid(self, rows=None):
        rows = self.rows if rows is None else rows
        return sum(self._f(r, "spread_cost") for r in rows)

    def by(self, keyfn, rows=None):
        rows = self.rows if rows is None else rows
        out = {}
        for r in rows:
            k = keyfn(r)
            e = out.setdefault(k, [0, 0.0])
            e[0] += 1
            e[1] += self._f(r, "profit")
        return out

    def halves(self, d_from, d_to):
        mid = d_from + (d_to - d_from) / 2
        first = [r for r in self.rows if self._close(r) and self._close(r) < mid]
        second = [r for r in self.rows if self._close(r) and self._close(r) >= mid]
        return self.net(first), self.net(second)


def fmt(v, nd=2, suffix=""):
    if v is None:
        return NA
    return ("%%.%df%%s" % nd) % (v, suffix)


def load_variant(vdir):
    rep_path = None
    for name in ("report.htm", "report.html"):
        p = os.path.join(vdir, name)
        if os.path.isfile(p):
            rep_path = p
            break
    if rep_path is None:
        for fn in sorted(os.listdir(vdir)) if os.path.isdir(vdir) else []:
            if fn.lower().endswith((".htm", ".html")):
                rep_path = os.path.join(vdir, fn)
                break
    report = parse_report(rep_path) if rep_path else {"history_quality": None, "rows": {}}
    legs = Legs()
    legs.load(os.path.join(vdir, "TwinPulse_legs.csv"))
    return report, legs


def main():
    ap = argparse.ArgumentParser(description="TwinPulse decision batch summary")
    ap.add_argument("--data", help="terminal DATA folder")
    ap.add_argument("--reports", help="reports/decision folder (overrides --data)")
    ap.add_argument("--from", dest="d_from", default="2022.01.01")
    ap.add_argument("--to", dest="d_to", default="2026.09.30")
    args = ap.parse_args()

    if args.reports:
        rdir = args.reports
    elif args.data:
        rdir = os.path.join(args.data, "reports", "decision")
    else:
        print("need --data <DATA folder> or --reports <folder>")
        return 2
    if not os.path.isdir(rdir):
        print("folder not found: %s" % rdir)
        return 2

    d_from = datetime.strptime(args.d_from, "%Y.%m.%d")
    d_to = datetime.strptime(args.d_to, "%Y.%m.%d") + timedelta(days=1)
    fwd_start = d_from + (d_to - d_from) * 2 / 3     # ForwardMode 2 = forward 1/3

    data = {}
    for v in VARIANTS:
        report, legs = load_variant(os.path.join(rdir, v))
        back_rows = [r for r in legs.rows if legs._close(r) and legs._close(r) < fwd_start]
        data[v] = {"report": report, "legs": legs, "back_rows": back_rows}

    # ---- the better RANDOM control (forward PF) ----------------------
    rnd_pfs = []
    for v in RANDOM:
        _, fwd_pf = pick_pair(data[v]["report"], ["profit factor"])
        if fwd_pf is not None:
            rnd_pfs.append(fwd_pf)
    rnd_pf = max(rnd_pfs) if rnd_pfs else None

    def gates(v):
        d = data[v]
        rep, legs = d["report"], d["legs"]
        is_random = v in RANDOM
        fwd_net, _ = pick_pair(rep, ["total net profit"])
        _, fwd_pf = pick_pair(rep, ["profit factor"])
        back_pf, _ = pick_pair(rep, ["profit factor"])
        _, fwd_dd = pick_pair(rep, ["equity drawdown"], pct=True)
        if fwd_dd is None:
            _, fwd_dd = pick_pair(rep, ["drawdown"], pct=True)
        _, fwd_rf = pick_pair(rep, ["recovery factor"])
        total_legs = legs.count()
        h1, h2 = legs.halves(d_from, d_to)
        hq = rep.get("history_quality")

        g = {}
        g["valid"] = hq is None or hq >= 90.0
        g["hq"] = hq
        g["pf_fwd >= 1.20"] = (fwd_pf is not None and fwd_pf >= 1.2)
        g["dd_fwd <= 20%"] = (fwd_dd is not None and fwd_dd <= 20.0)
        g["rf_fwd >= 2"] = (fwd_rf is not None and fwd_rf >= 2.0)
        g["legs >= 200"] = (total_legs >= 200)
        g["both halves > 0"] = (h1 > 0 and h2 > 0)
        if is_random:
            g["beats RANDOM by 0.15 PF"] = None     # control variant
        else:
            g["beats RANDOM by 0.15 PF"] = (
                fwd_pf is not None and rnd_pf is not None and (fwd_pf - rnd_pf) >= 0.15)
        g["_vals"] = (fwd_net, fwd_pf, fwd_dd, fwd_rf, total_legs, h1, h2, back_pf)
        if not g["valid"]:
            g["_pass"] = False
        else:
            checks = [val for key, val in g.items() if key not in ("valid", "hq", "_vals", "_pass") and val is not None]
            g["_pass"] = all(checks) if checks else False
        return g

    allg = {v: gates(v) for v in VARIANTS}

    # ---- SUMMARY.md --------------------------------------------------
    def row_md(v):
        d = data[v]
        rep, legs = d["report"], d["legs"]
        _, b_net = None, None
        b_net, _ = pick_pair(rep, ["total net profit"])
        f_net, f_pf = pick_pair(rep, ["total net profit"])
        _, f_pf = pick_pair(rep, ["profit factor"])
        b_pf, _ = pick_pair(rep, ["profit factor"])
        b_dd, f_dd = pick_pair(rep, ["equity drawdown"], pct=True)
        if b_dd is None:
            b_dd, f_dd = pick_pair(rep, ["drawdown"], pct=True)
        b_rf, f_rf = pick_pair(rep, ["recovery factor"])
        hq = rep.get("history_quality")
        g = allg[v]
        mark = "NOT VALID FOR GATES" if not g["valid"] else ("PASS" if g["_pass"] else "fail")
        return ("| %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |" % (
            v, fmt(hq, 2, "%"), fmt(b_net), fmt(f_net), fmt(b_pf), fmt(f_pf),
            fmt(f_dd, 2, "%"), fmt(f_rf), legs.count(),
            fmt(legs.gross_pf()), fmt(legs.spread_paid()), mark))

    lines = []
    lines.append("# TwinPulse decision batch - SUMMARY")
    lines.append("")
    lines.append("period %s .. %s, forward starts %s (ForwardMode 2 = forward 1/3)."
                 % (args.d_from, args.d_to, fwd_start.strftime("%Y.%m.%d")))
    lines.append("Report fields are taken from the tester report; legs / gross / spread")
    lines.append("from `TwinPulse_legs.csv`. Gates use the FORWARD column (PF, DD, RF).")
    lines.append("")
    lines.append("## Per variant")
    lines.append("")
    lines.append("| variant | HQ | BACK net | FWD net | BACK PF | FWD PF | FWD eq DD | FWD RF | legs | gross PF | spread paid | verdict |")
    lines.append("|---|---|---|---|---|---|---|---|---|---|---|---|")
    for v in VARIANTS:
        lines.append(row_md(v))
    lines.append("")
    lines.append("## Gate table")
    lines.append("")
    keys = ["pf_fwd >= 1.20", "dd_fwd <= 20%", "rf_fwd >= 2", "legs >= 200",
            "both halves > 0", "beats RANDOM by 0.15 PF"]
    lines.append("| variant | " + " | ".join(keys) + " |")
    lines.append("|---" * (len(keys) + 1) + "|")
    for v in VARIANTS:
        g = allg[v]
        cells = []
        for k in keys:
            val = g[k]
            cells.append("n/a" if val is None else ("YES" if val else "no"))
        lines.append("| %s | %s |" % (v, " | ".join(cells)))
    lines.append("")
    lines.append("better RANDOM control (forward PF): %s" % fmt(rnd_pf))
    lines.append("")

    # ---- per variant details ----------------------------------------
    lines.append("## Per-variant details")
    lines.append("")
    for v in VARIANTS:
        legs = data[v]["legs"]
        lines.append("### %s" % v)
        lines.append("")
        if not legs.rows:
            lines.append("no legs.csv rows.")
            lines.append("")
            continue
        byyear = legs.by(lambda r: r["time"][:4])
        bymonth = legs.by(lambda r: r["time"][:7])
        byreason = legs.by(lambda r: r.get("reason", "?"))
        byleg = legs.by(lambda r: r.get("leg", "?"))
        lines.append("net per year: " + "; ".join("%s: %.2f (%d)" % (k, byyear[k][1], byyear[k][0]) for k in sorted(byyear)))
        worst = min(bymonth.items(), key=lambda kv: kv[1][1]) if bymonth else None
        lines.append("worst month: %s (%.2f, %d legs)" % (worst[0], worst[1][1], worst[1][0]) if worst else "worst month: " + NA)
        lines.append("gross before spread PF: %s, spread paid: %s"
                     % (fmt(legs.gross_pf()), fmt(legs.spread_paid())))
        lines.append("")
        lines.append("| exit reason | legs | net |")
        lines.append("|---|---|---|")
        for k in sorted(byreason):
            lines.append("| %s | %d | %.2f |" % (k, byreason[k][0], byreason[k][1]))
        lines.append("")
        lines.append("| leg | legs | net |")
        lines.append("|---|---|---|")
        for k in sorted(byleg):
            lines.append("| %s | %d | %.2f |" % (k, byleg[k][0], byleg[k][1]))
        lines.append("")

    # ---- verdict (docs/DECISION_RULES.md, fixed before the results) ---
    passing = [v for v in SIMPLENESS if allg[v]["_pass"]]
    best_gross = None
    for v in VARIANTS:
        gp = data[v]["legs"].gross_pf()
        if gp is not None and (best_gross is None or gp > best_gross):
            best_gross = gp
    lines.append("## Verdict (docs/DECISION_RULES.md)")
    lines.append("")
    if passing:
        lines.append("**PASS: %s** -> trade the SIMPLEST passing variant (%s) on a"
                     % (", ".join(passing), passing[0]))
        lines.append("4-week demo, no more tuning.")
    elif best_gross is not None and best_gross >= 1.1:
        lines.append("**NO PASS, but gross-before-spread PF %s >= 1.10** -> ONE cost round"
                     % fmt(best_gross))
        lines.append("(max 3 changes), then rerun the batch. No other tuning.")
    else:
        lines.append("**STOP the hedge idea.** No variant passes the gates and the")
        lines.append("gross-before-spread PF does not reach 1.10 - say so plainly.")
    lines.append("")

    with open(os.path.join(rdir, "SUMMARY.md"), "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")

    # ---- SUMMARY_BACK.md - BACK only, no forward data at all ----------
    b = []
    b.append("# TwinPulse decision batch - SUMMARY (BACK period only)")
    b.append("")
    b.append("period %s .. %s, BACK = %s .. %s (the forward part is NOT included,"
             % (args.d_from, args.d_to, args.d_from, fwd_start.strftime("%Y.%m.%d")))
    b.append("no forward data appears in this file).")
    b.append("")
    b.append("| variant | HQ | BACK net | BACK PF | legs (back) | gross PF (back) | spread paid (back) |")
    b.append("|---|---|---|---|---|---|---|")
    for v in VARIANTS:
        d = data[v]
        rep, legs = d["report"], d["legs"]
        br = d["back_rows"]
        b_net, _ = pick_pair(rep, ["total net profit"])
        b_pf, _ = pick_pair(rep, ["profit factor"])
        hq = rep.get("history_quality")
        b.append("| %s | %s | %s | %s | %d | %s | %s |" % (
            v, fmt(hq, 2, "%"), fmt(b_net), fmt(b_pf), legs.count(br),
            fmt(legs.gross_pf(br)), fmt(legs.spread_paid(br))))
    b.append("")
    for v in VARIANTS:
        legs = data[v]["legs"]
        br = data[v]["back_rows"]
        if not br:
            continue
        b.append("## %s (BACK)" % v)
        b.append("")
        byyear = legs.by(lambda r: r["time"][:4], br)
        byreason = legs.by(lambda r: r.get("reason", "?"), br)
        byleg = legs.by(lambda r: r.get("leg", "?"), br)
        b.append("net per year: " + "; ".join("%s: %.2f (%d)" % (k, byyear[k][1], byyear[k][0]) for k in sorted(byyear)))
        b.append("")
        b.append("| exit reason | legs | net |")
        b.append("|---|---|---|")
        for k in sorted(byreason):
            b.append("| %s | %d | %.2f |" % (k, byreason[k][0], byreason[k][1]))
        b.append("")
        b.append("| leg | legs | net |")
        b.append("|---|---|---|")
        for k in sorted(byleg):
            b.append("| %s | %d | %.2f |" % (k, byleg[k][0], byleg[k][1]))
        b.append("")

    with open(os.path.join(rdir, "SUMMARY_BACK.md"), "w", encoding="utf-8") as f:
        f.write("\n".join(b) + "\n")

    print("wrote %s" % os.path.join(rdir, "SUMMARY.md"))
    print("wrote %s" % os.path.join(rdir, "SUMMARY_BACK.md"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
