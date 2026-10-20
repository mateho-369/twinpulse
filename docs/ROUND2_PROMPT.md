# Round 2 - the one Claude Code prompt

Copy everything between the two rules into Claude Code on the Windows machine.
Nothing is re-run by hand: it pulls, compiles, runs 13 presets and packs the zip.

---

You are on my Windows machine, in the TwinPulse MQL5 repository. Do the steps
below in order. Print every command and its real output. **Stop at the first
failure and show me the exact error** - never guess a path, never invent a
number, never edit a `.set`, never change dates, deposit or model.

**0. Find the three paths yourself - do not ask me.**
* repo: `git rev-parse --show-toplevel` (fall back to searching `C:\Users\*\`
  for `twinpulse\.git`, depth 3).
* MT5 data folder: `$env:APPDATA\MetaQuotes\Terminal\<32 hex>\MQL5` - the one
  whose `MQL5\Experts\TwinPulse` holds `TwinPulseScalp.mq5`.
* MetaEditor: `MetaEditor64.exe` beside `terminal64.exe` under `C:\Program Files\`.

**1. Update the code.**
```
git fetch origin
git checkout arena/7d00bffc-twinpulse
git pull --ff-only origin arena/7d00bffc-twinpulse
git log --oneline -1
```
Expect `35de5c5` or newer. Prove the presets are the round-2 ones:
```
(Get-ChildItem tester\scalp2\*.set).Count                                  # must be 13
(Select-String -Path tester\scalp2\*.set -Pattern '^InpMode=' | Measure-Object).Count  # must be 13
(Select-String -Path tester\scalp2\*.set -Pattern '^InpTrailStart_ATR=0.00' | Measure-Object).Count  # must be 10
```
The last check is the point of the round: the trail must be OFF in the five
exit pairs and their twins. If it is not 10, stop.

**2. Copy the EA into MT5 and compile it.**
```
robocopy "$repo\MQL5\Experts\TwinPulse" "$data\MQL5\Experts\TwinPulse" *.mq5 *.mqh /NFL /NDL /NJH /NJS
& $metaeditor /compile:"$data\MQL5\Experts\TwinPulse\TwinPulseScalp.mq5" /log:"$env:TEMP\tps_compile.log"
Get-Content "$env:TEMP\tps_compile.log" -Tail 25
```
(the log is UTF-16 - add `-Encoding Unicode` if it prints garbage.)
This build should report **0 errors, 0 warnings** (the two warnings of round 1
were fixed). If it does not, delete the old `.ex5`, paste the errors, stop.
Print the `.ex5` timestamp - it must be from this minute.

**3. MT5 must be closed.** Ask me, wait for "closed".

**4. Run the batch - 13 presets, back + forward = 26 tester runs.**
```
powershell -ExecutionPolicy Bypass -File tools\run_batch.ps1 -Symbol XAUUSDm -FromDate 2026.08.01 -ToDate 2026.10.19 -Deposit 100 -Preset tester\scalp2 -Expert TwinPulse\TwinPulseScalp -Period M5 -Model 1
```
Resume-safe: finished variants are skipped, so a rerun of the same command is
how you recover. Do not change anything.

**5. Summarize.**
Run the exact `python tools\summarize_batch.py ...` line the batch prints. Then
check and report:
* `SUMMARY.md` lists **13** variants,
* it has a `## The back half, same measures` table,
* the one table has a **days** column - a variant showing 9 instead of 19 hit
  the margin floor and stopped trading,
* the line `best average USD/day = ... vs target 50` is present.

**6. Pack.**
```
python tools\pack_round.py --reports "<the reports folder the batch printed>" --round 2
```
It writes `Desktop\round2.zip` and `Desktop\round2.zip.txt`. It now checks its
own work: if any file still contains the server or company name it stops with
`ERROR: ... NOT safe to upload` instead of packing. Print the size and path.

**7. Report back - short:**
* the two tables from `SUMMARY.md` verbatim (forward and back),
* the `## Control` table, so I can see each exit against its own random twin,
* the verdict block at the end of `SUMMARY.md`,
* the full path of `round2.zip.txt`.

Do not commit, do not push, do not edit any file, and do not state any number
you did not read from a report or a CSV.
