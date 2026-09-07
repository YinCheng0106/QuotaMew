# QuotaMew 架構

狀態：Milestone 1 實作基準、Codex provider core、Claude Code snapshot provider core、共用應用程式整合、v0.1 reset reminders、provider-agnostic 本機 reset detection、production privacy-safe compatibility diagnostics，以及 provider visibility／disabled semantics，2026-08-31。Production `AppDependencies` 已透過 `UsageProvider` 接入兩個 adapters；SwiftUI previews 保持 mock-only。Claude opt-in status-line bridge 與外部 Reset Intelligence feed 尚未實作。

## 1. 目標與限制

QuotaMew v0.1 是原生 macOS 選單列工具，將 Codex 與 Claude Code 的額度視窗資料正規化，並顯示已使用額度、剩餘額度、重設時間與倒數。它不是另一個 AI agent client。

架構必須：

- 把 provider 特有行為封裝在 adapters 後方
- 讓 UI 不依賴 provider payload 與檔案配置
- 區分新鮮、過期、無法取得與不支援的資料
- 避免工作重疊與積極輪詢
- 不讀取憑證、prompt、原始碼與完整 transcript 歷史
- 不需要伺服器也能支援本機通知
- 為 Gemini CLI、OpenCode 與未來 Reset Intelligence 保留清楚邊界

v0.1 不處理帳號、雲端同步、遠端公告擷取、歷史分析、token 成本計算、自動探索憑證或 iOS companion App。

## 2. 平臺基準

- macOS 14 以上
- Swift 6 與 SwiftUI app lifecycle
- 一個 AppKit `NSStatusItem`，以 `NSPopover` 承載既有 SwiftUI dashboard
- 原生 `Settings` scene
- `LSUIElement = true`，不顯示 Dock 圖示
- 使用 `@Observable` 並隔離於 `@MainActor`
- 無第三方 runtime 相依套件

Milestone 1 已確認 macOS 14 作為目前 deployment target。是否支援更舊版本仍是產品決策，不應在同一套程式碼維護平行的 Observation 實作。

長期仍規劃採 Mac App Store 外的 Developer ID 簽章與 notarization 方式散布，但這些工作在公開 GitHub v0.1 刻意延後；最初的 v0.1.0 是 source-only release，不附可下載 App。啟動已安裝 provider 執行檔及讀取 provider 自有檔案，與直接套用 App Sandbox 的設計存在衝突；若未來要求上架 Mac App Store，必須先重新設計 provider 整合與 security-scoped access。

## 3. 系統形狀

```text
NSStatusItem + SwiftUI popover / Settings
                 |
                 v
  @MainActor AppModel
          |
          v
   RefreshCoordinator ------> NotificationService
                                  |
                                  +----> ResetNotificationPolicy
                                  |
                                  +----> LocalResetDetector ----> bounded local state
          |
          v
     UsageService actor
          |
          +----> MockUsageProvider (SwiftUI previews / tests)
          |
          +----> CodexProvider -----------------------> Codex app-server
          |
          +----> ClaudeProvider ----------------------> legacy QuotaPulse-owned snapshot
                                                       ^
                                                       |
                                      opt-in status-line bridge（尚未實作）

未來的獨立路徑：
ResetEventSource ----> trusted, lightweight JSON feed
          |
          v
ResetEvent，保留不可變的原始來源 URL 與 source name
```

UI 只接收正規化後的 snapshot；不解析 provider payload、不啟動指令，也不讀取檔案。

### v0.2 Product Polish（2026-09-07，尚未發行）

額度名稱只有一個來源：`UsageWindowPresentation`。精確 duration 18,000 秒對應 `5-hour`／`5 小時`，604,800 秒對應 `Weekly`／`每週`，未知／缺少／無效 duration 使用通用名稱；不由 array position、primary/secondary 或倒數推論，也不把 raw provider label 顯示給使用者。Dashboard row、VoiceOver header 及 approaching/completed notification 文案都共用此 formatter；`UsagePresentation` 繼續只負責 Remaining／Used 百分比。Domain ID、label、duration、reset/cycle metadata 保持原值；`LocalResetDetector` 不參與本地化。

`ProviderWindowsPresentation` 是目前 snapshot 的純值 projection。Codex 精確 ID `codex.base_model_inference.primary/secondary`（runtime 觀察）與 `codex.gpt-reserve.primary/secondary`（相容別名）顯示為 **Luna Reserve**。一般 windows 先顯示；Reserve 平常只提供沒有 progress bar／倒數的次要精簡列。僅當 available、capture age 在 0..<15 分鐘、一般 codex bucket 的 5 小時或每週 window 原始 usedPercentage 恰為 100 且 reset 尚未到期，才展開 Reserve。這不宣稱 Reserve 已啟用、計費狀態或使用資格；缺少／stale／invalid 資料不觸發。選單列排除 Reserve，絕不以其百分比取代一般 window。沒有新增 persistence/history、refresh 或 timer。

Reserve 的 approaching reminders 在 policy 中排除；completed resets 在 service 授權與送達前排除。這是 v0.2 保守的通知範圍縮限。一般 thresholds、dedup identity、eligibility、provider lifecycle generation、authorization/revalidation 與 `LocalResetDetector` 演算法不變；detector 原有 bounded current-cycle state 繼續更新，不新增 Reserve history。

同一 `StatusItemController` 另持有一個 `StatusItemContextMenu`／`NSMenu`。既有標準 button 透過公開 [`sendAction(on:)`](https://developer.apple.com/documentation/appkit/nscontrol/sendaction(on:)) 接收左右 mouse-up，以 current event type 分派；右鍵關閉 popover 後透過 [`NSMenu.popUp(positioning:at:in:)`](https://developer.apple.com/documentation/appkit/nsmenu/popup(positioning:at:in:)) 顯示同一份選單。左鍵保持原 Dashboard toggle。Refresh 沿用 `AppModel.refreshManually()`；Settings 經 App 提供的公開 SwiftUI `openSettings` action 開啟原 Settings scene；Quit 正常 `NSApplication.terminate`。Teardown 清除 menu target/action 並取消 tracking，再走既有 observer/popover/item teardown。沒有 custom status view、global monitor、第二個 status item 或 private API；autosave/bundle/recovery/login-item 語意不變。

Milestone C 只有 persistence contract，Onboarding UI 仍為 v0.2 必要的下一項實作。原外部 Reset Intelligence D/E reader/network/matching 移至 v0.3；frozen contracts 保留。完整政策與版本流程見 [V0_2_PLAN.md](docs/V0_2_PLAN.md)。

## 4. Domain model

Milestone 1 已實作以下責任：

```swift
enum ProviderID: String, Codable, Sendable {
    case codex
    case claude
    // future: gemini, openCode
}

struct UsageWindow: Identifiable, Equatable, Sendable {
    let id: String
    let label: String
    let usedPercentage: Double?
    let resetAt: Date?
    let duration: Duration?
    let resetCycleIdentifier: String?
}

struct ProviderUsageSnapshot: Equatable, Sendable {
    let providerID: ProviderID
    let windows: [UsageWindow]
    let capturedAt: Date
    let source: UsageSource
}
```

支援狀態包含 `loading`、`available`、`stale`、`notConfigured`、`notInstalled`、`unsupportedAuthentication` 與 `failed`。`failed` 只攜帶正規化的 `ProviderFailure`（`refreshFailed`、`runtimeLaunchFailed`、`usageUnavailable`），不攜帶 raw error message。每個額度視窗都使用穩定 ID，因為同一 provider 可能同時提供數個視窗。`UsageWindow.id` 識別視窗類型；optional `resetCycleIdentifier` 則識別該視窗的特定 reset cycle。Provider 沒有提供 cycle metadata 時，本機 detector 才以分鐘化 `resetAt` 作為 fallback cycle identity。

存在的百分比必須是有限數值。原始 provider 值可保留在 domain model，實際繪製 progress 時才限制於 0...100；若 provider 只回傳有效 `resetAt`，window 仍可存在，但 UI 與通知都不得補造 percentage。`resetAt` 已經過期不代表額度真的重設，也不能推論用量為零；舊 snapshot 應標示為過期，直到 provider 提供新資料。

## 5. Provider adapter contract

使用能力導向名稱，不採籠統的 `ProviderProtocol`：

```swift
protocol UsageProvider: Sendable {
    var id: ProviderID { get }
    func fetchUsage() async throws -> ProviderUsageSnapshot
}
```

此 protocol 不暴露 provider 路徑、憑證、輪詢間隔、UI 顏色或通知行為。DTO 必須留在各自 provider 資料夾，並在 adapter 邊界轉成 domain model。

`UsageService` 依序刷新 providers 並回傳正規化結果。v0.1 只有兩個 adapters，不值得用 process 層級的平行處理增加尖峰資源；只有量測證明有需要後，才可考慮受限的並行。

Milestone 1 的 `MockUsageProvider` 使用固定規則產生 Codex 與 Claude Code 測試資料，沒有讀檔、網路或 process I/O。

後續限定範圍的 Codex discovery 已實作 `CodexProvider`、`CodexAppServerClient`、DTO 與 executable locator。Claude Code discovery 已實作 `ClaudeProvider`、版本化 snapshot DTO 與 bounded snapshot reader，但沒有 bridge installer。Production `AppDependencies` 以 `[any UsageProvider]` 建立兩者，再由 `UsageService` 依序刷新；SwiftUI 只接收 `ProviderState` 與 `ProviderUsageSnapshot`。完整調查與 fallback policies 記錄於 `docs/providers/codex.md` 與 `docs/providers/claude-code.md`。

## 6. Codex 資料來源評估

### 優先方案：有文件的 Codex App Server

[官方 Codex App Server](https://learn.chatgpt.com/docs/app-server) 透過 stdio 提供 newline-delimited JSON。目前 client：

1. 不經 shell，依序從標準位置與 `NSWorkspace` 發現的 ChatGPT.app 整合 runtime、舊 Codex.app、常見 CLI locations 與 GUI process 的受限 `PATH` 尋找 `codex` 執行檔
2. 使用 `Process` 啟動 `codex app-server`
3. 傳送含 QuotaMew client metadata 的 `initialize`
4. 傳送 `initialized` notification
5. 呼叫 `account/rateLimits/read`
6. 從一個或多個 rate-limit buckets 解碼 `usedPercent`、`windowDurationMins` 與 `resetsAt`
7. 健康時保留同一個 app-server connection 供後續刷新重用；timeout、cancellation、EOF、protocol failure 或 App 結束時才完整替換或關閉 child

此 method 與欄位已有 OpenAI 文件，並由 Codex 管理驗證狀態。QuotaMew 不得讀取 `~/.codex/auth.json` 或複製 token。Adapter 必須清楚呈現找不到執行檔、尚未登入、不提供 ChatGPT 訂閱額度的 API-key-only 模式、protocol 不相容、timeout 與 payload 格式錯誤。

目前實作採單一、按需建立且健康時重用的 app-server。`CodexAppServerClient` actor 合併重疊讀取，connection 只保留一個 stdout reader task 與一筆 response buffer；stderr 直接導向 null device，不建立 reader 或 buffer。每個 request 使用 5 秒 timeout，每行 stdout 上限 1 MiB。timeout、cancellation、EOF、protocol failure、explicit shutdown 或 App termination 都會先關閉 handles、終止並 reap child，再等待 stdout reader 結束；重連完成前不會啟動替代 child。它不讀取 `auth.json`、sessions、logs 或 state databases。

本機以 ChatGPT.app 內建的 `codex-cli 0.149.0-alpha.4.3` 做過 sanitized live probe，確認 method 與欄位型別可用。Production locator 先檢查標準位置及 `NSWorkspace` 發現的 `ChatGPT.app/Contents/Resources/codex`，再回退舊 `Codex.app`、常見獨立 CLI locations 與 GUI process 繼承的受限 `PATH`。ChatGPT.app 與舊 Codex.app 目前共用 `com.openai.codex`，因此 bundle identifier 只用於取得候選位置；locator 還會驗證 bundle 名稱、一般可執行檔與受信任路徑祖先。成功來源只在記憶體快取，每次使用前重新驗證，失效就重新探索。此 runtime path 仍是 app bundle packaging detail，需透過安全 fallback 與跨版本測試持續驗證；使用者 override 尚未實作。

### 可能的備援：本機 Codex session JSONL

Codex session event 可能包含 `primary` 與 `secondary` 視窗的使用百分比、duration 與 reset timestamp，但 persisted schema 是實作細節，最新 session 也可能過期或已封存。掃描 session 還可能接觸含 prompt 與 tool output 的內容。

若未來啟用此備援，必須明確標示 experimental，只讀取候選檔案受限大小的尾端，找到最新 rate-limit event 就停止，立即捨棄無關內容，並把 snapshot 標示為可能過期。目前官方 App Server 已通過本機驗證，因此不實作此備援。

### 拒絕的 Codex 來源

- `auth.json`：憑證儲存，不是用量資料
- screen scraping 互動式 `/status`：脆弱且不是 machine contract
- 由 token 數推估方案額度：provider 可控制加權方式，無法可靠重建

## 7. Claude Code 資料來源評估

### 優先方案：有文件的 status-line JSON 與 opt-in bridge

[Claude Code 官方 status-line 文件](https://code.claude.com/docs/en/statusline) 定義：

- `rate_limits.five_hour.used_percentage`
- `rate_limits.five_hour.resets_at`
- `rate_limits.seven_day.used_percentage`
- `rate_limits.seven_day.resets_at`

Claude Code 會在相關 session event 後啟動已設定的 status-line command，並把小型 JSON 寫入 stdin。QuotaMew 應使用需要使用者明確同意的 bridge，把最少量 snapshot 以原子方式寫入 legacy `~/Library/Application Support/QuotaPulse/Providers/Claude/`。

只可保留：

- 實際存在的兩個文件化 rate-limit windows
- 可取得時的 Claude Code version
- legacy QuotaMew bridge schema version
- 本機 capture time

必須捨棄 `cwd`、workspace/repository identity、transcript path、token 數、cost、model、session ID 與所有未知欄位。

限制包括：`rate_limits` 僅為 Claude.ai Pro/Max 訂閱者所文件化；欄位要在 session 第一次 API response 後才出現；任一視窗都可能缺少；更新由事件驅動，Claude Code 閒置時 snapshot 可能過期；安裝 bridge 可能與現有 custom status line 衝突。

Milestone 3 必須設計明確的設定與復原流程。QuotaMew 不得靜默取代既有 `statusLine.command`。可以產生供現有 script 整合的說明，或在顯示完整設定差異並保留可復原備份後，才安裝 wrapper。

目前已實作的 `ClaudeProvider` 只讀 legacy QuotaPulse-owned、`schemaVersion: 1` 的 `usage-v1.json`。`ClaudeSnapshotReader` 將輸入限制為 16 KiB，拒絕 missing、unreadable、oversized、malformed 與 future-schema files，並保留 `capturedAt` 供後續 stale policy 使用。它不讀取 `~/.claude`、`~/.claude.json`、transcripts、history、stats 或 credentials。完整本機探索與條件式可靠性說明見 `docs/providers/claude-code.md`。

本機 Claude Code package metadata 顯示版本 `1.0.43`，早於官方 changelog 加入 status-line `rate_limits` 的 `2.1.80`；因此沒有宣稱完成本機 live quota 驗證。本機也已有 status-line command，本次沒有讀取其值或修改設定。

### 拒絕的 Claude 來源

- `/usage`：適合互動檢查，但沒有文件說明可作為非互動 machine-readable command
- `~/.claude/projects/**/*.jsonl`：可能很大，且包含敏感對話與 workspace 資料
- `~/.claude/stats-cache.json`：歷史 token 與活動統計，不是訂閱額度
- 未文件化 OAuth usage endpoint 或直接讀取 Keychain token：不穩定且違反不碰憑證的邊界
- 單純為取得額度而發出 Claude request：會消耗額度並傳送資料，不適合被動監看工具

## 8. 刷新與並行模型

`AppModel` 是唯一的 refresh scheduling owner。它在 App 啟動時要求第一次刷新，並且最多只持有一個含 30 秒 tolerance 的 `ContinuousClock` sleeping task；menu view、`RefreshCoordinator`、`UsageService` 與 providers 都不建立週期 timer 或獨立 refresh loop。

Provider eligibility 的 persisted source of truth 是 `SettingsStore`。`AppModel.enabledProviderIDs` 是同一份設定在 UI／lifecycle 層的記憶體投影，用來即時產生 `activeProviderStates`；它不是第二份 persistence。`UsageService` 在真正進入 adapter I/O 前再次讀取 `SettingsStore`，作為 process、RPC 與 snapshot read 的最終防線。Dashboard 只渲染 `activeProviderStates`，不在個別 SwiftUI subview 重複判斷 provider 類型。

v0.1 固定政策：

- 正常完成一輪含 enabled provider 的刷新後，下一輪約在 15 分鐘後執行；全數停用時不建立 sleeping task，也不要求 provider work。
- menu panel 出現時立即使用記憶體中的 enabled `ProviderState`／snapshot；任一 enabled snapshot 的 `capturedAt` 已超過約 3 分鐘，且距離上一輪讀取完成也至少 3 分鐘時，在背景要求刷新，不等待結果才顯示 UI。Disabled snapshot 不參與 stale 判斷。
- 使用者按下 refresh 或 Command-R 時立即要求刷新所有 enabled providers；若已有手動或自動刷新進行中，沿用同一輪工作，不啟動重疊工作。Disabled provider 不參與 startup、scheduled、menu-open 或 manual refresh。
- 重新啟用 provider 後會要求一次立即、共用且可合併的 refresh；若另一輪已在進行，`AppModel.providerIDsAwaitingRefresh` 以 provider-scoped `Set` 記錄需求，當該輪的通知評估也結束後恰好補一輪。相同 provider 的重複 enable signal 仍只產生一輪 follow-up，不重疊，也不產生第三輪。
- 刷新開始時保留現有 snapshot 並顯示 refreshing；若同一 provider 最新刷新失敗，`AppModel` 保留上一份有效的記憶體內 snapshot，UI 同時顯示 stale／失敗提示與原始 `capturedAt`。這不建立磁碟 persistence 或 usage history。
- 任一 provider 回傳可重試的 `.failed` 時，共用刷新週期依 1、2、5、15、30 分鐘退避，連續失敗最多 30 分鐘；下一輪沒有 `.failed` 就恢復 15 分鐘。menu open 不會繞過尚未到期的退避；明確手動刷新可以立即重試。`notInstalled`、`notConfigured` 與其他非暫時性 unavailable 狀態不啟動快速重試。此為全 App 共用退避，健康 provider 仍會隨每輪依序更新，不另建 provider timer。
- system sleep 會取消唯一 sleeping task但保留 deadline；wake 時若 deadline 已過就要求一輪刷新，否則只重建一個剩餘時間 schedule。重複 wake 或 App activation 只會確認既有 schedule，不建立第二個 loop。

下一輪 deadline 以 provider I/O 完成時間計算，但 sleeping task 只在該輪通知評估結束、`AppModel` 清除 in-flight refresh ownership 後才安裝。若通知評估跨過 deadline，會以零延遲要求下一輪，而不是讓 timer 在 refresh 尚未清除時觸發後被合併掉。

工作合併分成刻意保留的防線，而不是多套排程：

1. `AppModel` 合併所有 UI、menu、lifecycle 與 scheduled triggers，並發布 loading／完成狀態。
2. `RefreshCoordinator` 只持有一個 in-flight refresh task，讓其他非 UI caller 也不能繞過合併；它不決定時間。
3. `UsageService` actor 依 provider 順序重新檢查 enablement；disabled provider 直接產生 normalized `.disabled` state，不呼叫 `fetchUsage()`，其餘 providers 依序刷新。單一 provider 失敗不會阻止後續 provider。
4. `CodexAppServerClient` actor 合併同一 provider 的重疊 RPC，健康時重用既有 app-server connection。

普通 refresh 只在健康 connection 上送出新的 `account/rateLimits/read`，不做 executable discovery 或 process recreation。只有 connection 不存在或已失效時才進入 locator／reconnect；重連會先完整停止舊 connection，再探索並建立 replacement。因此 reconnect lifecycle 與正常 refresh cadence 保持分離。

App termination 會取消 App-owned schedule／refresh，並要求 coordinator cancellation；Codex process boundary 仍以自己的同步 termination observer 保證 child cleanup。外部 process 一律維持 timeout、受限 stdout/stderr 與完整 termination cleanup。

每輪 refresh 開始時，`AppModel` 會快照 eligible provider IDs 與各 provider 的 lifecycle generation，再把 frozen eligible set 傳入 `RefreshCoordinator`／`UsageService`。Provider 在本輪開始後才啟用時，不會中途加入本輪；它由上述單一 follow-up 處理。Provider 在本輪中途停用，或停用後又重新啟用時，即使既有 bounded adapter I/O 最後成功，generation 已改變，`AppModel` 也會丟棄該 provider 的結果，不恢復舊 presentation、cached snapshot 或通知資格。後續 follow-up 才能用目前 lifecycle 的 fresh data 建立狀態。

`AppModel` 內三種 generation 各有單一用途：`refreshGeneration` 使整輪 refresh 的過期 completion 失效，`scheduleGeneration` 使已取消或被取代的 sleeping task 失效，provider lifecycle generation 則只判斷個別 provider 的 I/O 結果是否仍屬於目前 enablement lifecycle。前兩者是 process-local task token；第三者也是 process-local UI／refresh guard，不作為通知 request identity。

若使用者在 adapter I/O 已開始後停用該 provider，本輪不額外加入 provider-specific 強制取消：既有 bounded operation 可安全完成；尚未進入 I/O 的 provider 則由 `UsageService` 在 adapter 邊界重新讀取 `SettingsStore` 並跳過。已存在且健康的 Codex app-server connection 可以保持 idle，但停用後的新 refresh 不會建立新 process 或送出新 RPC；若停用發生在 process launch 已開始之後，該次 launch 屬於既有 in-flight operation。這避免為設定開關新增另一套 cancellation ownership。

畫面倒數使用一分鐘粒度的 `TimelineView(.periodic(from:by:))`，只以 `resetAt - context.date` 計算顯示文字。倒數 tick 不改寫 `AppModel`、不要求新 snapshot，也不會呼叫 provider、locator 或 app-server。不得發布全域一秒 tick，也不持久化持續變動的倒數值。

## 9. 通知

`NotificationService` 擁有 v0.1 的本機通知流程；`ResetNotificationPolicy` 是不依賴 `UserNotifications` 的純決策層，`UserNotificationCenterClient` 才把決策轉成 `UNNotificationRequest`。SwiftUI 不建立 request，也不持有通知去重狀態。Preview 與單元測試注入 fake center／store，不接觸真實通知中心。

### 9.1 評估與 eligibility

`AppModel` 在 `UsageService` 完成本輪 refresh 並發布 UI state、排定既有下一輪 refresh 後，把該輪原始 `ProviderState` 交給 notification service。通知不讀取 UI 為失敗狀態保留的 cached snapshot。每個 window 必須同時符合：

- provider 在評估當下仍由 `SettingsStore` 標示為 enabled
- state 是本輪成功的 `.available`，snapshot 與 state 的 provider identity 相同
- snapshot source 必須是 provider adapter 的真實來源；`.mock` 永遠不具通知資格
- `capturedAt` 距評估時間不超過 15 分鐘；只容許最多 5 分鐘的未來 clock skew
- `resetAt` 是有限值且仍在未來
- provider 不是 `.notInstalled`、`.notConfigured`、`.unsupportedAuthentication`、`.failed` 或 `.stale`

`usedPercentage` 不存在、非有限值或超出 0...100 時，仍可送不含 percentage 的 reset reminder；只有 0...100 的真實 percentage 能產生 remaining quota 文字。

### 9.2 Threshold 與通知種類

v0.1 依 normalized `UsageWindow.duration` 選擇門檻，不做 provider-specific 分支，也不做每 10% 等頻繁 percentage alerts。6 小時以下的短視窗使用 reset 前 1 小時與 30 分鐘；超過 6 小時的長視窗使用 24、6、1 小時候選門檻，並排除長於該視窗本身的門檻。缺少或無效 duration 時不猜測分類，也不建立通知。每個 window／threshold 最多一則：

- remaining percentage 至少 20% 時，送「significant remaining quota」版本；Product Polish title 使用共用名稱，例如 `Codex Weekly quota resets in 6 hours`，body `You still have 61% of your quota remaining.`
- percentage 缺少、無效或 remaining 低於 20% 時，送不含數字的「reset approaching」版本

20% 是 v0.1 的保守 noise floor，不是方案額度推估，也沒有在本次加入 Settings UI。若 App 第一次看到 window 時已同時跨過多個適用門檻，只送最接近 reset 的一則，並把較早門檻一併標記完成，避免多則提醒同時湧入。

### 9.3 Scheduling strategy

v0.1 選擇 **在既有 refresh 後評估並立即提交一次性 local notification**，不預先建立長期 `UNCalendarNotificationTrigger`。長期 request 若保存目前的 remaining percentage，真正送達時數字可能早已改變；若只保存 reset time，則無法可靠完成「仍有顯著額度」提醒。Refresh-driven delivery 讓 title、body 與 eligibility 都以同一輪新鮮資料決定，也能在 reset timestamp 改變時重新評估，不需維護另一個 scheduler。

正常運作的 menu bar App 最多受既有約 15 分鐘 refresh cadence 影響而延遲；Mac sleep 時不新增喚醒 timer，既有 wake refresh 會補做評估。App 完全退出期間不會產生新提醒，這是 v0.1 為資料正確性與低資源使用接受的限制。提交給通知中心的 1 秒 non-repeating trigger 只用於讓系統顯示已決定的即時通知，不是 refresh scheduler 或長時間 Task。

### 9.4 去重、reset window identity 與 timestamp 變更

去重 identity 由 provider、穩定的 usage-window ID、logical reset-window identity 與 threshold 組成。Reset timestamp 以分鐘正規化，兩分鐘內的解析／clock 差異視為同一值。每個 provider/window 只保留目前 logical window：

- 舊 reset 尚未到期時，不論 timestamp 往前或往後移，仍視為同一 logical window；更新目前 reset time，但保留已送 thresholds
- reset 移早且已經過期時不送；下一個未來 reset 出現後建立新 logical window
- 舊 reset 已經過期後出現新的未來 reset，視為真正的新 window，該 duration class 的門檻重新 eligible
- 若 provider 在舊 reset 已過後才宣告它其實往後移，無法與新 window 完全可靠區分；v0.1 保守地視為新 window，這是剩餘 edge case

`UserDefaultsNotificationStateStore` 只保存 schema version、provider、window ID、分鐘化 reset identity／目前 reset、已完成 thresholds 與最後觀察分鐘，不保存通知文案、percentage、snapshot、provider payload 或憑證。既有以小時保存的 threshold metadata 會相容轉成分鐘，保留跨版本去重；舊格式 pending request 則會在首次通知評估時移除。相同 provider/window 的新 generation 會取代舊 generation，全域另設 32 entries 上限，encoded state 超過 64 KiB 時拒絕讀取，沒有無限成長的 history。Provider notification lifecycle 另外只保存每個已知 `ProviderID` 的目前 `UInt64` generation；它是固定大小的 current-state counter，不保存歷史。

Service 在提交 request 前先持久化 threshold claim，以 App restart 與重複 refresh 的「最多一次」語意優先；若系統在 claim 後拒絕 `add`，該單一 threshold 可能漏送，但不會重送。Process 內以 evaluation generation 與提交前重新讀取 state 防止兩次 async evaluation 在 authorization suspension point 重複提交。這個 process-local evaluation generation 只淘汰重疊評估；persisted provider lifecycle generation 才保護跨 process 的 pending request identity 與 cleanup。兩者不能互換，也不與 `AppModel` 的 refresh／schedule generations 共用 ownership。

### 9.5 Stale data 與權限

本輪 refresh 失敗、typed unavailable 或 snapshot 超過 15 分鐘時，不建立新通知、不改寫已完成 thresholds，也不移除其他有效 request；因 v0.1 沒有長期 future reset requests，stale refresh 通常沒有待取消項目。各 provider 分開評估與去重，一個 provider 狀態不影響另一個。

停用 provider 時，`NotificationService` 只移除 identifier 屬於該 provider 的 pending `quotapulse.reset.*` 與 `quotapulse.reset-completed.*` requests，不移除其他 provider 或其他 App 的 request。停用後即使一輪 refresh 已在進行，也會依最新 `SettingsStore` 狀態拒絕 approaching-reset 與 completed-reset 通知。Reminder dedup state 繼續受既有 32 entries／64 KiB 上限約束，且不因 toggle 清空，避免反覆切換重送已 claim 的 approaching reminder。

Provider enablement 的非同步 cleanup 由 `NotificationService` 擁有，而非 SwiftUI。每次 transition 都同步增加並保存該 provider 的 bounded lifecycle generation、更新 enabled state 並清除該 provider 的 reset-detector baseline；每個 provider 最多只有一個可合併的 cleanup task。Pending request identifier 在 provider prefix 後帶目前的 `lifecycle-N`，但 generation 不進入 reminder dedup 或 detector history。App 啟動時，service 會合併一次 pending-request reconciliation：disabled provider 的 request 全部移除；enabled provider 只保留 persisted current generation，沒有 lifecycle 或屬於舊 generation 的 request 都移除。Cleanup 取得 pending identifiers 後，必須在真正刪除前重新檢查目前 lifecycle：最終為 disabled 時刪除該 provider 全部 pending requests；最終為 enabled 時只刪除舊 generation，保留目前 generation。若 transition 發生於 `center.add` suspension 期間，提交後也會再次驗證 generation，並立即移除剛加入的 stale request。因此舊 cleanup、舊 evaluation 或 process restart 的完成順序都不能刪除或保留較新 lifecycle 的通知。

Lifecycle state、cleanup task、request filtering 與 reset baseline 都以 `ProviderID` 分開保存。Codex 的 cleanup 不等待或刪除 Claude 的 pending request、snapshot、eligibility、dedup metadata 或 detector entries；系統沒有新增全域 provider transition queue。

只有出現第一個 eligible decision 且 authorization status 是 `.notDetermined` 時才要求 `.alert`／`.sound` 權限。並行評估共用同一個 authorization request；權限等待結束後，service 只讓最新一輪評估繼續，並以等待後的時間重新檢查 freshness、reset 與 dedup state。這避免使用者停留在系統提示期間又完成更新時，舊 percentage 或已過期 reset 才被送出。

之後先讀 system settings；`.denied` 不再要求、不送通知，也不影響 provider refresh、UI 或下一輪排程。使用者日後在 System Settings 重新允許後，尚未 claim 且仍 eligible 的 threshold 可在下一輪 refresh 送出。`UserNotificationCenterClient` 持有 notification center delegate，讓 App 在前景時也能要求 banner／sound presentation。Debug build 的 Settings 提供 development-only action，透過同一個 `UserNotificationCenterClient` 要求授權並排定約五秒後的固定 identifier 測試通知；其 protocol method、model action、feedback state 與 UI 全部以 `#if DEBUG` 排除於 Release。授權與本機通知提交遵循 Apple 的 [Requesting authorization](https://developer.apple.com/documentation/usernotifications/asking-permission-to-use-notifications) 與 [Scheduling a notification locally](https://developer.apple.com/documentation/usernotifications/scheduling-a-notification-locally-from-your-app) 流程。

### 9.6 本機 quota reset detection

`LocalResetDetector` 只在既有 provider refresh 完成後評估新鮮、真實來源的 `.available` snapshot，沒有自己的 timer、polling loop 或 process。它是 provider-agnostic 的 pure value type，輸入 normalized `ProviderState` 與有上限的先前狀態，輸出新狀態與 `DetectedQuotaReset`。

初次看到 provider/window 只建立 baseline，不送通知。之後只在有新鮮、時間順序正確的觀測時比較。強證據依優先度為：

- provider 提供的 explicit cycle identifier 改變
- 舊 reset boundary 已到（含 5 分鐘 clock-skew 容忍），且 `resetAt` 進入新視窗
- 使用量至少下降 25 percentage points，且 `resetAt` 往後移動足以代表新視窗（有 duration 時至少一半 duration；否則至少 30 分鐘）

單獨 percentage 下降不計為 reset。小於等於 2 分鐘的 reset timestamp 修正視為同一 cycle。Stale、out-of-order、malformed、mock 與暫時缺少 `resetAt` 的 snapshot 都不產生 reset；觀測間隔超過 2 小時時只重建 baseline，避免 app restart 或 provider reconnect 後猜測中間發生的事件。

Provider 每次 enablement transition 都會移除該 provider 的 bounded detector entries。重新啟用後的第一份新鮮 snapshot 因而只建立 baseline，不得產生 completed-reset；第二份之後才依正常強證據規則判斷。這個 provider-scoped re-baseline 不刪除 provider 設定、notification reminder dedup，也不影響其他 provider 的 detector state。

Completed-reset 通知以 provider 顯示名稱與 normalized window label/duration 產生在地化文案。去重 identity 是 `providerID + UsageWindow.id + cycleIdentifier`。Detector 在通知授權與提交前就把 cycle claim 以獨立 schema 保存，因此選擇 at-most-once：提交失敗可能漏送，但同一 cycle 不會因 restart 或重複 refresh 再送。狀態最多 32 個 provider/window entries、每個 identifier 最多 256 bytes，且 encoded payload 上限 64 KiB；不保存 usage history。

## 10. 設定

QuotaMew 使用原生 `Settings` scene 與 `@MainActor SettingsStore`。Settings 以原生 `TabView` 固定為 General／Providers／Notifications 三頁：General 包含 app behavior、presentation 與 Diagnostics；Providers 保留 enablement 與 Claude Experimental / Unverified 說明；Notifications 保留所有既有 reminder 與 permission 行為。`SettingsStore` 是 provider enablement、presentation mode、optional pinned provider、通知總開關，以及短視窗 1 小時／30 分鐘與長視窗 24／6／1 小時門檻的單一來源，並以 typed UserDefaults keys 保存；SwiftUI 只透過 `SettingsModel` 修改 store，再由 `UsageService` 與 `NotificationService` 讀取同一份狀態。Provider toggle 先同步通知 `NotificationService` 使舊 lifecycle 失效，再保存設定、更新 `AppModel` 投影，並於 enable 時要求共用 refresh。`SettingsModel.setProvider` 回傳 `Void`；View 只表達使用者意圖，不接收或 await cleanup task。Cleanup 可以非同步完成，因正確性由 service 的 provider generation 與 destructive-point validation 保證，不依賴 SwiftUI call site 記住實作細節。短、長視窗的 1 小時選項彼此獨立，舊版共用 1 小時偏好會作為短視窗偏好的 migration 預設。`NotificationService` 關閉時不再建立提醒，並移除 QuotaMew 自己的 pending reset requests；關閉單一門檻只移除相符 duration class 的門檻。

Launch at Login 使用 `ServiceManagement` 的 `SMAppService.mainApp`。Settings 每次顯示時重新讀取 system status；register／unregister 失敗時保留系統實際狀態並顯示安全錯誤，不把 UI toggle 當成成功依據。

同一個 app target 以 build configuration 分開 macOS bundle identity：Release 保留 production `dev.quotapulse.app`，Debug 使用 `dev.quotapulse.development.app` 並以 `QuotaMew Debug` 顯示。`PRODUCT_NAME`／executable 維持 `QuotaMew`，不複製 target。由於 `SMAppService.mainApp`、`UserDefaults.standard`、`UNUserNotificationCenter.current()` 與 macOS 26 Control Center 的第三方 menu bar 狀態都以目前 app identity 為邊界，開發操作只會落在 Debug identity；兩者不共用 preferences，也沒有 App Group entitlement。Debug 因而有自己的首次啟動設定與通知授權，這是刻意隔離而非 migration。

選單列生命週期拆成四種不可混用的狀態。`SettingsStore.isMenuBarItemRequested` 是 persisted QuotaMew user intent，新安裝預設為 `true`；`SettingsModel.isMenuBarItemVisible` 是目前 process 由公開 `NSStatusItem.isVisible` 與 KVO 投影的 logical visibility；Control Center 另為該 QuotaMew process 註冊並追蹤 system host；實際 status item 是否在目前螢幕有像素，最後仍由 macOS allowance、選單列可用空間、active display 與 system UI 決定，QuotaMew 沒有公開 API 可權威查詢。KVO 變成 `false` 只更新 logical state，不回寫 UserDefaults；只有 QuotaMew Settings toggle 與 recovery action 可以保存 intent。

**CURRENT**：production composition root 只建立一個 `StatusItemController`。Controller 建立並持有唯一 `NSStatusItem`，Debug／Release 分別使用 `dev.quotapulse.development.app.primary-status-item` 與 `dev.quotapulse.app.primary-status-item` 作為 stable `autosaveName`，以一個 `.transient` `NSPopover` 和 `NSHostingController` 呈現既有 `DashboardView`；Dashboard、Settings、providers、refresh、notifications 與 shared `AppModel`／`SettingsModel` 都未複製。Status button 以既有 SF Symbol、template image、monospaced compact percentage 或 unavailable placeholder 呈現，並明確設定 VoiceOver label/value。標準 `NSStatusBarButton` 使用 `.imageLeading`、`imageHugsTitle = true` 與 `.scaleProportionallyDown`；item 先以 `NSStatusItem.variableLength` 建立，再於每次內容更新時以 button 的 `intrinsicContentSize.width` 動態設定公開的 `length`，下限為目前 status bar thickness。此作法沒有固定百分比寬度、人工空白、kerning hack 或 custom view。

2026-09-02 的受控 macOS 26 實測顯示，將 Debug autosave identity 暫時換成 `dev.quotapulse.development.app.primary-status-item-v2` 仍會隨 ChatGPT visibility 一起被 Control Center blocked／unblocked；KVO 依序變成 `false`／`true`，但 QuotaPulse persisted intent 全程維持 `true`。因此 coupling boundary 位於 `autosaveName` 之上，不採用 v2 migration。Read-only Control Center state 顯示 `com.openai.codex` 的 tracked application locations 含 `dev.quotapulse.development.app`，所以關閉 ChatGPT 會對同一 application group 內的 QuotaPulse host 發出 blocked visibility request。從 Codex 內的 shell 直接執行 Mach-O 時，LaunchServices 同時把 QuotaPulse 的 inferred `parentASN` 記為 ChatGPT；改用 `open` 啟動同一 app bundle 時，QuotaPulse 由 PID 1 啟動、保有自己的 LaunchServices application identity，且沒有該 inferred parent。這組證據支持把 raw executable launch 視為可避免的關聯污染來源，但不能證明或透過公開 API 清除已存在的歷史 Control Center mapping。

Controller 是選單列 shell 的唯一 observation owner：一條 Swift Observation path 讀取 persisted intent 與 `MenuBarPresentation`，一條 KVO observation 讀取 system logical visibility。它記住最後一次已套用的 intent，因此 presentation 更新不會把使用者或 macOS 已移除的 item 反覆插回；recovery action 則可明確 force-show，即使 persisted intent 原本已是 `true`。Open popover 只呼叫既有 `AppModel.menuDidOpen()`；沒有新增 timer、polling、network、scheduler 或 provider I/O。Teardown 會取消 observation、清除 target/action、關閉 popover並移除同一個 status item，且可重複安全呼叫。

`QuotaMewTests` 仍是 app-hosted XCTest，但 `AppRuntimeEnvironment.shouldCreateStatusItemController` 在 XCTest 為 `false`，app delegate 在任何 controller factory 呼叫前就停止 production setup。因此並行測試不建立 `StatusItemController` 或 `NSStatusItem`，scheme 已恢復 `parallelizable = YES`。Controller-level tests 以 injected fake status item／popover 驗證 create-once、hide/show、system-removal projection、recovery、100 次開關、teardown 與 accessibility；直接測試 `SettingsStore` 的案例繼續使用 UUID test suites 並在結束時移除 domain。Control Center read-only log 可作為零 test-host status item 的附加 system evidence，但不是一般 unit assertion。

明確重新開啟提供隱藏 App 的可達路徑。requested 為 `false` 且由 Finder／Spotlight／`open` 明確啟動時，delegate 先建立一個 hidden controller，再以 SwiftUI-hosted `NSWindow` 顯示最小復原介面；已在背景執行且 logical visibility 為 `false` 時，公開的 `applicationShouldHandleReopen` callback 也顯示同一介面。復原期間暫時把 `NSApplication.ActivationPolicy` 從 accessory 改為 regular，讓視窗與 Dock 可到達；Show action 同步保存 true 並 force-show 同一個 status item，復原視窗在 shared logical state 變成 visible 後關閉，之後恢復 accessory。使用者在仍隱藏時關閉復原視窗會明確、正常退出，避免留下不可達 process。requested 為 `false` 且 `kAEOpenApplication` Apple Event 含公開的 `keyAELaunchedAsLogInItem` 時，在建立 controller 前安靜退出；requested 為 `true` 的 login-item launch 則走正常建立流程。若未來產品要求隱藏時仍在登入後監看 reset，必須另行改變這項政策，不能由 Milestone C 或未實作的 Reset Intelligence 偷渡。

macOS 26 的 Control Center／「系統設定」→「選單列」仍可在 requested 為 `true` 時阻止實際顯示。QuotaMew 不猜測該 system-managed allowance、不反覆切換 `isVisible`、不寫入 `group.com.apple.controlcenter` 或其他系統偏好，也不使用 private API 或 `defaults` workaround。復原介面只誠實提示使用者必要時到系統設定允許 QuotaMew；自動測試只能驗證 intent、logical visibility、controller／launch policy，不能宣稱驗證 Control Center allowance 或螢幕上的實際可見性。

Provider 停用代表「暫時排除於 QuotaMew 主動監看」，不是刪除 provider。`UsageService` 仍保留 provider 順序與 normalized `.disabled` state，但跳過其 `fetchUsage()`；Dashboard 不顯示 disabled placeholder，其他 providers 繼續依序刷新。全數停用時只顯示一個「No providers enabled」empty state 與原生 `SettingsLink`，Settings 的 toggles 仍可管理並跨 restart 保存。重新啟用不需重啟 App，也不刪除 provider configuration；它會先 re-baseline reset detector，再要求一次共用 refresh，仍經 `RefreshCoordinator` 合併。

背景刷新維持固定約 15 分鐘。動態 interval 會介入已完成的 deadline、retry backoff、sleep/wake 與單一 scheduled task invariant；v0.1 不為 5／15／30 分鐘選項擴大該架構。Settings 只顯示目前固定 cadence。

Claude Code 在 Settings 明確標為 Experimental／Unverified，只有 enable／disable，沒有 bridge 安裝或設定。不得使用 iCloud key-value storage，也不得保存 provider 憑證。

## v0.2 Hybrid migration final status

2026-09-02 的 clean macOS user account 以 Finder／LaunchServices 正常啟動 Release app bundle，確認 QuotaPulse 與 ChatGPT 是獨立的選單列應用程式；隱藏任一者不會影響另一者。主要開發帳號曾觀察到的 ChatGPT → QuotaPulse cascade，分類為歷史、使用者範圍的 macOS Control Center stale application association，源自過往非典型開發／測試啟動拓撲，不是目前 QuotaPulse Release 架構缺陷，也不是正常使用者應遇到的產品行為。不要以程式清除或修復該狀態，不要改 bundle identifier、`autosaveName` 或使用 private Control Center API；人工測試應從 Finder、Spotlight 或 LaunchServices／`open` 啟動 `.app`，不要直接執行 Mach-O。

**Milestone A — COMPLETE / frozen. Milestone B — COMPLETE. Milestone C — NEXT / NOT STARTED.** Automated XCTest、Debug／Release builds、zero status-item host、recovery／reopen、compact width 與 manual acceptance 均已分別驗證；本次不實作 Milestone C。

## 11. Compatibility Diagnostics

Production diagnostics 使用 provider-independent、current-state-only 的 `CompatibilityDiagnosticsSnapshot`。`AppModel` 擁有 last refresh attempt 與目前 `ProviderState`；`UsageService.providerDiagnostics()` 依既有 provider 順序，按需取得每個 adapter 的 `ProviderRuntimeDiagnostic`，但不呼叫 `fetchUsage()`。`SettingsModel` 只保留目前 snapshot 與 copy feedback，不建立診斷歷史。

```swift
protocol UsageProvider: Sendable {
    var id: ProviderID { get }
    func fetchUsage() async throws -> ProviderUsageSnapshot
    func runtimeDiagnostic() async -> ProviderRuntimeDiagnostic
}
```

Provider runtime contract 只允許固定 enum、boolean、經限制的版本字串與 normalized failure category。Codex adapter 可提供 ChatGPT.app 是否存在、經分類的 runtime source、runtime detected、compatibility、app-server connection，以及最後一個 sanitized failure category。SwiftUI 對所有 providers 渲染同一個 `ProviderDiagnosticSnapshot`，不解析 executable URL 或 provider DTO。

Copy Diagnostics 採 **typed allowlist 生成**，不是先 dump object 再 redact。可輸出的 failure categories 只有 `runtimeNotDetected`、`runtimeNotExecutable`、`appServerLaunchFailed`、`appServerConnectionFailed`、`rpcUnavailable`、`usageUnavailable`、`refreshFailed`、`providerDisabled` 與 `notConfigured`。不得輸出 `NSError`、POSIX description、RPC payload、stdout／stderr、完整 executable path、home directory、credential、account identifier、email、prompt、session、source code、project／repository metadata 或 raw provider JSON。

匯出報告固定使用英文，讓 GitHub issue 搜尋、fixture 與跨 locale 維護保持一致；Settings 畫面本身仍使用 English／zh-Hant String Catalog。時間只輸出到 UTC 分鐘，不輸出 exact quota percentage，也不包含 history。ChatGPT.app version 只從已驗證 bundle metadata 按需取得；Codex runtime version 若需額外啟動 process，現階段不取得。

Diagnostics 沒有 timer、observer、filesystem watcher、sampler、telemetry、network request 或 persistence。開啟 Settings／按下 Copy 只建立小型按需 snapshot；它不觸發 quota refresh，也不建立額外 app-server process。Codex locator 仍只回傳 executable URL 給 provider 內部，diagnostics 只接收 `ChatGPT.app`／`Codex.app`／`Standalone Codex` 等安全分類。

## 12. Reset Intelligence domain 與未來 feed 邊界

本機 quota reset detection 已實作；外部官方事件 reader 仍是 **FUTURE**。Milestone A 已凍結 versioned `ResetEventFeed` contract：每份完整 static snapshot 有 `schemaVersion`、absolute `generatedAt` 與不依 array order 的 events。每個 event 以 stable ID、單調 `revision`、provider、typed kind、publisher / source URL、published / retrieved / effective time、audience、verification、display-safe summary，以及 correction / retraction relationship 表示。`DetectedQuotaReset` 仍是本機觀測，永遠不能為了共用 model 而虛構 publisher 或 URL。

未來資料流固定為：

```text
Static trusted feed
    -> ResetEventSource
    -> ResetEventService (future; sole fetch/cache owner)
    -> validated, bounded ResetEventFeed / ResetEvent
    -> future presentation and local-only matching
```

此路徑獨立於 `UsageProvider`、`UsageService`、`RefreshCoordinator`、Codex app-server 與 Claude snapshot reader。future service 的 feed failure、cache miss 或 validation rejection 都不得阻礙本機 quota refresh，也不得產生新的 provider refresh、timer、polling loop 或 long-running task。v1 採 atomic rejection：future schema、unknown kind/provider、malformed timestamp/URL、duplicate ID、revision regression、超量 payload 或無效 relationship 全部拒絕候選 snapshot，保留 last-known-good state。沒有 per-event partial acceptance。

Revision 更新以同 ID 的較高 revision 取代舊表示；`correction` / `retraction` 只可單層指向同 provider 的普通原始 event，避免 chain/cycle。未來 notification dedup 必須使用 event ID + revision，並另外定義已送出 history 的 correction/retraction policy。本階段不實作通知行為。

`SettingsStore` 的純本機 v0.2 persisted presentation contract 是 `remaining` / `used`（預設 `remaining`）與 optional pinned provider raw value。`SettingsModel` 在啟動時建立這兩項偏好的唯一 runtime-observable projection；Settings action 會同步保存到 `SettingsStore` 並更新同一個 model。`StatusItemController` 直接觀察該 shared model，更新 standard status button 的 icon、compact metric 與 accessibility metadata；SwiftUI popover content 也使用同一份 models，不複製 state。`UsagePresentation` 是唯一的 display projection：它從同一個 normalized `UsageWindow` 導出 rounded remaining 或 used percentage，絕不寫回 domain、reset detector 或 notification policy。Dashboard 的主要 percentage、VoiceOver value 與選單列共享它；進度與通知仍保留既有 used／remaining semantics。`MenuBarPresentation` 明確區分 persisted pinned provider、selected provider、currently rendered provider 與 renderability：known explicit pin 只呈現該 provider 的可用 snapshot；loading/stale cached snapshot 可保留一個數字，disabled、unavailable、unknown future pin 或沒有可用資料時顯示固定 unavailable placeholder，絕不暗中切到另一個 provider。無 pin 時只依既有 provider order 選擇第一個 enabled/renderable provider，且不寫回 preference。General／Providers／Notifications 已是唯一 Settings IA。

不得將 social-media credential 放入 App，不得在 App 內爬取 X/Twitter 或呼叫 AI model。static feed 與未來 request 不得含本機 usage snapshot、prompt、repository、path、session、帳號或程式開發歷史。詳細 schema、governance、limits、migration 與 privacy policy 見 [docs/RESET_INTELLIGENCE_FEED.md](docs/RESET_INTELLIGENCE_FEED.md)。

## 13. Milestone 1 檔案結構

```text
QuotaMew.xcodeproj/
QuotaMew/
├── App/
│   ├── QuotaMewApp.swift
│   ├── AppModel.swift
│   └── AppDependencies.swift
├── Domain/
│   ├── ProviderID.swift
│   ├── ProviderStatus.swift
│   ├── ProviderUsageSnapshot.swift
│   ├── ResetEvent.swift
│   ├── ResetCountdown.swift
│   ├── UsageSource.swift
│   └── UsageWindow.swift
├── Diagnostics/
│   ├── CompatibilityDiagnostics.swift
│   └── RuntimeDiagnostics.swift
├── Providers/
│   ├── UsageProvider.swift
│   ├── Mock/
│   │   └── MockUsageProvider.swift
│   ├── Codex/
│       ├── CodexProvider.swift
│       ├── CodexAppServerClient.swift
│       ├── CodexExecutableLocator.swift
│       └── CodexDTO.swift
│   └── Claude/
│       ├── ClaudeProvider.swift
│       ├── ClaudeSnapshotDTO.swift
│       └── ClaudeSnapshotReader.swift
├── Services/
│   ├── UsageService.swift
│   ├── RefreshCoordinator.swift
│   ├── ResetNotificationPolicy.swift
│   ├── LocalResetDetector.swift
│   ├── NotificationService.swift
│   ├── SettingsStore.swift
│   └── LaunchAtLoginController.swift
└── Features/
    ├── MenuBar/
    │   ├── DashboardView.swift
    │   ├── StatusItemController.swift
    │   ├── ProviderCardView.swift
    │   ├── UsageWindowRow.swift
    │   └── ProviderStateView.swift
    └── Settings/
        ├── ProviderDiagnosticsView.swift
        ├── SettingsModel.swift
        └── SettingsView.swift
QuotaMewTests/
├── App/
├── Diagnostics/
├── Domain/
├── Providers/
└── Services/
```

Codex 與 Claude provider cores 已透過共用應用程式架構接入，且 Codex 已完成本機 live runtime 與 release lifecycle validation。Codex 已將 executable 缺少映射為 `notInstalled`、launch failure 映射為 `runtimeLaunchFailed`、無可用 window 映射為 `usageUnavailable`，其餘 app-server failure 映射為 `refreshFailed`；這些狀態都不含原始 provider payload。因官方尚未定義各 authentication failure 的穩定 error shape，目前不猜測 `unsupportedAuthentication`。Claude snapshot 缺少映射為 `notConfigured`，UI 固定標示為 `Experimental`／`Unverified`，直到完成 bridge 與正式訂閱帳號驗證。Milestone 3 尚須完成明確 opt-in 的 status-line bridge、既有 command 保留／復原與 live fixture validation。不要為了對齊架構圖，預先加入空的未來 service 或 provider。

## 14. 測試與驗證

Milestone 1 自動測試涵蓋：

- 百分比正規化與剩餘百分比
- 過期、缺少、分鐘、時數與天數倒數格式
- 重複刷新合併
- 啟動與 15 分鐘 scheduled refresh、3 分鐘 menu stale threshold、手動／自動重疊合併
- 1／2／5／15／30 分鐘 failure backoff 與成功後恢復正常週期
- 反覆 menu open、sleep／wake 與 App activation 不累積 refresh schedules
- enabled／disabled Dashboard projection、全數停用單一 empty state，以及 Settings toggle 的同步可見性與 restart persistence
- disabled provider 在 startup、scheduled background 與 manual refresh 都不進入 adapter I/O；重新啟用後可立即、非重疊地恢復共用 refresh
- 倒數時間推進不讀取 provider
- 以注入 service 驗證通知 action
- Codex single/multi-bucket mapping、缺少 window 與不猜測 percentage
- Codex availability、last-updated、reset timestamp、sanitized provider failure 與 missing executable 狀態
- app-server 正常、健康 connection 重用、重疊讀取合併、失敗重連、child reap、handle cleanup、缺欄位與 malformed response、stdout 上限、timeout 與 process termination
- Claude five-hour/seven-day mapping、independently missing window 與不猜測 percentage/reset time
- Claude snapshot missing、malformed/partial、oversized、future-schema 與 stale capture metadata
- 多 provider 順序、逐一失敗隔離、兩者同時 unavailable、每次刷新重新 fetch 與 provider/snapshot identity 一致性
- `AppModel` loading transition，以及全數 unavailable 時不虛構成功更新時間
- provider presentation 的 available／loading／unavailable／not detected／not configured／refresh failure／cached failure／missing reset／stale／Claude experimental 狀態，以及 user-facing 文案不洩漏內部錯誤
- 5 小時與 7 天 genuine reset transition、純 percentage 修正、stale/missing/out-of-order snapshot、provider 獨立性、同 cycle 去重與下一 cycle
- completed-reset 通知在地化、同 process 最多一次，以及以 persisted state 驗證 app restart 不重複送出或產生 false reset
- provider-scoped pending notification cleanup、disabled provider notification exclusion、disable／enable rapid-transition generation invalidation、persisted generation 的 restart reconciliation、cleanup task boundedness，以及重新啟用只建立 reset baseline、不誤送 completed-reset
- refresh in-flight 時啟用 provider 的單一 follow-up、重複 enable signal 合併、停用時丟棄 stale completion，以及 provider 間互不影響
- `ResetEvent` Codable round trip、原始 source URL 保留與事件種類可區分性
- 最新刷新失敗時保留上一份有效的記憶體內 snapshot 與成功更新時間
- compatibility diagnostics 的 healthy、runtime missing、disabled、connection failure、usage unavailable、last-refresh failure、provider independence 與 current-state bound
- Copy Diagnostics allowlist 與刻意含 credential／prompt／session／email／private path／raw JSON 的 privacy regression fixtures
- status item 新安裝預設、requested-state persistence、KVO callback 不覆寫 intent、create-once／100 次 hide-show／teardown、XCTest no-create boundary，以及 explicit／reopen／login-item recovery policy

後續 provider 工作還需要測試 app-server request/response correlation、正式 Claude status-line fixtures、bridge atomic write 與 permissions、existing-command composition、settings migration，以及各支援版本與 authentication modes 的 live behavior。

公開 v0.1 的剩餘人工檢查以 `docs/RELEASE_CHECKLIST.md` 為準。Production App Icon 已完成資產整合與建置驗證；Developer ID、Hardened Runtime 與 notarization 仍明確延後。未來聲稱完成正式散布前，仍須在最終 artifact 驗證簽章、Gatekeeper、通知、Launch at Login、child process 與長時間 runtime 行為。

編譯與 fixture 測試不能證明即時 Codex/Claude 整合、系統通知實際送達、notarization、記憶體目標或外部散布。回報時必須分開列出各種驗證。

## 15. 待決事項與不確定性

1. 確認是否長期維持 macOS 14 為最低支援版本。
2. 完成目前延後的 Developer ID／notarized distribution 驗證，以及確認是否有意不啟用 App Sandbox。
3. 決定是否仍需要 GUI executable override；目前已支援 ChatGPT.app 整合 runtime、舊 Codex.app、常見 CLI locations 與 GUI process 繼承的 `PATH`，但不載入 interactive shell 設定。
4. 實測支援的 Codex versions 與 authentication modes 對 app-server 的相容性。
5. 決定 QuotaMew 是否修改 Claude settings，或只產生 opt-in bridge 說明。
6. 定義現有 Claude status-line command 的保留與復原方式。
7. 依實際使用回饋確認目前 15 分鐘 presentation freshness label 門檻是否需要調整。
8. 依 `docs/PERFORMANCE.md` 量測長駐健康 app-server、重複刷新與重連是否符合延遲、記憶體、CPU、file descriptor 與 task 目標。
9. 承諾散布方式前，驗證 signing、hardened runtime 與 child-process 行為。
10. macOS 26 Control Center 的 system-managed menu bar allowance 沒有公開查詢 API；正式散布 artifact 仍需以獨立 bundle identifier 驗證正常顯示、移除、明確重啟復原與 login-item quiet exit。

這些都是明確的後續里程碑，不得藏在 provider implementation 裡當成已成立的假設。
