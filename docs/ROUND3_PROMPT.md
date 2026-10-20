# Round 3 - the one Claude Code prompt (measurement at 1000 USD)

Copy everything between the two rules into Claude Code on the Windows machine.

---

You are on my Windows machine, in the TwinPulse MQL5 repository. Do the steps
below in order. Print every command and its real output. **Stop at the first
failure and show me the exact error** - never guess a path, never invent a
number, never edit a `.set`, never change dates or model.

**0. Find the three paths yourself - do not ask me.**
* repo: `git rev-parse --show-toplevel` (else search `C:\Users\*\` for
  `twinpulse\.git`, depth 3).
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
Expect the newest commit on this branch. Then prove the round-3 presets:
```
(Get-ChildItem tester\scalp3\*.set).Count                                   # must be 34
(Select-String -Path tester\scalp3\*.set -Pattern '^InpMode=' | Measure-Object).Count   # must be 34
(Select-String -Path tester\scalp3\*.set -Pattern '^InpLots=0.01' | Measure-Object).Count # must be 34
```
If any count is wrong, stop. The lot **must still be 0.01**: this round changes
the account size only, never the position size.

**2. Copy the EA into MT5 and compile it.**
```
robocopy "$repo\MQL5\Experts\TwinPulse" "$data\MQL5\Experts\TwinPulse" *.mq5 *.mqh /NFL /NDL /NJH /NJS
& $metaeditor /compile:"$data\MQL5\Experts\TwinPulse\TwinPulseScalp.mq5" /log:"$env:TEMP\tps_compile.log"
Get-Content "$env:TEMP\tps_compile.log" -Tail 25
```
(add `-Encoding Unicode` if the log prints garbage.) Must be **0 errors**.
Print the `.ex5` timestamp.

**3. MT5 must be closed.** Ask me, wait for "closed".

**4. Run the batch - 34 presets, back + forward = 68 tester runs, deposit 1000.**
```
powershell -ExecutionPolicy Bypass -File tools\run_batch.ps1 -Symbol XAUUSDm -FromDate 2026.08.01 -ToDate 2026.10.19 -Deposit 1000 -Preset tester\scalp3 -Expert TwinPulse\TwinPulseScalp -Period M5 -Model 1
```
It is resume-safe: finished variants are skipped, so rerunning the same command
is how you recover. This is the long one (68 runs) - report progress as it goes.

**5. Summarize** - use the exact line the batch prints (it carries
`--deposit 1000`). Then check and report:
* `SUMMARY.md` lists **34** variants,
* every variant shows **19 days** on the forward and **~35** on the back - a
  small number here means the account died again,
* the line `best average USD/day = ... vs target 50` is present,
* the minimum-deposit table reads `risk on a 1000 USD account`.

**6. Pack.**
```
python tools\pack_round.py --reports "<the reports folder the batch printed>" --round 3
```
It writes `Desktop\round3.zip` and `Desktop\round3.zip.txt`, and refuses to
finish if the server or company name survives. Print the size and the path.
If it drops BACK reports because the archive passed 25 MB, say so.

**7. Report back - short:**
* the forward table and the back table verbatim,
* the `## Control` table (each variant against its own random twin),
* the verdict block,
* the full path of `round3.zip.txt`.

Do not commit, do not push, do not edit any file, and do not state any number
you did not read from a report or a CSV.
