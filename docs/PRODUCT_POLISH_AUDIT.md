# Product Polish 稽核（2026-09-07）

## 結論與起始狀態

本次 A–F **source implementation COMPLETE**，可開始 Product Polish 人工驗收。Repository **尚未達 Beta 3 整版 acceptance**：Milestone C Onboarding UI 與本次人工檢查仍未完成。未提交、push、tag、發布或製作 DMG。

起始工作樹乾淨，HEAD 為 ed96cb3；origin 已是 YinCheng0106/QuotaMew。[公開版本](https://github.com/YinCheng0106/QuotaMew/releases/tag/v0.2.0-beta.2)為 v0.2.0-beta.2，A/B COMPLETE，Hybrid migration 已完成。Milestone C 只有 OnboardingState、versioned persistence 與測試，沒有 UI。這次修正的是公開文件殘留，沒有再次進行產品更名。

## 實作決策

- 命名唯一來源 UsageWindowPresentation；精確 duration 18,000 秒 → 5-hour／5 小時，604,800 秒 → Weekly／每週。不依位置／role／倒數；其他使用安全通用名稱，不顯示 raw label。
- Dashboard row、VoiceOver header、approaching title、completed body 使用相同名稱；Remaining／Used 和倒數保持獨立。Domain ID、label、percentage、duration、cycle 資料不改寫。
- 只讀 Codex app quota tool 觀察到 base_model_inference bucket、gpt-reserve 名稱、10,080 分鐘 primary，以及一般 codex 的 300／10,080 分鐘 windows。這是 metadata observation，**不是本次 QuotaMew live provider XCTest**；未保存原始 payload／真實使用量。測試採 synthetic 數字。
- Reserve 精確比對既有 normalized codex.base_model_inference.primary/secondary 與 codex.gpt-reserve.primary/secondary；兩種語言都顯示 Luna Reserve。未知 ID 不做 substring 或 billing 推論。
- Reserve 平常為次要精簡列。available、capture age 0..<15 分鐘、一般 codex bucket 的已知 5 小時或每週 window 原始 usedPercentage == 100 且 reset 在未來，才展開完整列。這是展開資訊的規則，不宣稱 Reserve active 或保證可用。Reserve 不取代一般 window identity 或 status-item percentage。
- v0.2 排除 Reserve approaching/completed 通知，包含授權前過濾；一般 threshold、dedup identity、eligibility、lifecycle generation 不變。LocalResetDetector 檔案與演算法完全未修改，原有 bounded current-cycle state 繼續更新，沒有新的 Reserve history。
- 同一 StatusItemController 持有同一 NSMenu；標準 NSStatusBarButton 以公開 sendAction(on:) 接收左右 mouse-up。左鍵維持 Dashboard；右鍵只顯示原生選單。Refresh → AppModel.refreshManually() → 既有合併流程；Settings → SwiftUI openSettings → 原 Settings scene；Quit → 正常 NSApplication.terminate。只有 Quit 使用 Command-Q。無新視窗實作、status view、global monitor 或 observer。
- README 改為 Beta 2 與目前 repository；修正 provider-strategy 中一般 Codex 記憶體 snapshot 的舊品牌描述。script/create-dmg.sh 僅修正錯誤的 usage 路徑，未執行。
- v0.2 保留 C + Product Polish + beta feedback + hardening；外部 Reset Intelligence D/E reader/network/matching 移至 v0.3，保留 A frozen contracts。

## 自動化驗證

環境：macOS 26.6.2 (25G83)、Xcode 26.6 (17F113)、arm64。

| Gate | 本次結果 |
| --- | --- |
| 完整 parallel XCTest | **294 passed / 2 skipped / 0 failures（296 total）** |
| 新增測試 | 16 個：命名／Reserve 8、controller/menu 3、Codex mapping 1、Reserve notifications 1、branding 3；並更新既有通知／本地化預期 |
| 初次完整執行 | 一個舊 Claude 通知 title 預期未更新；修正後完整 suite 重跑通過 |
| Zero XCTest status-item hosts | 7 個 parallel test processes（92491–92497）；既有 AppRuntimeEnvironment gate + delegate/fake controller tests 通過；涵蓋本輪時間的 Control Center read-only log 無 dev.quotapulse.development.app host 事件 |
| Debug build | **PASS**；QuotaMew Debug / dev.quotapulse.development.app / 0.2.0 (2) |
| Release build | **PASS**；QuotaMew / dev.quotapulse.app / 0.2.0 (2) |
| 平臺與產物 | LSUIElement=true，minimum macOS 14.0；bundle IDs、autosaveName 未變 |
| diff whitespace | git diff --check **PASS** |
| Structural review | production MenuBarExtra = 0；production controller construction site = 1；production statusItem(withLength:) site = 1；tests 全用 fake handle，system status items = 0 |
| 保護邊界 | 沒有新增 network、periodic timer/polling/scheduler、Reset Intelligence reader/service/cache、private API、dependency 或 bundle-ID migration |

XCTest 結果位於本機 /tmp/QuotaMewPolishTestsFinal.xcresult；Debug／Release build logs 分別為 /tmp/quotamew-polish-debug-final.log、/tmp/quotamew-polish-release.log。唯一 build warning 是未使用 AppIntents.framework 的 metadata extraction skipped，沒有 Swift compiler warning。

2 個 skipped tests 為原本需明確 opt-in 的 live Codex provider 與 system notification delivery。這輪沒有啟動新的互動式 App、操作現有 App、實測 VoiceOver／native menu tracking、installed Login Item 或量測效能。Zero-host 是 composition/fake tests 與 read-only host-log 證據，不是畫面像素證明。

## 人工驗收與下一項任務

[20 項人工清單](RUNTIME_TESTING.md#v02-product-polish-acceptance)涵蓋 Dashboard 名稱／Reserve／Remaining-Used／倒數、真實通知一致性、左右鍵／Refresh／Settings／Quit／寬度、全部公開品牌、light/dark、English／繁中與 VoiceOver。特別檢查「尚未開過 Dashboard 就直接右鍵 Settings」與原生鍵盤導航；這些仍待驗收。

**下一項任務：實作 Milestone C Onboarding，完成 C 與 Product Polish 人工 acceptance。** 完成後才另行進行 Beta 3 release preparation → hardening → rc.1 → v0.2.0。

版本由 app target 的 MARKETING_VERSION/CURRENT_PROJECT_VERSION 驅動；Git fbbc449、a077596 顯示它們於 release preparation 調整，本次維持 0.2.0 (2)。後續 Beta 3 任務應將兩個 app configuration build number 改為 3，保留 0.2.0，驗證並準備 release/v0.2.0-beta.3/QuotaMew.app，之後才在授權下執行 `./script/create-dmg.sh 0.2.0-beta.3`。Test target 自有版本不作 App 版本來源。未改寫任何歷史 release entry。

## 變更檔案

- [ARCHITECTURE.md](../ARCHITECTURE.md)
- [CHANGELOG.md](../CHANGELOG.md)
- [QuotaMew/App/QuotaMewApp.swift](../QuotaMew/App/QuotaMewApp.swift)
- [QuotaMew/Domain/AppLocalization.swift](../QuotaMew/Domain/AppLocalization.swift)
- [QuotaMew/Domain/UsageWindowPresentation.swift](../QuotaMew/Domain/UsageWindowPresentation.swift)
- [QuotaMew/Features/MenuBar/MenuBarPresentation.swift](../QuotaMew/Features/MenuBar/MenuBarPresentation.swift)
- [QuotaMew/Features/MenuBar/MenuBarRecoveryView.swift](../QuotaMew/Features/MenuBar/MenuBarRecoveryView.swift)
- [QuotaMew/Features/MenuBar/ProviderCardView.swift](../QuotaMew/Features/MenuBar/ProviderCardView.swift)
- [QuotaMew/Features/MenuBar/StatusItemContextMenu.swift](../QuotaMew/Features/MenuBar/StatusItemContextMenu.swift)
- [QuotaMew/Features/MenuBar/StatusItemController.swift](../QuotaMew/Features/MenuBar/StatusItemController.swift)
- [QuotaMew/Features/MenuBar/UsageWindowRow.swift](../QuotaMew/Features/MenuBar/UsageWindowRow.swift)
- [QuotaMew/Localizable.xcstrings](../QuotaMew/Localizable.xcstrings)
- [QuotaMew/Services/NotificationService.swift](../QuotaMew/Services/NotificationService.swift)
- [QuotaMew/Services/ResetNotificationPolicy.swift](../QuotaMew/Services/ResetNotificationPolicy.swift)
- [QuotaMewTests/App/StatusItemControllerTests.swift](../QuotaMewTests/App/StatusItemControllerTests.swift)
- [QuotaMewTests/Domain/AppLocalizationTests.swift](../QuotaMewTests/Domain/AppLocalizationTests.swift)
- [QuotaMewTests/Domain/BrandingRegressionTests.swift](../QuotaMewTests/Domain/BrandingRegressionTests.swift)
- [QuotaMewTests/Features/UsageWindowPresentationTests.swift](../QuotaMewTests/Features/UsageWindowPresentationTests.swift)
- [QuotaMewTests/Providers/CodexProviderTests.swift](../QuotaMewTests/Providers/CodexProviderTests.swift)
- [QuotaMewTests/Services/NotificationServiceTests.swift](../QuotaMewTests/Services/NotificationServiceTests.swift)
- [README.md](../README.md)
- [README.zh-TW.md](../README.zh-TW.md)
- [ROADMAP.md](../ROADMAP.md)
- [docs/MENU_BAR_ARCHITECTURE_INVESTIGATION.md](../docs/MENU_BAR_ARCHITECTURE_INVESTIGATION.md)
- [docs/PRODUCT_POLISH_AUDIT.md](../docs/PRODUCT_POLISH_AUDIT.md)
- [docs/RUNTIME_TESTING.md](../docs/RUNTIME_TESTING.md)
- [docs/V0_2_PLAN.md](../docs/V0_2_PLAN.md)
- [docs/providers/provider-strategy.md](../docs/providers/provider-strategy.md)
- [script/create-dmg.sh](../script/create-dmg.sh)

## 舊名稱分類清冊

以 case-insensitive QuotaPulse／quotaPulse／quotapulse／Quota Pulse 搜尋所有 tracked 與新增文字檔；下表列出本次完成時 undefined 個命中行，逐檔依分類分組。同一行可含多次識別碼。行號為本次工作樹；本報告自身的搜尋字詞／歷史說明不重複列入。

A = 歷史發行／更名前驗證與回歸說明；B = compatibility-sensitive identity；C = defaults/migration/test suite namespace；D = path/schema/environment API boundary；E = 過期公開品牌；F = accidental implementation residue。

E 已修正：兩份 README 的 Beta 1-current 描述、舊 Releases URL、舊 App 安裝步驟與 pending rename 說明，以及 provider-strategy 的 Codex snapshot 描述。F 額外修正 packaging usage 的 scripts/ → script/ 路徑。未發現需要更動 production identity 的缺陷。

刻意保留 B/C/D：production/development/test bundle IDs、primary-status-item autosave suffix、notification prefixes、provider lifecycle/dedup keys、presentation.menu-bar-extra.requested、Claude legacy path/schema、diagnostics/live-test environment variables、隔離的 UUID test defaults。舊品牌的負向測試字串屬 A 回歸說明，不是過期 UI。

檔名另檢查：dist/QuotaPulse-v0.2.0-beta.1.dmg、其 sha256，以及 release/v0.2.0-beta.1/QuotaPulse.app 與 executable 都是 **A 歷史產物**，保留不變；未掛載／改寫二進位內容。Git history/object database 不做替換，workspace 舊目錄名是 **D 本機路徑相容性**，未更名。現在 origin 已指向新 repository。

| 檔案 | 命中行 | 分類 | 保留原因 |
| --- | --- | --- | --- |
undefined
