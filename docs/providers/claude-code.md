# Claude Code 用量資料探索

> 歷史研究紀錄（2026-08-26）。目前契約與實作決策以 [2026-10-05 Claude Provider Foundation](../CLAUDE_PROVIDER_FOUNDATION.md) 為準。本機另有 native `2.1.246`，舊版唯一安裝的推論已過時；目前 auth probe 回報未登入，仍無 live quota 證明。下文「invalid percentage 不產生 window」比實際程式保證更強：finite 超範圍值目前會保留並被 display clamp。最新 status-line 文件也有 idle reset expiry trigger 與 gateway 欄位；不得把 capture time 當成服務 freshness，或直接沿用現有通知／帳號連續性假設。

狀態：2026-08-26 完成本機隱私安全探索、`ClaudeProvider` snapshot reader core 與共用應用程式串接。Production `AppDependencies` 已透過 `UsageProvider` 使用此 provider；尚未安裝 status-line bridge，也沒有修改既有 Claude Code 設定。

## 結論

Claude Code 有文件化、可取得實際訂閱額度百分比與重設時間的本機整合介面：custom status line 的 stdin JSON。

[Claude Code status-line 官方文件](https://code.claude.com/docs/en/statusline) 定義：

- `rate_limits.five_hour.used_percentage`
- `rate_limits.five_hour.resets_at`
- `rate_limits.seven_day.used_percentage`
- `rate_limits.seven_day.resets_at`

`used_percentage` 是 0 到 100 的已使用比例；`resets_at` 是 Unix epoch seconds。`five_hour` 是 5-hour rolling window，`seven_day` 是 weekly window。

這個介面屬於「有條件可靠」而非隨時可查詢的 API：

- `rate_limits` 只為 Claude.ai Pro/Max 訂閱者所文件化
- 必須在 session 第一次 API response 後才可能出現
- `five_hour` 與 `seven_day` 可各自缺少
- 更新跟著 status-line event 發生；Claude Code 閒置時資料會變舊
- status-line command 必須先通過 workspace trust
- Claude Code 2.1.80 changelog 才加入這組欄位
- Anthropic 官方 repository 仍有新版本缺少 `rate_limits` 的公開 bug reports，因此 QuotaMew 必須把缺欄位視為 unavailable，不能推估

沒有找到文件化的非互動 `claude usage --json`、本機 daemon query、公開訂閱 quota API，或可安全供第三方 App 重用的 authenticated endpoint。

因此 v0.1 的合理設計是：由使用者明確同意的 status-line bridge，只把四個文件化 rate-limit values、capture time、snapshot schema version 與可選的 Claude Code version 寫進 QuotaMew 自有小型 snapshot。`ClaudeProvider` 只讀該 snapshot，不讀 Claude Code transcripts、history、credentials 或 internal caches。

## 探索方法與隱私限制

本次只進行：

- 已知設定、state、stats、history、projects 與 debug paths 的存在性、類型、大小與權限檢查
- `settings.json` 的 JSON validity、root key count 與 `statusLine` 結構存在性
- `stats-cache.json` 的 root metadata key names 與是否有 quota-related root keys
- session JSONL 的檔案數量與檔案大小 aggregate，不讀任何一行
- 已安裝 npm package 的 package name、version 與 Node engine metadata
- 官方文件、官方 changelog 與官方 repository issue 的 contract 查證

本次沒有讀取或輸出：

- prompt、assistant response 或 conversation contents
- 原始碼、tool output、workspace path、repository identity 或 session name
- `history.jsonl` 內容或任何 `projects/**/*.jsonl` 行
- authentication token、OAuth state、API key、credential helper value 或 Keychain item
- status-line command value 或 script 內容
- 實際個人用量百分比與 reset timestamp

## 本機安裝與設定

### Claude Code executable 與版本

本機存在常見位置的 Claude Code npm launcher。package metadata 顯示版本為 `1.0.43`。

官方 changelog 記錄 `rate_limits` status-line fields 從 `2.1.80` 才加入，因此本機這個舊版本不能視為支援本次 contract。QuotaMew 未嘗試升級、登入或啟動互動 session。

本機 `CLAUDE_CONFIG_DIR` 未設定，所以官方預設的 `~/.claude` 與 `~/.claude.json` locations 適用。若使用者設定 `CLAUDE_CONFIG_DIR`，Claude Code 會把 settings、session history 與 plugins 移到該位置；未來 bridge setup 必須尊重這個設定，但 provider 本身只應讀 legacy QuotaPulse-owned snapshot。

### `~/.claude/settings.json`

官方文件把它定義為 user settings。Project shared 與 local settings 還可能來自 `.claude/settings.json`、`.claude/settings.local.json`，另有 managed settings precedence。

本機 user settings：

- 是有效 JSON
- root 有 9 個 keys
- 已存在 object 型別的 `statusLine`
- `statusLine.command` 已設定
- 沒有設定 `statusLine.refreshInterval`

本次沒有讀取或輸出 command value。

判定：

- 設定位置與 `statusLine` contract 有官方文件，可依賴
- 既有 command 屬於使用者工作流程，QuotaMew 絕不能靜默取代
- status-line setup 必須能 preview、保留、組合或讓使用者自行整合，並提供可復原方式
- 本次只偵測，不修改任何設定

### `~/.claude.json`

官方設定文件說明這是 Claude Code 自行維護的 global state，包含 sign-in session、MCP server configurations、per-project trust state 與 global config keys。

本機檔案存在，約 93 KiB。本次只讀取 stat metadata，沒有解析 JSON。

判定：

- 不是 quota contract
- 可能包含 authentication 與私密 project metadata
- `ClaudeProvider` 永不讀取

### Credential storage

本機已知的 `~/.claude/.credentials.json` 不存在，但 credential 也可能由其他官方機制管理。不存在特定檔案不代表沒有登入狀態。

判定：

- 不搜尋 Keychain 或其他 credential locations
- 不讀 token、API key、OAuth state 或 credential helper result
- 不直接呼叫未文件化 Claude.ai usage endpoint

## 本機 session 與 metadata

### `~/.claude/projects/**/*.jsonl`

本機有 106 個 JSONL files，合計約 87.5 MiB，最大單檔約 32.6 MiB。本次只統計檔案數量與大小，`contents_read=false`。

這些檔案是 transcript/session persistence，可能包含 prompt、response、tool result、workspace 與 repository metadata。即使部分版本可能在 event 或 API response metadata 中留下 rate-limit clues，也不是文件化 subscription-quota contract。

判定：

- 不解析、不 tail、不全文搜尋
- 不作為 fallback
- 不由 token totals 推算方案百分比
- 這也避免掃描近 90 MiB 私密資料與造成不必要 I/O

### `~/.claude/history.jsonl`

本機檔案存在，約 309 KiB。它可能包含 prompt history，因此本次沒有讀取任何內容。

判定：不相關，永不使用。

### `~/.claude/stats-cache.json`

本機檔案存在，約 14 KiB，權限為 `0600`。Schema-only 檢查找到：

- `dailyActivity`
- `dailyModelTokens`
- `firstSessionDate`
- `hourCounts`
- `lastComputedDate`
- `longestSession`
- `modelUsage`
- `totalMessages`
- `totalSessions`
- `version`

root 沒有名稱包含 rate、limit、quota 或 reset 的 key。

官方 `/usage` 文件也區分 plan usage bars 與依本機 session history 計算的 activity breakdown。Token/activity statistics 不能可靠重建 Claude.ai subscription quota，因為其他裝置、claude.ai 與 provider-side weighting 都不在本機統計內。

判定：不作為 quota source，也不由它推算百分比。

### Debug logs 與 `usage-data`

本機 debug directory 存在，但沒有讀取檔名或內容。`/insights` 可建立包含工作模式分析的 `~/.claude/usage-data/report.html`，這不是 quota contract，而且可能含敏感的工作行為摘要。

判定：不讀取 logs 或 reports。

## 文件化查詢介面評估

### Status-line stdin JSON：採用

Claude Code 在特定 session events 後執行 configured status-line command，透過 stdin 傳入 JSON。這個 command 在本機執行，本身不消耗 API tokens。

優點：

- quota fields 與語意有官方文件
- 不需要 QuotaMew 取得 authentication secrets
- 可以在 bridge 邊界立刻捨棄所有非 quota fields
- event-driven，不需要掃描 transcripts 或積極輪詢

限制：

- 不是 pull API，無法由 QuotaMew 隨時要求新資料
- first API response 之前沒有資料
- Claude Code 閒置時 snapshot 可能 stale
- 每個 window 可以缺少
- eligibility 與實際 field delivery 可能因 plan、version、authentication mode 或 bug 而不同
- 現有 status-line command 的相容與復原需要獨立 UX

### `/usage`、`/cost`、`/stats`：不作為 machine source

官方文件說明 `/usage` 顯示 session cost、plan usage limits、activity stats 與 plan usage bars；`/cost`、`/stats` 是 aliases。當 plan usage request 失敗時，新版 Claude Code 可顯示 60 分鐘內 last-known bars。

但這些是 interactive TUI commands。CLI reference 沒有 `claude usage --json` 或讓第三方程式取得 plan bars 的非互動 flag。Screen scraping 會受版本、終端寬度、顏色與文案影響，也可能意外擷取 account metadata。

判定：只供使用者人工比對，不解析畫面。

### Agent SDK `RateLimitEvent`：不作為被動 quota query

官方 Agent SDK 定義 `RateLimitEvent`／`RateLimitInfo`，可能含：

- `rate_limit_type`
- `utilization`（0.0 到 1.0）
- `resets_at`
- `status`
- overage state

但它是執行 Agent SDK session 時的事件，不是獨立 current-usage query。為了等事件而啟動 agent 可能需要 authentication、發出 API request、消耗額度並產生 conversation output。

判定：不為被動 menu bar monitor 啟動 Agent SDK session。

### Claude.ai usage page 與 authenticated endpoint：不直接使用

官方文件會把使用者導向 Claude.ai usage/settings 頁面，但沒有提供第三方 App 可使用的 subscription-usage public API contract。

Anthropic 的 authentication 文件也明確區分 Claude.ai subscription OAuth 與第三方產品應使用的 API-key用途。QuotaMew 不應重用 Claude Code OAuth credential、模擬 claude.ai login 或 reverse-engineer internal endpoint。

判定：沒有 backend、沒有 web scraping、沒有 credential access、沒有 undocumented HTTP request。

## 穩定性分類

| 來源 | 實際百分比／reset | 文件化程度 | 隱私與可靠性 | 決策 |
| --- | --- | --- | --- | --- |
| status-line `rate_limits` | 是 | 官方文件化 | 低隱私風險；但 event-driven、條件式且有缺欄位回報 | opt-in bridge 的主要來源 |
| `/usage` TUI | 是 | 官方 interactive command | machine parsing 脆弱，可能含其他 account/activity data | 只供人工確認 |
| Agent SDK `RateLimitEvent` | 有時有 | 官方 SDK event | 需要 active agent session，不是 query | 不使用 |
| `stats-cache.json` | 否 | internal local stats | 不含跨裝置 plan quota | 不使用 |
| `projects/**/*.jsonl` | 未承諾 | internal transcript | 極高隱私風險、檔案可能很大 | 永不掃描 |
| `history.jsonl` | 否 | prompt history | 極高隱私風險 | 永不讀取 |
| `~/.claude.json`／credentials | authentication/state only | internal | 極高隱私風險 | 永不讀取 |
| Claude.ai internal endpoint | 可能 | 未公開 | credential、政策與相容性風險 | 不使用 |

## 已實作的 `ClaudeProvider`

這次加入 provider core，但沒有 bridge installer、UI wiring 或 settings mutation：

- `ClaudeSnapshotReader` 只讀 legacy QuotaPulse-owned `usage-v1.json`
- 預設位置為 user Application Support 下的 legacy `QuotaPulse/Providers/Claude/usage-v1.json`
- snapshot 上限為 16 KiB
- 只支援明確的 `schemaVersion: 1`
- `capturedAt` 使用 ISO 8601，讓 stale policy 有可靠基準
- 只模型化 `fiveHour`、`sevenDay`、可選的 Claude Code version 與 capture metadata
- unknown fields 由 decoder 捨棄，不進入 domain model
- independently missing window 會被省略，不補 0%
- invalid percentage 不會產生 window
- 缺少或 invalid reset timestamp 保持 `nil`，不虛構時間
- provider 保留原始有限 percentage；既有 display domain 才限制在 0...100
- 5-hour 與 7-day durations 只來自官方固定 window 語意
- missing、unreadable、oversized、malformed、partial 與 future-schema snapshots 都會安全失敗
- `capturedAt` 原樣保留；provider 不把舊資料宣稱為 fresh
- production `AppDependencies` 使用 `ClaudeProvider`；SwiftUI previews 使用 `MockUsageProvider.claude`
- UI 固定以 `Experimental` 標籤呈現 Claude Code，直到 bridge 與正式訂閱帳號 live validation 完成

legacy QuotaPulse-owned schema：

```json
{
  "schemaVersion": 1,
  "capturedAt": "2033-05-18T03:33:20Z",
  "claudeCodeVersion": "2.1.80",
  "rateLimits": {
    "fiveHour": {
      "usedPercentage": 23.5,
      "resetsAt": 2000003600
    },
    "sevenDay": {
      "usedPercentage": 41.2,
      "resetsAt": 2000604800
    }
  }
}
```

上例是 redacted synthetic fixture，不是本機實際額度。

## 尚未實作的 bridge

本次刻意沒有修改本機已存在的 status-line command，也沒有建立 executable bridge target。Provider core 只有在明確安裝、測試過的 bridge 寫出 snapshot 後才會有資料。

後續 bridge 必須：

1. 由使用者明確啟用。
2. 顯示目前設定來源與完整變更預覽，但不得顯示 credential。
3. 不覆寫既有 command；採使用者選擇的 wrapper、composition 或人工整合方式。
4. stdin 設定嚴格大小上限。
5. decode 後只保留四個 quota values、Claude Code version 與 capture time。
6. 不保存 `cwd`、workspace、repository、transcript path、session ID、prompt ID、model、cost、token、git、PR、worktree 或 unknown fields。
7. 以 owner-only directory 與 atomic replace 寫 snapshot。
8. 保留可復原的設定備份與 uninstall 流程。
9. 檢查 Claude Code 版本至少具有文件化 contract，但仍允許欄位缺失安全失敗。

## Fallback policy

建議順序：

1. 讀取 legacy QuotaPulse-owned snapshot。
2. 沒有 snapshot：顯示 `notConfigured`，提供 opt-in bridge 說明。
3. snapshot schema 不支援或內容錯誤：顯示 unavailable/failed，不讀 Claude internal files。
4. snapshot 太舊：保留 last-known values 並明確標示 stale。
5. reset time 已過：仍標示 stale，不假設額度已重設為 0%。
6. 任一 window 缺少：只顯示實際存在的 window。
7. 兩個 windows 都缺少：顯示 unavailable；不得由 tokens、activity 或 plan name 推算。
8. 不 fallback 到 `/usage` screen scraping、session JSONL、history、stats cache 或 credential-backed endpoint。

## 尚待驗證

- Claude Code 2.1.80 以上正式支援版本的真實 status-line fixture
- Pro、Max、Team、Enterprise、API key 與 cloud-provider modes 的 field availability
- 官方已知缺欄位情境與 error/status UX
- existing status-line command 的 wrapper/composition 方案
- bridge executable 的 signing、安裝位置、sandbox、workspace trust 與 cleanup
- snapshot atomic-write、permissions、symlink 與 race-condition hardening
- 15 分鐘 presentation stale threshold 的實際使用回饋
- 乾淨 profile、已有 status line 與 managed settings 的安裝／復原測試

## 官方參考來源

- [Customize your status line](https://code.claude.com/docs/en/statusline)
- [Commands：`/usage`](https://code.claude.com/docs/en/commands)
- [Manage costs effectively](https://code.claude.com/docs/en/costs)
- [Claude Code settings](https://code.claude.com/docs/en/settings)
- [CLI reference](https://code.claude.com/docs/en/cli-usage)
- [Agent SDK Python reference：`RateLimitEvent`](https://code.claude.com/docs/en/agent-sdk/python)
- [Claude Code changelog](https://github.com/anthropics/claude-code/blob/main/CHANGELOG.md)
- [Claude Code authentication and credential use](https://code.claude.com/docs/en/legal-and-compliance)
- [Public status-line missing-field report](https://github.com/anthropics/claude-code/issues/86169)
