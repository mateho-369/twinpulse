# TwinPulse Hedge EA - មែង្គវាស់ប្រតិបត្តិលើ Windows (ភាសាខ្មែរ)

ឯកសារនេះមានពាក្យគ្រប់យ៉ាងមួយយ៉ាង ដើម្បីដំឡើង និងសាកល្បង EA នៅកុំព្រោះ Windows។
កុំដំឡើងពីឯកសារនេះដោយមិនអានទាំងអស់។

---

## 0. ពាក្យផ្លូវ (Paths) ដែលត្រូវដាក់

| ឈ្មោះ | ផ្លូវ |
|---|---|
| `REPO` | ថតិចដែលមានឯកសារ `MQL5`, `dist`, `tester`, `docs` |
| `<INSTALL>` | ថតិចដែលដំឡើង MetaTrader 5 ឧទរណ៍ `C:\Program Files\MetaTrader 5` |
| `<DATA>` | ថតិចទិន្នន័យទិន្នន័យរបស់ terminal — បើកដោយ `File → Open Data Folder` ហើយចុចផ្លូវ |

ឧទរណ៍ធម្មតា៖

```
REPO    = C:\TwinPulse
INSTALL = C:\Program Files\MetaTrader 5
DATA    = C:\Users\<ឈ្មោះអ្នក>\AppData\Roaming\MetaQuotes\Terminal\<HASH>
```

> បើកមួយដែលបើក **Open Data Folder** នៃ terminal បច្ចុប្បន្ន គឺជាដតិចដែលត្រូវប្រើ ព្រោះទីតាងប្ដិន គឺមានលេខ SHA ខុសគ្នាទៅតាម terminal។

---

## 1. ចម្លងឯកសារទៅក្នុង terminal

### 1.1 ឯកសារ MQL5 (ចាំបញ្ចូល)

បើក MetaTrader 5 → `File → Open Data Folder` → បើកថតិច `<DATA>`។ បន្ទាប់មកចម្លងទាំងអស់នៃប្រព័ន្ធថ្នាក់ទី្រង់នេះ៖

```
<DATA>\MQL5\Experts\TwinPulse\       (ពី TwinPulse.mq5)
<DATA>\MQL5\Include\TwinPulse\       (ពី Config.mqh, Utils.mqh, Logger.mqh, State.mqh, Regime.mqh,
                                      Legs.mqh, Bank.mqh, Risk.mqh, Execution.mqh, News.mqh, Panel.mqh)
<DATA>\MQL5\Scripts\TwinPulse\       (ពី TwinPulseSelfTest.mq5, TwinPulseNewsExport.mq5)
```

ការចម្លងដោយពាក្យគ្រប់ (CMD)៖

```
xcopy "<REPO>\MQL5\*" "<DATA>\MQL5\" /E /I /Y
```

### 1.2 ឯកសារ Profiles\Tester

```
xcopy "<REPO>\MQL5\Profiles\Tester\*.set" "<DATA>\MQL5\Profiles\Tester\" /Y
xcopy "<REPO>\MQL5\Profiles\Tester\*.set" "<INSTALL>\MQL5\Profiles\Tester\" /Y
```

(ចម្លងទៅទាំងថតិចទិន្នន័យ និងថតិចដំឡើង ដើម្បីប្រាកដថា terminal នីមួយយកបាន)។

### 1.3 ឯកសារ single file (បើចង់ប្រើតែមួយឯកសារ)

```
copy "<REPO>\dist\TwinPulse_single.mq5" "<DATA>\MQL5\Experts\"
```

---

## 2. Compile (ត្រូវមាន 0 error)

បើក **Command Prompt** ហើយវាយ៖

```
"<INSTALL>\metaeditor64.exe" /compile:"<DATA>\MQL5\Experts\TwinPulse\TwinPulse.mq5" /log
```

```
"<INSTALL>\metaeditor64.exe" /compile:"<DATA>\MQL5\Scripts\TwinPulse\TwinPulseSelfTest.mq5" /log
```

```
"<INSTALL>\metaeditor64.exe" /compile:"<DATA>\MQL5\Scripts\TwinPulse\TwinPulseNewsExport.mq5" /log
```

```
"<INSTALL>\metaeditor64.exe" /compile:"<DATA>\MQL5\Experts\TwinPulse_single.mq5" /log
```

* ឯកសារ log ត្រូវបានសរសេរនៅក្បែរឯកសារដើម (ឧទរណ៍ `TwinPulse.log` ជាប់នឹង `TwinPulse.mq5`)។
* **ត្រូវមាន 0 errors** (warnings អាចទទួលបាន ប៉ុន្តែត្រូវអានពណ៌មែនទៀត)។
* បើកឯកសារ log ដោយ `Notepad` ដើម្បីពិនិត្យបំណោរបែងចែកលើក្នុងជំហានទី ៣។

---

## 3. ដំឡើង Self Test (ត្រូវមានតែ PASS)

1. បើក terminal → បើក chart ណាមួយ (ឧទរណ៍ EURUSD M1)។
2. អូស chart ទៅកាន់ `Navigator` → `Expert Advisors` → `TwinPulseSelfTest` → អូសទៅលើ chart។
3. ចុច **OK** (មិនចាំបាច់បើក Algo Trading សម្រាប់ script)។
4. មើលផ្ទាំង **Expert** (tab) នៃ terminal៖ ត្រូវមាន `PASS` គ្រប់ជួរ និង `ALL TESTS PASSED`។

បើកប្រសិនបើមាន `FAIL` ណាមួយ → **មិនត្រូវ** ប្រើ EA ទៀតទេ សូមផ្ញើសារទៅមកវិញជាមួយសាកល្បងទាំងអស់។

---

## 4. បង្កើតឯកសារព័ត៌មា (News Export) — ត្រូវធ្វើ **ម្តង** នៅលើ chart live **មុន** tester រាល់លើក

> **សំខាន់ (មុនការសាកល្បងណាមួយ)៖** Strategy Tester មិនអាចអាន economic calendar បានទេ ដូច្នេះរាល់ការសាកល្បង
> ត្រូវការឯកសារ `Common\Files\TwinPulse_news.csv` ដែលបង្កើតដោយ `TwinPulseNewsExport` ជាមុនសិន។
> បើឯកសារនេះគ្មាន ពេល tester ចាប់ផ្តើម EA នឹងបោះពុម្ពសារនេះនៅក្នុងកំណត់ហេតុ៖
>
> ```
> TwinPulse_news.csv not found in Common\Files - news filter OFF
> ```
>
> ហើយ **news filter នឹងបិទដោយស្វ័យប្រវត្តិ** (ដោយមិនឃាត់ព័ត៌មាអ្វីទាំងអស់ក្នុងអំឡុងពេលសាកល្បង)។
> លទ្ធផលសាកល្បងនឹងខុសពីការពិត។ ដូច្នេះ៖ **ត្រូវដំណើរការ `TwinPulseNewsExport` ម្តងនៅលើ chart របស់
> គណនី live ជានិច្ច មុននឹងចាប់ផ្តើម tester ណាមួយ**។

ត្រូវបើក chart របស់ **XAUUSDm** នៅគណនី live ហើយដំឡើង script `TwinPulseNewsExport` លើ chart នោះ។

* ឯកសារនឹងបង្កើត `Common\Files\TwinPulse_news.csv` ដែលមានព័ត៌មា USD ចំនួនធំពីឆ្នាំ ២០១៨ ដល់ថ្ងៃនេះ។
* ពេលក្នុង **Strategy Tester** កម្មវិធីនៃ calendar មិនមានទិន្នន័យ ដូច្នេះឯកសារនេះជាមូលដ្ឋានតែមួយក្នុងការសាកល្បង។
* បើកឯកសារដើម្បីពិនិត្យ៖ `File → Open Data Folder → MQL5\Files` (ឬផ្លូវ `Common` ដែលមានក្នុងថតិច `Terminal\Common`)។
* ពិនិត្យមើល **មុន** រាល់ការសាកល្បងថាឯកសារនេះពិតជាមាន ហើយ EA មិនបានបោះពុម្ពសារ
  `TwinPulse_news.csv not found in Common\Files - news filter OFF` នោះទេ។

---

## 5. ដំឡើង Strategy Tester តាម `.ini`

0. **បង្កើតថតិច `<DATA>\reports` ជាមុនសិន** — ឯកសារ `.ini` ទាំងអស់សរសេររបាយការណ៍ទៅ
   `Report=reports\...` ហើយ tester នឹងមិនរក្សាទុករបាយការណ៍ (ឬមិនចាប់ផ្តើមត្រឹមត្រូវ) ទេ
   បើថតិចនេះមិនទាន់មាន។ បង្កើតវាដោយ៖

   ```
   mkdir "<DATA>\reports"
   ```

   ហើយត្រូវប្រាកដថា `Common\Files\TwinPulse_news.csv` មានរួចហើយ (ផ្នែកទី ៤ ខាងលើ)។

1. **បើក chart របស់ XAUUSDm M5 មួយដំណើង** (ត្រូវបើក ដើម្បីទាញយកប្រវេតិកម្ម និងប្រាកដថា terminal យកបានទិន្នន័យស្មាន)។
2. បើក **Command Prompt** ហើយវាយ៖

```
"<INSTALL>\terminal64.exe" /config:"<REPO>\tester\backtest_full.ini"
```

```
"<INSTALL>\terminal64.exe" /config:"<REPO>\tester\backtest_pure.ini"
```

```
"<INSTALL>\terminal64.exe" /config:"<REPO>\tester\backtest_oneside.ini"
```

```
"<INSTALL>\terminal64.exe" /config:"<REPO>\tester\optimize_full.ini"
```

3. រង់ចាំឲ្យ terminal បង្ហាញលទ្ធផល។ `ShutdownTerminal=1` ធ្វើឲ្យ terminal បិទដោយខ្លួនឯងបន្ទាប់ចប់ការសាកល្បង។
4. របៀបបិទផ្ទាំងរបស់ terminal ត្រូវមើលក្នុងថតិច `<DATA>\reports\` (ត្រូវបង្កើតថតិចនេះជាមុនសិន ជំហានទី ០)។

> បើកតែបញ្ចូលនៃ `.ini`៖ `ToDate=2026.09.30` គឺជថ្ងៃចុងក្រោយនៃខែមុន។ បើកចាស់់ ដូចនេះ សូមកែការណ៍នេះ និងរង់ចាំការសាកល្បងបានបញ្ចប់ មុននឹងចាប់ផ្តើម។

---

## 6. ដំឡើងលើគណនី Demo (Exness)

1. បើក chart **XAUUSDm M5**។
2. ផ្ទាំងដែលមាននៅខាងលើ → `Algo Trading` → **ON** (និងបើក `Allow live trading` ក្នុងផ្ទាំង Expert Advisors)។
3. អូស `TwinPulse` ពី `Navigator` → ទៅលើ chart → ជ្រើសកំណត់តាម `Default.set`។
4. ចុច **OK**។ ត្រូវឃើញផ្ទាំងក្រហមពណ៌នៅជង់ក្រោមខាងស្មើរបស់ chart ដែលមានព័ត៌មាទាំងអស់។
5. ត្រូវតែចាំបញ្ចូលលើគណនី **Demo** រហូតដល់លក្ខខណ្ឌទាំងអស់បានឆ្លោះ។

---

## 7. បញ្ហាប្រុងប្រយ័ត្ន (Troubleshooting)

| សញ្ញា / កំណត់ចំណាំ | មូលដ្ឋាន | ដំណើរការដោយតែមួយ |
|---|---|---|
| **10030** (fill required / invalid fill) | របៀបបំពេញមិនត្រូវជាមួយ broker | EA ជ្រើសរើសរបៀបបំពេញពី `SYMBOL_FILLING_MODE` ដោយស្វ័យរឿង បើកតាមរយៈពេលមួយក្នុងឯកសារ ហើយពិនិត្យ `VerboseLog=true` ម្តងទៀត |
| **10019** (no money) | គណនីគ្មានសាច់គាត់គ្រប់គ្នា | បន្ថែមគណនី ឬបន្ថែម `MaxTotalLots`/`BaseLot` ត្រូវបានការពារ `MinMarginLevelPct` ក៏ត្រូវការពារដែរ |
| **"not hedging account"** | `ACCOUNT_MARGIN_MODE` មិនមែន `RETAIL_HEDGING` | បើក hedging ក្នុង `Tools → Options → Accounts` (ត្រូវបានគណនីថ្មី) ឬប្ដូរទៅ broker ដែលគ្រប់គ្នា។ **មិនអាច** បង្កើត EA ឲ្យបញ្ជាទិញលើ netting បានទេ |
| **"Real account and AllowLive=false"** | ការការពារដោយច្បាស់ | នៅគណនី demo វានឹងមិនក្របស់; កុំបើក `AllowLive=true` បើកមិនទាន់ត្រូវ |
| **ឯកសារព័ត៌មាមិនទាន់មាន** (`TwinPulse_news.csv not found in Common\Files - news filter OFF`) | tester មិនអាន calendar បាន ហើយ news filter បិទដោយស្វ័យប្រវត្តិ | ដំឡើង `TwinPulseNewsExport` ម្តងនៅ chart live **មុន** ការសាកល្បងរាល់លើក (ផ្នែកទី ៤) |
| **tester មិនសរសេររបាយការណ៍** | ថតិច `<DATA>\reports` មិនទាន់មាន | បង្កើតថតិច `mkdir "<DATA>\reports"` ជាមុនសិន មុននឹងរត់ឯកសារ `.ini` ណាមួយ (ផ្នែកទី ៥ ជំហានទី ០) |
| **tester មិនចាប់ផ្តើម** | terminal មិនទាន់បានទិន្នន័យប្រវេតិកម្ម ឬ `.ini` មិនត្រឹមតែទ្រង់ | ១) បើក chart XAUUSDm M5 មួយដំណើង ២) សុំទិន្នន័យប្រវេតិកម្ម (`View → Symbols → XAUUSDm → Download`) ៣) ពិនិត្យថា `ExpertParameters` មានផ្លូវត្រឹមតែគណនីទិន្នន័យ ៤) កុំបើក `Visual=1` ពេលប្រើ `/config` |
| **"Market closed"** | សប្តាហ៍ ឬពេលបិទមណ្ឌល | EA រង់ចាំត្រូវ វានឹងសាកល្បងវិញនៅម៉ោងប្រទាន់បើក |
| **"too many requests"** | ការបញ្ជាទិញញាប់ញៀន | `MaxOrderRetries` និង `TimerSeconds` កុំបន្ថែម; កុំបើក EA ច្រើនដែលនៅគណនីដូចគ្នា |
| **មិនឃើញផ្ទាំងក្រហម** | `ShowPanel=false` | បើក `ShowPanel` វិញ ឬដំឡើង EA ម្តងទៀត |
| **ចំណេញមិនដូចទាន់ព្រមាននៅ tester** | តម្លៃចម្ងាយ និង slippage មិនដូចគ្នា | ប្រើ `Model=4` (real ticks) និង `ExecutionMode` ត្រឹមតែ terminal; ប្រែប្រួលតាមជួរតែមួយ ហើយកត់ត្រាវារតាមរយៈពេល |
| **ការបញ្ជាទិញមិនដាក់** | `Mode`, សម័យ ឬ regime | មើលផ្ទាំងក្រហម៖ `regime` ត្រូវជា `RANGE` សម្រាប់ FULL; មិនទៀតបើករយៈពេល ២១:០០–២៣:៥៩; ថ្ងៃសុក្រមិនបើកក្នុងម៉ោង ២០:០០–២០:៤៥ |

---

## 8. បញ្ជីឯកសារដែលត្រូវរក្សាទុក

| ថតិច | ខ្លឹម |
|---|---|
| `<DATA>\MQL5\Experts\TwinPulse\TwinPulse.ex5` | អ្នកបាន compile ហើយ |
| `<DATA>\MQL5\Scripts\TwinPulse\TwinPulseSelfTest.ex5` | អ្នកបាន compile ហើយ |
| `<DATA>\MQL5\Scripts\TwinPulse\TwinPulseNewsExport.ex5` | អ្នកបាន compile ហើយ |
| `<DATA>\MQL5\Experts\TwinPulse_single.ex5` | អ្នកបាន compile ហើយ |
| `<DATA>\MQL5\Files\TwinPulse.log` | កំណត់ចំណាំ |
| `<DATA>\MQL5\Files\TwinPulse_legs.csv` | ប្រវេតិកម្មដែលបានបិទ |
| `<DATA>\MQL5\Files\TwinPulse_cycles.csv` | ប្រវេតិកម្មវគ្គ |
| `Common\Files\TwinPulse_news.csv` | ព័ត៌មា (បង្កើតដោយ script) |
| `<terminal data>\reports\*.htm` | របៀបសាកល្បង |

---

## រត់ decision batch ពេលយប់ (tools\run_batch.ps1)

ការសម្រេចចិត្ត (hedge idea បន្ត ឬបញ្ឈប់) ត្រូវការ batch ទិន្នន័យ ៨ ប្រភេទ
(V1..V8) លើប្រវែងពេញ ៤ ឆ្នាំកន្លះ។ វាយូរ - រត់វាពេលយប់។

### ១. មុនពេលរត់

1. Compile ចុងក្រោយ (TwinPulse.mq5 + TwinPulseSelfTest.mq5) ហើយរត់ SelfTest
   ឲ្យបាន PASS ទាំងអស់។
2. ត្រូវការប្រវត្តិតម្លៃពិត (real ticks) សម្រាប់និមិត្តសញ្ញាដែលនឹងសាកល្បង។
   បើ History Quality តិចជាង ៩០% - លទ្ធផលនឹងត្រូវសម្គាល់ថា
   **NOT VALID FOR GATES** ហើយមិនអាចសម្រេចអ្វីបានទេ។
3. កែប៉ារ៉ាម៉ែត្រនៅដើម `tools\run_batch.ps1` (ឬហៅជាមួយ -Symbol ។ល។):
   `-Symbol` (ដូចជា XAUUSDm), `-FromDate` (2022.01.01), `-ToDate` (2026.09.30),
   `-Deposit` (1000) រួមទាំង `-InstallDir` (ថត terminal64.exe) និង
   `-DataDir` (ថត data របស់ terminal)។
4. រៀបចំ `Common\Files\TwinPulse_news.csv` បើប្រើតម្រងព័ត៌មាន (NewsFilter)។

### ២. រត់ម្តងទៅគេង (PowerShell)

```powershell
powershell -ExecutionPolicy Bypass -File tools\run_batch.ps1
```

Script នឹងបង្កើតឯកសារ `.ini` ទាំង ៨ ពីប៉ារ៉ាម៉ែត្រខាងលើ ចម្លងឯកសារ `.set`
ទៅ `<DATA>\MQL5\Profiles\Tester\` និង `<INSTALL>\Profiles\Tester\` ហើយរត់
terminal64.exe ម្តងមួយៗ (រង់ចាំមួយបញ្ចប់ទើបមួយទៀត)។ រាល់ variant:
ផ្លាស់ទី `TwinPulse*.csv` ចាស់ពី `Common\Files` ទៅ `reports\decision\_archive\`
សិន រួចចម្លងរបាយការណ៍ + CSV ថ្មីទៅ `reports\decision\<variant>\`។

**អាចបន្តវិញបាន (resume-safe):** បើរត់ជាប់គាំង ឬគ្រឿងថាមពលដាច់ ចាប់ផ្តើម
script ដដែល - variant ដែលមានរបាយការណ៍រួចហើយនឹងត្រូវរំលង។

### ៣. ពេលព្រឹក - បូកសរុប

```powershell
python tools\summarize_batch.py --data "<DataDir>" --from 2022.01.01 --to 2026.09.30
```

អាន `reports\decision\SUMMARY.md` (BACK + FORWARD + តារាង gates + ការសម្រេច)
និង `SUMMARY_BACK.md` (លេខ BACK ប៉ុណ្ណោះ)។ ការសម្រេច (PASS / cost round /
បញ្ឈប់) ត្រូវគោរពតាម `docs\DECISION_RULES.md` - ក្បួននោះត្រូវបានកំណត់
**មុនពេលមានលទ្ធផល** ហើយមិនត្រូវកែក្រោយឃើញលទ្ធផលឡើយ។
