# Codex 用量資料探索

狀態：2026-09-28 已驗證 ChatGPT.app 的新 `codex-cli` 套件版面，並保留舊 bundled runtime 與獨立 CLI 探索。Production `AppDependencies` 已透過 `UsageProvider` 使用此 provider；SwiftUI previews 仍使用 mock 資料。

## 結論

Codex 的實際額度百分比、額度視窗長度與下次重設時間可以可靠取得，但首選來源不是直接讀取 `~/.codex` 檔案，而是官方 [Codex App Server](https://learn.chatgpt.com/docs/app-server) 的 `account/rateLimits/read`。

此 method 回傳：

- `usedPercent`
- `windowDurationMins`
- `resetsAt`（Unix timestamp，單位為秒）
- backward-compatible 的 `rateLimits` single-bucket view
- 可用時的 `rateLimitsByLimitId` multi-bucket view

本機 Codex process 負責現有 authentication。QuotaMew 不需要、也不得讀取或複製 `~/.codex/auth.json`。這個作法仍需要可用的 Codex authentication 與網路；它不是離線額度資料庫。

## Executable discovery

探索順序如下，不遞迴掃描磁碟，也不使用 shell 搜尋；新套件提供的入口本身可能是 shell launcher：

1. `/Applications/ChatGPT.app`：先從 `Contents/Resources/codex-cli/codex-package.json` 取得經驗證的相對 `entrypoint`，再試已知的 `codex-cli/bin/codex`，最後試舊版 `Contents/Resources/codex`
2. `~/Applications/ChatGPT.app`：使用同一套套件與舊版候選順序
3. 由 `NSWorkspace` 以 `com.openai.codex` 找到的非標準位置 `ChatGPT.app`：使用同一套候選順序
4. `/Applications/Codex.app/Contents/Resources/codex` 與 `~/Applications/Codex.app/Contents/Resources/codex`，作為舊版相容性 fallback
5. 由同一個 `NSWorkspace` 查詢結果辨識的非標準位置舊 `Codex.app`
6. `/opt/homebrew/bin/codex`、`/usr/local/bin/codex`、`~/.local/bin/codex`、`~/.bun/bin/codex`
7. GUI process 實際繼承之 `PATH` 裡的絕對路徑

Desktop 候選必須解析為名為 `ChatGPT.app` 或 `Codex.app`、bundle identifier 為 `com.openai.codex` 的 bundle；因兩者目前共用 identifier，identifier 只作為 `NSWorkspace` lookup hint，不能單獨視為可信身分。其 bundled binary 與所有 CLI 候選都必須解析 symlink 後為一般可執行檔，且其路徑祖先不可由不受信任帳號或 everyone 寫入。套件 manifest 最多讀取 4 KiB；僅接受已理解的 layout version 與 `codex` variant，入口必須是無絕對路徑、`..`、空 segment 或 NUL 的相對路徑，解析後仍位於受信任套件目錄內。manifest 缺少、無效或指向不可執行檔時，仍逐一驗證已知套件入口與舊版入口。成功來源只在 process memory 中快取，每次使用前重新驗證；app 被移動、刪除、更新後改變 runtime，或 binary 失去執行權限時會重新解析或走完整探索。有效快取不會在每次 quota refresh 重複查詢 `NSWorkspace`。找不到時維持 `notInstalled`；已偵測到 host app 時，Diagnostics 另以「Runtime unavailable／Runtime not detected」標示 runtime 問題。

QuotaMew 把所有 runtime 探索保留在同一個 locator，並共用 bundle 身分、一般檔案、symlink、路徑權限、受限 `PATH`、快取及 stale recovery 驗證；沒有在 app-server client 內建立第二套 discovery。

歷史本機 ChatGPT `26.818.61809` 的簽章 bundle 內含 arm64 `Contents/Resources/codex`，版本為 `codex-cli 0.149.0-alpha.4.3`。2026-09-28 本機 ChatGPT `26.924.22138`（build `11645`）已無此舊檔；新的 `Contents/Resources/codex-cli/codex-package.json` 宣告 layout version `1`、variant `codex`、`entrypoint: bin/codex`、target `aarch64-apple-darwin`、version `0.158.0-alpha.2.1`、`resourcesDir: codex-resources` 與 `pathDir: codex-path`。`bin/codex` 是 shell launcher，以 `exec` 啟動套件內 `CodexCLI.app/Contents/MacOS/codex`。它在本機可完成 app-server request。這些 bundle 內路徑是經驗證的封裝候選，**不是 OpenAI 承諾維持的公開 API**；定位器仍保留舊 Codex.app、standalone CLI 與安全 `PATH` fallback。

## 探索方法與隱私限制

本次只進行下列只讀檢查：

- 目錄名稱、檔案類型、大小、權限與修改時間
- `config.toml` 的 section 與 key 名稱，不讀取或輸出 value
- JSONL 的 event type、key path、資料型別與 aggregate counts
- SQLite table 與 column schema，不查詢 row body
- app-server response 的 key、型別、bucket 數量與欄位存在性

沒有輸出或保存 prompt、原始碼、conversation、thread name、workspace path、repository identity、token、secret、credential 或實際個人額度數值。

## 本機檔案評估

### `~/.codex/config.toml`

用途：Codex 的使用者設定。CLI help 明確指出這是預設 config path，因此「設定位置」可視為相對穩定。

本機觀察：設定 keys 涵蓋 model、sandbox、features、desktop 與 integrations，但沒有文件化的 quota、usage percentage 或 reset timestamp key。

判定：

- 可用來理解 Codex 設定位置
- 不可作為額度來源
- 不應把整份設定內容寫入 log，因為 integrations 可能帶有 command、environment 或本機 path

### `~/.codex/auth.json`

用途：Codex-managed authentication material。

本次只確認檔案存在且權限受限，未讀取內容。

判定：

- 絕對不可作為 QuotaMew 資料來源
- 不得解析、複製、監看或上傳
- authentication 應完全交由 `codex app-server` 管理

### `~/.codex/sessions/**/*.jsonl`

本機 schema-only 掃描確認，`event_msg/token_count` event 可能包含：

```text
payload.rate_limits.primary.used_percent
payload.rate_limits.primary.window_minutes
payload.rate_limits.primary.resets_at
payload.rate_limits.secondary
payload.rate_limits.plan_type
```

本機樣本共有 95 個 active/archived session files，其中 75 個含 rate-limit event；最大單檔超過 49 MiB。樣本中的 3,930 筆 rate-limit records 都有 primary window，但沒有 secondary window。絕大部分舊 reset timestamp 已過期，只有目前活動 session 的 event 保持新鮮。

這些數字只描述本次本機樣本，不是 Codex contract，也不能推論所有安裝或方案都相同。

判定：

- actual percentage 與 reset timestamp 確實可能落地
- persisted event schema 沒有在官方 app-server 文件中承諾
- event 只會跟著 session activity 更新，可能缺少、過期或位於 archived session
- 同一檔案包含 prompt、tool output 與其他私密 conversation data
- 掃描大量 session 檔違反 QuotaMew 的資料最小化與效能目標
- 不實作為預設 fallback

### `~/.codex/session_index.jsonl`

本機 schema 包含 `id`、`thread_name`、`updated_at`，沒有 quota fields。`thread_name` 可能包含私密 conversation metadata，因此不應讀取內容。

判定：不相關，拒絕使用。

### 本機 logs SQLite

本機 log database 的 schema 只有時間、level、target、module/file metadata 與通用 body 欄位，沒有專用 quota、rate-limit、usage 或 reset columns。通用 log body 可能包含私密或未來版本才理解的內容。

判定：

- 沒有穩定 quota schema
- 不掃描 log body
- 不作為 fallback

### state、thread-history 與其他 SQLite databases

Schema-only 搜尋沒有找到專用 quota、rate-limit、usage 或 reset columns。這些 databases 主要管理 thread、project、timeline、automation 或 application state。

判定：不相關，拒絕使用。

### `models_cache.json`、installation metadata 與 application caches

用途與 model catalog、安裝或 App cache 有關，不是 account quota contract。

判定：不相關，拒絕使用。

## 穩定性分類

| 來源 | 是否有實際額度 | 穩定性 | 隱私風險 | 決策 |
| --- | --- | --- | --- | --- |
| `account/rateLimits/read` | 是 | 官方文件化 | 低；Codex 自行處理 authentication | 主要來源 |
| `config.toml` | 否 | path 相對穩定 | 中；可能含本機 integration 設定 | 不使用 |
| `auth.json` | authentication only | 不適用 | 極高 | 永不讀取 |
| session JSONL `rate_limits` | 有時有 | 未文件化、event-driven、可能過期 | 極高；與 conversation data 混存 | 預設停用 |
| `session_index.jsonl` | 否 | internal | 高；含 thread metadata | 不使用 |
| logs SQLite | 沒有專用 schema | internal | 高；通用 body | 不使用 |
| state/history SQLite | 未發現 | internal | 高；thread/project state | 不使用 |

## Authenticated endpoint 是否必要

是。`account/rateLimits/read` 是本機 app-server protocol method，但資料代表 ChatGPT account rate limits，必須由 Codex 使用其現有 authentication 向服務取得。QuotaMew 不應自行呼叫未文件化 HTTP endpoint，也不應讀取 token 後組裝 request。

應區分：

- app-server 可執行檔存在，但使用者未登入
- authentication mode 不提供 ChatGPT rate-limit windows
- 網路或服務暫時不可用
- app-server protocol/version 不相容
- response 合法但沒有可用 window

在任何情況下都不能把「無資料」顯示成 0% usage 或虛構 reset time。

## 本機 protocol 驗證

歷史上曾以當時安裝的 ChatGPT.app bundled Codex binary `codex-cli 0.149.0-alpha.4.3` 做 sanitized live probe；2026-09-28 再以目前套件宣告的 `bin/codex`（`codex-cli 0.158.0-alpha.2.1`）執行同一流程：

1. 啟動 `codex app-server`
2. 傳送 stable `initialize`
3. 傳送 `initialized`
4. 傳送 `account/rateLimits/read`
5. 只檢查 response keys 與 types
6. 關閉 process，不輸出實際 quota values

目前套件的 request 成功，`rateLimits` 與 `rateLimitsByLimitId` 均存在，且回傳有效的 window 欄位型別；正式 opt-in `CodexProvider().fetchUsage()` 測試取得兩個有效 windows。探測僅記錄 schema、型別與數量，不輸出私人額度或帳號值。這只證明本機版本與 authentication 在測試當下可用，不代表所有 Codex versions 或 auth modes 都已驗證。

Production app assembly 的本機驗證也成功：locator 選到 ChatGPT.app runtime，`CodexProvider` 產生含兩個有效 windows 的 `ProviderUsageSnapshot`，共用 UI 顯示實際 usage 與 reset 資料。現行單一 child、健康 connection 重用、重連與 reap 已由 process-boundary tests 驗證，並完成 `docs/PERFORMANCE.md` 記錄的一小時 Release runtime 測試。這只代表該次環境與觀察期間；更長的 8／24 小時 soak 仍可作為後續信心檢查。這項範圍不包含其他 Codex／ChatGPT 開發工具為自身工作而啟動的 app-server。

ChatGPT.app bundle 內的 Codex binary path 屬於 packaging detail，官方文件沒有承諾第三方 App 可永久依賴該位置。Production locator 現在把它視為首選候選，但不盲目信任或複製 binary；每次使用前都會重新驗證，若 app 被移動、更新後改變 runtime 或候選失效，就回到完整 discovery。舊 Codex.app 保留為相容性來源。

## 已實作的 `CodexProvider`

`CodexProvider` 與 `CodexAppServerClient` 已加入資料層，並透過共用 `UsageProvider`、`UsageService` 與 `ProviderState` 接到 UI：

- 不自行組裝 shell 指令或啟動 login shell；若套件宣告的入口是 OpenAI 提供的 shell launcher，仍由 `Process` 直接啟動該入口
- 只傳送 `initialize`、`initialized` 與 `account/rateLimits/read`
- 不開啟 `experimentalApi`
- 支援 single-bucket 與 multi-bucket response
- 支援 primary 與 secondary windows
- 保留 provider 回傳的 percentage，不自行估算；只有既有 UI domain 在繪製時 clamp
- 5 秒 timeout
- 每行最多接受 1 MiB stdout；response channel 最多緩衝一筆目標回應
- stderr 丟棄，不保留可能敏感的 command output
- 健康時重用唯一 app-server child 與唯一 stdout reader task
- timeout、cancellation、EOF、protocol failure、explicit shutdown 與 App termination 都會關閉 file handles、終止並 reap child；重連前等待舊 stdout reader 結束
- 不讀取 `~/.codex` 的 config、auth、session、log 或 database
- executable 缺少時由 `UsageService` 正規化為 `notInstalled`
- launch failure 正規化為 `runtimeLaunchFailed`；timeout、malformed response、oversized response 與未分類 server error 正規化為 `refreshFailed`，不公開原始 response 或 error body
- `ProviderState.lastUpdatedAt` 直接來自成功 snapshot 的 `capturedAt`；失敗且沒有 snapshot 時保持 `nil`
- 後續刷新失敗時，`AppModel` 保留上一份有效的記憶體內 snapshot 並讓 UI 標示 stale；App 重啟後不保留，且不建立 usage history

Executable locator 已支援標準／`NSWorkspace` 發現的 ChatGPT.app 整合 runtime、舊 Codex.app、常見 CLI locations 與受限 `PATH`。尚未實作 UI override；production `AppDependencies` 已建立此 provider。

App Server error code 目前沒有足夠穩定的官方分類可安全區分 logged-out、API-key-only、offline 或 plan eligibility。實作不依數字猜測 authentication 狀態；除 missing executable 外，這些情況暫時使用一般 provider failure。等官方 contract 或跨版本 redacted fixtures 足以證明穩定分類後，才可映射 `unsupportedAuthentication`。

## Fallback policy

建議順序：

1. 使用者手動刷新或資料過期時，按需建立 app-server；健康時由後續刷新重用。
2. 成功時只保留目前的正規化 snapshot，不累積 raw response 或 usage history。
3. executable 不存在時回報 `notInstalled` 或 `notConfigured`。
4. authentication 不支援時回報 `unsupportedAuthentication`；不要嘗試讀 token。
5. timeout、offline 或暫時錯誤時，若本次 App 執行期間已有 last-known snapshot，就保留並清楚標示 stale；沒有 snapshot 時顯示 refresh failure。此行為不做磁碟 persistence。
6. response 沒有 window 時顯示 unavailable；不得推論 0% 或已 reset。
7. session JSONL fallback 預設保持停用。
8. connection 失效時先完整關閉舊 child、pipes 與 stdout reader，再於下一次讀取重新 discovery 並建立 replacement。

若未來真的評估 experimental session fallback，必須另外取得使用者明確同意，採 bounded tail read、只解析最新 matching event、立即捨棄其他內容，並顯示來源為 undocumented/stale-prone。現階段官方 app-server 已可工作，沒有實作此 fallback 的合理必要性。

## 尚待驗證

- 不同 ChatGPT 與舊 Codex Desktop 發行版本的 bundled resource path 相容性
- API-key-only、logged-out、offline 與不同 ChatGPT plan 的實際 error shapes
- 多個 `rateLimitsByLimitId` buckets 的 live response
- secondary window 的 live response
- 支援版本下限與 protocol compatibility policy
- Developer ID、hardened runtime、App Sandbox 與 child process 行為
- UI status mapping 與 last-known snapshot persistence
