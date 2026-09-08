# QuotaMew v0.2 產品範圍

> 更新：2026-09-08。本決策取代 2026-08-31 將外部 feed reader/matching 納入 v0.2 的規劃。
> 公開版本：**v0.2.0-beta.3 — QuotaMew v0.2.0 Beta 3**。v0.2.0 final 尚未發行。

## 產品目標與里程碑

v0.2 聚焦隱私優先的本機額度呈現、可靠的原生選單列操作與容易理解的首次啟動體驗。產品與 repository 更名已完成；相容性敏感的 bundle、偏好設定、通知與 autosave identity 不再搬遷。

| Milestone | 目前狀態 |
| --- | --- |
| A — contract freeze | **COMPLETE / frozen**。既有 feed schema、presentation、pin 與 onboarding persistence contracts 保留。 |
| B — Display + Settings | **COMPLETE**。Hybrid NSStatusItem、Remaining／Used、pin、Settings、recovery 與 zero-XCTest-host gates 已完成。 |
| C — Onboarding | **COMPLETE**。Source implementation 與 2026-09-07 user-observed manual runtime/UI acceptance 均完成；單頁原生 UI、啟動優先序、首次／重看語意、明確通知授權與 migration boundaries 已驗收。 |
| Product Polish | **COMPLETE**。額度命名、Luna Reserve 呈現、右鍵選單與公開文件修正已完成；驗證見 [Product Polish 稽核](PRODUCT_POLISH_AUDIT.md)，planned manual acceptance 已由使用者回報全數通過。 |
| Menu Bar Display Polish | **COMPLETE**。SOURCE COMPLETE、AUTOMATED VALIDATION COMPLETE、MANUAL ACCEPTANCE COMPLETE；Single／Overview、明確 quota selection、Beta 2 Weekly compatibility、conditional Reserve、完整 VoiceOver 語意與 bounded observation 均已完成。 |
| Release acceptance | C、Product Polish 與 Menu Bar Display Polish 驗收 → **beta.3** → release hardening → **rc.1** → **v0.2.0**。 |

Milestone C source implementation 與 manual acceptance 均完成；Beta 3 已發行，v0.2.0 final 尚未完成。Reset Intelligence 仍屬 v0.3。

## v0.2 交付範圍

- 一個 production NSStatusItem／StatusItemController，原生 popover 承載既有 SwiftUI Dashboard。
- Remaining／Used、固定 provider、General／Providers／Notifications Settings。
- Single／Overview 選單列顯示，以及獨立的 5-hour／Weekly／Luna Reserve quota selection。
- 既有 lifecycle、hide/show、reopen/recovery、Launch at Login 行為與穩定身分。
- 已完成的 QuotaMew 公開品牌更名，以及必要的相容性名稱保留。
- 可略過、可重看的 Milestone C Onboarding。
- 共用的 5 小時／每週額度命名與通知／VoiceOver 一致性。
- Luna Reserve 次要資訊與保守的展開規則。
- 原生右鍵選單：立即重新整理、設定…、退出 QuotaMew。
- Beta 回饋修正與 release hardening。

不納入：Reset Intelligence network/feed reader、cache/service、local matching、collector/backend、自動更新、歷史圖表、burn-rate、Gemini/OpenCode 或 Claude bridge 安裝器。Claude 保持 **Experimental / Unverified**。

## Milestone C — Onboarding

單頁原生首次啟動流程已重用既有 preferences 與 allowlisted diagnostics：

1. 歡迎與隱私摘要：讀取本機額度，不讀 prompt、transcript、credential 或 coding history。
2. Codex runtime detected/not detected 與 Claude snapshot configured/not configured 狀態；不新增 provider I/O、bridge installer 或私密路徑輸出。
3. 使用者可選 Launch at Login、Remaining／Used、pinned provider；初次呈現不覆寫既有選擇。
4. 通知權限只由「Enable Notifications」明確動作觸發；開啟／略過／完成／重看 Onboarding 與一般 refresh 都不要求權限。
5. Skip 保存 `skipped`；Get Started 保存 `completed`。首次視窗的標準關閉視同 Skip；Settings 重看關閉只關視窗，不改 onboarding state/version。
6. `OnboardingWindowController` 只擁有一個可重用視窗；product settings 仍由共用 `SettingsModel`／`SettingsStore` 擁有。顯示期間暫時把 accessory policy 切為 regular，最後一個 presentation 關閉後恢復原值。
7. 啟動順序固定為 hidden login-item quiet exit → hidden explicit recovery → normal explicit eligible onboarding。Recovery 存在時不另開 Onboarding，兩者不競爭焦點。

持久化沿用 `onboarding.state`（neverShown／completed／skipped）、`onboarding.last-completed-version` 與 current version 1，不新增平行 state owner。

Fresh installation 在初次建立 `SettingsStore` 前沒有 onboarding state 與任何既有安裝 evidence，會保存 `neverShown`／version 0。已啟動過 Beta 2 的 domain 會有短視窗 reminder migration key；較早版本或 developer domain 若有既有 menu-bar、provider、notification、presentation、Reset Intelligence 或 notification state key，也視為 established installation。這類 domain 缺少 onboarding state 時一次性保存 `skipped`／current version，升級不強制搶焦點。若 domain 已有 onboarding state/version，該明確狀態優先且不被 migration 覆寫；只有完全沒有 evidence 的 domain 才視為 fresh。安裝過但從未啟動、因而沒有任何 preference domain 的 app，無法與 fresh install 區分，會顯示首次使用說明。

驗收須涵蓋 fresh user、Codex absent、Claude unconfigured、all disabled、permission denied、完成／略過／重看、重啟保留，以及英／繁中、鍵盤、VoiceOver、light/dark。若說明需要 quota-window 名稱，使用 UsageWindowPresentation。

## Product Polish 決策

### 共用額度名稱

UsageWindowPresentation 是純呈現值，接受 normalized UsageWindow，或 completed-reset 現有的 provider/window ID/duration。

- duration **精確等於 18,000 秒** → **5-hour／5 小時**。
- duration **精確等於 604,800 秒** → **Weekly／每週**。
- 已知 Reserve ID 優先 → **Luna Reserve**，兩種語言不翻譯。
- 其他／缺少／無效 duration → 通用 quota window／配額週期；不顯示 provider raw label。

不以 array position、primary/secondary role 或距 reset 剩餘時間命名，不改 domain ID/label、百分比、reset/cycle metadata。Dashboard、VoiceOver 與 approaching/completed notifications 共用名稱；倒數獨立顯示。

### Luna Reserve

2026-09-07 只讀 runtime metadata 顯示 dictionary key/limitId 為 `base_model_inference`、limitName 為 `gpt-reserve`，有一個 10,080 分鐘 primary window；一般 codex bucket 為 300／10,080 分鐘。現有 mapper 依 dictionary key 產生 `codex.base_model_inference.primary`，排序會讓它在一般 windows 前面。沒有可靠的 Reserve-active 布林訊號可供目前 model 使用。

呈現層精確 allowlist：`codex.base_model_inference.primary/secondary` 與 `codex.gpt-reserve.primary/secondary`，且 provider 必須是 Codex。前者為觀察到的形式，後者僅為相容別名。未知類似名稱不作 substring 推論。此 metadata 關聯不是穩定的官方 billing contract，未來變更時安全退回通用名稱。

一般 windows 永遠先顯示。Reserve 平常是沒有 progress bar／倒數的精簡次要列，只顯示名稱與既有 Remaining／Used 百分比或 unavailable。

只有 available、capture age 在 **0..<15 分鐘**，且一般 `codex.codex.primary/secondary` 的 5 小時或每週 window 有 **原始 usedPercentage == 100**、reset 仍在未來時，Reserve 才展開成完整列。任一一般 window 都可符合，不只 weekly。缺少資料、stale/failure/loading、未知 bucket/duration、99.9 的四捨五入或超界百分比都不能觸發。

這只讓 fallback 資訊更容易找到，不聲稱 Reserve active、計費語意、資格或一定能繼續使用。Reserve-only snapshot 在 Dashboard 保留次要列；Automatic／Overview 不用 Reserve 偷換一般額度，只有 Single + Luna Reserve 的明確使用者選擇可直接顯示有效 Reserve metric。純 projection 不刷新、不持久化、不建立 history。

v0.2 **不送 Reserve approaching/completed reset notifications**：policy 排除提醒；service 在授權前排除 completed-reset delivery。一般 threshold、dedup identity、eligibility、provider generation 與 LocalResetDetector 演算法不變。Detector 原有 bounded current-cycle baseline 繼續更新，不增加 Reserve history store，也不清除既有使用者 state。

### 右鍵選單

既有標準 NSStatusBarButton 的公開 sendAction(on:) 接收左右 mouse-up；左鍵切換 Dashboard，右鍵由同一 controller 關閉 popover 並顯示同一份 NSMenu。不安裝 custom status view、global mouse monitor、timer 或第二個 item。

Refresh 使用 AppModel.refreshManually()，保留 RefreshCoordinator 合併。Settings 經 App 的公開 SwiftUI openSettings action 開啟原有 Settings scene；Quit 呼叫正常 NSApplication.terminate，沿用既有 refresh/process/observer/controller cleanup，不改任何 preference。只有 Quit 配置 Command-Q；其餘使用原生 menu keyboard navigation。

## Menu Bar Display Polish 決策

### 顯示合約與預設

選單列 provider pin、display style、quota selection 與 Remaining／Used 是四個分離的決策。`SettingsStore` 保存：

- `presentation.menu-bar.display-style`：`single`／`overview`。
- `presentation.menu-bar.quota-selection`：`fiveHour`／`weekly`／`lunaReserve`。

兩個新值的 deterministic default 是 **Single + Weekly**。Beta 2 tag 的 implementation 只取 `snapshot.windows.first`，沒有 semantic selection contract；歷史 release runtime 的產品行為是 Weekly，因此缺少新 keys 的既有 domain 以 `W n%` 明示並保留原意。Fresh installation 使用相同預設，不另建隱性分支。未知 future raw value 只在 runtime 安全 fallback，不覆寫 storage；其他 preferences 不遷移。

Single 顯示 `5H n%`、`W n%` 或 `R n%`，缺少所選 window 時顯示相同 identifier 加 `—`。Explicit provider pin 不 fallback 到別的 provider；explicit quota selection 也不 fallback 到別的 metric。Overview 固定為 5H、W，只有既有 `ProviderWindowsPresentation.showsReserveProminently` 為 true 且 Reserve usage 有效時才以第三項 R 加入；順序固定，不重複 metric，也不把 Reserve presence 描述為 active routing。

5H／W 只對 normalized duration 精確等於 18,000／604,800 秒的 window 成立；Reserve 只沿用既有 Codex exact-ID allowlist。Claude 的 documented status-line snapshot 若提供同樣兩個明確 durations，可共用 Single／Overview；未知 durations 顯示 unavailable，不以 provider order、primary/secondary 或 raw label 猜測。

### AppKit、寬度與無障礙

既有唯一 `StatusItemController`／`NSStatusItem`、standard `NSStatusBarButton`、stable `autosaveName`、template image、popover、左右鍵、recovery 與 Login Item 全部保留。Presentation preferences 依 `SettingsStore → SettingsModel → MenuBarPresentation → StatusItemController` 更新同一個 button，不觸發 provider fetch、Codex RPC、notification evaluation、reset detection 或 scheduler work。100 次 style、quota 與 Remaining／Used 切換的 controller test 驗證仍只建立一個 owner／fake item 與一條 visibility observation。

保留 icon，因為它維持識別、Single／Overview 一致性與可發現的 click target；移除只能固定節省 17.5 pt，卻不解決最寬 Overview 的 crowded-menu policy。受控 `NSStatusBarButton.intrinsicContentSize` 量測如下（pt）：

| 文字 | 有 icon | 無 icon |
| --- | ---: | ---: |
| `W 0%`／`W 71%`／`W 100%` | 63.5／70.5／77.5 | 46／53／60 |
| `5H 0%`／`5H 71%`／`5H 100%` | 67.5／74.5／81.5 | 50／57／64 |
| `R 0%`／`R 71%`／`R 100%` | 59.5／66.5／73.5 | 42／49／56 |
| `5H 0% · W 0%`／`5H 71% · W 71%`／`5H 100% · W 100%` | 110.5／124.5／138.5 | 93／107／121 |
| `5H 0% · W 0% · R 71%`／`5H 100% · W 100% · R 100%` | 156.5／191.5 | 139／174 |

Production 繼續以實際 button intrinsic width 設定 variable-length item，並以 status-bar thickness 作下限；沒有 hard-coded total width、NBSP、manual kerning、custom view 或 geometry polling。Overview 的較寬內容是使用者明確選擇；crowded／notch 狀態交給 macOS allowance 與既有 recovery，不自動切換模式。

Visible identifiers `5H`／`W`／`R` 保持語言中立；accessibility value 不解析 visible title，而以完整名稱與 percentage projection 組合。英文例如 `Codex, 5-hour quota, 86% remaining; Weekly quota, 71% remaining`；繁中例如 `Codex，5 小時配額，剩餘 86%；每週配額，剩餘 71%`。Onboarding 不增加進階顯示 controls，但其 completion／skip／replay 會保留這兩個 preferences。

## v0.3 — Reset Intelligence

原 Milestone D/E 移至 **v0.3**：人工審核 static feed governance/reader、bounded cache、ETag/expiry、獨立 fetch owner，以及 verified-event + fresh-local-snapshot matching。Milestone A 的 frozen contracts 與 fixtures 保留，不因延後而刪除。

- 每筆事件保留原始 URL、publisher、publication/retrieval/effective time、verification、revision、correction/retraction。
- App 不爬來源頁面、不自動發布；AI 不能作 publisher 或權威來源。
- reader/service 不依賴 provider refresh，不上傳 usage、workspace、prompt、裝置或帳號資訊。
- future-schema、oversized、invalid/retracted/offline/stale 都要安全失敗，本機額度保持可用。

詳細既有合約見 [RESET_INTELLIGENCE_FEED.md](RESET_INTELLIGENCE_FEED.md)。本次不實作 network、reader、service、cache 或 matching。

## 版本與發行工作流程

目前 Xcode app target 的 Debug／Release 都由 MARKETING_VERSION = 0.2.0 與 CURRENT_PROJECT_VERSION = 2 產生 Info.plist；test target 自有版本不是 App 對外版本。Beta 字尾只存在 Git tag／發行產物命名，packaging script 不修改 Info.plist。

Git 歷史 fbbc449 與 a077596 顯示版本／build number 在 release preparation 更新。本次 Beta 3 使用 App **0.2.0 (3)**，歷史 Beta 2 維持 **0.2.0 (2)**。

**下一項任務：release hardening / RC 1。** Beta 3 使用兩個 App configuration 的 marketing version `0.2.0` 與 build number `3`，並以 `./script/create-dmg.sh 0.2.0-beta.3` 產生發行產物。v0.2.0 final 尚未完成；Reset Intelligence 仍為 v0.3。

不得把編譯／XCTest 視為 VoiceOver、真實通知送達、Launch at Login、Developer ID signing、notarization 或 DMG 發行證據。
