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

# The variant list is DISCOVERED from the reports folder: the decision batch
# (V1..V8) and a preset round (tester\upgrade: W1..W6) both work without
# touching this file. Any folder that holds a report or a legs CSV counts;
# a "RANDOM" control is recognised by its name.
VARIANTS = []
RANDOM = []

# ---------------------------------------------------------------------------
#  FAMILIES
#  Every family has its own frozen rule document. The hedge gates (PF 1.20,
#  RF 2, "STOP the hedge idea") must NEVER be applied to a strategy they were
#  not written for: a trend EA judged with hedge gates is a false verdict in
#  both directions.
# ---------------------------------------------------------------------------
FAMILY = None
FAMILIES = {
    # leaf folder name -> family
    "decision": "hedge",
    "upgrade":  "hedge",
    "trend":    "trend",
    "reversal": "reversal",
    "scalp":    "scalp",
}
FAMILY_DOC = {
    "hedge":    "docs/DECISION_RULES.md",
    "trend":    "docs/DECISION_RULES_2.md",
    "reversal": "docs/DECISION_RULES_2.md (reversal section) + docs/REVERSAL_TEST.md",
    "scalp":    "docs/DECISION_RULES_3.md",
}


def detect_family(rdir, explicit=None):
    """the family of a batch: explicit --rules wins, else the reports folder.

    Fails LOUDLY: an unknown folder is never guessed, because guessing wrong
    means printing a verdict against the wrong rulebook."""
    if explicit:
        fam = explicit.strip().lower()
        if fam not in FAMILY_DOC:
            raise SystemExit("ERROR: unknown --rules '%s' (known: %s)"
                             % (explicit, ", ".join(sorted(FAMILY_DOC))))
        return fam
    leaf = os.path.basename(os.path.normpath(rdir)).lower()
    if leaf in FAMILIES:
        return FAMILIES[leaf]
    raise SystemExit(
        "ERROR: cannot tell which rulebook applies to reports folder '%s'.\n"
        "       Known folders: %s.\n"
        "       Pass --rules {hedge|trend|reversal} explicitly instead of letting\n"
        "       a guess pick the gates." % (leaf, ", ".join(sorted(FAMILIES))))


def discover(rdir):
    """folders of rdir that carry a tester report or a legs CSV"""
    out = []
    if not os.path.isdir(rdir):
        return out
    for fn in sorted(os.listdir(rdir)):
        vdir = os.path.join(rdir, fn)
        if not os.path.isdir(vdir) or fn.startswith("_"):
            continue
        names = os.listdir(vdir)
        has = any(n.lower().endswith((".htm", ".html")) for n in names) or \
              any(n.startswith("TwinPulse_legs") and n.endswith(".csv") for n in names)
        if has:
            out.append(fn)
    return out
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
        """The EA writes `2026.08.03 14:05:00`. Accept dashes and a missing
        seconds field too, so a format change lowers the row into a warning
        instead of silently emptying every per-day figure."""
        t = (r.get("time") or "").strip()
        for f in ("%Y.%m.%d %H:%M:%S", "%Y.%m.%d %H:%M",
                  "%Y-%m-%d %H:%M:%S", "%Y-%m-%d %H:%M"):
            try:
                return datetime.strptime(t, f)
            except Exception:
                pass
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



# ===========================================================================
#  ROUND 3+ FAMILIES (trend / reversal)
#
#  Separate on purpose. The hedge rules (docs/DECISION_RULES.md) ask a
#  different question and would give a false verdict here. These gates come
#  from docs/DECISION_RULES_2.md and were frozen before the first round-3
#  report existed.
# ===========================================================================

def coverage_probe(legs, rows, d_from, d_to):
    """days that produced a closed leg, against the weekdays in the window.

    Printed in every SUMMARY, never gated: a trend EA can go two weeks
    without a trade and still be healthy. It exists so a mostly empty run is
    visible instead of looking like a small sample."""
    days = set()
    for r in rows:
        t = legs._close(r)
        if t is not None:
            days.add(t.date())
    weekdays = 0
    d = d_from.date()
    end = d_to.date()
    while d < end:
        if d.weekday() < 5:
            weekdays += 1
        d = d + timedelta(days=1)
    pct = (100.0 * len(days) / weekdays) if weekdays else None
    return len(days), weekdays, pct


def _median(vals):
    vals = sorted(v for v in vals if v is not None)
    if not vals:
        return None
    n = len(vals)
    if n % 2:
        return vals[n // 2]
    return (vals[n // 2 - 1] + vals[n // 2]) / 2.0


def _stop_distances(legs, rows, sl_atr):
    """stop distance in price units per closed leg.

    New EAs write `stop_dist` (the distance actually used at entry). The
    hedge EA never did, so fall back to sl_atr x `atr5` - and say which."""
    out = []
    used_col = False
    for r in rows:
        v = (r.get("stop_dist") or "").strip()
        if v != "":
            used_col = True
            try:
                out.append(float(v))
            except ValueError:
                pass
    if used_col:
        return out, "stop_dist (as used at entry)"
    for r in rows:
        a = (r.get("atr5") or "").strip()
        if a != "":
            try:
                out.append(float(a) * sl_atr)
            except ValueError:
                pass
    return out, "atr5 x %.2f (hedge EA: HardSL_ATR)" % sl_atr


def _cycle_key(r):
    return r.get("cycle", "?")


def family_summary(ctx):
    """SUMMARY for the trend / reversal families. Returns 0 on success."""
    data = ctx["data"]
    VARIANTS_ = ctx["variants"]
    ref = ctx["ref"]
    csize = ctx["csize"]
    d_from = ctx["d_from"]
    d_to = ctx["d_to"]
    fwd_start = ctx["fwd_start"]
    d_from_s = ctx["d_from_s"]
    d_to_s = ctx["d_to_s"]
    risk_pct = ctx["risk_pct"]
    sl_atr = ctx["sl_atr"]
    missing = ctx["missing"]
    stale_warning = ctx["stale_warning"]
    posnet = ctx["posnet"]
    pair = ctx["pair"]
    rdir = ctx["rdir"]

    rev = (FAMILY == "reversal")
    randoms = [v for v in VARIANTS_ if "random" in v.lower() or "ctl" in v.lower()]

    # the best control, measured on the forward half and stressed
    ctl_pf, ctl_pf_ref = None, None
    for v in randoms:
        d = data[v]
        _, f = pair(v, ["profit factor"])
        if f is not None:
            ctl_pf = f if ctl_pf is None else max(ctl_pf, f)
        pr = d["legs"].pf_ref(d["fwd_rows"], ref, csize)
        if pr is not None:
            ctl_pf_ref = pr if ctl_pf_ref is None else max(ctl_pf_ref, pr)

    def stats(v):
        d = data[v]
        legs = d["legs"]
        frows = d["fwd_rows"]
        _, f_net = pair(v, ["total net profit"])
        _, f_pf = pair(v, ["profit factor"])
        _, f_dd = pair(v, ["equity drawdown maximal"], pct=True)
        if f_dd is None:
            _, f_dd = pair(v, ["equity drawdown relative"], pct=True)
        vals = [legs.nval(r) for r in frows]
        wins = [x for x in vals if x > 0]
        losses = [x for x in vals if x < 0]
        gross_win = sum(wins)
        largest = max(wins) if wins else 0.0
        pfs = [x for x in (f_pf, legs.pf_ref(frows, ref, csize)) if x is not None]
        sd, sd_src = _stop_distances(legs, frows, sl_atr)
        cycles = len(set(_cycle_key(r) for r in frows))
        return {
            "legs": legs, "frows": frows,
            "net": legs.net(frows), "net_rep": f_net,
            "net_ref": legs.net_ref(frows, ref, csize),
            "pf": f_pf, "pf_ref": legs.pf_ref(frows, ref, csize),
            "pf_worst": min(pfs) if pfs else None,
            "dd": f_dd, "trades": len(frows), "cycles": cycles,
            "gross_win": gross_win, "largest": largest,
            "stop_med": _median(sd), "stop_src": sd_src,
            "pf_gap": (min(pfs) - max([x for x in (ctl_pf, ctl_pf_ref) if x is not None])
                       if pfs and (ctl_pf is not None or ctl_pf_ref is not None) else None),
        }

    st = {v: stats(v) for v in VARIANTS_}

    def gates(v):
        s_ = st[v]
        g = {}
        g["net_fwd > 0"] = s_["net"] > 0
        g["pf_fwd >= 1.10"] = (s_["pf_worst"] is not None and s_["pf_worst"] >= 1.10)
        g["dd_fwd <= 20%"] = (s_["dd"] is not None and s_["dd"] <= 20.0)
        if rev:
            g["cycles >= 30"] = s_["cycles"] >= 30
            g["no position open at end"] = (posnet[v][1][2] is True)
            g["no single cycle > 25% of net"] = (
                s_["largest"] <= 0.25 * s_["net"] if s_["net"] > 0 else False)
        else:
            g["trades >= 30"] = s_["trades"] >= 30
            g["largest win <= 40% of gross"] = (
                s_["largest"] <= 0.40 * s_["gross_win"] if s_["gross_win"] > 0 else False)
            if v in randoms:
                g["beats CONTROL by 0.15 PF"] = None
            else:
                g["beats CONTROL by 0.15 PF"] = (
                    s_["pf_gap"] is not None and s_["pf_gap"] >= 0.15)
        g["pos_net == report (both halves)"] = (
            posnet[v][0][2] is True and posnet[v][1][2] is True)
        checks = [x for x in g.values() if x is not None]
        g["_pass"] = all(checks) if checks else False
        return g

    allg = {v: gates(v) for v in VARIANTS_}

    def money(x):
        return "n/a" if x is None else "%.2f" % x

    def pct(x, d=2):
        return "n/a" if x is None else ("%.*f%%" % (d, x))

    L = []
    L.append("# TwinPulse %s batch - SUMMARY" % FAMILY)
    L.append("")
    L.append("Rulebook: **%s** (frozen before the first report of this family)."
             % FAMILY_DOC[FAMILY])
    L.append("")
    if stale_warning:
        L.append("> **IDENTICAL RESULTS - the settings were not applied.** %s"
                 % ", ".join(stale_warning))
        L.append("> MT5 drops unknown `.set` keys when the `.ex5` is older than the")
        L.append("> inputs. Recompile (F7, 0 errors) and rerun.")
        L.append("")
    if missing:
        L.append("> **BATCH INCOMPLETE** - no data for: %s. No verdict." % ", ".join(missing))
        L.append("")
    L.append("period %s .. %s, forward starts %s (forward = the last 1/3)."
             % (d_from_s, d_to_s, fwd_start.strftime("%Y.%m.%d")))
    L.append("")
    L.append("Every forward number below is measured from `report_fwd` /")
    L.append("`TwinPulse_legs_fwd.csv`; nothing is copied from the back half.")
    L.append("")
    L.append("Coverage probe (printed, not gated - see the rulebook):")
    L.append("")
    for v in VARIANTS_:
        dd, wd, pc = coverage_probe(data[v]["legs"], data[v]["fwd_rows"], d_from, d_to)
        L.append("* `%s`: %d days with a closed leg of %d weekdays (%.1f%%)"
                 % (v, dd, wd, pc if pc is not None else 0.0))
    L.append("")

    L.append("## Per variant")
    L.append("")
    L.append("| variant | FWD net | FWD net@ref | FWD PF | FWD PF@ref | FWD eq DD | trades | cycles | verdict |")
    L.append("|---|---|---|---|---|---|---|---|---|")
    for v in VARIANTS_:
        s_ = st[v]
        g = allg[v]
        mark = "PASS" if g["_pass"] else "fail"
        if missing and v in missing:
            mark = "NO DATA"
        L.append("| %s | %s | %s | %s | %s | %s | %d | %d | %s |"
                 % (v, money(s_["net"]), money(s_["net_ref"]),
                    money(s_["pf"]), money(s_["pf_ref"]), pct(s_["dd"]),
                    s_["trades"], s_["cycles"], mark))
    L.append("")

    L.append("## Gate table")
    L.append("")
    keys = [k for k in allg[VARIANTS_[0]] if not k.startswith("_")]
    L.append("| variant | " + " | ".join(keys) + " |")
    L.append("|---" * (len(keys) + 1) + "|")
    for v in VARIANTS_:
        cells = []
        for k in keys:
            val = allg[v].get(k)
            cells.append("n/a" if val is None else ("YES" if val else "no"))
        L.append("| %s | %s |" % (v, " | ".join(cells)))
    L.append("")
    if randoms:
        L.append("control(s) %s: forward PF %s (report), %s (at reference spread)"
                 % (", ".join(randoms), money(ctl_pf), money(ctl_pf_ref)))
        L.append("")

    # ---- minimum deposit ---------------------------------------------------
    L.append("## Minimum deposit for the intended risk")
    L.append("")
    L.append("A 0.01 lot of %s is the broker minimum and risks **1 USD per 1.00 of"
             % ctx["symbol"])
    L.append("price distance**. The EA is designed for %.2f%% of equity per trade,"
             % risk_pct)
    L.append("so a 0.01 lot only equals that risk when the account is big enough:")
    L.append("")
    L.append("| variant | median stop distance | min deposit (0.01 lot = %.2f%%) |"
             % risk_pct)
    L.append("|---|---|---|")
    for v in VARIANTS_:
        s_ = st[v]
        sd = s_["stop_med"]
        md = (100.0 * sd / risk_pct) if sd else None
        L.append("| %s | %s | %s |"
                 % (v, money(sd), ("%.0f USD" % md) if md else "n/a"))
    L.append("")
    L.append("Source of the stop distance: %s."
             % (st[VARIANTS_[0]]["stop_src"] if VARIANTS_ else "n/a"))
    L.append("")

    # ---- open positions ----------------------------------------------------
    L.append("## Money check (report net vs sum of closed legs)")
    L.append("")
    L.append("| variant | sum(pos_net) BACK | report BACK | sum(pos_net) FWD | report FWD | open at end |")
    L.append("|---|---|---|---|---|---|")
    for v in VARIANTS_:
        (sb, rb_, ob), (sf, rf_, of) = posnet[v]
        gap = None
        if sf is not None and rf_ is not None:
            gap = rf_ - sf
        txt = "n/a" if gap is None else "%.2f" % gap
        L.append("| %s | %s | %s | %s | %s | %s |" % (v, money(sb), money(rb_),
                                                      money(sf), money(rf_), txt))
    L.append("")
    bad = [v for v in VARIANTS_ if posnet[v][1][2] is False]
    if bad:
        L.append("**MISMATCH / OPEN POSITIONS**: %s - the closed legs do not add up"
                 % ", ".join(bad))
        L.append("to the report net, which means a position was still open at the end")
        L.append("(its floating P/L is in neither the report nor the CSV). Treat the")
        L.append("run as invalid until the EA closes everything on the last bar.")
        L.append("")

    # ---- exits -------------------------------------------------------------
    L.append("## Exit reasons (FORWARD half)")
    L.append("")
    L.append("| exit | legs | net | net@ref |")
    L.append("|---|---|---|---|")
    agg = {}
    for v in VARIANTS_:
        legs, rows = st[v]["legs"], st[v]["frows"]
        for r in rows:
            k = r.get("reason", "?")
            a = agg.setdefault(k, [0, 0.0, 0.0])
            a[0] += 1
            a[1] += legs.nval(r)
            a[2] += legs.profit_ref_of(r, ref, csize)
    for k in sorted(agg):
        L.append("| %s | %d | %.2f | %.2f |" % (k, agg[k][0], agg[k][1], agg[k][2]))
    L.append("")

    # ---- verdict -----------------------------------------------------------
    L.append("## Verdict")
    L.append("")
    if missing or not any(data[v]["legs"].rows or data[v]["report_fwd"] for v in VARIANTS_):
        L.append("**NO VERDICT** - the batch is incomplete or produced no data.")
    else:
        passing = [v for v in VARIANTS_ if allg[v]["_pass"]]
        if passing:
            L.append("**PASS: %s** against %s." % (", ".join(passing), FAMILY_DOC[FAMILY]))
            L.append("")
            L.append("A pass is a pass of the BAR-BASED test only. It does not permit")
            L.append("a demo account or any live claim until the forward half is")
            L.append("reproduced with `Model=4` (real ticks) - see the rulebook.")
        else:
            L.append("**NO PASS.** No variant clears every gate.")
            L.append("")
            L.append("Per the frozen rulebook this family is stopped: no demo, no")
            L.append("merge to `main`, no further parameter rounds on it.")
    L.append("")

    with open(os.path.join(rdir, "SUMMARY.md"), "w", encoding="utf-8") as f:
        f.write("\n".join(L) + "\n")
    with open(os.path.join(rdir, "SUMMARY_BACK.md"), "w", encoding="utf-8") as f:
        B = ["# TwinPulse %s - BACK period only (no forward data)" % FAMILY, ""]
        B.append("Rulebook: %s" % FAMILY_DOC[FAMILY])
        B.append("")
        B.append("period %s .. %s, BACK = %s .. %s"
                 % (d_from_s, d_to_s, d_from_s, fwd_start.strftime("%Y.%m.%d")))
        B.append("")
        B.append("| variant | BACK net | BACK net@ref | BACK PF | trades | cycles |")
        B.append("|---|---|---|---|---|---|")
        for v in VARIANTS_:
            d = data[v]
            legs, rows = d["legs"], d["back_rows"]
            _, b_pf = pair(v, ["profit factor"])
            B.append("| %s | %.2f | %s | %s | %d | %d |"
                     % (v, legs.net(rows), money(legs.net_ref(rows, ref, csize)),
                        money(b_pf), len(rows),
                        len(set(_cycle_key(r) for r in rows))))
        B.append("")
        with open(os.path.join(rdir, "SUMMARY_BACK.md"), "w", encoding="utf-8") as f2:
            f2.write("\n".join(B) + "\n")

    print("wrote %s" % os.path.join(rdir, "SUMMARY.md"))
    print("wrote %s" % os.path.join(rdir, "SUMMARY_BACK.md"))
    return 0



# ===========================================================================
#  SCALP family (round 4). Answers exactly the questions the owner asked:
#  USD per day, trades per day, win rate against break-even, gross before
#  spread, spread paid per day, drawdown, and the gap to the daily target.
# ===========================================================================
SCALP_TARGET_USD_PER_DAY = 50.0


def _end_of_test_deals(rdir, variant):
    """how many deals the tester closed itself at the end of the run.

    OnDeinit does not always run under the tester; MT5 then closes the open
    positions itself and the comment says so. Those closes are in the report
    but not in the legs CSV, which is exactly why the money check prints a
    gap. Counting them here makes the gap explainable instead of mysterious."""
    for name in ("report_fwd.htm", "report_back.htm", "report.htm"):
        path = os.path.join(rdir, variant, name)
        if not os.path.isfile(path):
            continue
        text = read_text_file(path).lower()
        return text.count("end of test")
    return 0


def scalp_summary(ctx):
    data = ctx["data"]
    VARIANTS_ = ctx["variants"]
    ref = ctx["ref"]
    csize = ctx["csize"]
    d_from = ctx["d_from"]
    d_to = ctx["d_to"]
    fwd_start = ctx["fwd_start"]
    missing = ctx["missing"]
    stale_warning = ctx["stale_warning"]
    posnet = ctx["posnet"]
    pair = ctx["pair"]
    rdir = ctx["rdir"]
    symbol = ctx["symbol"]

    # S5 is the ENTRY control (random entries, same exits); S11 is the COUNT
    # control (same splits as S10, drawn at random). They answer two different
    # questions and must never be compared against each other.
    entry_ctl = [v for v in VARIANTS_ if "random" in v.lower()]
    count_ctl = [v for v in VARIANTS_ if "rnd" in v.lower()]
    randoms = entry_ctl + count_ctl

    def money_rows(rows):
        """the 'open' rows exist only to record how many legs were open; they
        carry no money and must never be counted as a trade"""
        return [r for r in rows if (r.get("reason") or "") != "open"]

    def day_stats(legs, rows, start, end):
        per = {}
        for r in rows:
            t = legs._close(r)
            if t is None:
                continue
            d = t.date()
            a = per.setdefault(d, [0.0, 0])
            a[0] += legs.nval(r)
            a[1] += 1
        if not per:
            return None
        vals = [v[0] for v in per.values()]
        days = (end.date() - start.date()).days
        med = sorted(vals)
        n = len(med)
        median = med[n // 2] if n % 2 else (med[n // 2 - 1] + med[n // 2]) / 2.0
        return {
            "days": len(per), "calendar_days": max(days, 1),
            "avg": sum(vals) / len(vals),
            "median": median,
            "best": max(vals), "worst": min(vals),
            "pct_ge_target": 100.0 * len([v for v in vals if v >= SCALP_TARGET_USD_PER_DAY]) / len(vals),
            "pct_loss": 100.0 * len([v for v in vals if v < 0]) / len(vals),
            "trades": sum(v[1] for v in per.values()),
            "per_day": float(sum(v[1] for v in per.values())) / len(per),
            "total": sum(vals),
            "per_day_list": sorted(per.items()),
        }

    def stats(v):
        d = data[v]
        legs = d["legs"]
        rows = d["fwd_rows"] if d["fwd_rows"] else d["back_rows"]
        legs_rows = rows
        rows = money_rows(rows)
        vals = [legs.nval(r) for r in rows]
        wins = [x for x in vals if x > 0]
        losses = [x for x in vals if x < 0]
        aw = (sum(wins) / len(wins)) if wins else None
        al = (sum(losses) / len(losses)) if losses else None
        wr = (100.0 * len(wins) / len(vals)) if vals else None
        be = None
        if aw and al:
            be = 100.0 * abs(al) / (aw + abs(al))
        ds = day_stats(legs, rows, fwd_start, d_to)
        legs_all = [int(legs._f(r, "open_legs")) for r in legs_rows
                    if (r.get("open_legs") or "").strip() != ""]
        avg_legs = (sum(legs_all) / len(legs_all)) if legs_all else None
        max_legs = max(legs_all) if legs_all else None
        rep = d["report_fwd"] if d["report_fwd"] else d["report_back"]
        dep = None
        dd = None
        if rep:
            dv, _ = pick(rep, "initial deposit")
            dep = dv[0]
            _, ddp = pick_pair(rep, ["equity drawdown maximal"], pct=True)
            dd = ddp
            if dd is None:
                _, ddp2 = pick(rep, ["equity drawdown maximal"])
                dd = ddp2
        gross = sum(legs._f(r, "gross") for r in rows)
        spread_paid = None
        if legs.has_spread:
            spread_paid = sum(legs._f(r, "spread_open") * legs._f(r, "volume") * csize
                              for r in rows)
        return {
            "legs": legs, "rows": rows, "vals": vals,
            "net": sum(vals), "gross": gross, "spread": spread_paid,
            "n": len(vals), "wins": len(wins), "wr": wr,
            "aw": aw, "al": al, "be": be,
            "dd": dd, "deposit": dep if dep is not None else ctx.get("deposit"),
            "final": (dep + sum(vals)) if dep is not None else None,
            "day": ds,
            "be_day": (legs, rows),
            "avg_legs": avg_legs, "max_legs": max_legs,
            "endtest": _end_of_test_deals(rdir, v),
        }

    st = {v: stats(v) for v in VARIANTS_}

    def m(x, d=2):
        return "n/a" if x is None else ("%.*f" % (d, x))

    def p(x):
        return "n/a" if x is None else ("%.1f%%" % x)

    L = []
    L.append("# TwinPulse scalp - SUMMARY (round 4)")
    L.append("")
    L.append("Rulebook: **%s**. Target: %.0f USD/day on a 100 USD account."
             % (FAMILY_DOC["scalp"], SCALP_TARGET_USD_PER_DAY))
    L.append("")
    if stale_warning:
        L.append("> **IDENTICAL RESULTS** - %s. MT5 ignored the .set keys; recompile"
                 % ", ".join(stale_warning))
        L.append("> and rerun.")
        L.append("")
    if missing:
        L.append("> **BATCH INCOMPLETE** - no data for: %s. No verdict." % ", ".join(missing))
        L.append("")
    L.append("## The one table")
    L.append("")
    L.append("| variant | net/day avg | median | best | worst | %days>=50 | %losing | "
             "trades/day | win% | req% | DD | final |")
    L.append("|---|---|---|---|---|---|---|---|---|---|---|---|")
    for v in VARIANTS_:
        s_ = st[v]
        ds = s_["day"] or {}
        spd = None
        if s_["spread"] is not None and ds.get("days"):
            spd = s_["spread"] / ds["days"]
        L.append("| %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |"
                 % (v, m(ds.get("avg")), m(ds.get("median")), m(ds.get("best")),
                    m(ds.get("worst")), p(ds.get("pct_ge_target")), p(ds.get("pct_loss")),
                    m(ds.get("per_day"), 1), p(s_["wr"]), p(s_["be"]),
                    p(s_["dd"]), m(s_["final"])))
    L.append("")
    L.append("")
    L.append("## Cost and payoff")
    L.append("")
    L.append("| variant | gross before spread | spread paid/day | avg win | avg loss | avg legs | max legs |")
    L.append("|---|---|---|---|---|---|---|")
    for v in VARIANTS_:
        s_ = st[v]
        ds = s_["day"] or {}
        spd = None
        if s_["spread"] is not None and ds.get("days"):
            spd = s_["spread"] / ds["days"]
        L.append("| %s | %s | %s | %s | %s | %s | %s |"
                 % (v, m(s_["gross"]), m(spd), m(s_["aw"]), m(s_["al"]),
                    m(s_["avg_legs"], 2), "n/a" if s_["max_legs"] is None else str(s_["max_legs"])))
    L.append("")
    L.append("`req%` = the win rate the measured avg win / avg loss would need to break")
    L.append("even. If `win%` < `req%` the variant loses by construction, whatever the")
    L.append("entry does.")
    L.append("")

    # ---- gap to target ----------------------------------------------------
    L.append("## Gap to the target")
    L.append("")
    best = None
    for v in VARIANTS_:
        ds = st[v]["day"]
        if ds and (best is None or ds["avg"] > best[1]):
            best = (v, ds["avg"])
    if best:
        gap = SCALP_TARGET_USD_PER_DAY - best[1]
        bd = st[best[0]]["day"] or {}
        L.append("**best average USD/day = %.2f vs target %.0f** - variant `%s`, "
                 "gap %.2f USD/day (%.0f%% of the target)."
                 % (best[1], SCALP_TARGET_USD_PER_DAY, best[0], gap,
                    100.0 * best[1] / SCALP_TARGET_USD_PER_DAY))
        L.append("")
        L.append("Its median day is %.2f USD, %s of days reach 50 USD, %s of days "
                 "lose money, and the worst day is %s USD."
                 % (bd.get("median") or 0.0, p(bd.get("pct_ge_target")),
                    p(bd.get("pct_loss")), m(bd.get("worst"))))
    else:
        L.append("No daily figure available.")
    L.append("")

    # ---- random control ---------------------------------------------------
    L.append("## Control")
    L.append("")
    if entry_ctl:
        for v in entry_ctl:
            ds = st[v]["day"] or {}
            L.append("* `%s` - random ENTRY, identical exits: %.2f USD/day, win %s"
                     % (v, ds.get("avg", 0.0), p(st[v]["wr"])))
        L.append("")
        L.append("| variant | USD/day | vs its own target setting | beats the entry control by |")
        L.append("|---|---|---|---|")
        for v in VARIANTS_:
            if v in entry_ctl:
                continue
            ds = st[v]["day"] or {}
            if ds.get("avg") is None:
                continue
            # like with like: a no-target variant is judged against the
            # no-target random, not against the one carrying the daily stop
            ref = None
            for c in entry_ctl:
                if (c.endswith("_N")) == (v.endswith("_N")):
                    ref = c
                    break
            rnd = (st[ref]["day"] or {}) if ref else {}
            gap = (ds["avg"] - rnd["avg"]) if rnd.get("avg") is not None else None
            L.append("| %s | %.2f | %s | %s |"
                     % (v, ds["avg"], "no target" if v.endswith("_N") else "target on",
                        "n/a" if gap is None else "%+.2f" % gap))
        L.append("")
    else:
        L.append("No random entry control in this batch - the entry cannot be judged.")
    if count_ctl:
        L.append("")
        L.append("The COUNT control: the same 3/0-2/2 splits, drawn at random")
        L.append("instead of from the score. `%s` is what S10 must beat."
                 % ", ".join("`%s`" % c for c in count_ctl))
        L.append("")
    L.append("")

    # ---- exits and hours --------------------------------------------------
    L.append("## Where the money went")
    L.append("")
    L.append("| variant | exit | trades | net |")
    L.append("|---|---|---|---|")
    for v in VARIANTS_:
        agg = {}
        legs = st[v]["legs"]
        for r in st[v]["rows"]:
            k = r.get("reason", "?")
            a = agg.setdefault(k, [0, 0.0])
            a[0] += 1
            a[1] += legs.nval(r)
        for k in sorted(agg):
            L.append("| %s | %s | %d | %.2f |" % (v, k, agg[k][0], agg[k][1]))
    L.append("")
    L.append("| variant | hour | trades | net |")
    L.append("|---|---|---|---|")
    for v in VARIANTS_:
        agg = {}
        legs = st[v]["legs"]
        for r in st[v]["rows"]:
            t = legs._close(r)
            if t is None:
                continue
            a = agg.setdefault(t.hour, [0, 0.0])
            a[0] += 1
            a[1] += legs.nval(r)
        for h in sorted(agg):
            L.append("| %s | %02d:00 | %d | %.2f |" % (v, h, agg[h][0], agg[h][1]))
    L.append("")

    # ---- money check ------------------------------------------------------
    L.append("## Money check")
    L.append("")
    L.append("| variant | sum(pos_net) FWD | report FWD | gap | end-of-test closes |")
    L.append("|---|---|---|---|---|")
    for v in VARIANTS_:
        (sb, rb_, ob), (sf, rf_, of) = posnet[v]
        gap = None
        if sf is not None and rf_ is not None:
            gap = rf_ - sf
        L.append("| %s | %s | %s | %s | %d |"
                 % (v, m(sf), m(rf_), m(gap), st[v]["endtest"]))
    L.append("")
    L.append("A non-zero gap is expected when the tester closes positions itself at")
    L.append("the end of the run: those deals are in the report and not in the CSV.")
    L.append("")

    # ---- the BUY/SELL split (S8..S11) -----------------------------------
    splits_seen = any((r.get("split") or "") != "" for v in VARIANTS_ for r in st[v]["rows"])
    if splits_seen:
        L.append("## How many legs of each side, and what each split earned")
        L.append("")
        L.append("| variant | split | closed legs | net |")
        L.append("|---|---|---|---|")
        for v in VARIANTS_:
            agg = {}
            legs = st[v]["legs"]
            for r in st[v]["rows"]:
                k = (r.get("split") or "?").strip()
                if k == "":
                    k = "?"
                a = agg.setdefault(k, [0, 0.0])
                a[0] += 1
                a[1] += legs.nval(r)
            for k in sorted(agg):
                L.append("| %s | %s | %d | %.2f |" % (v, k, agg[k][0], agg[k][1]))
        L.append("")
        L.append("The split recorded on a leg is the book at the moment it CLOSED.")
        L.append("")

    # ---- balance curve ---------------------------------------------------
    L.append("## Balance curve (forward half, from the deposit)")
    L.append("")
    L.append("| variant | deposit | low | high | month ends | final |")
    L.append("|---|---|---|---|---|---|")
    for v in VARIANTS_:
        s_ = st[v]
        legs = s_["legs"]
        bal = s_["deposit"]
        if bal is None or not s_["rows"]:
            L.append("| %s | n/a | n/a | n/a | n/a | n/a |" % v)
            continue
        lo = bal
        hi = bal
        cur = bal
        months = {}
        for r in sorted(s_["rows"], key=lambda x: x.get("time", "")):
            cur += legs.nval(r)
            lo = min(lo, cur)
            hi = max(hi, cur)
            months[r.get("time", "")[:7]] = cur
        mends = ", ".join("%s %.2f" % (k, months[k]) for k in sorted(months))
        L.append("| %s | %.2f | %.2f | %.2f | %s | %.2f |"
                 % (v, bal, lo, hi, mends, cur))
    L.append("")

    # ---- with / without the daily target ---------------------------------
    # `X` carries the 50 USD target, `X_N` is the same EA with it switched off
    pairs = []
    for v in VARIANTS_:
        if v.endswith("_N") and v[:-2] in VARIANTS_:
            pairs.append((v[:-2], v))
    if pairs:
        L.append("## The daily target: with vs without")
        L.append("")
        L.append("| variant | no target USD/day | with target USD/day | delta | "
                 "no target %losing | with target %losing | no target worst | with target worst |")
        L.append("|---|---|---|---|---|---|---|---|")
        for base, off in pairs:
            a = st[off]["day"] or {}
            b = st[base]["day"] or {}
            if a.get("avg") is None or b.get("avg") is None:
                continue
            L.append("| %s | %.2f | %.2f | %+.2f | %s | %s | %s | %s |"
                     % (base, a["avg"], b["avg"], b["avg"] - a["avg"],
                        p(a.get("pct_loss")), p(b.get("pct_loss")),
                        m(a.get("worst")), m(b.get("worst"))))
        L.append("")
        L.append("A daily target that *raises* the average is cutting losing days")
        L.append("early; one that *lowers* it is cutting good days short.")
        L.append("")

    L.append("## Verdict (docs/DECISION_RULES_3.md)")
    L.append("")
    if missing:
        L.append("**NO VERDICT** - incomplete batch.")
    else:
        passing = []
        rows = []
        for v in VARIANTS_:
            s_ = st[v]
            ds = s_["day"] or {}
            avg = ds.get("avg")
            n = s_["n"]
            gap = None
            for c in entry_ctl:
                if (c.endswith("_N")) == (v.endswith("_N")) and c != v:
                    r = (st[c]["day"] or {}).get("avg")
                    if r is not None and avg is not None:
                        gap = avg - r
                    break
            why = []
            if avg is None or avg <= 0:
                why.append("net/day <= 0")
            if n < 100:
                why.append("%d trades < 100" % n)
            if s_["wr"] is None or s_["be"] is None or s_["wr"] <= s_["be"]:
                why.append("win rate below its break-even rate")
            if s_["dd"] is not None and s_["dd"] > 35.0:
                why.append("DD %.1f%% > 35%%" % s_["dd"])
            if gap is not None and gap < 0.20:
                why.append("beats its control by only %+.2f" % gap)
            if not why and v not in randoms:
                passing.append(v)
            rows.append((v, why))
        if passing:
            L.append("**PASS the screening gates: %s.**" % ", ".join(passing))
            L.append("Screening is Model=1 (M1 OHLC). Before any demo the winner must")
            L.append("be re-run on Model=4 (real ticks) over the same period and pass")
            L.append("again; only then does it go to an Exness DEMO with AllowLive=false.")
        else:
            L.append("**No variant passes the screening gates.**")
        L.append("")
        L.append("| variant | first blocking reason |")
        L.append("|---|---|")
        for v, why in rows:
            if v in randoms:
                continue
            L.append("| %s | %s |" % (v, "ok" if not why else why[0]))
        L.append("")
        L.append("A control is never a candidate: S5 judges the ENTRY, S11 judges the")
        L.append("SPLIT. Passing means the idea is not just its own control.")
    L.append("")

    with open(os.path.join(rdir, "SUMMARY.md"), "w", encoding="utf-8") as f:
        f.write("\n".join(L) + "\n")
    with open(os.path.join(rdir, "SUMMARY_BACK.md"), "w", encoding="utf-8") as f:
        f.write("\n".join(L[:6]) + "\n(back-only copy)\n")
    print("wrote %s" % os.path.join(rdir, "SUMMARY.md"))
    return 0


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
    ap.add_argument("--rules", default=None,
                    help="which rulebook to apply: hedge | trend | reversal. "
                         "Default: detected from the reports folder name; "
                         "an unknown folder is an error, never a guess.")
    ap.add_argument("--deposit", type=float, default=None,
                    help="account deposit of the run; used for the balance curve "
                         "and the margin cap when the report is missing")
    ap.add_argument("--risk-pct", dest="risk_pct", type=float, default=0.5,
                    help="risk per trade the EA is sized to, %% of equity (default 0.5)")
    ap.add_argument("--sl-atr", dest="sl_atr", type=float, default=2.5,
                    help="stop in ATR, used only when the CSV has no stop_dist "
                         "column (hedge EA: HardSL_ATR, default 2.5)")
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

    global FAMILY
    FAMILY = detect_family(rdir, args.rules)
    print("rules: %s  (%s)" % (FAMILY, FAMILY_DOC[FAMILY]))

    global VARIANTS, RANDOM
    VARIANTS = discover(rdir)
    RANDOM = [v for v in VARIANTS if "random" in v.lower()]
    if VARIANTS:
        print("variants (%d): %s" % (len(VARIANTS), ", ".join(VARIANTS)))

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

    # ---- a stale .ex5 silently ignores unknown .set keys -------------
    # MT5 drops parameters it does not know, so a preset that needs an
    # input the compiled EA does not have runs as the plain default. The
    # tell is two presets with different settings producing byte-identical
    # accounting. Say it before anything else is read into the numbers.
    def _sig(d):
        lg = d["legs"]
        return (len(lg.rows), round(lg.net(), 2), round(lg.spread_paid(), 2))

    stale_warning = []
    if len(data) > 1:
        sigs = {}
        for v in VARIANTS:
            if data[v]["legs"].rows:
                sigs.setdefault(_sig(data[v]), []).append(v)
        for sig, group in sigs.items():
            if len(group) > 1 and len(group) == len([v for v in VARIANTS if data[v]["legs"].rows]):
                stale_warning = group
        if stale_warning:
            print("WARNING: every variant produced identical accounting (%s)." % ", ".join(stale_warning))
            print("         The .set settings were probably IGNORED - MT5 drops unknown")
            print("         parameters, which happens when TwinPulse.ex5 is older than")
            print("         the inputs. Recompile TwinPulse.mq5 (F7, 0 errors) and rerun.")

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
            # the CSV of a single run covers exactly that run, so the whole
            # sum is the right one; only a legacy CSV that mixes back+forward
            # needs the trim. Try the plain sum first and trim to the report's
            # last trade (+ a few seconds: the report lists the order time,
            # the CSV the deal time, they can differ by a second) only when
            # the plain one disagrees.
            s_all = legs.net(rows) if rows else None
            lt = rep.get("last_trade")
            if s_all is not None and abs(s_all - rn) <= 1.00:
                row.append((s_all, rn, True))
                continue
            use = rows
            if lt is not None:
                lim = lt + timedelta(seconds=5)
                use = [r for r in rows if legs._close(r) is None or legs._close(r) <= lim]
            s = legs.net(use)
            row.append((s, rn, abs(s - rn) <= 1.00))
        posnet[v] = row

    # ---- a non-hedge family gets its own rulebook and its own report --
    # (the hedge gates below would be a false verdict for a trend EA: it
    # asks "does the signal beat a random control", not "does the bank work")
    if FAMILY == "scalp":
        return scalp_summary({
            "data": data, "variants": VARIANTS, "ref": ref, "csize": csize,
            "d_from": d_from, "d_to": d_to, "fwd_start": fwd_start,
            "missing": missing, "stale_warning": stale_warning,
            "posnet": posnet, "pair": pair, "rdir": rdir, "symbol": args.symbol,
            "deposit": args.deposit,
        })

    if FAMILY != "hedge":
        return family_summary({
            "data": data, "variants": VARIANTS, "ref": ref, "csize": csize,
            "d_from": d_from, "d_to": d_to, "fwd_start": fwd_start,
            "d_from_s": args.d_from, "d_to_s": args.d_to,
            "risk_pct": args.risk_pct, "sl_atr": args.sl_atr,
            "missing": missing, "stale_warning": stale_warning,
            "posnet": posnet, "pair": pair, "rdir": rdir,
            "symbol": args.symbol,
        })

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
    head.append("Coverage probe (printed, not gated):")
    head.append("")
    for v in VARIANTS:
        dd, wd, pc = coverage_probe(data[v]["legs"], data[v]["fwd_rows"], d_from, d_to)
        head.append("* `%s`: %d days with a closed leg of %d weekdays (%.1f%%)"
                    % (v, dd, wd, pc if pc is not None else 0.0))
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
    if stale_warning:
        lines.append("> **IDENTICAL RESULTS - the settings were probably not applied.**")
        lines.append("> %s produced exactly the same legs / net / spread, so the .set"
                     % ", ".join(stale_warning))
        lines.append("> keys were ignored (MT5 drops unknown parameters). Recompile")
        lines.append("> TwinPulse.mq5 (F7, 0 errors) and rerun the batch.")
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
    # the decision batch order first, then anything else alphabetically
    order = [v for v in SIMPLENESS if v in allg] + \
            [v for v in VARIANTS if v not in SIMPLENESS]
    passing = [v for v in order if allg[v]["_pass"]]
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
