# ==========================================================================
#  TwinPulse Hedge EA - decision batch runner (Windows, PowerShell)
#
#  Runs the 8 decision variants (V1..V8) in the strategy tester overnight.
#  Every variant: archive the old TwinPulse*.csv from Common\Files, start
#  terminal64.exe /config:<ini>, wait for the exit, copy the report and the
#  fresh CSV files into <DATA>\reports\decision\<variant>\.
#  The run is RESUME-SAFE: a variant whose report and CSVs already exist is
#  skipped, so the script can be started again after a crash.
#
#  Usage:
#    powershell -ExecutionPolicy Bypass -File tools\run_batch.ps1
#    powershell -ExecutionPolicy Bypass -File tools\run_batch.ps1 -Symbol XAUUSDm `
#        -FromDate 2022.01.01 -ToDate 2026.09.30 -Deposit 1000
# ==========================================================================

#--- parameters -----------------------------------------------------------
param(
    # SYMBOL, FROM_DATE, TO_DATE, DEPOSIT - the batch is generated from these
    [string]$Symbol   = "XAUUSDm",
    [string]$FromDate = "2022.01.01",
    [string]$ToDate   = "2026.09.30",
    [string]$Deposit  = "1000",

    # optional: run only these variants (names, e.g. V1_Full) - useful for
    # a quick single-variant check before the whole overnight batch
    [string[]]$Only = @(),

    # optional: folder of .set presets to use instead of tester\decision
    # (e.g. -Preset "tester\upgrade"); one variant per <name>.set file
    [string]$Preset = "",

    # optional: ignore finished results and run the batch again (the old
    # reports / CSVs are moved into _old_<timestamp>, never deleted)
    [switch]$Redo,

    # optional: which expert to run ("Folder\Name" under MQL5\Experts)
    [string]$Expert = "TwinPulse\TwinPulse",

    # optional: chart timeframe of the run (the EA picks its own signal TF)
    [string]$Period = "M5",

    # optional: MT5 tester model, EXACTLY as the .ini understands it:
    #   0 = every tick, 1 = 1 minute OHLC, 2 = OPEN PRICES ONLY,
    #   3 = math calculations, 4 = every tick based on real ticks
    # (2 is NOT "1 minute OHLC" - using it here would feed the EA one
    #  price per bar and silently turn every strategy into nonsense)
    [int]$Model = 4,

    # paths: <INSTALL> = folder with terminal64.exe, <DATA> = terminal data
    # folder (File -> Open Data Folder in the terminal)
    [string]$InstallDir = "C:\Program Files\MetaTrader 5",
    [string]$DataDir    = "$env:APPDATA\MetaQuotes\Terminal\D0E8209F77C8CF37AD8BF550E51FF075",

    # server clock vs UTC in hours (integer). Session / rollover / Friday
    # inputs are SERVER hours: the script writes them into the .set files
    # from the UTC values below, so the same UTC windows are used on any
    # broker. Exness = 0.
    [double]$ServerUtcOffset = 0,

    [string]$RepoRoot = (Split-Path $PSScriptRoot -Parent)
)

$ErrorActionPreference = "Stop"

$variants = @(
    @{ name = "V1_Full";         desc = "FULL mode control" },
    @{ name = "V2_FullRollover"; desc = "FULL + flatten before rollover" },
    @{ name = "V3_Pure";         desc = "PURE_IDEA, regime filter off" },
    @{ name = "V4_OneSide";      desc = "ONE_SIDE" },
    @{ name = "V5_LegB";         desc = "FULL, only leg B (runners)" },
    @{ name = "V6_LegA";         desc = "FULL, only leg A (scalps)" },
    @{ name = "V7_Random1";      desc = "FULL + RANDOM entry, seed 1" },
    @{ name = "V8_Random2";      desc = "FULL + RANDOM entry, seed 2" }
)

$terminal = Join-Path $InstallDir "terminal64.exe"
$iniDir   = Join-Path $RepoRoot  "tester\decision"      # tracked templates (read only)
$localDir = Join-Path $DataDir   "tester_local\decision" # generated run files (never the repo)
$reports  = Join-Path $DataDir   "reports\decision"
$common   = Join-Path $DataDir   "..\Common\Files"

if(!(Test-Path $terminal)) { throw "terminal64.exe not found: $terminal" }
if(!(Test-Path $DataDir))  { throw "DATA folder not found: $DataDir" }

#--- `Report=` in the .ini is relative to the DATA folder and MT5 SILENTLY
#--- writes nothing when that folder does not exist. Derive it from the
#--- actual reports folder, so a -Preset run does not try reports\decision.
function Get-ReportRel([string]$dir)
  {
   $full  = [System.IO.Path]::GetFullPath($dir)
   $root  = [System.IO.Path]::GetFullPath($DataDir)
   if(!$full.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase))
     { throw "reports folder must live inside DATA: $dir" }
   return $full.Substring($root.Length).TrimStart('\')
  }

#--- -Preset: discover the variants from a folder of .set files -----------
if($Preset -ne "")
  {
   $presetDir = Join-Path $RepoRoot $Preset
   if(!(Test-Path $presetDir)) { throw "preset folder not found: $presetDir" }
   $variants = @(Get-ChildItem -Path $presetDir -Filter "*.set" | Sort-Object Name |
                 ForEach-Object {
                    $desc = (Get-Content $_.FullName -TotalCount 3 |
                             Where-Object { $_ -match "^;\s{2,}\S" } |
                             Select-Object -First 1)
                    if($desc) { $desc = $desc -replace "^;\s+", "" } else { $desc = "preset" }
                    @{ name = $_.BaseName; desc = $desc }
                 })
   if($variants.Count -eq 0) { throw ("no .set files in {0}" -f $presetDir) }
   $iniDir = $presetDir
   #never overwrite the decision batch: own reports folder per preset
   $reports = Join-Path $DataDir ("reports\" + (Split-Path $Preset -Leaf))
   Write-Host ("[batch] preset {0}: {1} variant(s) -> {2}" -f $Preset, $variants.Count, $reports)
  }

#--- -Only: keep the requested variants only ------------------------------
if($Only.Count -gt 0)
  {
   $variants = @($variants | Where-Object { $Only -contains $_.name })
   if($variants.Count -eq 0) { throw ("unknown -Only variant(s): {0}" -f ($Only -join ", ")) }
  }

#--- <DATA>\reports\decision must exist before any tester run --------------
New-Item -ItemType Directory -Force -Path $reports | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $DataDir "reports") | Out-Null
#--- the generated .ini files live OUTSIDE the repo (never modify tracked
#--- files from a run script) ---------------------------------------------
New-Item -ItemType Directory -Force -Path $localDir | Out-Null

#--- the run .ini files are generated per pass inside the run loop below --
#--- (one backtest run + one forward run per variant) --------------------
Write-Host "[batch] symbol=$Symbol  $FromDate .. $ToDate  deposit=$Deposit"
Write-Host "[batch] run .ini files are generated in $localDir (the repo is not modified)"

#--- copy every .set to DATA and INSTALL Profiles\Tester ------------------
#--- (ExpertParameters carries the file name only). The session /         --
#--- rollover / Friday hours are SERVER hours: generate them from the     --
#--- UTC values with -ServerUtcOffset (Exness = 0) so the same UTC        --
#--- windows are used on any broker. Day wrap is handled: 24 keeps its    --
#--- end-of-day meaning, everything else wraps into 0..23.                --
if($ServerUtcOffset -ne [math]::Floor($ServerUtcOffset)) { throw "ServerUtcOffset must be whole hours (got $ServerUtcOffset)" }
$off = [int]$ServerUtcOffset

# UTC base hours ("session as now", rollover 21-24 UTC, Friday stop 20 UTC)
$utcHours = [ordered]@{
   SessionStartHour  = 0
   SessionEndHour    = 21
   RolloverStartHour = 21
   RolloverEndHour   = 24      # 24 = end of day
   FridayStopHour    = 20
   FridayFlattenHour = 20      # FridayFlattenMinute (45) is not shifted
}

function To-ServerHour([int]$utcHour, [int]$offsetHours)
  {
   $h = $utcHour + $offsetHours
   if($utcHour -eq 24 -and $h -eq 24) { return 24 }   # end of day stays 24
   while($h -lt 0)  { $h += 24 }
   while($h -ge 24) { $h -= 24 }
   return $h
  }

Write-Host "[batch] server hours from UTC (offset $off h):"
$srvHours = @{}
foreach($k in $utcHours.Keys)
  {
   $srvHours[$k] = To-ServerHour $utcHours[$k] $off
   Write-Host ("        {0,-18} UTC {1,2} -> server {2,2}" -f $k, $utcHours[$k], $srvHours[$k])
  }
if($off -ne 0) { Write-Host "        (windows that cross midnight wrap in the EA)" }

$dataSetDir  = Join-Path $DataDir     "MQL5\Profiles\Tester"
$instSetDir  = Join-Path $InstallDir  "Profiles\Tester"
New-Item -ItemType Directory -Force -Path $dataSetDir | Out-Null

#--- the INSTALL copy is optional: Program Files is write protected for
#--- normal users (PermissionDenied) and the tester reads DATA ---------
$instOk = $true
try
  {
   New-Item -ItemType Directory -Force -Path $instSetDir -ErrorAction Stop | Out-Null
  }
catch
  {
   $instOk = $false
   Write-Host "[batch] WARNING: cannot write $instSetDir - the tester reads DATA, continuing without the INSTALL copy"
  }

foreach($v in $variants)
  {
   $src  = Join-Path $iniDir "$($v.name).set"
   $text = Get-Content $src -Raw
   foreach($k in $utcHours.Keys)
     {
      $text = $text -replace ("(?m)^{0}=\d+" -f $k), ("{0}={1}" -f $k, $srvHours[$k])
     }
   Set-Content -Path (Join-Path $dataSetDir "$($v.name).set") -Value $text -Encoding ASCII
   if($instOk)
     {
      try
        {
         Set-Content -Path (Join-Path $instSetDir "$($v.name).set") -Value $text -Encoding ASCII -ErrorAction Stop
        }
      catch
        {
         $instOk = $false
         Write-Host "[batch] WARNING: INSTALL copy failed ($($_.Exception.Message)) - continuing with the DATA copy only"
        }
     }
  }
Write-Host "[batch] .set files (hours generated) copied to $dataSetDir"
if($instOk) { Write-Host "[batch] .set files copied to $instSetDir as well" }

#--- run the variants -----------------------------------------------------
#--- /config is IGNORED while a terminal is already open: the new process -
#--- only hands the command line to the running instance and exits with 0 -
#--- (all variants "succeed" in a second and write nothing). Refuse to    -
#--- start in that state. ------------------------------------------------
$running = @(Get-Process -Name terminal64 -ErrorAction SilentlyContinue)
if($running.Count -gt 0)
  {
   throw ("MetaTrader 5 is still running (PID {0}). Close the terminal completely (also the tray icon / background process) and run the batch again - /config does nothing while MT5 is open." -f (($running | ForEach-Object { $_.Id }) -join ", "))
  }

#--- BACK and FORWARD are two SEPARATE tester runs ------------------------
#--- A single run with ForwardMode=2 saves the BACKTEST report only (the ---
#--- trade list of the saved report ends at the forward boundary while the -
#--- CSVs go on), so the forward PF / DD / RF were never measured. Two ---
#--- runs with ForwardMode=0 give a real report for each half. -----------
#--- The forward run starts from a fresh deposit; with the fixed 0.01 lot -
#--- PF and RF do not depend on the balance, and the forward DD% is ------
#--- measured against the smaller fresh balance (more conservative). -----
$d_from = [datetime]::ParseExact($FromDate, "yyyy.MM.dd", $null)
$d_to   = [datetime]::ParseExact($ToDate,   "yyyy.MM.dd", $null)
$span   = $d_to - $d_from
$fwd_start = $d_from.AddDays([math]::Floor($span.TotalDays * 2.0 / 3.0))
$back_to   = $fwd_start.AddDays(-1)
$fwd_from  = $fwd_start
Write-Host ("[batch] split: BACK {0} .. {1}   FORWARD {2} .. {3}" -f `
            $d_from.ToString("yyyy.MM.dd"), $back_to.ToString("yyyy.MM.dd"), `
            $fwd_from.ToString("yyyy.MM.dd"), $d_to.ToString("yyyy.MM.dd"))

$repRel = Get-ReportRel $reports
#--- MT5 writes the report only into an EXISTING folder and says nothing --
#--- when it is missing: create every variant folder before the first run -
foreach($v in $variants)
  {
   New-Item -ItemType Directory -Force -Path (Join-Path (Join-Path $DataDir $repRel) $v.name) | Out-Null
  }
Write-Host ("[batch] reports -> {0}\<variant> (Report= is relative to DATA, folders created)" -f $repRel)

$index = 0
foreach($v in $variants)
  {
   $index++
   $n      = $v.name
   $outDir = Join-Path $reports $n
   New-Item -ItemType Directory -Force -Path $outDir | Out-Null

   $passes = @(
       @{ tag = "back"; from = $d_from;   to = $back_to;
          report = "report_back.htm"; legs = "TwinPulse_legs_back.csv" },
       @{ tag = "fwd";  from = $fwd_from; to = $d_to;
          report = "report_fwd.htm";  legs = "TwinPulse_legs_fwd.csv"  }
   )

   #--- a finished folder is only reusable for the SAME run: deposit,
   #--- symbol, dates and preset are stamped into runinfo.txt. MT5 writes
   #--- no trace of the deposit into the report, so reusing a 1000 USD
   #--- folder for a 100 USD test would silently "analyse" the wrong run.
   $runId = ("sym={0};from={1};to={2};dep={3};preset={4}" -f `
             $Symbol, $d_from.ToString("yyyy.MM.dd"), $d_to.ToString("yyyy.MM.dd"), `
             $Deposit, $Preset)
   $idFile  = Join-Path $outDir "runinfo.txt"
   $oldId   = ""
   if(Test-Path $idFile)
     {
      $oldId = (Get-Content $idFile -Raw -ErrorAction SilentlyContinue)
      if($null -eq $oldId) { $oldId = "" }
      $oldId = $oldId.Trim()
     }
   $stale = (($oldId -ne "") -and ($oldId -ne $runId))

   if($Redo -or $stale)
     {
      if($stale)
        {
         Write-Host ("[{0}/{1}] {2}: results are from a DIFFERENT run - redoing" -f $index, $variants.Count, $n)
         Write-Host ("        old: {0}" -f $oldId)
         Write-Host ("        new: {0}" -f $runId)
        }
      else
        {
         Write-Host ("[{0}/{1}] {2}: -Redo, redoing" -f $index, $variants.Count, $n)
        }
      $keep = Join-Path $outDir ("_old_" + (Get-Date -Format "yyyyMMdd_HHmmss"))
      New-Item -ItemType Directory -Force -Path $keep | Out-Null
      Get-ChildItem $outDir -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ne "runinfo.txt" } |
        ForEach-Object { Move-Item $_.FullName (Join-Path $keep $_.Name) -Force }
     }
   Set-Content -Path $idFile -Value $runId -Encoding ASCII

   #--- resume: a variant whose two reports and two CSVs exist is done ----
   $done = $true
   foreach($pass in $passes)
     {
      if(!(Test-Path (Join-Path $outDir $pass.report)) -or
         !(Test-Path (Join-Path $outDir $pass.legs))) { $done = $false }
     }
   if($done)
     {
      Write-Host ("[{0}/{1}] {2}: already done, skipped" -f $index, $variants.Count, $n)
      continue
     }

   Write-Host ("[{0}/{1}] {2}: {3}" -f $index, $variants.Count, $n, $v.desc)

   foreach($pass in $passes)
     {
      $reportH = Join-Path $outDir $pass.report
      $legsCsv = Join-Path $outDir $pass.legs
      if((Test-Path $reportH) -and (Test-Path $legsCsv))
        {
         Write-Host ("        {0}: already done, skipped" -f $pass.tag)
         continue
        }

      #--- archive the old TwinPulse*.csv of Common\Files -----------------
      $archive = Join-Path $reports "_archive"
      New-Item -ItemType Directory -Force -Path $archive | Out-Null
      Get-ChildItem -Path $common -Filter "TwinPulse*.csv" -ErrorAction SilentlyContinue |
        ForEach-Object {
           $stamp = Get-Date -Format "yyyyMMdd_HHmmss"
           Move-Item $_.FullName (Join-Path $archive ("{0}_{1}_{2}_{3}" -f $n, $pass.tag, $stamp, $_.Name)) -Force
        }

      #--- the run .ini for this pass -------------------------------------
      $tag = $pass.tag
      $ini = Join-Path $localDir ("{0}_{1}.ini" -f $n, $tag)
      $txt = @"
; ==========================================================================
;  TwinPulse Hedge EA - decision batch ${n} (${tag} pass)
;  Generated by tools/run_batch.ps1. Model 4 = every tick based on real
;  ticks, ForwardMode 0 = one plain run (the two halves are separate runs
;  so that BOTH have a saved tester report).
; ==========================================================================
[Tester]
Expert=$Expert
ExpertParameters=$n.set
Symbol=$Symbol
Period=$Period
Model=$Model
ExecutionMode=150
Deposit=$Deposit
Currency=USD
Leverage=1:500
FromDate=$($pass.from.ToString("yyyy.MM.dd"))
ToDate=$($pass.to.ToString("yyyy.MM.dd"))
ForwardMode=0
Report=$repRel\$n\$($pass.tag)_report_tmp
ReplaceReport=1
ShutdownTerminal=1
Visual=0
"@
      Set-Content -Path $ini -Value $txt -Encoding ASCII

      Write-Host ("        {0}: {1} .. {2}" -f $tag, $pass.from.ToString("yyyy.MM.dd"), $pass.to.ToString("yyyy.MM.dd"))
      Write-Host "        terminal64.exe /config:$ini"
      $t0 = Get-Date
      $p = Start-Process -FilePath $terminal -ArgumentList "/config:`"$ini`"" -PassThru
      $p.WaitForExit()
      $secs = [int](((Get-Date) - $t0).TotalSeconds)
      Write-Host ("        exit code {0} after {1} s" -f $p.ExitCode, $secs)

      #--- the report: the tester writes it where `Report=` points (relative
      #--- to the DATA folder). Collect what appeared in the last minutes from
      #--- the variant folder and both reports roots, keep the newest. ------
      $cand = @()
      $cand += @(Get-ChildItem -Path $outDir -Filter "*.htm*" -ErrorAction SilentlyContinue |
                 Where-Object { $_.Name -ne "report.htm" -and $_.Name -ne "report_back.htm" -and
                                $_.Name -ne "report_fwd.htm" -and $_.LastWriteTime -ge $t0.AddMinutes(-1) })
      foreach($root in @((Join-Path $DataDir "reports"), (Join-Path $InstallDir "reports")))
        {
         if(Test-Path $root)
           {
            $cand += @(Get-ChildItem -Path $root -Recurse -Filter "*.htm*" -ErrorAction SilentlyContinue |
                       Where-Object { $_.LastWriteTime -ge $t0.AddMinutes(-1) })
           }
        }
      if($cand.Count -gt 0)
        {
         $rep = $cand | Sort-Object LastWriteTime -Descending | Select-Object -First 1
         Copy-Item $rep.FullName $reportH -Force
        }

      #--- fresh CSVs from Common\Files ------------------------------------
      $csvs = @(Get-ChildItem -Path $common -Filter "TwinPulse*.csv" -ErrorAction SilentlyContinue)
      foreach($c in $csvs) { Copy-Item $c.FullName (Join-Path $outDir $pass.legs) -Force }

      if(!(Test-Path $reportH))
        {
         Write-Host ("        ERROR: {0} {1} produced NO report ({2})." -f $n, $tag, ("exit {0} after {1} s" -f $p.ExitCode, $secs))
         Write-Host "        Last lines of the newest tester / terminal log:"
         $logs = @()
         foreach($root in @((Join-Path $DataDir "logs"), (Join-Path $DataDir "Tester")))
           {
            if(Test-Path $root)
              {
               $logs += @(Get-ChildItem -Path $root -Recurse -Filter "*.log" -ErrorAction SilentlyContinue |
                          Where-Object { $_.LastWriteTime -ge $t0.AddMinutes(-2) })
              }
           }
         if($logs.Count -gt 0)
           {
            $newest = $logs | Sort-Object LastWriteTime -Descending | Select-Object -First 1
            Write-Host ("        " + $newest.FullName)
            Get-Content $newest.FullName -Tail 25 | ForEach-Object { Write-Host ("        | " + $_) }
           }
         throw ("{0} {1} produced no report - fix the cause above and run the batch again (it is resume-safe)." -f $n, $tag)
        }

      if($csvs.Count -eq 0)
        {
         Write-Host ("        WARNING: no TwinPulse*.csv in {0} - did the EA really run?" -f $common)
        }
      Write-Host ("        {0}: report + {1} CSV ok" -f $tag, $csvs.Count)
     }

   #--- keep the report file names tidy ----------------------------------
   Get-ChildItem -Path $outDir -Filter "*_report_tmp*.htm*" -ErrorAction SilentlyContinue |
     Remove-Item -Force -ErrorAction SilentlyContinue
   Write-Host ("        done -> {0}" -f $outDir)
  }

Write-Host "[batch] all variants processed."
#--- --data alone means reports\decision: after a -Preset run that is the
#--- WRONG batch, so print the reports folder explicitly -----------------
Write-Host ("[batch] now run:  python tools\summarize_batch.py --reports `"{0}`" --from {1} --to {2} --symbol {3} --deposit {4} --contract-size 100 --ref-spread 0.20" -f $reports, $FromDate, $ToDate, $Symbol, $Deposit)
