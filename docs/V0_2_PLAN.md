# QuotaMew v0.2 產品範圍

> 更新：2026-09-07。本決策取代 2026-08-31 將外部 feed reader/matching 納入 v0.2 的規劃。
> 公開版本：**v0.2.0-beta.2 — QuotaMew v0.2.0 Beta 2**。Beta 3 尚未發行。

## 產品目標與里程碑

v0.2 聚焦隱私優先的本機額度呈現、可靠的原生選單列操作與容易理解的首次啟動體驗。產品與 repository 更名已完成；相容性敏感的 bundle、偏好設定、通知與 autosave identity 不再搬遷。

| Milestone | 目前狀態 |
| --- | --- |
| A — contract freeze | **COMPLETE / frozen**。既有 feed schema、presentation、pin 與 onboarding persistence contracts 保留。 |
| B — Display + Settings | **COMPLETE**。Hybrid NSStatusItem、Remaining／Used、pin、Settings、recovery 與 zero-XCTest-host gates 已完成。 |
| C — Onboarding | **COMPLETE**。Source implementation 與 2026-09-07 user-observed manual runtime/UI acceptance 均完成；單頁原生 UI、啟動優先序、首次／重看語意、明確通知授權與 migration boundaries 已驗收。 |
| Product Polish | **COMPLETE**。額度命名、Luna Reserve 呈現、右鍵選單與公開文件修正已完成；驗證見 [Product Polish 稽核](PRODUCT_POLISH_AUDIT.md)，planned manual acceptance 已由使用者回報全數通過。 |
| Release acceptance | C 與 Product Polish 驗收 → **beta.3** → release hardening → **rc.1** → **v0.2.0**。 |

Milestone C source implementation 與 manual acceptance 均完成；這不代表 Beta 3 已發行或 v0.2.0 final 已完成。Public release 仍是 **v0.2.0-beta.2**；Reset Intelligence 仍屬 v0.3。

## v0.2 交付範圍

- 一個 production NSStatusItem／StatusItemController，原生 popover 承載既有 SwiftUI Dashboard。
- Remaining／Used、固定 provider、General／Providers／Notifications Settings。
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

這只讓 fallback 資訊更容易找到，不聲稱 Reserve active、計費語意、資格或一定能繼續使用。Reserve-only snapshot 保留次要列，選單列顯示 unavailable，不用 Reserve 偷換一般額度。純 projection 不刷新、不持久化、不建立 history。

v0.2 **不送 Reserve approaching/completed reset notifications**：policy 排除提醒；service 在授權前排除 completed-reset delivery。一般 threshold、dedup identity、eligibility、provider generation 與 LocalResetDetector 演算法不變。Detector 原有 bounded current-cycle baseline 繼續更新，不增加 Reserve history store，也不清除既有使用者 state。

### 右鍵選單

既有標準 NSStatusBarButton 的公開 sendAction(on:) 接收左右 mouse-up；左鍵切換 Dashboard，右鍵由同一 controller 關閉 popover 並顯示同一份 NSMenu。不安裝 custom status view、global mouse monitor、timer 或第二個 item。

Refresh 使用 AppModel.refreshManually()，保留 RefreshCoordinator 合併。Settings 經 App 的公開 SwiftUI openSettings action 開啟原有 Settings scene；Quit 呼叫正常 NSApplication.terminate，沿用既有 refresh/process/observer/controller cleanup，不改任何 preference。只有 Quit 配置 Command-Q；其餘使用原生 menu keyboard navigation。

## v0.3 — Reset Intelligence

原 Milestone D/E 移至 **v0.3**：人工審核 static feed governance/reader、bounded cache、ETag/expiry、獨立 fetch owner，以及 verified-event + fresh-local-snapshot matching。Milestone A 的 frozen contracts 與 fixtures 保留，不因延後而刪除。

- 每筆事件保留原始 URL、publisher、publication/retrieval/effective time、verification、revision、correction/retraction。
- App 不爬來源頁面、不自動發布；AI 不能作 publisher 或權威來源。
- reader/service 不依賴 provider refresh，不上傳 usage、workspace、prompt、裝置或帳號資訊。
- future-schema、oversized、invalid/retracted/offline/stale 都要安全失敗，本機額度保持可用。

詳細既有合約見 [RESET_INTELLIGENCE_FEED.md](RESET_INTELLIGENCE_FEED.md)。本次不實作 network、reader、service、cache 或 matching。

## 版本與發行工作流程

目前 Xcode app target 的 Debug／Release 都由 MARKETING_VERSION = 0.2.0 與 CURRENT_PROJECT_VERSION = 2 產生 Info.plist；test target 自有版本不是 App 對外版本。Beta 字尾只存在 Git tag／發行產物命名，packaging script 不修改 Info.plist。

Git 歷史 fbbc449 與 a077596 顯示版本／build number 在 release preparation 更新。本次保留 App **0.2.0 (2)**，以 CHANGELOG Unreleased 記錄。

**下一項任務：v0.2 Menu Bar Display Polish／Beta 3 stabilization work。** Beta 3 release preparation 另行進行：把兩個 App configuration 的 build number 更新為 3，保留 marketing version 0.2.0，驗證 Release artifact，再依明確授權準備 `release/v0.2.0-beta.3/QuotaMew.app`。既有打包指令為 `./script/create-dmg.sh 0.2.0-beta.3`；它必須在後續發行任務才執行，不是本次命令。Do not mark v0.2.0-beta.3 released or final v0.2.0 complete here。

不得把編譯／XCTest 視為 VoiceOver、真實通知送達、Launch at Login、Developer ID signing、notarization 或 DMG 發行證據。
