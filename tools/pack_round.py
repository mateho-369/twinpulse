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

# An MT5 report puts the identity in four places and only two of them carry a
# label: `Login:` / `Name:` / `Server:` rows, a `Company:` row, and a bare
# `<b>Broker-Server (Build 1234)</b>` cell with no label at all. Labelled
# redaction alone left the server name in all 44 reports of round 1, so the
# packer now LEARNS the identity strings from the report and then deletes every
# occurrence of them, wherever they are.
LABELS = ("login", "name", "server", "company", "password")

LABELLED = [
    # <td>Company:</td><td><b>Broker Ltd</b></td> - replace the whole bold cell,
    # otherwise the closing </b> is left behind and the HTML stops making sense
    (re.compile(r"(?is)(\b(?:%s)\s*:?\s*</t[dh]\s*>\s*<t[dh][^>]*>)\s*<b>[^<]*</b>"
                % "|".join(LABELS)), r"\1[redacted]"),
    # <td>Server:</td><td>Exness-MT5Trial6</td>  (attributes and colspan allowed)
    (re.compile(r"(?is)(\b(?:%s)\s*:?\s*</t[dh]\s*>\s*<t[dh][^>]*>)\s*(?:<b>\s*)?([^<]+)"
                % "|".join(LABELS)), r"\1[redacted]"),
    # Server: Exness-MT5Trial6   (same cell)
    (re.compile(r"(?is)(\b(?:%s)\s*:\s*)([^\s<][^<\r\n]*)" % "|".join(LABELS)),
     r"\1[redacted]"),
    # <b>Exness-MT5Trial6 (Build 6238)</b> - the unlabelled header cell
    (re.compile(r"(?is)<b>\s*([A-Za-z0-9._-]+)\s*\(Build\s*\d+\)\s*</b>"),
     "<b>[server]</b>"),
]

# strings that are never a name but are ours to remove anyway
ALWAYS = [re.compile(r"(?i)\bExness[-\w.]*(?:\s+[A-Z][\w&.-]*){0,3}"),
          re.compile(r"(?i)\bMetaQuotes\b")]


def identity_strings(text):
    """the values a report uses to identify the account, learned from the report
    itself so an unusual layout cannot leak them."""
    found = set()
    for m in re.finditer(r"(?is)\b(?:%s)\s*:?\s*</t[dh]\s*>\s*<t[dh][^>]*>\s*(?:<b>\s*)?([^<]+)"
                         % "|".join(LABELS), text):
        found.add(m.group(1).strip())
    for m in re.finditer(r"(?is)\b(?:%s)\s*:\s*([^\s<][^<\r\n]*)" % "|".join(LABELS), text):
        found.add(m.group(1).strip())
    for m in re.finditer(r"(?is)<b>\s*([A-Za-z0-9._-]+)\s*\(Build\s*\d+\)", text):
        found.add(m.group(1).strip())
    # a login is a bare number; anything shorter than 4 chars is a word like
    # "USD" and must not be turned into a global replacement
    return set(x for x in found if len(x) >= 4)


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


def scrub(text, learned=()):
    for pat, rep in LABELLED:
        text = pat.sub(rep, text)
    for word in learned:
        # learned strings are literal, not regex
        text = re.sub(re.escape(word), "[redacted]", text, flags=re.I)
    for pat in ALWAYS:
        text = pat.sub("[redacted]", text)
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

    # pass 1: read everything once and learn the identity strings from it
    texts = {}
    for f in files:
        try:
            texts[f] = read_text(f)[0]
        except Exception as e:                      # a locked or odd file
            print("WARNING: cannot read %s (%s) - packed unscrubbed?" % (f, e))
            texts[f] = ""
    learned = set()
    for t in texts.values():
        learned |= identity_strings(t)
    if learned:
        print("redacting %d learned identity string(s)" % len(learned))

    # pass 2: scrub and write a UTF-8 copy. The originals stay untouched.
    rels = []
    for f in files:
        rel = os.path.relpath(f, args.reports)
        dst = os.path.join(stage, rel)
        d = os.path.dirname(dst)
        if d and not os.path.isdir(d):
            os.makedirs(d)
        with open(dst, "w", encoding="utf-8", newline="") as fh:
            fh.write(scrub(texts[f], learned))
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

    # verify: every archived text file must be free of the learned strings
    leaks = []
    for r in rels:
        try:
            body = open(os.path.join(stage, r), encoding="utf-8").read()
        except Exception:
            continue
        if any(w.lower() in body.lower() for w in learned):
            leaks.append(r)
        elif re.search(r"(?i)(exness|metaquotes|technologies)", body):
            leaks.append(r)

    if leaks:
        print("ERROR: %d file(s) still contain an identity string, the archive is"
              " NOT safe to upload:" % len(leaks))
        for r in leaks[:10]:
            print("   " + r)
        # leave nothing behind: a failed pack used to keep a full copy of the
        # reports (identity included) in the temp folder
        shutil.rmtree(stage, ignore_errors=True)
        if os.path.exists(zip_path):
            os.remove(zip_path)
        txt = zip_path + ".txt"
        if os.path.exists(txt):
            os.remove(txt)
        return 3

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
