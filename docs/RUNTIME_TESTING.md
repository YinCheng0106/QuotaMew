# QuotaMew v0.1 長時間 Runtime 驗證

本文件是 QuotaMew v0.1 的人工 runtime 測試手冊。目標是找出長時間執行、反覆刷新、重連、Settings／menu lifecycle 與通知流程中的累積問題；不是用單元測試取代 soak test，也不是用單一記憶體讀數判定 memory leak。

## v0.2 Milestone C Onboarding acceptance

2026-09-07 source 已實作；使用者回報以下 planned runtime/UI checks 全數通過，故 Milestone C manual acceptance **COMPLETE（user-observed）**。這筆紀錄不是由 unit test、build 或 preview 推導，也不新增未回報的量測值。不要為了製造 fresh state 清除 production `dev.quotapulse.app` domain；只操作 Debug identity 或乾淨測試帳號。

| 群組 | 人工檢查 | 結果 |
| --- | --- | --- |
| Fresh install | Finder／LaunchServices normal launch 後 status item 與單一 Onboarding 都可見；第二次 activation 只 focus 同一視窗；Codex 顯示目前 conservative diagnostics；Claude 同時標示 Experimental / Unverified；隱私文案正確；沒有自動通知提示 | 使用者回報通過 |
| Shared settings | Remaining／Used 立即同步 Dashboard/status item；Automatic／Codex／Claude pin 沿用既有 unavailable-pin 規則；Launch at Login 顯示系統實際狀態，成功與失敗都正確回讀；沒有 Luna Reserve 選項 | 使用者回報通過 |
| Complete | Get Started 不 refresh、不要求通知、不重插 status item；關閉視窗後下次 normal launch 不重開 | 使用者回報通過 |
| Skip/close | Skip 與首次標準 close／Escape／Command-W 保存 skipped；先前手動改的 display、pin、Login Item 或通知選擇保留；Skip 本身沒有其他 side effect；下次 launch 不重開 | 使用者回報通過 |
| Replay | Settings → General → Show Onboarding Again 反映目前設定；重複要求 focus/reuse；Close／Escape／Command-W 不改 completed/skipped/version；關閉後可再次開啟；不自動要求通知 | 使用者回報通過 |
| Recovery | menu-bar intent OFF 的 explicit reopen 只顯示 Recovery；Onboarding 不同時出現。hidden + Login Item quiet exit，沒有 status item 或 Onboarding | 使用者回報通過 |
| Notifications | 只有 Enable Notifications 會出現 macOS authorization；允許／拒絕後狀態正確；詳細 thresholds 仍只在 Settings → Notifications；Get Started/Skip/replay/display/pin 都不要求 | 使用者回報通過 |
| Regression | 左鍵 Dashboard、右鍵 Refresh Now／Settings…／Quit、5 小時／每週、Luna Reserve、provider lifecycle、notification lifecycle 與單一 status item 都不退化 | 使用者回報通過 |
| Appearance/accessibility | Light、Dark、English、繁體中文（臺灣）、Tab／Shift-Tab、Return、Escape、Command-W、VoiceOver heading/control order/provider text status 與窄視窗皆可用 | 使用者回報通過 |

Fresh migration 另做三種受控 domain：完全空白顯示一次；模擬 Beta 2（只有既有 short-window reminder migration key、沒有 onboarding key）分類為 skipped 而不顯示；已有 completed/skipped/version 的 domain 原樣保留。使用者亦回報完成 Recovery priority、Login Item behavior、onboarding window focus/reuse、transient activation／Dock、notification explicit-action、Launch at Login、left-click Dashboard、right-click actions、5-hour／Weekly、English／Traditional Chinese、light／dark、keyboard 與 VoiceOver/accessibility smoke test。普通 XCTest 已覆蓋分類與 owner 行為；本段 manual acceptance 仍以使用者觀察為證據，不宣稱額外測量。

## v0.2 Product Polish acceptance

2026-09-07 新增；使用者回報以下 planned checks 全數通過，Product Polish manual acceptance **COMPLETE（user-observed）**。不因 XCTest/build 通過而代替人工 evidence。Public release 仍是 Beta 2，工作樹是未發行 source。既有長時間 runtime 手冊與下方歷史 Milestone B 證據繼續適用。

| # | 檢查 | 結果 |
| --- | --- | --- |
| 1 | 一般 Codex 顯示「5 小時／每週」；英文「5-hour／Weekly」 | 使用者回報通過 |
| 2 | 一般視窗不顯示「主要配額週期／次要配額週期」 | 使用者回報通過 |
| 3 | UI 沒有 raw gpt-reserve 或 base_model_inference | 使用者回報通過 |
| 4 | Reserve 平常為精簡次要列；新鮮一般額度恰為 100% used 且 reset 未到期才展開；stale／缺值不展開 | 使用者回報通過 |
| 5 | Remaining／Used 與 pin 切換正常，Reserve 不取代 status item 的一般百分比 | 使用者回報通過 |
| 6 | 倒數正確且與名稱分開，reset 已過不宣稱完成；窄寬不截斷主要資訊 | 使用者回報通過 |
| 7 | 實際 approaching／completed 通知名稱與 Dashboard 一致；Reserve 不通知 | 使用者回報通過 |
| 8 | 左鍵開啟／關閉 Dashboard；外部點擊 dismissal 正常 | 使用者回報通過 |
| 9 | 右鍵只開一份原生選單，不開 Dashboard；重複開關不累積 item | 使用者回報通過 |
| 10 | 立即重新整理正常；進行中再次要求不產生重疊刷新 | 使用者回報通過 |
| 11 | 未曾開 Dashboard 就直接右鍵「設定…」也能開既有 Settings；反覆開啟重用視窗 | 使用者回報通過 |
| 12 | 退出 QuotaMew 正常結束，owned Codex child 清理，偏好/onboarding 不變 | 使用者回報通過 |
| 13 | icon、—／0%／61%／100% 與 intrinsic width 不退化；notch／多螢幕可用 | 使用者回報通過 |
| 14 | 沒有意外出現舊 QuotaPulse 公開 App 名稱 | 使用者回報通過 |
| 15 | About（若提供）、recovery、Settings、Dashboard 與系統 App 名稱符合 QuotaMew／QuotaMew Debug | 使用者回報通過 |
| 16 | Light mode；secondary Reserve 與 progress 對比清楚 | 使用者回報通過 |
| 17 | Dark mode；包含 reduced transparency | 使用者回報通過 |
| 18 | English 文案與右鍵選單 | 使用者回報通過 |
| 19 | 繁體中文（臺灣）文案與右鍵選單 | 使用者回報通過 |
| 20 | VoiceOver 讀出 provider／共用名稱／百分比；倒數仍可存取；方向鍵／Return／Escape 操作選單與 Command-Q 正常 | 使用者回報通過 |

Reserve 耗盡條件可先用 synthetic preview/fixture 檢查，不為驗收耗用真實額度或改寫 provider 資料。普通 XCTest 不送實際通知；系統通知送達須另行明確操作。這輪未完成新 UI 的視覺／VoiceOver、真實通知、installed Login Item 或效能驗證，不沿用舊 Milestone B 的人工通過紀錄冒充本次證據。

自動化證據、名稱殘留分類與版本下一步見 [PRODUCT_POLISH_AUDIT.md](PRODUCT_POLISH_AUDIT.md)。

效能門檻以 [`docs/PERFORMANCE.md`](PERFORMANCE.md) 為唯一來源。本文件負責測試步驟與紀錄格式。

## 1. 前置條件

- macOS 14 以上。
- Xcode 與 Command Line Tools 可正常使用。
- ChatGPT.app 可正常啟動，而且其整合 Codex runtime 已登入並可取得額度。
- 測試期間避免同時執行另一份 QuotaMew。
- 每次 Xcode Run、LaunchServices launch 或 Computer Use 前，先以 QuotaMew 的正常 Quit 結束既有 Debug process，並確認沒有另一個相同 bundle host；不要用 `open -n` 或同時保留 Xcode Run 與 DerivedData launch。人工 menu-bar acceptance 不得從 ChatGPT／Codex 擁有的 shell 直接執行 app 內的 Mach-O；應從 Finder、Spotlight 或 `/usr/bin/open <QuotaMew.app>` 啟動 app bundle。
- 測試前記錄 macOS、Xcode、ChatGPT.app 與 Codex runtime 版本；不得記錄 credential、token、provider raw response、prompt、conversation、session 或私密路徑。
- 先執行完整 XCTest；自動測試通過只代表既有不變量仍成立，不代表長時間穩定。

建議分成兩種執行：

1. **Release soak**：正式記憶體與 CPU 驗收，以 Activity Monitor、`ps`、`top`、`lsof` 與 Instruments 觀察。效能預算只套用在這一輪。
2. **Debug diagnostics run**：觀察 refresh、scheduler、Codex child、reader、notification 與 provider 狀態。Debug 記憶體不可拿來判定 Release 是否符合預算。

### 開發與正式 bundle identity

QuotaMew 使用同一個 app target，透過 Xcode build configuration 隔離 macOS 以 bundle identifier 管理的狀態：

| Configuration | Bundle identifier | Display name |
| --- | --- | --- |
| Debug | `dev.quotapulse.development.app` | `QuotaMew Debug` |
| Release | `dev.quotapulse.app` | `QuotaMew` |

因此平常從 Xcode Run 啟動 Debug 時，`NSStatusItem` 的 stable autosave identity、Control Center 狀態、`SMAppService.mainApp` 的 Launch at Login registration、`UserDefaults.standard` domain 與 `UNUserNotificationCenter.current()` 的權限／通知都屬於 Debug identity，不會沿用或寫入 Release identity。兩者不使用 shared preferences，也沒有 App Group entitlement；Debug 首次啟動看到預設設定是預期行為，不應從 Release preferences 手動搬移。

目前產物檔名與 executable 使用 `QuotaMew.app`／`QuotaMew`，test host 與操作指令也必須使用這組名稱；在 Finder、系統通知與相關 macOS 設定中，Debug 以 `QuotaMew Debug` 顯示。要驗證 Release runtime 時，務必明確使用 Release 產物的完整路徑，不要把 Debug build 複製、改名或註冊成 production app。

App-hosted live tests 的 UserDefaults opt-in 也必須寫入 Debug domain：`runLiveNotificationTest` 與 `runLiveCodexProviderTest` 都使用 `dev.quotapulse.development.app`，測試後立即刪除。不要再把這些 development-only keys 寫入 `dev.quotapulse.app`。

一般 XCTest 也是 app-hosted，但 production composition root 會在 controller factory 執行前辨識 XCTest，完全略過 `StatusItemController`／`NSStatusItem` 建立。`QuotaMew.xcscheme` 因此恢復 `parallelizable = YES`；完整 suite 的 acceptance gate 是所有並行 test-host process 都建立零 status item，必要時再用 Control Center read-only log 抽查。Controller 行為由 injected fake status item／popover 的單元測試覆蓋，不靠真實 system UI。所有直接修改 `SettingsStore` 的 tests 必須繼續使用 UUID suite 並清除 domain；完整測試前後也應抽查 `presentation.menu-bar-extra.requested` 沒有改變。System-level Control Center allowance 與實際像素可見性不是普通 XCTest 的驗證項目。

### Foreign-association prevention

1. Debug 永久使用 `dev.quotapulse.development.app`，Release 永久使用 `dev.quotapulse.app`；不得以輪替 identity 當成修復。
2. Menu bar 人工驗證必須從 fresh Debug app bundle 透過 LaunchServices 啟動，並先確認只有一個 QuotaMew process／status-item host。
3. Build-only 不得啟動 App。普通 XCTest 可並行，但所有 test-host process 必須建立零 status item。
4. Helper process 不得建立 QuotaMew status item，也不得同時有多個 process host 同一個 item。
5. 不得由 parent PID／responsible process 單獨推論 Control Center ownership。至少同時記錄 LaunchServices bundle identity、executable path 與 unified log 中的 status-item host identifier。
6. macOS 26.6.2 的歷史 read-only evidence 顯示，從 Codex-owned shell 直接執行當時仍名為 QuotaPulse 的 Mach-O 時，LaunchServices 會保留正確的 QuotaPulse bundle identity，但把 inferred `parentASN` 記為 ChatGPT；同一 app bundle 經 `open` 啟動時則由 PID 1 啟動且沒有該 inferred parent。Control Center host 仍必須另外確認，不得只由 ancestry 推論 ownership。
7. 歷史 stale association 不得透過 Control Center 私有檔案、protected preferences、private frameworks、`defaults` workaround 或 bundle-ID rotation 修復。

### Final clean-user Release evidence

2026-09-02 在乾淨的 macOS 使用者帳號中，透過 Finder／LaunchServices 正常啟動 Release `QuotaPulse.app`。QuotaPulse 與 ChatGPT 顯示為獨立的選單列應用程式；隱藏 ChatGPT 不會隱藏 QuotaPulse，隱藏 QuotaPulse 也不影響 ChatGPT。這是 clean-user Release 行為證據，不宣稱每一台 macOS 安裝都不可能有系統層級異常。

主要開發帳號先前觀察到的 ChatGPT → QuotaPulse cascade，分類為歷史、使用者範圍的 macOS Control Center stale application association，與過往非典型開發／測試啟動拓撲有關，不是目前 QuotaPulse Release 架構缺陷。不要以程式清除或修復該 stale state；不要改 bundle identifier、`autosaveName` 或使用 private Control Center API。人工 menu-bar runtime 測試應從 Finder、Spotlight 或 `/usr/bin/open` 啟動 app bundle，不要從 Codex／ChatGPT 擁有的 shell 直接執行 Mach-O。

Final status: **Hybrid NSStatusItem migration COMPLETE; Milestone A COMPLETE / frozen; Milestone B COMPLETE; Milestone C COMPLETE; Product Polish COMPLETE.** Next: v0.2 Menu Bar Display Polish／Beta 3 stabilization work. Public release remains v0.2.0-beta.2; Beta 3 is not released and final v0.2.0 is not complete.

### Autosave identity 與 status-item 寬度

- Debug stable autosave identity 固定為 `dev.quotapulse.development.app.primary-status-item`；Release 固定為 `dev.quotapulse.app.primary-status-item`。2026-09-02 的 temporary `primary-status-item-v2` 實驗沒有中斷 ChatGPT cascade，因此不得保留 v2 或繼續輪替 identity。
- 標準 button 固定使用 template SF Symbol、`.imageLeading`、`imageHugsTitle = true`、`.scaleProportionallyDown` 與沒有前後空白的 monospaced-digit title。
- `NSStatusItem` 以 `variableLength` 建立，但內容設定後的最終 `length` 必須由 `button.intrinsicContentSize.width` 導出，且不小於 `NSStatusBar.thickness`。不得用固定 percentage 寬度、空白、負 kerning 或 custom view 壓縮。
- 人工量測 `—`、`0%`、`61%`、`100%` 時，分別記錄 item length、button bounds、intrinsic width、image/title rect；拖曳前後另外記錄 button frame。frame 外的鄰接 spacing、overflow 與 notch placement 屬 macOS，不應用 QuotaMew 內容 hack 消除。

### Menu bar label 的證據邊界

選單列 compact label 必須把三種證據分開記錄：

1. `UsagePresentationTests` 與 `MenuBarPresentation` tests 只驗證 percentage、placeholder 與 provider selection 等 presentation-model contract。
2. `SettingsIntegrationTests.testMenuBarPresentationObservationInvalidatesForPinAndUsageModeChanges` 只驗證 SwiftUI Observation 讀取的 runtime model 會因 pin 與 Remaining／Used 改變而 invalidated，並驗證這些變更不觸發 provider refresh、notification 或 reset pipeline。
3. XCTest 與 controller fake 都不能證明 macOS system status item 實際渲染文字。修改 label composition 後，必須用 fresh Debug artifact、單一 `dev.quotapulse.development.app` process 與真實選單列做人工檢查：production standard status button 應同時顯示 template icon 與 compact percentage／placeholder。不得將 DEBUG probe、timer 或 bundle identity workaround 留在 production。

做視覺比對時，讓 Finder 等選單較短的 App 位於前景。macOS 可能因前景 App 選單與其他 status items 佔用寬度而暫時隱藏整個 QuotaMew item；不要把相鄰第三方圖示誤認為 QuotaMew，也不要由 process、UserDefaults 或 Control Center toggle 推論實際可見性。

### MenuBar hide／show 生命週期

QuotaMew 的 AppKit controller 與 status item visibility 分離；`Show Menu Bar Item` OFF 只保存 hide intent 並設定同一個 `NSStatusItem.isVisible = false`，process 應繼續運作。四項證據必須分列：

1. `presentation.menu-bar-extra.requested`：沿用舊 key 以保留 migration 的 QuotaMew 使用者意圖，只有 Settings／recovery action 可寫。
2. `SettingsModel.isMenuBarItemVisible`：本次 process 的 public logical visibility projection；`NSStatusItem.isVisible` KVO 可改成 `false`，但不得回寫 persisted intent。
3. Control Center app-status-item host：unified log 可只讀確認哪個 process／bundle 正在註冊與請求 visibility，但這不是可用的產品 API。
4. 實際 status item 像素可見性／Control Center allowance：macOS 最終決定，沒有 QuotaMew 可用的公開權威查詢 API；`isVisible == true` 也不保證目前畫面一定看得見。

每次生命週期修改都要用 fresh Debug artifact 執行以下序列，不使用任意 sleep，也不讀寫 Control Center 私有 preference：

1. 確認 requested ON，啟動單一 `dev.quotapulse.development.app` process，記錄 PID 與實際 menu bar 畫面。
2. 開啟 Settings，切換 OFF；確認 toggle 與 runtime status 立即變成 hidden、status item 消失，但同一 PID 仍存在。
3. 查詢該 PID 的 Unified Log，確認沒有 assertion、uncaught exception、crash signal 或 termination sequence；再檢查 `~/Library/Logs/DiagnosticReports` 沒有新的 QuotaMew report。
4. 關閉 Settings，使 App 完全隱藏；從 Finder／Spotlight 明確重新開啟同一 artifact。確認 recovery window 可達，沒有永久 Dock icon。
5. 按 Show；確認 persisted intent 與 logical visibility 都回到 true，且仍是同一 PID／同一 controller／同一 status item。視窗應在 shared model 傳遞 KVO change 後關閉。再人工確認 menu bar label 的 icon、percentage、Automatic／pin 與 Remaining／Used。
6. 若只做 read-only 系統檢查，可到「系統設定」→「選單列」記錄 QuotaMew 列出的狀態。改動 Allow in the Menu Bar 屬 system-setting mutation，需另行明確確認；不得使用 `defaults`、`group.com.apple.controlcenter`、受保護 preference file 或 private API。

基線消失若要分類，先看 exit status、`App termination approved`／`Termination complete` 等 AppKit log、Xcode console 與 crash report，再判斷是正常自動／明確終止或真正 crash。關閉 Settings toggle 本身不得呼叫 `terminate`。目前仍保留兩個刻意正常終止點：hidden 的 login-item launch 安靜退出；使用者在 hidden recovery 中按 Quit 或關閉唯一復原視窗時退出，避免不可達的 invisible process。

若要做實際 Launch at Login register／restart 測試，先把已簽章 Debug artifact 安裝到獨立且穩定的 `/Applications/QuotaMew Debug.app`，再從該路徑啟用；不要覆蓋 `/Applications/QuotaMew.app`。用 `sfltool dumpbtm` 確認紀錄屬於 `dev.quotapulse.development.app`，測試完成後先在 QuotaMew Debug 關閉登入時啟動，再移除測試 artifact。DerivedData 或 `/tmp` 啟動只適合確認 UI／identity，不足以宣稱 installed-app registration 與重新登入已通過。

## 2. 建置與啟動

### Xcode

在 Xcode 開啟 `QuotaMew.xcodeproj`，選擇 `QuotaMew` scheme 與 `My Mac`。

- Diagnostics run：使用 Debug，按 Run。
- Performance soak：Edit Scheme > Run > Build Configuration 改成 Release，再按 Run。

### Command line

以下命令把產物放在獨立的暫存 Derived Data，不會改寫 repository：

```sh
/usr/bin/xcodebuild \
  -project QuotaMew.xcodeproj \
  -scheme QuotaMew \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/QuotaMewRuntime-Debug \
  build

/usr/bin/open /tmp/QuotaMewRuntime-Debug/Build/Products/Debug/QuotaMew.app
```

Release：

```sh
/usr/bin/xcodebuild \
  -project QuotaMew.xcodeproj \
  -scheme QuotaMew \
  -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/QuotaMewRuntime-Release \
  build

/usr/bin/open /tmp/QuotaMewRuntime-Release/Build/Products/Release/QuotaMew.app
```

## 3. DEBUG runtime snapshots

Debug build 的 Settings > Development 有 `Log runtime snapshot`。它只在按下時查詢 pending notifications 與目前 process footprint，然後把一行 privacy-safe snapshot 寫到 Unified Logging。正常 refresh 開始與結束也各寫一行；沒有 timer、background sampler 或 in-memory history。

在 Terminal 監看：

```sh
/usr/bin/log stream \
  --style compact \
  --predicate 'subsystem == "dev.quotapulse.development.app" AND category == "RuntimeDiagnostics"'
```

主要欄位：

| 欄位 | 意義 | 健康值 |
| --- | --- | --- |
| `memory_bytes` | QuotaMew process 的 `phys_footprint` | 看趨勢，不以單點判定；Release 預算仍以外部量測為準 |
| `app_refresh_active` / `app_refresh_max` | App-level refresh 數與本次 process 觀察到的最大值 | current 0 或 1；max 1 |
| `provider_refresh_active` / `provider_refresh_max` | 正在執行的 provider fetch 總數與最大值 | current 0 或 1；max 1 |
| `refresh_in_flight` | 是否有 App-level refresh | 閒置時 `false` |
| `last_attempt_epoch` | 最近一次 refresh attempt | 每次實際開始刷新才改變 |
| `last_success_epoch` | 最近一次至少一個 provider 成功的 refresh | 成功後更新；全失敗時不虛構成功 |
| `scheduler` / `refresh_scheduler_count` | 排程狀態與 sleeping scheduler 數 | 閒置通常 `scheduled` / 1；刷新中 0；sleep 時 `suspended_for_sleep` / 0 |
| `next_refresh_epoch` / `backoff_failures` | 下次 deadline 與目前 failure backoff 階段 | 正常約 15 分鐘；失敗依 1／2／5／15／30 分鐘 |
| `codex_state` / `codex_pids` / `codex_process_count` | QuotaMew 擁有的 Codex connection 狀態與 child PID | 健康後 `healthy`、1 個 PID、count 1 |
| `codex_stdout_readers` / `codex_reconnects` | 目前 reader 數與 process 內累計 replacement 次數 | 健康時 reader 1；每次有效重連 reconnect 加 1 |
| `pending_notifications` | identifier 以 `quotapulse.` 開頭的 pending request 數 | 有界；測試通知重複排程仍最多一個相同 identifier |
| `notification_dedup_entries` | bounded reset-notification dedup entries | 0...32 |
| `providers` | 正規化 provider availability | 只有安全狀態，不含 raw error 或 payload |

`codex_pids` 是 QuotaMew 自身啟動並觀察到的 child。若 child 被外部終止，snapshot 會在下一次 connection health check／refresh 後反映；外部 process table 仍是即時來源。

### 選擇性 SwiftUI invalidation tracing

只有在追查 Test E 時才啟用 Xcode scheme environment variable：

```text
QUOTAPULSE_DEBUG_LOG_SWIFTUI_CHANGES=1
```

它會對 `DashboardView` 與 `SettingsView` 使用 SwiftUI `_logChanges()`；macOS 14.0 會安全略過，14.1 以上才啟用。完成觀察後移除環境變數，避免大量 console noise。可在 Console.app 以 subsystem `com.apple.SwiftUI`、category `Changed Body Properties` 篩選。

## 4. 外部量測

取得目前 QuotaMew PID：

```sh
QUOTAMEW_PID=$(/usr/bin/pgrep -x QuotaMew | /usr/bin/tail -n 1)
/bin/ps -p "$QUOTAMEW_PID" -o pid=,%cpu=,rss=,etime=,state=,command=
```

`ps` 的 RSS 單位是 KiB。Activity Monitor 的 Memory／Real Memory 與 Debug snapshot 的 `phys_footprint` 定義不同；同一張結果表必須固定使用同一來源，不能混在同一欄比較。

短時間觀察 CPU、memory 與 thread count：

```sh
/usr/bin/top -l 5 -s 2 -pid "$QUOTAMEW_PID" -stats pid,cpu,mem,threads
```

記錄 open-file 列數供趨勢比較：

```sh
/usr/sbin/lsof -n -P -p "$QUOTAMEW_PID" | /usr/bin/wc -l
```

此數字包含不只 pipe 的 open-file records，因此只能在相同命令與相同測試條件下比較趨勢。若持續增加，再用完整 `lsof` output 與 Instruments 定位；回報時先移除私密路徑。

列出 QuotaMew 的直接 Codex app-server child：

```sh
/bin/ps -axo pid=,ppid=,%cpu=,rss=,etime=,command= | \
  /usr/bin/awk -v parent="$QUOTAMEW_PID" \
  '$2 == parent && $0 ~ /codex[[:space:]]+app-server/'
```

計數：

```sh
/bin/ps -axo ppid=,command= | \
  /usr/bin/awk -v parent="$QUOTAMEW_PID" \
  '$1 == parent && $0 ~ /codex[[:space:]]+app-server/ { count += 1 } END { print count + 0 }'
```

不要用全系統的 `pgrep -f 'codex app-server'` 直接當 QuotaMew child 數；ChatGPT、Codex 或其他開發工具也可能有自己的 app-server。

需要定位 retained allocations、Swift tasks、wakeups 或 view updates 時，依序使用 Instruments：

- Allocations 與 Leaks：找 refresh／reconnect／Settings cycle 後沒有回落的 retained objects。
- VM Tracker：區分 allocator／VM 波動與持續 footprint growth。
- Time Profiler：確認閒置時沒有持續工作。
- System Trace／Energy Log：確認 timer、wakeups、threads 與 process lifecycle。
- SwiftUI instrument：只在 UI lifecycle 測試中找 invalidation source；不要把 view body 次數單獨當 leak 證據。

## 5. Test A — Idle stability

1. 先做 Release run。冷啟動 QuotaMew，打開 menu 一次，確認 Codex 顯示正常後關閉 menu。
2. 在 launch、10、30、60 分鐘記錄 Activity Monitor／`ps`／`top`、direct child count、child PID、thread 與 `lsof` 列數。
3. 發行前另做 8 小時 soak，至少一次 24 小時 soak。
4. 再做 Debug diagnostics run；在相同 checkpoint 打開 Settings，按 `Log runtime snapshot`，保存 snapshot line 後關閉 Settings。
5. checkpoint 之間不要持續打開 menu，也不要開啟 SwiftUI change logging。

預期：

- warm-up 可有波動，之後應接近 plateau；不能持續單調成長。
- Release idle CPU 接近 0%，正常穩態一般低於 1%。
- Codex 初始化前 child 可為 0；健康 connection 建立後恰好 1，PID 在正常刷新間保持不變。
- 閒置 snapshot 為 app/provider refresh 0、`refresh_in_flight=false`、scheduler `scheduled`、scheduler count 1、stdout reader 1。
- 不應有固定高頻 wakeup。

## 6. Test B — Repeated manual refresh

1. 記錄開始前的 QuotaMew RAM、child PID/count、thread、`lsof` 與 Debug snapshot。
2. 約 20 次按下 menu 的 Refresh／Command-R。可在一輪仍進行時連續要求數次，再等按鈕恢復。
3. 每 5 次記錄一次 snapshot；第 20 次後等待 1 至 2 分鐘再量測 RAM、CPU、child、thread 與 open files。
4. 若用 Instruments，同時觀察 Swift tasks 與 allocations 是否在工作結束後回落。

預期：

- `app_refresh_max=1`、`provider_refresh_max=1`。
- healthy child PID 不變、process count 1、stdout reader 1。
- refresh 結束後 scheduler 回到 `scheduled` / 1；沒有第二個 loop。
- memory 可因 cache／allocator 上升，但應回到接近原 plateau，而不是每次刷新固定增加。

## 7. Test C — Provider failure and recovery

這個測試只暫停 QuotaMew 自己的 child，不修改、搬動、覆寫或重新簽署 ChatGPT.app。

1. 用 direct-child 命令取得並再次確認 child 的 PPID 等於 `QUOTAMEW_PID`，保存為 `QUOTAMEW_CODEX_PID`。
2. 執行：

   ```sh
   /bin/kill -STOP "$QUOTAMEW_CODEX_PID"
   ```

3. 立刻在 QuotaMew 手動刷新。停止中的 app-server 應在約 5 秒 request timeout 後被 QuotaMew 關閉；cleanup 必要時會使用 SIGKILL。
4. 記錄失敗 snapshot。預期 `backoff_failures=1`，scheduler deadline 約 1 分鐘後，舊 PID 不再存在：

   ```sh
   /bin/kill -0 "$QUOTAMEW_CODEX_PID"
   ```

   預期回傳 `No such process`。若 PID 已被系統重用，必須重新核對 PPID 與 command，不可只相信 PID 數字。
5. 明確手動刷新以繞過等待中的 backoff，讓 QuotaMew 建立 replacement。
6. 記錄新 snapshot 與 direct-child process table。

預期：

- 舊 child、pipes 與 reader 先停止，才出現 replacement。
- recovery 後恰好 1 個新 PID、stdout reader 1、`codex_state=healthy`、`codex_reconnects` 增加。
- 正常刷新恢復，failure count 回到 0，下一輪約 15 分鐘。
- error 與 log 不包含 provider raw output，也沒有隨重連累積的錯誤 history。

若測試步驟中途停止，對舊 PID 執行 `/bin/kill -CONT "$QUOTAMEW_CODEX_PID"`；若 QuotaMew 已完成 timeout cleanup，該 PID 應已不存在。

## 8. Test D — Active Codex usage

1. 保持 QuotaMew 執行，同時正常使用 Codex 開發至少一個自動刷新週期。
2. 在 Codex 活動前、活動中、約 15 分鐘自動刷新後與 menu interaction refresh 後記錄 usage 顯示、timestamp、CPU、RAM、child PID/count 與 snapshot。
3. 關閉 menu 後再觀察 2 至 5 分鐘 idle CPU。

預期：

- usage 只在既有 refresh cadence／menu stale／manual refresh 更新。
- 倒數的 minute tick 不觸發 provider refresh。
- QuotaMew child count 維持 1；其他工具自己的 app-server 不算入。
- menu 關閉後 CPU 回到接近 0%，memory 不持續成長。

## 9. Test E — Settings / UI lifecycle

1. 記錄 baseline snapshot、RAM、thread 與 open files。
2. 重複開關 Settings 50 次，重複開關 menu 200 次。
3. 在合理範圍切換 Codex／Claude enablement、notifications 與 reminder thresholds；每次等待 UI 完成，再觸發 refresh。
4. 測試 system sleep/wake 與 App activation 各數次。
5. 有 invalidation 疑慮時另開一次 Debug run，設定 `QUOTAPULSE_DEBUG_LOG_SWIFTUI_CHANGES=1`，只重現最小步驟並觀察 `DashboardView`／`SettingsView` change cause。
6. 結束後關閉 menu／Settings，等待 1 至 2 分鐘，再記錄 snapshot、RAM、thread、open files 與 Instruments object graph。

預期：

- App-lifetime `Runtime`、`AppModel`、`SettingsModel` 不因 scene 重開而重建。
- scheduler count 保持 1 或在 refresh／sleep 時暫為 0；不出現第二個 background loop。
- Codex enable/disable 不銷毀健康 connection；重新啟用只要求共用 refresh。
- observer、task、TimelineView、thread 與 open-file 趨勢回到固定範圍。
- minute countdown 只使含倒數的窄 view subtree 更新，不應改寫 `AppModel` 或要求 provider。

## 10. Test F — Notification lifecycle

1. 使用 Debug build；先記錄 snapshot 的 `pending_notifications` 與 `notification_dedup_entries`。
2. 在 Settings > Development 連續按 `Send test notification` 多次，再立刻按 `Log runtime snapshot`。
3. 測試通知使用固定 identifier，重複測試應替換同一 request，不應線性增加 pending count。
4. 反覆刷新與切換 notification／threshold settings，確認停用時只移除 QuotaMew 自己的相符 pending requests。
5. Quit 並重新啟動 QuotaMew，再次記錄 snapshot；若真實 usage 剛好符合 reset threshold，確認相同 logical reset generation 不重送。
6. XCTest 仍須覆蓋並行 evaluation、restart dedup、新 reset generation 與 32-entry 上限；人工測試不應製造或竄改真實 provider snapshot。

預期：

- `pending_notifications` 有界；重複 development notification 最多保留相同 identifier 的一筆 pending request。
- `notification_dedup_entries` 永遠不超過 32。
- notification policy 只隨既有 refresh／明確測試 action 執行，沒有自己的 timer 或 polling loop。
- 拒絕通知權限不影響 provider refresh、menu UI 或 scheduler。

## 11. 結果紀錄

每張表必須註明 build configuration 與數值來源。

| Time | Build | QuotaMew RAM | CPU | app-server PID | app-server count | Active app refreshes | Active provider refreshes | Scheduler | Threads | Open-file rows | Notes |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | --- | ---: | ---: | --- |
| launch | Release | | | | | n/a | n/a | n/a | | | |
| 10m | Release | | | | | n/a | n/a | n/a | | | |
| 30m | Release | | | | | n/a | n/a | n/a | | | |
| 60m | Release | | | | | n/a | n/a | n/a | | | |

Debug diagnostics 另存 `runtime_snapshot` lines；不要把 Debug `memory_bytes` 與 Release RAM 放在同一趨勢線。

## 12. 健康行為與警訊

健康：

- warm-up 後 RAM、threads、open files、reader 與 retained allocations 接近 plateau。
- 每次 refresh／reconnect 的暫時尖峰會回落。
- healthy Codex connection 恰好 1 個 child、1 個 stdout reader。
- App/provider concurrent refresh 最大值都是 1。
- 一個 background scheduler；沒有 Foundation `Timer`，reset countdown 為 view-owned minute `TimelineView`。
- notification dedup state 最多 32 entries，沒有 notification history。

警訊：

- 每次 refresh、menu open、Settings open 或 reconnect 都固定增加 retained bytes、thread、FD、reader 或 task。
- warm-up 後 RAM 在數小時內維持正斜率，沒有 plateau；不要只因 allocator 單次擴張就宣告 leak。
- 同一 QuotaMew PPID 下同時存在兩個 app-server，或 replacement 出現時舊 PID 尚未被清理。
- `app_refresh_max` 或 `provider_refresh_max` 大於 1。
- 閒置時 scheduler count 不是 1、CPU 長時間高於 1%，或有固定高頻 wakeup。
- pending notification／dedup entries 隨相同步驟無界增加。
- 關閉 menu／Settings 後 SwiftUI invalidation 仍持續，且可追到重複 model、observer 或 timer。

## 13. 回報疑似 memory／lifecycle regression

Issue 至少包含：

- 測試 A–F 的哪一個 scenario、完整重現步驟與迴圈次數。
- commit／工作樹識別、Debug 或 Release、macOS／Xcode／ChatGPT／Codex runtime 版本。
- measurement source 與 checkpoint table；RAM 必須註明 RSS、Activity Monitor Memory 或 `phys_footprint`。
- sanitized `runtime_snapshot` lines、QuotaMew direct-child process table、thread 與 open-file trend。
- 最小化 Instruments trace 或 allocation／retain evidence；指出成長斜率與第一次偏離 plateau 的操作。
- expected 與 actual process/task/timer/notification count。
- Quit 後 child 是否仍存在。

不得附上 provider raw stdout/stderr、prompt、conversation、session、source code、credential、token、完整私密路徑或未清理的 `lsof` output。若證據只有單點 RAM 上升，先補做相同條件的時間序列與 refresh/reconnect 後回落觀察，再分類為 regression。
