# Round 1 - the one Claude Code prompt

Copy everything between the two rules into Claude Code on the Windows machine.
It updates the code, compiles, runs the 22 presets and hands back one zip.

---

You are on my Windows machine, in the TwinPulse MQL5 repository. Do the steps
below in order. Print every command you run and its real output. **Stop at the
first failure and show me the exact error** - never guess a path, never invent a
number, never edit a `.set`, never change dates, deposit or model.

**0. Find three paths yourself - do not ask me.**
* repo: `git rev-parse --show-toplevel`. If that is not a TwinPulse checkout,
  look for `twinpulse\.git` under `C:\Users\*\` (depth 3) and `cd` there.
* MT5 data folder: `$env:APPDATA\MetaQuotes\Terminal\<32 hex chars>\MQL5` - the
  one whose `MQL5\Experts\TwinPulse` already holds `TwinPulseScalp.mq5`.
* MetaEditor: `MetaEditor64.exe` beside the `terminal64.exe` you find under
  `C:\Program Files\`.

**1. Update the code.**
```
git fetch origin
git checkout arena/7d00bffc-twinpulse
git pull --ff-only origin arena/7d00bffc-twinpulse
git log --oneline -1
```
Expect `0f30802` or newer on `arena/7d00bffc-twinpulse`. Then prove the presets
are the current ones - both counts must print 22:
```
(Get-ChildItem tester\scalp\*.set).Count
(Select-String -Path tester\scalp\*.set -Pattern '^InpMode=' | Measure-Object).Count
```
If either is not 22, stop and tell me. A `.set` without `InpMode` silently runs
in single mode.

**2. Copy the EA into MT5.**
```
robocopy "$repo\MQL5\Experts\TwinPulse" "$data\MQL5\Experts\TwinPulse" *.mq5 *.mqh /NFL /NDL /NJH /NJS
```

**3. Compile.**
```
& $metaeditor /compile:"$data\MQL5\Experts\TwinPulse\TwinPulseScalp.mq5" /log:"$env:TEMP\tps_compile.log"
Get-Content "$env:TEMP\tps_compile.log" -Tail 25
```
(the log is UTF-16 - if it prints garbage, add `-Encoding Unicode`.)
The last line must say **0 errors**. If it does not: delete the old
`TwinPulseScalp.ex5`, paste me the error lines, and stop. If it does, print the
`.ex5` timestamp - it must be from this minute.

**4. MT5 must be closed.** `run_batch.ps1` refuses to start while `terminal64`
is running. Ask me to close MT5 and wait until I answer "closed".

**5. Run the batch - 22 presets, back + forward = 44 tester runs.**
```
powershell -ExecutionPolicy Bypass -File tools\run_batch.ps1 -Symbol XAUUSDm -FromDate 2026.08.01 -ToDate 2026.10.19 -Deposit 100 -Preset tester\scalp -Expert TwinPulse\TwinPulseScalp -Period M5 -Model 1
```
* It is resume-safe: a variant already finished is skipped, so if anything
  stops, rerun the same command - do not fix anything by hand.
* If MT5 asks to download `XAUUSDm` M1 history, say yes and let it finish.
* If it stops, paste the last 40 lines and stop there.

**6. Summarize.**
Run the exact `python tools\summarize_batch.py ...` command the batch printed at
the end (it already carries `--deposit 100 --contract-size 100 --ref-spread 0.20`).
Then check and report:
* `SUMMARY.md` lists **22** variants,
* the line `best average USD/day = ... vs target 50` is present,
* the section `The daily target: with vs without` has **11** rows,
* the section `How many legs of each side` has rows for S8, S9, S10, S11.

**7. Prove the margin facts** (I asked for these before the first round):
```
Select-String -Path "<reports>\*\*\TwinPulse_scalp.log" -Pattern 'TPS margin:' | Select-Object -First 2
```
Paste both lines: account margin mode, `OrderCalcMargin` for 0.01 lot,
`SYMBOL_MARGIN_HEDGED`, and the largest leg count that fits at 300% and 250%.

**8. Pack.**
```
python tools\pack_round.py --reports "<the reports folder the batch printed>" --round 1
```
It writes `Desktop\round1.zip` and `Desktop\round1.zip.txt`, with Login, Name
and Server redacted. Print the final file size and the full path.

**9. Report back - short, no prose padding:**
* the "one table" from `SUMMARY.md`, verbatim,
* the with/without-target table, verbatim,
* the two `TPS margin:` lines,
* the full path of `round1.zip.txt`.

Do not commit, do not push, do not edit any file, and do not state any number
you did not read from a report or a CSV.
