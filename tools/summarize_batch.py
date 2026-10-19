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
#             --from 2022.01.01 --to 2026.09.30 \
#             --symbol XAUUSDm --contract-size 100 --ref-spread 0.20
#
#  Periods (frozen in docs/DECISION_RULES.md):
#     ForwardMode 2 = forward 1/3 of the period:
#        forward_start = from + (to - from) * 2/3
#     "both halves of the period" = first / second calendar half of from..to.
#  The gates PF / DD / RF use the FORWARD column of the report (the honest
#  out-of-sample numbers), leg counts and the halves use the whole period.
#
#  Cost realism (the worse-of-two rule): every net is also computed at the
#  reference spread (default 0.20 = Exness XAUUSDm median, price units):
#     net@ref = net - sum(max(0, ref_spread - spread_open) * volume * contract)
#  Gates that read a net or a profit factor are evaluated on BOTH series
#  and pass only on the worse of the two (docs/DECISION_RULES.md).
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
              "V6_LegA", "V5_LegB", "V7_Random1", "V8_Random2"]

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
    out = {"history_quality": None, "rows": {}}
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
        out["rows"].setdefault(label, []).append(cells[1:])
    for label, valuerows in out["rows"].items():
        if "history quality" in label:
            for v in valuerows[0]:
                q = num(v)
                if q is not None:
                    out["history_quality"] = q
                    break
    return out


def pick(report, *needles):
    """find a statistics row by fuzzy label -> (values, pcts) padded to 3"""
    for label, valuerows in report["rows"].items():
        if all(n in label for n in needles):
            cells = valuerows[0]
            vals = [num(v) for v in cells]
            pcts = [pct_in_parens(v) for v in cells]
            vals = (vals + [None, None, None])[:3]
            pcts = (pcts + [None, None, None])[:3]
            return vals, pcts
    return [None, None, None], [None, None, None]


def pick_pair(report, needles, pct=False):
    """-> (back, fwd): 3 cells = (all, back, fwd), 2 cells = (back, fwd),
    1 cell = common section. pct=True reads the (x%) inside drawdown cells."""
    vals, pcts = pick(report, *needles)
    use = vals
    if pct and any(p is not None for p in pcts):
        use = pcts
    if use[2] is None and use[1] is not None:
        return use[0], use[1]
    if use[1] is None and use[0] is not None:
        return use[0], use[0]
    return use[1], use[2]


class Legs(object):
    def __init__(self):
        self.rows = []
        self.has_spread = False
        self.has_pos_net = False

    def load(self, path):
        if not os.path.isfile(path):
            return
        with open(path, "r", encoding="utf-8", errors="replace", newline="") as f:
            for r in csv.DictReader(f):
                if (r.get("spread_open") or "").strip() != "":
                    self.has_spread = True
                if (r.get("pos_net") or "").strip() != "":
                    self.has_pos_net = True
                self.rows.append(r)

    def nval(self, r):
        """the realised money of the position: pos_net (full P/L incl.
        partial shreds, commission and swap); profit for old CSVs"""
        if self.has_pos_net:
            return self._f(r, "pos_net")
        return self._f(r, "profit")

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
        return sum(self.nval(r) for r in rows)

    def extra_at_ref(self, rows, ref_spread, contract_size):
        """sum(max(0, ref_spread - spread_open) x volume x contract)"""
        if not self.has_spread:
            return None
        rows = self.rows if rows is None else rows
        extra = 0.0
        for r in rows:
            gap = ref_spread - self._f(r, "spread_open")
            if gap > 0.0:
                extra += gap * self._f(r, "volume") * contract_size
        return extra

    def net_ref(self, rows, ref_spread, contract_size):
        """net at the reference spread, or None without a spread_open column"""
        if not self.has_spread:
            return None
        rows = self.rows if rows is None else rows
        return self.net(rows) - self.extra_at_ref(rows, ref_spread, contract_size)

    def profit_ref_of(self, r, ref_spread, contract_size):
        gap = ref_spread - self._f(r, "spread_open") if self.has_spread else 0.0
        if gap < 0.0:
            gap = 0.0
        return self.nval(r) - gap * self._f(r, "volume") * contract_size

    def count(self, rows=None):
        rows = self.rows if rows is None else rows
        return len(rows)

    @staticmethod
    def _pf_of_values(pos, neg):
        return (pos / abs(neg)) if neg < 0 else None

    def gross_pf(self, rows=None):
        rows = self.rows if rows is None else rows
        g = sum(self._f(r, "gross") for r in rows if self._f(r, "gross") > 0)
        l = sum(self._f(r, "gross") for r in rows if self._f(r, "gross") < 0)
        return self._pf_of_values(g, l)

    def pf(self, rows=None):
        rows = self.rows if rows is None else rows
        pos = sum(self.nval(r) for r in rows if self.nval(r) > 0)
        neg = sum(self.nval(r) for r in rows if self.nval(r) < 0)
        return self._pf_of_values(pos, neg)

    def pf_ref(self, rows, ref_spread, contract_size):
        """profit factor of the series stressed to the reference spread"""
        if not self.has_spread:
            return None
        rows = self.rows if rows is None else rows
        pos = neg = 0.0
        for r in rows:
            p = self.profit_ref_of(r, ref_spread, contract_size)
            if p > 0:
                pos += p
            elif p < 0:
                neg += p
        return self._pf_of_values(pos, neg)

    def spread_paid(self, rows=None):
        rows = self.rows if rows is None else rows
        return sum(self._f(r, "spread_cost") for r in rows)

    def spread_stats(self, rows=None):
        """(median, p90, n) of the spread_open column"""
        rows = self.rows if rows is None else rows
        vals = sorted(self._f(r, "spread_open") for r in rows
                      if (r.get("spread_open") or "").strip() != "")
        n = len(vals)
        if n == 0:
            return None, None, 0
        return vals[n // 2], vals[int((n - 1) * 0.9)], n

    def by_ref(self, keyfn, rows, ref_spread, contract_size):
        """per key: (count, net, net@ref)"""
        rows = self.rows if rows is None else rows
        out = {}
        for r in rows:
            k = keyfn(r)
            e = out.setdefault(k, [0, 0.0, 0.0])
            e[0] += 1
            e[1] += self.nval(r)
            e[2] += self.profit_ref_of(r, ref_spread, contract_size)
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


def fmt2(a, b, nd=2):
    """'a (b)' - net (net@ref)"""
    return "%s (%s)" % (fmt(a, nd), fmt(b, nd))


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


def find_symbol_info(rdir, data_dir):
    """the TwinPulseSymbolInfo.mq5 output, when the owner saved it"""
    cands = [os.path.join(rdir, "symbol_info.txt"),
             os.path.join(rdir, "TwinPulseSymbolInfo.txt")]
    if data_dir:
        cands.append(os.path.join(data_dir, "..", "Common", "Files", "TwinPulseSymbolInfo.txt"))
    if os.path.isdir(rdir):
        for fn in sorted(os.listdir(rdir)):
            vdir = os.path.join(rdir, fn)
            if os.path.isdir(vdir):
                cands.append(os.path.join(vdir, "TwinPulseSymbolInfo.txt"))
    for p in cands:
        if os.path.isfile(p):
            with open(p, "r", encoding="utf-8", errors="replace") as f:
                return p, f.read()
    return None, None


def main():
    ap = argparse.ArgumentParser(description="TwinPulse decision batch summary")
    ap.add_argument("--data", help="terminal DATA folder")
    ap.add_argument("--reports", help="reports/decision folder (overrides --data)")
    ap.add_argument("--from", dest="d_from", default="2022.01.01")
    ap.add_argument("--to", dest="d_to", default="2026.09.30")
    ap.add_argument("--symbol", default="XAUUSDm")
    ap.add_argument("--contract-size", dest="contract_size", type=float, default=100.0,
                    help="contract size for the spread cost (XAUUSD standard = 100)")
    ap.add_argument("--ref-spread", dest="ref_spread", type=float, default=0.20,
                    help="reference spread in price units (default 0.20 = Exness XAUUSDm median)")
    args = ap.parse_args()

    if args.reports:
        rdir = args.reports
        data_dir = None
    elif args.data:
        data_dir = args.data
        rdir = os.path.join(args.data, "reports", "decision")
    else:
        print("need --data <DATA folder> or --reports <folder>")
        return 2
    if not os.path.isdir(rdir):
        print("folder not found: %s" % rdir)
        return 2

    ref = args.ref_spread
    csize = args.contract_size
    d_from = datetime.strptime(args.d_from, "%Y.%m.%d")
    d_to = datetime.strptime(args.d_to, "%Y.%m.%d") + timedelta(days=1)
    fwd_start = d_from + (d_to - d_from) * 2 / 3     # ForwardMode 2 = forward 1/3

    data = {}
    for v in VARIANTS:
        report, legs = load_variant(os.path.join(rdir, v))
        back_rows = [r for r in legs.rows if legs._close(r) and legs._close(r) < fwd_start]
        fwd_rows = [r for r in legs.rows if legs._close(r) and legs._close(r) >= fwd_start]
        data[v] = {"report": report, "legs": legs,
                   "back_rows": back_rows, "fwd_rows": fwd_rows}

    # ---- run-level spread stats (the run's own spread) --------------
    all_rows = []
    for v in VARIANTS:
        all_rows.extend(data[v]["legs"].rows)
    tmp = Legs()
    tmp.rows = all_rows
    tmp.has_spread = any(data[v]["legs"].has_spread for v in VARIANTS)
    run_median, run_p90, run_n = tmp.spread_stats()

    sym_path, sym_text = find_symbol_info(rdir, data_dir)

    # ---- the better RANDOM control (worse-of-two forward PF) --------
    rnd_pf = None       # report side
    rnd_pf_ref = None   # stressed side (legs level)
    for v in RANDOM:
        _, fwd_pf = pick_pair(data[v]["report"], ["profit factor"])
        if fwd_pf is not None:
            rnd_pf = fwd_pf if rnd_pf is None else max(rnd_pf, fwd_pf)
        pf_ref = data[v]["legs"].pf_ref(data[v]["fwd_rows"], ref, csize)
        if pf_ref is not None:
            rnd_pf_ref = pf_ref if rnd_pf_ref is None else max(rnd_pf_ref, pf_ref)

    def gates(v):
        d = data[v]
        rep, legs = d["report"], d["legs"]
        is_random = v in RANDOM
        fwd_net, _ = pick_pair(rep, ["total net profit"])
        _, fwd_pf = pick_pair(rep, ["profit factor"])
        _, fwd_dd = pick_pair(rep, ["equity drawdown"], pct=True)
        if fwd_dd is None:
            _, fwd_dd = pick_pair(rep, ["drawdown"], pct=True)
        _, fwd_rf = pick_pair(rep, ["recovery factor"])
        total_legs = legs.count()
        hq = rep.get("history_quality")

        # the two series: as recorded and stressed to the reference spread
        fwd_net_ref = legs.net_ref(d["fwd_rows"], ref, csize)
        fwd_pf_ref = legs.pf_ref(d["fwd_rows"], ref, csize)
        h1, h2 = legs.halves(d_from, d_to)
        mid = d_from + (d_to - d_from) / 2
        h1_rows = [r for r in legs.rows if legs._close(r) and legs._close(r) < mid]
        h2_rows = [r for r in legs.rows if legs._close(r) and legs._close(r) >= mid]
        h1_ref = legs.net_ref(h1_rows, ref, csize)
        h2_ref = legs.net_ref(h2_rows, ref, csize)

        g = {}
        g["valid"] = hq is None or hq >= 90.0
        g["hq"] = hq

        # worse-of-two: a net / PF gate must pass on BOTH series
        pf_gate_vals = [x for x in (fwd_pf, fwd_pf_ref) if x is not None]
        g["pf_fwd >= 1.20"] = (len(pf_gate_vals) == 2 and min(pf_gate_vals) >= 1.2)
        g["dd_fwd <= 20%"] = (fwd_dd is not None and fwd_dd <= 20.0)
        g["rf_fwd >= 2"] = (fwd_rf is not None and fwd_rf >= 2.0)
        g["legs >= 200"] = (total_legs >= 200)
        halves_vals = [x for x in (h1, h2, h1_ref, h2_ref) if x is not None]
        g["both halves > 0"] = (len(halves_vals) == 4 and min(halves_vals) > 0)
        if is_random:
            g["beats RANDOM by 0.15 PF"] = None     # control variant
        else:
            diffs = []
            if fwd_pf is not None and rnd_pf is not None:
                diffs.append(fwd_pf - rnd_pf)
            if fwd_pf_ref is not None and rnd_pf_ref is not None:
                diffs.append(fwd_pf_ref - rnd_pf_ref)
            g["beats RANDOM by 0.15 PF"] = (len(diffs) == 2 and min(diffs) >= 0.15)
        g["_vals"] = (fwd_net, fwd_net_ref, fwd_pf, fwd_pf_ref, fwd_dd, fwd_rf,
                      total_legs, h1, h2, h1_ref, h2_ref)
        if not g["valid"]:
            g["_pass"] = False
        else:
            checks = [val for key, val in g.items()
                      if key not in ("valid", "hq", "_vals", "_pass") and val is not None]
            g["_pass"] = all(checks) if checks else False
        return g

    allg = {v: gates(v) for v in VARIANTS}

    # ---- pos_net vs report net (the money must match) --------------
    def report_net_total(rep):
        vals, _ = pick(rep, "total net profit")
        if vals[0] is not None:
            return vals[0]
        parts = [x for x in (vals[1], vals[2]) if x is not None]
        return sum(parts) if parts else None

    posnet = {}
    for v in VARIANTS:
        legs = data[v]["legs"]
        s = legs.net()
        rn = report_net_total(data[v]["report"])
        if rn is None or not legs.rows:
            posnet[v] = (s, rn, None)
            continue
        posnet[v] = (s, rn, abs(s - rn) <= 1.00)

    # ---- the header block (symbol specs + the run's spread) ---------
    head = []
    head.append("## Symbol specs")
    head.append("")
    head.append("- symbol: %s" % args.symbol)
    head.append("- contract size: %s (used for the spread cost)" % fmt(csize, 2))
    head.append("- reference spread: %s (%s, price units)" % (fmt(ref, 3), "--ref-spread"))
    if run_n > 0:
        head.append("- spread of the run (legs.csv `spread_open`, %d legs): median %s, p90 %s"
                    % (run_n, fmt(run_median, 3), fmt(run_p90, 3)))
    else:
        head.append("- spread of the run: " + NA + " (no `spread_open` column in the CSVs)")
    if sym_text:
        head.append("- symbol info (`%s`):" % os.path.basename(sym_path))
        for line in sym_text.strip().splitlines():
            head.append("    " + line)
    else:
        head.append("- symbol info: " + NA + " (run MQL5\\Scripts\\TwinPulse\\TwinPulseSymbolInfo.mq5"
                    " on the batch symbol and keep Common\\Files\\TwinPulseSymbolInfo.txt)")
    head.append("")

    # ---- SUMMARY.md -------------------------------------------------
    def row_md(v):
        d = data[v]
        rep, legs = d["report"], d["legs"]
        b_net = legs.net(d["back_rows"])
        f_net = legs.net(d["fwd_rows"])
        b_ref = legs.net_ref(d["back_rows"], ref, csize)
        f_ref = legs.net_ref(d["fwd_rows"], ref, csize)
        b_pf, _ = pick_pair(rep, ["profit factor"])
        _, f_pf = pick_pair(rep, ["profit factor"])
        _, f_dd = pick_pair(rep, ["equity drawdown"], pct=True)
        if f_dd is None:
            _, f_dd = pick_pair(rep, ["drawdown"], pct=True)
        _, f_rf = pick_pair(rep, ["recovery factor"])
        hq = rep.get("history_quality")
        g = allg[v]
        mark = "NOT VALID FOR GATES" if not g["valid"] else ("PASS" if g["_pass"] else "fail")
        return ("| %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %d | %s | %s | %s |" % (
            v, fmt(hq, 2, "%"),
            fmt(b_net), fmt(b_ref), fmt(f_net), fmt(f_ref),
            fmt(b_pf), fmt(f_pf), fmt(f_dd, 2, "%"), fmt(f_rf),
            legs.count(), fmt(legs.gross_pf()), fmt(legs.spread_paid()), mark))

    lines = []
    lines.append("# TwinPulse decision batch - SUMMARY")
    lines.append("")
    lines.append("period %s .. %s, forward starts %s (ForwardMode 2 = forward 1/3)."
                 % (args.d_from, args.d_to, fwd_start.strftime("%Y.%m.%d")))
    lines.append("Report fields are taken from the tester report; legs / gross / spread")
    lines.append("from `TwinPulse_legs.csv`. Every legs-level net uses the `pos_net`")
    lines.append("column (the full realised P/L of the position). Gates use the FORWARD")
    lines.append("column (PF, DD, RF) and the worse of the two cost series")
    lines.append("(see docs/DECISION_RULES.md).")
    lines.append("net@ref = net at the reference spread, from the legs.csv `spread_open` column.")
    lines.append("")
    lines.extend(head)
    lines.append("## Per variant")
    lines.append("")
    lines.append("| variant | HQ | BACK net | BACK net@ref | FWD net | FWD net@ref | BACK PF | FWD PF | FWD eq DD | FWD RF | legs | gross PF | spread paid | verdict |")
    lines.append("|---|---|---|---|---|---|---|---|---|---|---|---|---|---|")
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
    lines.append("better RANDOM control: forward PF %s (report), %s (at reference spread)"
                 % (fmt(rnd_pf), fmt(rnd_pf_ref)))
    lines.append("")
    lines.append("## pos_net vs report net (must match within 1.00)")
    lines.append("")
    lines.append("| variant | sum(pos_net) | report net | check |")
    lines.append("|---|---|---|---|")
    for v in VARIANTS:
        s, rn, ok = posnet[v]
        if ok is None:
            mark = NA
        elif ok:
            mark = "OK"
        else:
            mark = "**MISMATCH**"
        lines.append("| %s | %s | %s | %s |" % (v, fmt(s), fmt(rn), mark))
    lines.append("")
    bad = [v for v in VARIANTS if posnet[v][2] is False]
    if bad:
        lines.append("**MISMATCH**: sum(pos_net) and the report net disagree for %s -"
                     " the legs.csv accounting does not add up to the tester report." % ", ".join(bad))
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
        s, rn, ok = posnet[v]
        if ok is None:
            lines.append("sum(pos_net) %s vs report net: %s" % (fmt(s), fmt(rn)))
        else:
            lines.append("sum(pos_net) %s vs report net %s: %s"
                         % (fmt(s), fmt(rn), "OK" if ok else "**MISMATCH**"))
        byyear = legs.by_ref(lambda r: r["time"][:4], legs.rows, ref, csize)
        bymonth = legs.by_ref(lambda r: r["time"][:7], legs.rows, ref, csize)
        byreason = legs.by_ref(lambda r: r.get("reason", "?"), legs.rows, ref, csize)
        byleg = legs.by_ref(lambda r: r.get("leg", "?"), legs.rows, ref, csize)
        lines.append("net per year (net@ref): " + "; ".join(
            "%s: %s [%d legs]" % (k, fmt2(byyear[k][1], byyear[k][2]), byyear[k][0])
            for k in sorted(byyear)))
        if bymonth:
            worst = min(bymonth.items(), key=lambda kv: kv[1][2])
            lines.append("worst month (at reference spread): %s (%s) [%d legs]"
                         % (worst[0], fmt2(worst[1][1], worst[1][2]), worst[1][0]))
        lines.append("gross before spread PF: %s, spread paid: %s"
                     % (fmt(legs.gross_pf()), fmt(legs.spread_paid())))
        lines.append("")
        lines.append("| exit reason | legs | net | net@ref |")
        lines.append("|---|---|---|---|")
        for k in sorted(byreason):
            lines.append("| %s | %d | %.2f | %.2f |" % (k, byreason[k][0], byreason[k][1], byreason[k][2]))
        lines.append("")
        lines.append("| leg | legs | net | net@ref |")
        lines.append("|---|---|---|---|")
        for k in sorted(byleg):
            lines.append("| %s | %d | %.2f | %.2f |" % (k, byleg[k][0], byleg[k][1], byleg[k][2]))
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
    b.extend(head)
    b.append("| variant | HQ | BACK net | BACK net@ref | BACK PF | legs (back) | gross PF (back) | spread paid (back) |")
    b.append("|---|---|---|---|---|---|---|---|")
    for v in VARIANTS:
        d = data[v]
        rep, legs = d["report"], d["legs"]
        br = d["back_rows"]
        b_net = legs.net(br)
        b_ref = legs.net_ref(br, ref, csize)
        b_pf, _ = pick_pair(rep, ["profit factor"])
        hq = rep.get("history_quality")
        b.append("| %s | %s | %s | %s | %s | %d | %s | %s |" % (
            v, fmt(hq, 2, "%"), fmt(b_net), fmt(b_ref), fmt(b_pf),
            legs.count(br), fmt(legs.gross_pf(br)), fmt(legs.spread_paid(br))))
    b.append("")
    for v in VARIANTS:
        legs = data[v]["legs"]
        br = data[v]["back_rows"]
        if not br:
            continue
        b.append("## %s (BACK)" % v)
        b.append("")
        byyear = legs.by_ref(lambda r: r["time"][:4], br, ref, csize)
        byreason = legs.by_ref(lambda r: r.get("reason", "?"), br, ref, csize)
        byleg = legs.by_ref(lambda r: r.get("leg", "?"), br, ref, csize)
        b.append("net per year (net@ref): " + "; ".join(
            "%s: %s [%d legs]" % (k, fmt2(byyear[k][1], byyear[k][2]), byyear[k][0])
            for k in sorted(byyear)))
        b.append("")
        b.append("| exit reason | legs | net | net@ref |")
        b.append("|---|---|---|---|")
        for k in sorted(byreason):
            b.append("| %s | %d | %.2f | %.2f |" % (k, byreason[k][0], byreason[k][1], byreason[k][2]))
        b.append("")
        b.append("| leg | legs | net | net@ref |")
        b.append("|---|---|---|---|")
        for k in sorted(byleg):
            b.append("| %s | %d | %.2f | %.2f |" % (k, byleg[k][0], byleg[k][1], byleg[k][2]))
        b.append("")

    with open(os.path.join(rdir, "SUMMARY_BACK.md"), "w", encoding="utf-8") as f:
        f.write("\n".join(b) + "\n")

    print("wrote %s" % os.path.join(rdir, "SUMMARY.md"))
    print("wrote %s" % os.path.join(rdir, "SUMMARY_BACK.md"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
