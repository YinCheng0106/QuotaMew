# QuotaMew 路線圖

本路線圖以成果為導向。在平臺基準與即時 provider 整合驗證完成前，刻意不承諾日期。

目前公開版為 **QuotaMew v0.2.0-rc.1**。以下歷史 milestone／strategy records 保留原決策；目前 scope 以本文最後的 **2026-09-07 v0.2 規劃決策**及 [V0_2_PLAN.md](docs/V0_2_PLAN.md) 為準。

## Milestone 0 — 規劃基準

狀態：已完成

- 定義 v0.1 範圍與非目標
- 評估 Codex 與 Claude Code 資料來源
- 定義 provider、service、隱私與 Reset Intelligence 邊界
- 記錄檔案結構與未解決的散布、整合決策
- 建立英文國際版 README 與臺灣繁中維護文件

完成條件：

- `README.md`、`README.zh-TW.md`、`ARCHITECTURE.md`、`ROADMAP.md` 與 `AGENTS.md` 對範圍和資料來源策略一致
- 在架構與隱私邊界確認前，沒有提早實作即時 provider

## Milestone 1 — 基礎與 mock 垂直切片

狀態：已完成；後續發行稽核結果集中記錄於 `docs/RELEASE_CHECKLIST.md`

- 確認目前最低版本為 macOS 14，採直接散布作為待驗證假設
- 使用 XCTest 建立 macOS App 與單元測試 targets
- 建立純選單列 `MenuBarExtra(.window)` App 與 Settings scene
- 實作與 provider 無關的 domain models 與 `UsageProvider`
- 實作 `UsageService`、可合併重複工作的 `RefreshCoordinator` 與 `@MainActor AppModel`
- 以固定 mock adapters 顯示 Codex 與 Claude Code 卡片
- 顯示多個額度視窗、剩餘百分比、重設時間與分鐘級倒數
- 透過可注入 `NotificationService` 提供由使用者觸發的測試通知
- Milestone 1 原始切片沒有週期性輪詢；後續 refresh lifecycle 已加入單一保守排程，仍沒有 backend、persistence 或第三方相依套件

已驗證：

- Debug build 成功
- Release build 成功，且產物的 `LSUIElement` 為 `true`
- 6 項單元測試通過
- 重複 refresh request 只共用一個 in-flight refresh
- 倒數使用一分鐘粒度的 `TimelineView`，沒有全域一秒 timer
- 一次啟動約 11 秒後的 Release smoke snapshot 為 0.1% CPU、75,696 KB RSS；這不是穩定效能結論，且尚未達到理想的 50 MB 以下目標
- Milestone 2 的 UI 串接尚未實作；後續限定範圍的 Codex discovery 與 provider core 狀態見下節

仍需在 v0.1 發行前完成：

- 以 VoiceOver 與純鍵盤手動檢查完整選單流程
- 驗證亮色、暗色與窄版選單配置
- 用 Activity Monitor 或 Instruments 進行可重複的 Release build 長時間閒置量測
- 真實系統通知送達與散布驗證；Developer ID signing 與 notarization 後續依 Milestone 5 決策延後

## Milestone 2 — 即時 Codex adapter

狀態：v0.1 核心已完成；ChatGPT 整合 runtime 已完成本機 live validation，跨版本相容性仍是持續驗證項目

- 已依序從標準／`NSWorkspace` 發現的 ChatGPT.app 整合 runtime、舊 Codex.app、常見 CLI locations 與受限 `PATH` 尋找 Codex 執行檔，不啟動 login shell；使用者 override 尚未實作
- 已實作可取消、具 timeout、輸出上限與 cleanup 的 process boundary
- 已實作 app-server initialize handshake 與 `account/rateLimits/read`
- 已支援 single-bucket、multi-bucket、primary 與 secondary response mapping
- 已區分找不到執行檔、timeout、server 與 protocol errors；UI status mapping、未登入與不支援 authentication 的實際 error-shape 驗證仍待完成
- 已用 fake process 測試正常 response、健康 connection 重用、並行讀取合併、失敗重連、child reap、shutdown、oversized output 與 timeout；partial 與 out-of-order coverage 仍待補齊
- 已用 sanitized live probe 驗證 ChatGPT.app bundled `codex-cli 0.149.0-alpha.4.3`；仍須驗證數個正式支援版本
- 已在本機 production app assembly 驗證真實 Codex snapshot 可到達共用 UI，並以父程序取樣確認單次 refresh 最多只有一個 QuotaMew app-server child process
- 已透過 production `AppDependencies`、`UsageProvider` 與 `UsageService` 接入共用 UI state；SwiftUI 不含 Codex-specific rendering branch
- 量測啟動延遲、尖峰與閒置記憶體，以及 process cleanup

完成條件：

- 不讀取 Codex credential file 即可刷新真實用量
- 健康時恰有一個 app-server child 供刷新重用；失敗、取消與 App 結束後不殘留
- provider process 不會與另一個 refresh 重疊
- 不支援的設定會明確且安全地失敗

未文件化的 session JSONL 備援仍不在範圍內，除非有證據顯示官方 protocol 不足。

Production `AppDependencies` 現在建立 `CodexProvider`；SwiftUI previews 仍使用 mock provider。詳細本機來源評估與 fallback policy 見 `docs/providers/codex.md`。

## Milestone 3 — Claude opt-in bridge

狀態：進行中；usage discovery、版本化 snapshot reader、provider core 與共用應用程式串接已完成，但 bridge setup 與 live validation 尚未實作

- 已定義有版本的最小 Claude snapshot schema
- 已實作只讀 legacy QuotaPulse-owned snapshot 的 bounded reader；可執行 bridge writer 尚未實作
- 已偵測本機現有 Claude status-line 設定但未讀取 command value，也未修改設定
- 設計明確的設定預覽、備份與復原流程
- 決定 v0.1 是否修改 settings，或只產生人工整合說明
- 已處理 snapshot missing、partial、stale capture metadata、malformed、oversized 與 future-version data；atomic writer 仍待 bridge 實作
- 在 UI 清楚說明 Pro/Max 與 first-response availability 限制
- 已用 redacted fixtures 驗證 provider model 不保存 workspace、transcript、session、repository、cost、token 或 model 欄位
- 已透過 production `AppDependencies`、`UsageProvider` 與 `UsageService` 接入共用 UI state；snapshot 缺少時顯示 `notConfigured`

Production `AppDependencies` 現在建立 `ClaudeProvider`；在 bridge 尚未產生 snapshot 時，provider 安全回傳 `notConfigured`。SwiftUI previews 仍使用 mock provider。詳細本機來源、版本限制、已知缺欄位風險與 fallback policy 見 `docs/providers/claude-code.md`。

完成條件：

- Claude 額度卡片能由文件化 status-line 欄位更新
- 絕不靜默取代現有 status line
- 過期資料有清楚標示，經過 reset time 不會被視為已重設的證明
- 在全新 profile 與已有 status line 的 profile 測試安裝和復原

## Milestone 4 — 刷新、設定與實用本機提醒

狀態：已完成實作、自動化驗證與發行層級稽核；系統層級項目依 release checklist 人工驗證

- 已完成固定的 v0.1 freshness 與刷新政策；Settings 顯示固定 15 分鐘 cadence，不開放動態 interval
- 已在啟動時刷新；選單顯示且 snapshot 超過約 3 分鐘時非阻塞刷新；使用者手動要求時立即刷新
- 已由 `AppModel` 單一擁有約 15 分鐘背景 schedule，並以 1／2／5／15／30 分鐘處理暫時性失敗
- 已處理 sleep/wake、App activation 與反覆 menu open，不建立重複 refresh loops
- 已讓 disabled provider 從 Dashboard、啟動、手動與背景 refresh 排程中排除；重新啟用會安全地併入下一輪刷新
- 已加入選單列被隱藏時的明確復原入口；實際選單列可見性仍由 macOS 控制
- 已從本輪成功且新鮮的本機 snapshot 依 `UsageWindow.duration` 建立門檻通知：6 小時以下使用 1 小時／30 分鐘，長視窗使用不超過視窗長度的 24／6／1 小時門檻；不從 stale cached data 建立新通知
- 已以 provider／window／logical reset generation／threshold 去除重複通知，並以最多 32 筆 metadata 保持 persistence bounded
- 已加入原生 Settings：`SMAppService` Launch at Login、Codex／Claude enablement、通知總開關，以及分組的短視窗 1 小時／30 分鐘與長視窗 24／6／1 小時門檻
- 已在關閉通知或個別門檻時移除相符的 pending QuotaMew reset requests；拒絕 system permission 不影響刷新與 UI
- 已以 typed UserDefaults keys 保存 preferences，Claude 明確標為 Experimental／Unverified，沒有加入 bridge setup
- 使用 String Catalog 本地化使用者可見字串
- 完成 VoiceOver、鍵盤、對比與 reduced-motion 檢查

完成條件：

- 使用者拒絕通知時 App 仍然實用
- 相同 provider window 與 threshold 不會重複通知
- 單一 provider 錯誤不阻塞其他 providers
- settings migration 保留既有選擇

## Milestone 5 — v0.1 發行準備

狀態：release-readiness audit、MIT License、初始 Git baseline 與 Production App Icon 已完成；目前準備公開 source-only GitHub v0.1.1 patch release。Developer ID 與 notarization 依本次發行決策刻意延後，必須持續清楚標示為限制，不得宣稱已完成。

- 已選擇並加入 MIT License
- 已補齊貢獻、安全性、隱私、建置、發行與 draft release notes 文件
- 已完成自動化 release audit、runtime lifecycle 稽核與約一小時開發環境效能觀察
- 已確認公開文件把 Claude Code 維持為 Experimental／Unverified
- 已啟用 GitHub Private Vulnerability Reporting
- v0.1.1 採 source-only GitHub Release，不附可下載 App、DMG 或安裝套件
- README 的實際畫面截圖刻意延後，且目前不連結可能損壞的 placeholder 圖片
- Production App Icon 已完成資產整合、各尺寸檢查與乾淨 Debug／Release 建置驗證
- Developer ID signing、Hardened Runtime、notarization 與正式散布驗證延後處理

完成條件：

- 公開發行範圍內的自動與必要人工 checks 都有紀錄
- 沒有已知的 prompt、原始碼、transcript、repository 或 credential 蒐集
- 即時 provider 驗證與 fixture tests 清楚分開
- source-only 狀態在 README 與 release notes 中一致揭露；未來附加 binary 前再完成對應 artifact 驗證
- Developer ID 與 notarization 仍清楚列為 deferred，不被誤寫成完成

## v0.1 之後

### 其他本機 providers

- 研究 Gemini CLI 有文件的本機或程式化 usage surface
- 研究 OpenCode 有文件的本機或程式化 usage surface
- 每個 provider 都透過 `UsageProvider` 加入，不更動 UI-domain contract

不得由原始 token totals 推估方案額度。

### Reset Intelligence

- 已從 normalized provider snapshots 實作 provider-agnostic 本機 reset detection，並以 bounded persisted cycle state 避免 restart 重複通知
- 已定義 `ResetEvent` value model 與最小 `ResetEventSource.fetchEvents()` abstraction
- 定義可信來源與 publisher 標準
- 擷取官方或明確核准的公開公告
- 保留並顯示原始來源 URL、publisher、publication time 與 retrieval time
- 區分已確認公告、可信報導、更正與過期事件
- 在不上傳本機 usage snapshot 的前提下，提醒仍有大量未使用額度
- 設計來源更正與撤回處理
- 為所有網路服務進行獨立隱私審查

官方外部 Reset Intelligence ingestion 仍為 FUTURE。它必須與本機 provider adapters 分離，也不得以未經審查的 network call 偷渡進產品。

## Post-v0.1 product roadmap（2026-08-30 strategy audit）

本節保留上述 v0.1 歷史與已完成里程碑，並為後續工作重新排序。詳細問題、目標使用者、風險、依賴與 acceptance criteria 見 [`docs/PRODUCT_STRATEGY.md`](docs/PRODUCT_STRATEGY.md)；競品證據與刻意不採用的模式見 [`docs/COMPETITIVE_ANALYSIS.md`](docs/COMPETITIVE_ANALYSIS.md)。

QuotaMew 的主要定位是 **重視隱私的 AI coding 額度選單列工具**。近期不把它擴張為通用 AI dashboard，也不投入其他非必要的 branding migration；後者維持 deferred polish，除非實際阻擋散布。

### v0.1.x — Polish／Adoption／Compatibility

目標：讓既有產品更容易理解、回報問題與持續維護，不增加新的資料擷取面。

1. 已加入 production、privacy-safe Diagnostics 與 allowlisted Copy Diagnostics；使用 provider-independent current-state model、英文固定格式與明確 privacy regression tests。
2. disabled provider 不再出現在 Dashboard；Settings 保持唯一的重新啟用入口，refresh／notification 繼續跳過它。
3. 建立公開 CI、unsigned Release build、compatibility matrix 與 privacy-safe issue template。
4. 加入可略過的最小 first-launch onboarding：provider detection、資料邊界、refresh cadence、Launch at Login、通知說明，以及純 presentation 的 Remaining／Used 選擇。
5. 對目前已實作的 local completed-reset notification 完成 release-level regression 與 opt-in 系統通知驗證，不重做 detector。

完成條件：使用者可在不提供路徑、credential、prompt、transcript、session、token 或 raw payload 的情況下回報相容性；所有 provider disabled 時有單一 empty state；onboarding 失敗或略過不阻擋 dashboard；CI 與 live／system 驗證仍明確分列。

### v0.2 — Product Experience／Trusted Distribution

目標：移除 source-only 安裝摩擦，改善每天都會看到的呈現與第二個 provider 的可信度。

1. 在維護者決定承諾 binary release 後，完成 Developer ID、Hardened Runtime、notarization、stapling、installed App、Gatekeeper 與 Launch at Login 驗證，提供 signed／notarized ZIP 或 DMG。
2. binary 存在後加入 GitHub latest-release checker：手動與低頻背景檢查，只提示並開啟 release page，不自動下載或安裝。
3. Settings 最多拆成 General／Providers／Notifications；Display 保留在 General，Diagnostics 先使用 sheet／入口，不建立空泛 Advanced tab。
4. 將既有 Remaining／Used preference 納入 scalable Settings，並加入 Icon only／單一 pinned provider；不支援 rotation、multiple compact providers 或 automatic priority。
5. 完成 Claude opt-in bridge 的 contract research、setup preview、backup／restore 與 live subscribed-account validation；未達成前持續 Experimental／Unverified。

完成條件：fresh Mac 不需要 Xcode 即可驗證並啟動 App；更新提示不誤導 Homebrew／source 使用者；presentation 不複製 quota calculation；Claude setup 不靜默覆寫既有 `statusLine.command` 且可完整復原。

### v0.3 — Reset Intelligence research

目標：只在來源治理與維護責任成立時，研究 QuotaMew 的長期差異化。

1. 先以 maintainer-curated、GitHub-hosted static `ResetEvent` feed 做 MVP；每筆事件保留 publisher、source URL、publication／effective time、verification、correction／retraction 與 schema version。
2. GitHub Actions 只負責 schema／URL／time validation 與 artifact 產生；規則優先，AI 只協助人工處理模糊候選，不能直接發布。
3. App 端 local matching 不上傳 usage snapshot；feed 離線、過期或失敗不得影響本機 provider。
4. 可平行做 coarse pacing 離線研究；若不能在 sleep gap、reset、跨裝置與不足 samples 時可靠輸出 `Insufficient data`，即停止交付。

完成條件：Reset Intelligence 可更正、撤回、離線失敗且每筆可追溯到原始來源；任何 AI 摘要都不是 authoritative source；沒有本機 usage、workspace 或裝置識別送出。

### Long-term／not committed

- Sparkle 2：至少完成 2–3 個穩定 signed／notarized binary releases 後再導入 appcast、EdDSA、下載與安裝。
- custom Homebrew tap：可信 artifact 穩定後；official Cask 再依 adoption 與 release cadence 評估。
- remote compatibility manifest：只有文件 matrix 無法處理重複 packaging breakage 時。
- Gemini／OpenCode：只有文件化、安全且 bounded 的 quota contract 存在時。
- user-visible history／charts：只有 pacing research 證明能改變使用者行為時。
- monetization：目前 deferred；核心 quota visibility、privacy 與基本 reset notifications 保持免費，先考慮 Sponsors／support，不做 client-side premium locks。

### Explicitly deferred

1. automated external Reset Intelligence backend／collector。
2. burn-rate ETA、長期 history 與 charts。
3. Gemini、OpenCode 或大規模 provider expansion。

不採用 custom updater、credential／cookie access、transcript scanning、automatic provider rotation 或以 `xattr` 移除 quarantine 作為正式散布方案。

## v0.2 規劃決策（2026-09-07）

> 本節取代 2026-08-31 的 feed-inclusive v0.2 scope，優先於上方較早的 post-v0.1 建議；歷史 v0.1 milestone 保留不改寫。

v0.2 聚焦 **隱私優先的本機額度工具與原生使用體驗**：

1. **A／B COMPLETE**：保留 frozen contracts、Hybrid NSStatusItem、Remaining／Used、pin、Settings、lifecycle/recovery 與已完成的 QuotaMew 更名。
2. **C REQUIRED／UI NOT STARTED**：可略過、可重看的單頁 Onboarding，重用既有 detection/diagnostics/persistence，不做 provider setup installer。
3. **Product Polish source implemented／manual acceptance pending**：共用 5 小時／每週名稱、Luna Reserve 次要呈現、原生右鍵選單、公開文件修正與 beta feedback。

Local completed-reset notification、Diagnostics、disabled-provider lifecycle 與 MenuBar recovery 保持既有行為。Claude 維持 Experimental / Unverified；更新檢查、Sparkle、自動更新、Gemini/OpenCode、burn-rate/history/charts 不納入本次工作。

**原 D/E 的外部 feed reader/network/cache/service 與 event/local matching 移至 v0.3**；保留 Milestone A 合約與 fixtures，不實作外部來源功能。

版本順序：**C + Product Polish acceptance → v0.2.0-beta.3 → release hardening → v0.2.0-rc.1 → v0.2.0**。Beta 3 已公開提供 DMG；Developer ID signing 與 notarization 仍未完成。Reset Intelligence 維持 v0.3 scope。

完整候選評估、架構、驗收條件與實作順序見 [`docs/V0_2_PLAN.md`](docs/V0_2_PLAN.md)。
