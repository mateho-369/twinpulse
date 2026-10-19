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
import io
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


def read_text_file(path):
    """read an MT5 file whatever encoding it uses.

    The tester writes report.htm (and the CSVs of some builds) in UTF-16
    with a BOM; reading those as UTF-8 leaves a NUL between every
    character, so every label match fails and the whole report reads as
    `n/a`. Decode by BOM, then try the usual code pages.
    """
    with open(path, "rb") as f:
        raw = f.read()
    if raw[:2] in (b"\xff\xfe", b"\xfe\xff"):
        return raw.decode("utf-16", errors="replace")
    if raw[:3] == b"\xef\xbb\xbf":
        return raw.decode("utf-8-sig", errors="replace")
    if raw[:2] == b"PK":
        return ""
    for enc in ("utf-8", "cp1252", "latin-1"):
        try:
            return raw.decode(enc)
        except UnicodeDecodeError:
            continue
    return raw.decode("latin-1", errors="replace")


def parse_report(path):
    """extract the statistics rows of an MT5 tester report (tolerant)."""
    out = {"history_quality": None, "rows": {}, "last_trade": None}
    if not os.path.isfile(path):
        return out
    html = read_text_file(path)
    rows = re.findall(r"<tr[^>]*>(.*?)</tr>", html, re.S | re.I)
    for row in rows:
        cells = re.findall(r"<t[dh][^>]*>(.*?)</t[dh]>", row, re.S | re.I)
        cells = [strip_tags(c).replace("\xa0", " ").strip() for c in cells]
        cells = [c for c in cells if c != ""]
        if len(cells) < 2:
            continue
        first = cells[0].strip()
        if re.match(r"^\d{4}\.\d{2}\.\d{2} \d{2}:\d{2}", first):
            # a trade row: remember the newest one (tells which period the
            # saved report really covers - the forward pass is not in it)
            try:
                t = datetime.strptime(first[:19], "%Y.%m.%d %H:%M:%S")
                if out["last_trade"] is None or t > out["last_trade"]:
                    out["last_trade"] = t
            except ValueError:
                pass
        label = first.lower()
        out["rows"].setdefault(label, []).append(cells[1:])
        # MT5 packs three label/value pairs into one <tr>:
        #   "Gross Profit: | 856.85 | Balance Drawdown Maximal: | 185 (18%) | ..."
        # register the inline labels too, otherwise every *Maximal* /
        # *Relative* value (equity drawdown maximal, recovery factor of the
        # second column, ...) is invisible.
        for i in range(1, len(cells) - 1):
            if cells[i].endswith(":") and not cells[i + 1].endswith(":"):
                out["rows"].setdefault(cells[i].strip().lower(), []).append(cells[i + 1:])
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
    1 cell = one single-column report -> (value, None).

    A single-column report is NEVER copied into the forward side: the
    tester writes the report of the backtest pass only, so duplicating the
    value made BACK PF == FWD PF and a gate could have passed on a number
    that was never measured forward."""
    vals, pcts = pick(report, *needles)
    use = vals
    if pct and any(p is not None for p in pcts):
        use = pcts
    if use[2] is None and use[1] is not None:
        return use[0], use[1]
    if use[1] is None:
        return use[0], None
    return use[1], use[2]


class Legs(object):
    def __init__(self):
        self.rows = []
        self.has_spread = False
        self.has_pos_net = False

    def load(self, path):
        if not os.path.isfile(path):
            return
        with io.StringIO(read_text_file(path), newline="") as f:
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


EMPTY_REPORT = {"history_quality": None, "rows": {}, "last_trade": None}


def _first_file(vdir, names):
    for n in names:
        p = os.path.join(vdir, n)
        if os.path.isfile(p):
            return p
    return None


def load_variant(vdir):
    """read one variant folder -> dict.

    Layout A (current tools/run_batch.ps1): backtest and forward are two
    separate tester runs, each with its own report and its own CSVs -
    `report_back.htm` / `report_fwd.htm` and `TwinPulse_legs_back.csv` /
    `TwinPulse_legs_fwd.csv`. This is the layout that gives a real forward
    report: a single run with ForwardMode saved the backtest column only
    (its trade list stopped at the forward boundary while the CSVs went on).
    Layout B (older runs): one `report.htm` (backtest only) and one
    `TwinPulse_legs.csv` with both periods mixed together.
    """
    out = {"report_back": None, "report_fwd": None,
           "legs": Legs(), "legs_back": Legs(), "legs_fwd": Legs(),
           "split": False, "report": EMPTY_REPORT}

    p_back = _first_file(vdir, ("report_back.htm", "report_back.html"))
    p_fwd = _first_file(vdir, ("report_fwd.htm", "report_fwd.html"))
    c_back = _first_file(vdir, ("TwinPulse_legs_back.csv",))
    c_fwd = _first_file(vdir, ("TwinPulse_legs_fwd.csv",))

    if p_back or p_fwd or c_back or c_fwd:
        out["split"] = True
        out["report_back"] = parse_report(p_back) if p_back else None
        out["report_fwd"] = parse_report(p_fwd) if p_fwd else None
        if c_back:
            out["legs_back"].load(c_back)
        if c_fwd:
            out["legs_fwd"].load(c_fwd)
        legs = out["legs"]
        legs.rows = list(out["legs_back"].rows) + list(out["legs_fwd"].rows)
        legs.has_spread = out["legs_back"].has_spread or out["legs_fwd"].has_spread
        legs.has_pos_net = out["legs_back"].has_pos_net or out["legs_fwd"].has_pos_net
        out["report"] = out["report_back"] or EMPTY_REPORT
        return out

    rep_path = _first_file(vdir, ("report.htm", "report.html"))
    if rep_path is None:
        for fn in sorted(os.listdir(vdir)) if os.path.isdir(vdir) else []:
            if fn.lower().endswith((".htm", ".html")):
                rep_path = os.path.join(vdir, fn)
                break
    out["report_back"] = parse_report(rep_path) if rep_path else None
    out["report"] = out["report_back"] or EMPTY_REPORT
    out["legs"].load(os.path.join(vdir, "TwinPulse_legs.csv"))
    return out


def rval(report, needles, pct=False):
    """the single value of a statistics row of a one-column report"""
    if report is None:
        return None
    vals, pcts = pick(report, *needles)
    use = pcts if (pct and any(p is not None for p in pcts)) else vals
    return use[0]


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
            return p, read_text_file(p)
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
    d_last = datetime.strptime(args.d_to, "%Y.%m.%d")          # ToDate is inclusive
    d_to = d_last + timedelta(days=1)                           # exclusive
    # same split as tools/run_batch.ps1: floor(span * 2/3) whole days
    fwd_start = d_from + timedelta(days=int((d_last - d_from).days * 2 / 3))

    data = {}
    for v in VARIANTS:
        d = load_variant(os.path.join(rdir, v))
        legs = d["legs"]
        if d["split"]:
            d["back_rows"] = d["legs_back"].rows
            d["fwd_rows"] = d["legs_fwd"].rows
        else:
            d["back_rows"] = [r for r in legs.rows
                              if legs._close(r) and legs._close(r) < fwd_start]
            d["fwd_rows"] = [r for r in legs.rows
                             if legs._close(r) and legs._close(r) >= fwd_start]
        data[v] = d

    def pair(v, needles, pct=False):
        """-> (back, fwd) of one statistic, from the two reports when the
        batch used the split layout; a legacy single-column report gives
        (value, None) - the forward side was never measured."""
        d = data[v]
        b = rval(d["report_back"], needles, pct)
        if d["report_fwd"] is not None:
            return b, rval(d["report_fwd"], needles, pct)
        return pick_pair(d["report"], needles, pct)

    # ---- refuse to judge an empty batch -----------------------------
    # A batch whose tester never started (MT5 still open -> /config is
    # ignored, wrong Expert name, missing history, ...) leaves no report
    # and no CSV behind. Writing "STOP the hedge idea" from that would be
    # a false verdict, so stop here and name the probable cause instead.
    def _has_data(d):
        if d["legs"].rows:
            return True
        return rval(d["report_back"], ["total net profit"]) is not None

    if not any(_has_data(data[v]) for v in VARIANTS):
        print("NO DATA: no variant has a report or legs.csv rows in %s" % rdir)
        print("         the batch did NOT run - the tester produced nothing.")
        print("         check: (1) was MetaTrader 5 completely closed when")
        print("                    run_batch.ps1 started? /config is ignored")
        print("                    while the terminal is open;")
        print("                (2) does <DATA>\\MQL5\\Experts\\TwinPulse\\TwinPulse.ex5 exist?")
        print("                (3) does the .ini Expert= name match the .ex5?")
        print("SUMMARY.md / SUMMARY_BACK.md were NOT written - no verdict.")
        return 3

    # a partial batch (the overnight run was interrupted, or only some
    # variants were run with -Only) must not produce a verdict either
    missing = [v for v in VARIANTS if not _has_data(data[v])]

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
        _, fwd_pf = pair(v, ["profit factor"])
        if fwd_pf is not None:
            rnd_pf = fwd_pf if rnd_pf is None else max(rnd_pf, fwd_pf)
        pf_ref = data[v]["legs"].pf_ref(data[v]["fwd_rows"], ref, csize)
        if pf_ref is not None:
            rnd_pf_ref = pf_ref if rnd_pf_ref is None else max(rnd_pf_ref, pf_ref)

    def gates(v):
        d = data[v]
        legs = d["legs"]
        is_random = v in RANDOM
        _, fwd_net = pair(v, ["total net profit"])
        _, fwd_pf = pair(v, ["profit factor"])
        # the MAXIMAL drawdown, in percent - not "Equity Drawdown Absolute"
        # (that is money, and it sits in the "Total Net Profit" row)
        _, fwd_dd = pair(v, ["equity drawdown maximal"], pct=True)
        if fwd_dd is None:
            _, fwd_dd = pair(v, ["equity drawdown relative"], pct=True)
        _, fwd_rf = pair(v, ["recovery factor"])
        total_legs = legs.count()
        hq = (d["report_back"] or {}).get("history_quality")
        hq_f = (d["report_fwd"] or {}).get("history_quality") if d["report_fwd"] else None

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
        # a gate needs real tick history on BOTH sides; a missing forward
        # report is not "no history" but it leaves every forward gate None,
        # so the variant cannot pass anyway
        g["valid"] = ((hq is None or hq >= 90.0) and
                      (hq_f is None or hq_f >= 90.0))
        g["hq"] = hq
        g["hq_f"] = hq_f

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
                      if key not in ("valid", "hq", "hq_f", "_vals", "_pass") and val is not None]
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
        d = data[v]
        legs = d["legs"]
        row = []
        for rows, rep in ((d["back_rows"], d["report_back"]),
                          (d["fwd_rows"], d["report_fwd"])):
            rn = report_net_total(rep) if rep is not None else None
            if rn is None:
                row.append((legs.net(rows) if rows else None, None, None))
                continue
            # only the rows the report really covers: the tester report of a
            # single run ends at its last trade (the forward pass of a
            # ForwardMode run is NOT in the saved report, while the CSVs go
            # on), so comparing it with every row of the period is wrong
            lt = rep.get("last_trade")
            use = rows
            if lt is not None:
                use = [r for r in rows if legs._close(r) is None or legs._close(r) <= lt]
            s = legs.net(use)
            row.append((s, rn, abs(s - rn) <= 1.00))
        posnet[v] = row

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
        b_pf, f_pf = pair(v, ["profit factor"])
        _, f_dd = pair(v, ["equity drawdown maximal"], pct=True)
        if f_dd is None:
            _, f_dd = pair(v, ["equity drawdown relative"], pct=True)
        _, f_rf = pair(v, ["recovery factor"])
        g = allg[v]
        hq = g["hq"]
        hq_f = g["hq_f"]
        hq_txt = fmt(hq, 2, "%") if hq_f is None else ("%s / %s" % (fmt(hq, 2, "%"), fmt(hq_f, 2, "%")))
        if not g["valid"]:
            mark = "NOT VALID FOR GATES"
        elif f_pf is None and f_dd is None:
            mark = "NO FORWARD REPORT"
        else:
            mark = "PASS" if g["_pass"] else "fail"
        return ("| %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %d | %s | %s | %s |" % (
            v, hq_txt,
            fmt(b_net), fmt(b_ref), fmt(f_net), fmt(f_ref),
            fmt(b_pf), fmt(f_pf), fmt(f_dd, 2, "%"), fmt(f_rf),
            legs.count(), fmt(legs.gross_pf()), fmt(legs.spread_paid()), mark))

    lines = []
    lines.append("# TwinPulse decision batch - SUMMARY")
    lines.append("")
    if missing:
        lines.append("> **BATCH INCOMPLETE** - no data for: %s" % ", ".join(missing))
        lines.append("> (the tester produced no report / no legs.csv rows for them).")
        lines.append("> The gates below only describe the variants that ran - this file")
        lines.append("> contains NO verdict. Run `run_batch.ps1` again (it is resume-safe)")
        lines.append("> and re-summarize with the complete batch.")
        lines.append("")
    split_layout = any(d["split"] for d in data.values())
    lines.append("period %s .. %s, forward starts %s (forward = the last 1/3)."
                 % (args.d_from, args.d_to, fwd_start.strftime("%Y.%m.%d")))
    if split_layout:
        lines.append("Backtest and forward are two SEPARATE tester runs"
                     " (`report_back` / `report_fwd`), so every forward"
                     " number is measured, not copied.")
    else:
        lines.append("Legacy single-run layout: the saved report covers the"
                     " backtest only, the forward columns stay n/a.")
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
    lines.append("| variant | sum(pos_net) BACK | report net BACK | check |"
                 " sum(pos_net) FWD | report net FWD | check |")
    lines.append("|---|---|---|---|---|---|---|")
    def _chk(ok):
        if ok is None:
            return NA
        return "OK" if ok else "**MISMATCH**"

    for v in VARIANTS:
        (sb, rb_, ob), (sf, rf_, of) = posnet[v]
        lines.append("| %s | %s | %s | %s | %s | %s | %s |"
                     % (v, fmt(sb), fmt(rb_), _chk(ob), fmt(sf), fmt(rf_), _chk(of)))
    lines.append("")
    bad = [v for v in VARIANTS if posnet[v][0][2] is False or posnet[v][1][2] is False]
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
        for side, (s, rn, ok) in zip(("BACK", "FWD"), posnet[v]):
            if ok is None:
                lines.append("%s: sum(pos_net) %s vs report net: %s"
                             % (side, fmt(s), fmt(rn)))
            else:
                lines.append("%s: sum(pos_net) %s vs report net %s: %s"
                             % (side, fmt(s), fmt(rn), "OK" if ok else "**MISMATCH**"))
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
    if missing:
        lines.append("**BATCH INCOMPLETE - no verdict.** Missing data for: %s."
                     % ", ".join(missing))
        lines.append("A verdict needs all 8 variants; rerun the batch (resume-safe)")
        lines.append("and re-summarize.")
    elif not any(allg[v]["valid"] for v in VARIANTS):
        lines.append("**NO VALID RESULT - no verdict.** The history quality is below")
        lines.append("90% for every variant (BOTH halves must be at least 90%), so the")
        lines.append("numbers describe a mostly synthetic tick stream. Do not read the")
        lines.append("gross PF or the gates as a result: download the real ticks of the")
        lines.append("symbol for the whole period and rerun the batch.")
    elif any(d["report_fwd"] is None for d in data.values()):
        lines.append("**NO FORWARD REPORT - no verdict.** The forward period has no")
        lines.append("tester report, so the forward gates (PF / DD / RF) were not")
        lines.append("measured. Rerun the batch with the current run_batch.ps1 (it runs")
        lines.append("backtest and forward as two separate tester runs).")
    elif passing:
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
    if missing:
        b.append("> **BATCH INCOMPLETE** - no data for: %s (no verdict)." % ", ".join(missing))
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
