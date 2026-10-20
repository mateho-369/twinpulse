#!/usr/bin/env python3
"""Pack one round's reports, CSVs and logs into a single zip for upload.

The owner runs the tester by hand; this turns the output folder into one file
he can attach, with the account identity removed first. It never touches the
originals: everything is copied into a temporary stage.

    python tools/pack_round.py --reports "C:\\...\\reports\\scalp" --round 1

Writes  %USERPROFILE%\\Desktop\\round1.zip
and     %USERPROFILE%\\Desktop\\round1.zip.txt   (the same bytes, a name that
                                                  the chat can attach)

If the archive would go over --max-mb, the BACK reports are dropped first (the
CSVs already carry the same money), and the script says so in its summary.
"""
import argparse
import os
import re
import shutil
import sys
import tempfile
import zipfile

# MT5 writes the account block as either `Login: 123` or a two-cell table row.
# Both shapes are redacted; nothing else in the report is touched.
REDACT = [
    (re.compile(r"(?i)(\bLogin\s*:\s*)([^\s<]+)"), r"\1[redacted]"),
    (re.compile(r"(?i)(\bLogin\s*:\s*</td>\s*<td[^>]*>)([^<]*)"), r"\1[redacted]"),
    (re.compile(r"(?i)(\bName\s*:\s*)([^\s<][^<\n]*)"), r"\1[redacted]"),
    (re.compile(r"(?i)(\bName\s*:\s*</td>\s*<td[^>]*>)([^<]*)"), r"\1[redacted]"),
    (re.compile(r"(?i)(\bServer\s*:\s*)([^\s<][^<\n]*)"), r"\1[redacted]"),
    (re.compile(r"(?i)(\bServer\s*:\s*</td>\s*<td[^>]*>)([^<]*)"), r"\1[redacted]"),
    (re.compile(r"(?i)(\bPassword\s*:\s*)(\S+)"), r"\1[redacted]"),
]
EXTS = (".htm", ".html", ".csv", ".log", ".md", ".txt")


def read_text(path):
    """MT5 reports are UTF-16LE with a BOM; the CSVs and logs are UTF-8 with no
    BOM. Only trust UTF-16 when the BOM says so - any even-length byte string
    decodes as UTF-16 without raising, which silently turns a log into CJK."""
    raw = open(path, "rb").read()
    if raw[:2] in (b"\xff\xfe", b"\xfe\xff"):
        return raw.decode("utf-16"), "utf-16"
    for enc in ("utf-8-sig", "utf-8", "cp1252"):
        try:
            return raw.decode(enc), enc
        except (UnicodeDecodeError, UnicodeError):
            continue
    return raw.decode("latin-1"), "latin-1"


def scrub(text):
    for pat, rep in REDACT:
        text = pat.sub(rep, text)
    return text


def collect(root):
    out = []
    for dirpath, _dirs, files in os.walk(root):
        for f in files:
            if f.lower().endswith(EXTS):
                out.append(os.path.join(dirpath, f))
    return sorted(out)


def main():
    ap = argparse.ArgumentParser(description="pack one round into round<N>.zip")
    ap.add_argument("--reports", required=True, help="the reports folder of the run")
    ap.add_argument("--round", dest="n", required=True, type=str, help="round number, e.g. 1")
    ap.add_argument("--desktop", default=os.path.join(os.path.expanduser("~"), "Desktop"),
                    help="where round<N>.zip is written (default: the Desktop)")
    ap.add_argument("--max-mb", type=float, default=25.0,
                    help="drop the BACK reports above this archive size (default 25)")
    args = ap.parse_args()

    if not os.path.isdir(args.reports):
        print("ERROR: no such folder: %s" % args.reports)
        return 2

    files = collect(args.reports)
    if not files:
        print("ERROR: nothing to pack under %s" % args.reports)
        return 2

    stage = tempfile.mkdtemp(prefix="round%s_" % args.n)
    rels = []
    for f in files:
        rel = os.path.relpath(f, args.reports)
        dst = os.path.join(stage, rel)
        d = os.path.dirname(dst)
        if d and not os.path.isdir(d):
            os.makedirs(d)
        text, enc = read_text(f)
        new = scrub(text)
        # write a UTF-8 copy: redaction must survive, and the originals stay
        # untouched on disk
        with open(dst, "w", encoding="utf-8", newline="") as fh:
            fh.write(new)
        rels.append(rel)

    zip_path = os.path.join(args.desktop, "round%s.zip" % args.n)
    if not os.path.isdir(args.desktop):
        os.makedirs(args.desktop)

    def build(paths):
        if os.path.exists(zip_path):
            os.remove(zip_path)
        with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as z:
            for r in paths:
                z.write(os.path.join(stage, r), r)
        return os.path.getsize(zip_path)

    size = build(rels)
    dropped = 0
    if size > args.max_mb * 1024 * 1024:
        # only the BACK *reports* go: "S1_Pullback/..." contains "back" too,
        # and dropping a variant because of its name would be silent data loss
        keep = [r for r in rels
                if "report_back" not in os.path.basename(r).lower()]
        if keep and len(keep) < len(rels):
            dropped = len(rels) - len(keep)
            rels = keep
            size = build(rels)

    txt = zip_path + ".txt"
    shutil.copyfile(zip_path, txt)

    print("packed %d file(s) -> %s  (%.1f MB)" % (len(rels), zip_path, size / 1048576.0))
    print("copied to %s" % txt)
    if dropped:
        print("NOTE: %d BACK report(s) left out - the archive was over %.0f MB."
              % (dropped, args.max_mb))
    print("")
    print("Tell the owner to attach %s (not the .zip - the chat takes text)." % txt)
    shutil.rmtree(stage, ignore_errors=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
