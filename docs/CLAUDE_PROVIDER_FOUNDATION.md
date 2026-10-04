# Claude Provider Foundation

研究日期：2026-10-05（Asia/Taipei）。本文件是截至此日的來源稽核與後續實作決策，不是 live provider 完成證明。

**實作分類：B — CLAUDE PROVIDER PARTIALLY IMPLEMENTABLE。**

可開始隔離的訂閱 quota 契約、嚴格 parser、能力與失敗狀態設計。官方 status-line 提供條件式額度資料，但本機未登入、bridge 未安裝，尚無真實欄位交付、服務 freshness 或帳號連續性驗證。不得直接啟用 live retrieval 或重設通知。Claude 的個人訂閱 Account Activity／Activity Insights 沒有找到符合本產品邊界的來源。

**最終狀態：CLAUDE PROVIDER FOUNDATION PARTIAL — IMPLEMENT SAFE CAPABILITIES ONLY**

## 1. 起始基準、範圍與證據用語

| 項目 | 本輪確認 |
| --- | --- |
| Repository | `/Users/yincheng/development/quotaPulse` |
| 起始 branch／worktree | `main`；tracked／untracked 工作樹乾淨 |
| 遠端一致性 | `git fetch origin main` 後，local main = origin/main |
| 實際 main SHA | `924df240b0311bb82c261692beae18204d8b94f7` |
| Activity Insights PR #1 | GitHub 回報 MERGED；merge commit 為上述 SHA；2026-10-05 00:20:45 +08:00 合併 |
| 本輪 branch | `feat/claude-provider-foundation` |
| App metadata 基準 | Debug／Release `MARKETING_VERSION = 0.3.0`、`CURRENT_PROJECT_VERSION = 6` |
| Test target metadata 基準 | `MARKETING_VERSION = 0.1.1`、`CURRENT_PROJECT_VERSION = 1` |
| beta 基準 | `v0.3.0-beta.1^{commit}` = `87485c2e1ac65c90718a091cb2e521d8443519b3` |
| 允許交付 | 研究文件、必要架構文件更新、focused local documentation commit |
| 本輪排除 | Swift／live provider、Claude settings mutation、登入／登出／切帳號、人工 prompt、website、push／merge／tag、版本／build、DMG／manifest／release validation |

本文的「未提供／NOT AVAILABLE」限定為所列來源及已查核版本，不代表 Anthropic 的所有私有介面永遠不存在。

- **PROVEN**：本輪原始碼、唯讀 CLI、schema metadata 或官方契約直接支持。
- **PARTIALLY PROVEN**：部分有證據，但資格、版本、freshness 或 live 行為未成立。
- **UNVERIFIED**：缺少直接證據；不能以 fixture 或既有實作替代。
- **STALE**：舊結論已被目前環境／文件取代。
- **UNSAFE**：違反隱私／安全邊界，或會把未知資料轉成可信產品結論。

## 2. 目前本機 Claude Code 環境

### 2.1 同時存在兩套安裝

| 項目 | npm launcher | Native launcher |
| --- | --- | --- |
| 可執行路徑 | `/usr/local/bin/claude` | `~/.local/bin/claude` |
| 解析後位置 | `/usr/local/lib/node_modules/@anthropic-ai/claude-code/cli.js` | `~/.local/share/claude/versions/2.1.246` |
| 精確版本 | package metadata `@anthropic-ai/claude-code` **1.0.43** | `--version` **2.1.246 (Claude Code)** |
| 可執行性 | symlink target 存在且 executable；實際啟動失敗 | symlink target 存在且 executable；version／help 成功 |
| 本輪 PATH | 優先命中此 launcher | 必須使用明確路徑；未變更 PATH 設定檔 |
| 結果 | `--version`／`--help` exit 1，module initialization TypeError | `--version`、`--help`、auth help exit 0 |

npm package 聲明 Node `>=18.0.0`；本輪執行 Node 為 **v26.5.0**。失敗類別是 undefined prototype TypeError；本輪沒有證明根因，也沒有修改／升級任一安裝。單靠檔案存在不能保證 runtime 可用，單靠 PATH 首個失敗候選也不能判斷 Claude 未安裝。

最初直接 shell probe 意外輸出大量套件錯誤內容。後續全部 process probes 改為先擷取、限時／限量，再輸出白名單結果；沒有把錯誤原文、raw auth JSON 或私人 payload 寫進 repository。此失誤沒有觀察到憑證或對話內容，但不能把一般 shell truncation 當成隱私遮罩。

### 2.2 Broad authentication state

在 `/tmp`、既有 process environment 下，以 native launcher 執行 `auth status --json`；僅為該子程序設定 `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1`。沒有傳入 prompt、login、logout 或設定修改。

| 結構／行為 | 結果 |
| --- | --- |
| exit code | 1 |
| JSON | 有效；108 bytes；stderr 無內容 |
| root schema | `loggedIn: bool`、`authMethod: string`、`apiProvider: string`、`analyticsDisabled: bool` |
| broad state | `loggedIn = false`、`authMethod = none` |
| subscription metadata | 未回報 |
| opaque account discriminator | 本次 response 沒有此欄位 |
| 一次觀察的 wall time | 約 418 ms；不是穩定 latency／效能承諾 |

shell 未設定 `CLAUDE_CONFIG_DIR`、`ANTHROPIC_API_KEY`、`ANTHROPIC_AUTH_TOKEN`、`CLAUDE_CODE_OAUTH_TOKEN`、Bedrock／Vertex／Foundry selector 或 `ANTHROPIC_BASE_URL`。只檢查存在性，沒有輸出環境值。user settings 未含 `apiKeyHelper` 或 `env` object，repository 的兩個 settings files 不存在。

這只證明**此 native CLI invocation** 回報未登入；不推論瀏覽器、Claude Desktop、其他 profile／config directory 或其他 process 也未登入。不存在 `.credentials.json` 不能證明未登入，macOS 另有 Keychain 等官方儲存方式 [S03]。

## 3. 現有 QuotaMew Claude 稽核

搜尋 repository 的 tracked／一般未追蹤原始檔、文件、tests、localization、project 與 scripts；排除 `.git` 與 binary distribution。沒有掃描 Claude 私人 history。下表涵蓋所有現有 Claude runtime 路徑及主要繼承假設；release notes 保留當時事實，不改寫成目前功能。

| 範圍／假設 | 原始碼或文件 | 分類與判定 |
| --- | --- | --- |
| Provider 定義與排列 | `Domain/ProviderID.swift` | **PROVEN**：`.codex`／`.claude`；displayName／icon；不代表相同能力 |
| Production adapter 已接入 | `App/AppDependencies.swift` | **PROVEN**：runtime 同時建立 CodexProvider 與 ClaudeProvider；previews 使用 mock |
| Claude live source 已完成 | `Providers/Claude/ClaudeProvider.swift` | **UNVERIFIED**：只有讀取 QuotaMew-owned snapshot，沒有 source writer、CLI query 或 HTTP quota retrieval |
| Local reader 邊界 | `ClaudeSnapshotReader.swift` | **PROVEN**：`usage-v1.json`、16 KiB+1 bounded read、regular-file check、O_NOFOLLOW／O_NONBLOCK／O_CLOEXEC、關閉 handle／cancellation |
| 檔案安全已完整 | 同上 | **PARTIALLY PROVEN**：leaf symlink／FIFO 拒絕；沒有祖先目錄 symlink、owner、mode、writer authenticity／atomic replacement 的完整檢查 |
| Snapshot schema 即官方 JSON | `ClaudeSnapshotDTO.swift` | **UNSAFE**：這是自有 camelCase schemaVersion 1；官方 stdin 使用 snake_case，不能直接把原始 payload 落盤當此檔案 |
| Unknown data 不進 domain | DTO／reader tests | **PROVEN**：typed decoding 不模型化未知欄位；但 reader 仍會暫時載入上限內 bytes，不是原始資料從未被接觸的證明 |
| Optional／independently missing windows | DTO／provider | **PROVEN**：不補 0%；兩個視窗都不可用才 noRateLimits |
| 五小時與七天 duration | `ClaudeProvider.swift` | **PROVEN**：官方命名支持 18,000／604,800 秒；不是從 Codex bucket 推論 [S01][S08] |
| 百分比範圍已嚴格驗證 | provider／`UsageWindow.swift` | **UNSAFE**：僅排除非有限值；140 被接受，再截成 100；現有 test 明確要求此行為，與訂閱 0…100 contract 不符 |
| `remaining = 100 - used` | `UsageWindow.remainingPercentage` | **PARTIALLY PROVEN**：只在真實、有限且 0…100 的 subscription used value 上是安全派生；clamp 不能證明有效性 |
| Reset epoch seconds | provider／test | **PROVEN**：`Date(timeIntervalSince1970:)`；nil 不補造。只有 finite、positive gate，沒有合理範圍／已過期 freshness gate |
| `claudeCodeVersion` 強制支援檢查 | DTO／provider | **UNVERIFIED**：目前解碼但不驗證、不拒絕舊版本 |
| capture 保留而不重新 stamp | provider | **PROVEN**：沿用 document.capturedAt；但沒有可信 upstream fetchedAt／account continuity |
| 重設已過即顯示過期 | `ProviderStateView.swift` | **UNVERIFIED**：目前 stale presentation 只看 capture age；fresh capture 配過去 reset 仍可能 Available |
| bridge capture 就等於服務 fresh | 自有 schema／通知 policy | **UNSAFE**：writer invocation／讀檔成功不證明新服務資料；最新文件有 idle expiry 與舊值修正，仍無通用 upstream acquisition timestamp [S01][S04][S08] |
| 所有 reader failures 都能辨識原因 | reader／`ProviderStatus.swift` | **PARTIALLY PROVEN**：typed reader errors 存在，但 unsupported schema、oversize、malformed、unreadable 最終多數收斂成 refreshFailed |
| `notInstalled`／auth tests 證明真偵測 | `ClaudeProviderTests.swift` | **UNVERIFIED**：只是 fake injected error passthrough；production reader 沒有 installation／auth discovery |
| 實驗性狀態 | Settings／Onboarding／ProviderStateView／Diagnostics | **PROVEN**：Settings Experimental, Unverified；Dashboard Experimental；diagnostics 固定 `.unverified`、runtimeDetected nil |
| Provider 開關、pin、status item | SettingsStore／MenuBarPresentation／StatusItemController | **PROVEN**：Claude default enabled，可停用／固定；5H/W 以精確 duration selection，Reserve 僅 Codex IDs |
| Claude 專用 capability flag | source／scripts／project | **UNVERIFIED**：沒有 explicit ProviderCapabilities；只有 enablement、固定 experimental presentation，沒有新 live bridge feature flag |
| 活動功能共用所有 providers | AppDependencies／SettingsStore／ActivityService | **UNSAFE**：runtime 只註冊 CodexTokenActivitySource；consent／ActivityModel 明確 Codex-only；Claude tests 多為 isolation/unsupported 情境 |
| Claude subprocess 已存在 | `Providers/Claude/` | **UNVERIFIED**：adapter 不啟動 process；既有 process runner／app-server 是 Codex 路徑，不應直接複製為 Claude contract |
| notification source 真實性已驗證 | ResetNotificationPolicy／LocalResetDetector | **PARTIALLY PROVEN**：排除 mock、檢查 age／reset、provider identity、enablement；自有檔案存在不等於官方 delivery／same-account 證明 |
| completed reset 可直接共用 | detector／NotificationService | **UNSAFE**：key 是 provider+window；帳號切換、人工 limit reset／更正可能被當成新週期，沒有 Claude-specific continuity gate |
| 失敗後 cached snapshot 可安全續用 | `AppModel.finishRefresh` | **PARTIALLY PROVEN**：`.failed`／`.disabled` 可保留 cache；不是帳號一致性的證明，Claude auth／contract 失效後不能直接沿用 |
| 本機只有 Claude 1.0.43 | 舊 provider doc／ARCHITECTURE | **STALE**：另有可執行 native 2.1.246；npm 舊版仍存在 |
| status line 僅事件、idle 無變化 | 舊 provider doc | **STALE**：目前文件含 optional refreshInterval 與 reset expiry trigger；timer 不等於新 service query [S01] |
| invalid percentage 不產生 window | 舊 provider doc | **STALE**：實際 finite 超範圍值會保留；文件敘述比 code 保證更強 |
| fixtures 等於 subscription live proof | provider docs／tests | **UNSAFE**：11 個 provider tests + 8 個 reader tests 是 synthetic deterministic coverage；本輪只稽核，未重跑，不證明 subscription delivery |

其他搜尋命中包含 `docs/providers/provider-strategy.md`、產品策略／競品／polish／V0_2_PLAN、RUNTIME_TESTING／PERFORMANCE／RELEASE_CHECKLIST、v0.1／v0.2 release notes、v0.3 beta／daily activity 文件、RESET_INTELLIGENCE 文件與其 Claude audience fixtures。它們沒有增加 runtime Claude quota source；歷史預估或 mock event 不能提升契約等級。

**保留原始碼是本輪 research-only edit scope 的結果，不是核准沿用。** 下一輪應先修正 parser validity／lifecycle，再接來源，不以「既有 tests 通過」延續不安全假設。

## 4. 官方能力矩陣與三種資料領域

| 能力 | 官方契約分類 | scope／QuotaMew 判定 |
| --- | --- | --- |
| Subscription consumed quota | **DOCUMENTED STABLE** | Pro/Max status-line `used_percentage`；條件式欄位，不是 token 數 [S01] |
| Subscription remaining quota | **DOCUMENTED BUT AMBIGUOUS** | machine source 未獨立提供 remaining；有效百分比的 100-used 可安全派生，不能反推 message/token allowance |
| Absolute reset timestamp | **DOCUMENTED STABLE** | `resets_at` Unix epoch seconds [S01] |
| Rolling five-hour／weekly seven-day | **DOCUMENTED STABLE** | 官方命名／plan 時間語意，不能由 Codex 推論 [S01][S09][S10][S15] |
| Session limits | **DOCUMENTED STABLE** | 五小時 subscription「session」是 quota period，並非單一對話生命週期 [S09][S10] |
| Model-specific limits | **DOCUMENTED BUT AMBIGUOUS** | SDK type 有 seven_day_opus／seven_day_sonnet，但不是所有帳號當下都啟用；status-line 未提供這些 aggregate 外的欄位 [S07] |
| 額外月度／feature caps | **DOCUMENTED BUT AMBIGUOUS** | plans 保留調整限制；沒有合格的個人 subscription machine schema，UNKNOWN 資格／數值 [S09][S10] |
| 個人 account-level token activity | **UNKNOWN** | 查核的 passive CLI／status-line 沒有此介面；本輪產品能力 unsupported |
| 個人 daily account token history | **NOT AVAILABLE**（所列來源） | 不在 status-line／auth status contract；不能由 local stats 補成 account activity |
| Local activity／daily/model stats | **DOCUMENTED BUT AMBIGUOUS** | 官方 `/usage` 顯示本機資料；internal stats cache persistence schema 無穩定承諾 [S04] |
| Session/context token counts | **DOCUMENTED STABLE** | status-line／SDK 為 SESSION 或 CONVERSATION，不是帳號日累計 [S01][S07][S17] |
| Request counts | **DOCUMENTED STABLE**（特定版本／範圍） | 新版 prompt cache 統計只覆蓋 main conversation；本機 2.1.246 早於 2.1.251，未 live 驗證 [S01][S08] |
| Auth machine status | **DOCUMENTED STABLE**（操作）／**DOCUMENTED BUT AMBIGUOUS**（完整 JSON schema） | `auth status` JSON 與 0/1 退出約定；不可當作遠端每次請求有效性的保證 [S02] |
| Subscription/account metadata | **DOCUMENTED BUT AMBIGUOUS** | SDK AccountInfo 有 optional subscriptionType／organization／email；本機未登入 response 不包含；不保存識別資料 [S17] |
| API token usage／billing | **DOCUMENTED STABLE** | 組織 Admin API；**API BILLING**，不是 consumer subscription quota [S11] |
| Claude Code 組織 daily analytics | **DOCUMENTED STABLE** | Admin API，多使用者、Claude Code 使用範圍；非個人跨 Claude 產品帳號資料 [S12][S13] |
| Enterprise 跨產品 analytics | **DOCUMENTED STABLE** | 組織授權 API；usage-based／seat-based 的數據涵蓋不同；目前排除 [S13] |
| 可供第三方使用的 subscription HTTP quota API | **UNKNOWN** | 未找到公開、可不碰 Claude 憑證的契約；不能宣稱服務不存在，也不能宣稱可直接用 |

三個領域必須維持：

| 領域 | 可表示的意義 | 絕不能換成 |
| --- | --- | --- |
| A. Consumer subscription limits | account 共享方案額度比例與服務回報 reset；Pro/Max 條件式 | API bill、session token totals、固定 token allowance |
| B. Local client/session/conversation activity | 本機觀察到的 tokens、requests、模型與 session 統計 | 跨裝置／跨 Claude 產品的 ACCOUNT LEVEL 活動 |
| C. Anthropic API usage/billing | API 組織消耗與帳務 | Claude subscription 剩餘／已用額度 |

另有 Enterprise organization analytics 與 gateway spend limits。它們是不同授權與資料 scope，不能偷渡為 A 或一般個人 Account Activity。使用額外付費 credits 也不等於 Codex Reserve [S04][S13][S16]。

## 5. CLI／SDK 契約

### 5.1 本機官方 help

Native 2.1.246 help 列出：`agents`、`auth`、`auto-mode`、`doctor`、`gateway`、`import`、`install`、`mcp`、`plugin|plugins`、`project`、`setup-token`、`ultrareview`、`update|upgrade`。這是命令清單，不是執行授權；本輪只執行 version/help 與 auth status。

支援 `-p/--print`、`--output-format text|json|stream-json`、`--input-format text|stream-json`、`--json-schema`、`--no-session-persistence`。這些是 agent 輸出／結構化回應模式，**不是獨立 subscription quota query**。未看到 `claude usage --json`／`limits`／quota server query subcommand；沒有向未知 command 傳值嘗試，避免 fallback 成 prompt。

`auth status --help`確認 JSON 預設、`--json`／`--text`。最新線上 CLI 文件還列出較新命令／`configDirectory`（>=2.1.268）；不能假設 2.1.246 具有所有最新文件功能 [S02][S08]。

### 5.2 人類 UI 與 SDK 分開評級

- `/usage`、`/cost`、`/stats` 是官方互動指令／aliases；`/status`可看登入／帳號狀態，但都是 **D 級 terminal UI**，不是官方 JSON 查詢；不以`-p /usage`代替受支援的 passive query [S04][S05]。
- SDK RateLimitEvent／RateLimitInfo 是 **A 級文件化事件**：`status`、optional `rate_limit_type`／`utilization`／`resets_at`與 overage。事件隨 agent 活動／狀態變更，未提供獨立 read-current-quota operation；不為取得事件而建立推論工作 [S07]。
- SDK `accountInfo()` 是文件化 metadata 操作；AccountInfo 模型只有 optional email、organization、subscriptionType、tokenSource、apiKeySource，沒有文件化穩定個人 opaque ID。SDK query lifecycle 與是否完全無模型 request 本輪未驗證，且不比 one-shot auth status 更適合本產品 [S17]。
- SDK ModelUsage／ResultMessage usage 是 session/model 數據，不是個人 account daily buckets。已文件化也不能提升 scope [S07][S17]。

## 6. Local state：只查必要 schema／metadata

以下`~`是文件化相對 home 位置，不是匯出的私人 home 路徑。

| Surface | 分類 | 本輪觀察／處理 |
| --- | --- | --- |
| `~/.claude/settings.json` | CONFIGURATION | regular、有效 JSON；statusLine object／command 存在，refreshInterval 未設定；沒有輸出 command／其 script，也沒有修改 |
| Repository `.claude/settings.json`／`settings.local.json` | CONFIGURATION | 兩者不存在 |
| `/Library/Application Support/ClaudeCode/managed-settings.json` | CONFIGURATION | 不存在；沒有據此宣稱所有 MDM／server-managed policy 均不存在 |
| `~/.claude/managed-settings.json` | CONFIGURATION | 不存在；不是完整 managed 來源探索 |
| `~/.claude.json` | CONFIGURATION + AUTH METADATA + ACCOUNT METADATA | 存在；僅 stat，不解碼；不適用 quota [S14] |
| `~/.claude/.credentials.json` | AUTH METADATA | 不存在；未讀 Keychain、未搜尋／複製其他 credential locations |
| `~/.claude/stats-cache.json` | USAGE CACHE（LOCAL CLIENT） | regular、0600、有效 JSON；只記 known root names/types，不輸出值；有 dailyActivity、dailyModelTokens、modelUsage 等，沒有 quota/reset 名稱 root |
| `~/.claude/projects` | SESSION DATA／CONVERSATION DATA | directory 存在；沒有列私人 project/session 檔名、沒有開任何 transcript |
| `~/.claude/history.jsonl` | CONVERSATION DATA | 存在；僅 stat，未讀一行 |
| `~/.claude/debug` | OTHER（敏感 logs） | directory 存在；未列檔名、未讀內容 |
| `~/.claude/usage-data` | OTHER（本機衍生 reports） | 不存在；未執行`/insights` |
| `~/Library/Application Support/QuotaPulse/Providers/Claude/usage-v1.json` | OTHER（QuotaMew-owned snapshot） | 不存在；沒有建立 synthetic 檔案冒充 live data |

stats-cache schema 僅見`version`、`dailyActivity`、`dailyModelTokens`、`modelUsage`、`totalSessions`、`totalMessages`、`firstSessionDate`、`lastComputedDate`、`hourCounts`、`longestSession`的既知 key 與型別。型別與 root 名稱不是內容 scope 的正式保證；官方本機 stats 語意加上私密 derived-cache 性質，使它不適合 subscription quota 或 account activity。

讀取不存在的 credentials 檔、或看到 global state file，都不提升 auth 判定。本輪可靠 broad auth evidence 來自 CLI 自身回報 [S03]。

## 7. Network／service sources 與穩定性

官方 `/usage` 文件明確描述 plan-limit service request、rate limiting 與 60 分鐘 last-known bars [S04]，所以**Claude Code 會向服務取得 quota 狀態是 PROVEN**。但第三方直連該服務的公開 contract、URL、完整 response 與 auth scope 本輪未成立。沒有封包攔截、TLS 代理、debug logs、credential extraction 或 undocumented HTTP request。

| Candidate／穩定級 | Auth 類別／request 生命週期 | Schema／scope／reset／error 與決策 |
| --- | --- | --- |
| status-line `rate_limits`：**A** | Claude Code 管理自己的登入／網路；本機 command 透過 stdin 接收事件，不由 QuotaMew 送模型 request | 官方 snake_case quota fields；條件式 subscription ACCOUNT LEVEL limits；epoch reset；missing／expiry 正常；**唯一優先 quota 候選**，需 opt-in bridge 隔離 |
| QuotaMew-owned v1 snapshot：**B**（自有 contract；官方來源鏈 UNVERIFIED） | 本機 file read，沒有 auth；writer 尚未實作 | camelCase、schemaVersion、capturedAt；不能自證來源或服務新鮮度；missing／malformed／future schema 可辨識；不是獨立 Anthropic 資料來源 |
| `auth status --json`：**B** | Claude CLI 擁有 auth；one-shot、on-demand，不由 App 取得 token | JSON／exit code 約定 A 級，完整版本化 schema 與 remote validity 未完整承諾；僅 broad auth；沒有 quota／reset；schema 需 isolation/tests |
| SDK RateLimitEvent：**A** | 既有 agent session 的狀態事件，可能涉及模型 requests 與額度 | consumption fraction0…1、epoch、五小時／七天／model／overage type；不是 passive getter；本產品不建立 agent 工作 |
| SDK AccountInfo：**A**（型別）／**B**（本產品被動生命週期） | SDK session/control operation；CLI own auth；本輪未執行 | optional auth/account metadata，沒有可靠個人 ID；無 quota；不採用為預設來源 |
| subscription service 直接請求：**UNKNOWN**；若僅 implementation detail 則**C**；需讀 OAuth 則**E** | CLI 正常使用自己 auth；第三方支援方法 UNKNOWN | endpoint path／完整 schema／error body／TTL 本輪 UNKNOWN；不 Reverse-engineer 再宣稱 production-safe |
| `/usage`／`/status`／claude.ai Usage UI：**D** | Claude 終端／網頁自身登入；人類操作 | 人類 bars／時間／可能 cached；不 scrape，僅未來人類比對 |
| stats-cache：**C**；拿來 quota 則**E** | 本機衍生 cache | 無 account completeness；無 subscription reset contract；拒絕 |
| transcripts／history／insights reports／credentials：**E** | 私人內容、憑證或私有 derived state | 不讀、不 copy、不用作 fallback |
| API Usage & Cost：**A**，但本產品排除 | 組織 Admin credential 類別；日期區間／bucket／pagination request | `/v1/organizations/usage_report/messages`與 cost report；API BILLING；不等於 subscription allowance [S11] |
| Claude Code Analytics Admin API：**A**，但本產品排除 | 組織 Admin credentials；按日／cursor | `/v1/organizations/usage_report/claude_code`；date、actor、organization、model tokens／estimated cost；組織 Claude Code 子範圍，不是個人跨 Claude 活動 [S12] |
| Enterprise Analytics API：**A**，但本產品排除 | primary owner 建立 Analytics API key；`read:analytics`；日期 request | `/v1/organizations/analytics/`；跨產品組織 activity；usage-based token/cost，seat-based 只反映 usage credits；日期延遲／400 等另有 contract [S13] |
| Gateway spend_limit：**A**，但本產品排除 | Claude gateway 自身 credential 與 policy；事件／部分附加請求 | used_percentage 可能>100、estimated USD／period optional；不是 subscription quota 或 Reserve [S01][S08] |

政策：A 可作契約基礎；B 需隔離／tests／對來源鏈另外驗證；C 只可明確 Experimental 且需重新批准理由；D 不作核心 monitor；E 拒絕。**文件穩定級不等於 live 驗證，也不等於本產品 scope 合適。**

沒有發現必須採用的「SUPPORTED BUT UNDOCUMENTED」production source。internal endpoint 的存在與欄位不能由第三方工具或網路傳聞補為 PROVEN。

## 8. Quota 與 reset 語意

| Provider-facing limit | 視窗／duration | consumed／remaining | Reset 語意 | 資格／account／model scope | 信心 |
| --- | --- | --- | --- | --- | --- |
| `five_hour` | rolling five-hour；18,000 秒 | used_percentage 為消耗 0…100；remaining 可派生，沒有固定 token denominator | 服務經 CLI 回報 absolute epoch；不能在 client 以首次啟動+5h 重建；精確 rolling 演算法 UNKNOWN | status-line 文件限定 claude.ai Pro/Max；shared subscription pool；非單一 CLI session／非限定目前模型 | 文件 HIGH；本機 live UNKNOWN [S01][S09][S15] |
| `seven_day` | weekly；604,800 秒 | aggregate used percentage；remaining 同上 | plan 文件為 assigned fixed weekly day/time；absolute epoch 優先，不以 local 週一／subscription start 計算 | Pro/Max；跨 models general allowance；不要猜 model 別 sub-bucket | 文件 HIGH；本機 live UNKNOWN [S01][S09][S10] |
| SDK `seven_day_opus`／`seven_day_sonnet` | SDK 命名 weekly；實際資格／細節 UNKNOWN | optional utilization0…1；不可取代 aggregate 或推斷當下可用 | optional resets_at Unix timestamp；無 timestamp 即 UNKNOWN | model-specific 事件；不是每帳號都承諾存在，也不在所選 status-line schema | type HIGH；產品 eligibility UNKNOWN [S07] |
| SDK `overage` | 不屬 included quota；period 細節 UNKNOWN | overage status 等；不作 100-used subscription 值 | optional overage reset；不能沿用 regular notifications | 額外付費 usage，與 included allowance 分開 | 不納入 [S07][S16] |
| Gateway `spend_limit` | period 可為 daily／weekly／monthly；非本產品 subscription bucket | spend 用量可能超過 100%；USD estimate 非 invoice | 文件化 epoch；百分比與 optional 美元額可不同步 | gateway policy 適用對象，不是 consumer shared quota | 文件 HIGH，scope 排除 [S01] |

`five_hour`是官方 Claude 名詞，非 Codex terminology；「rolling」不等於每個 token 逐筆滑出桶的演算法承諾。`seven_day`不假設同樣 rolling；目前 Pro/Max 文件支持固定每週時間。

Epoch 表示 absolute instant；儲存／比較不套用 local timezone，UI 才轉為使用者時區。官方 plan day/time 的 assignment timezone、DST 計算與所有 server weighting 未建立，應 UNKNOWN；不能以 Asia/Taipei 重建 server reset。

Reset countdown 只是回報 timestamp 的顯示派生。**過了 resetAt、視窗消失、百分比下降，都不是 QuotaMew 已觀察到新額度週期的充分證明。** 官方亦有人工 limit reset，不能由新時間／低百分比聲稱預定週期正常結束 [S18]。

官方 changelog 在 2.1.243 修正 idle 過 reset 仍顯示舊百分比，2.1.80 則加入基本欄位 [S08]。Native 2.1.246 高於此修正版，但仍未經 live 驗證；未來首個支援版本應至少滿足已知 idle 修正，再以能力 probe／fixtures 決定，不把版本數字當成功保證。

**通知目前 blocked。** Reset 時間有契約，但缺少可驗證 source freshness／account continuity，且沒有 bridge。先支援「回報的重設時間／樣本倒數」；approaching reminders 需獨立 M5 gate，completed reset detection 更不能先承諾。

## 9. Activity／usage scope

| Source | 明確 scope | 可讀意義 | 是否是 Codex Account Activity analogue |
| --- | --- | --- | --- |
| status-line subscription `rate_limits` | **ACCOUNT LEVEL**（limits） | 共享方案百分比；不是 token 活動 | 否，缺 daily buckets 與 token 契約 |
| context_window／current_usage | **CONVERSATION／SESSION** | 最近 API response／目前 context tokens | 否；非帳號日總量 [S01] |
| SDK usage／ModelUsage | **SESSION** | session/model token components 與 estimate | 否 [S07][S17] |
| `/usage` activity breakdown／stats cache | **LOCAL CLIENT** | 本機歷史 approximate stats；其他裝置與 claude.ai 不含 | 否 [S04] |
| `/insights` | **LOCAL CLIENT／CONVERSATION** | 分析 recent sessions，會用模型 tokens 並產生 report | 否；本輪未執行 [S04] |
| OpenTelemetry tokens／requests | **LOCAL CLIENT／SESSION** | opt-in telemetry，自配置 collector；可能帶 email／prompt 相關 attributes | 否；不新增 telemetry／upload [S19] |
| Usage & Cost Admin API | **API BILLING** | 組織 API token／cost 時間桶 | 否 [S11] |
| Code Analytics Admin API | **ACCOUNT LEVEL（organization/user；僅 Claude Code 產品範圍）** | per-user 日 tokens／metrics；需組織 admin 授權 | 目前否，scope 與 permission 不同 [S12] |
| Enterprise Analytics | **ACCOUNT LEVEL（organization/user；plan-dependent）** | 跨產品組織 activity；token usage 有方案涵蓋限制 | 目前否，另立產品／隱私／credential 決策 [S13] |

只有 ACCOUNT LEVEL 且 scope／授權符合的來源才可進一步評估 analog。組織 admin analytics 不是缺失的個人 consumer getter；不可要求使用者交出 admin key 以讓 Claude「補齊 Codex 功能」。

## 10. Authentication 與帳號生命週期

1. **Installed**：bounded locator 需檢查 native 常見位置、限定 PATH 等候選的 regular/executable/受信任祖先，然後限時`--version`。不啟動 login shell；安全解析 native 版本與 npm metadata 須區分「已安裝但無法啟動」。本輪只有研究 probe，App 未新增 locator。
2. **Auth available**：CLI `auth status`提供 broad 狀態；latest 文件定義 authMethod enum，但版本更新有歷史誤分類修正 [S02][S08]。只有 positive broad state 仍不能證明 subscription eligibility／服務 token 未過期／rate_limits 必出現。
3. **Expiry**：Claude 自身 refresh auth；失敗時模型 request 可能要求登入 [S03]。QuotaMew 不 refresh／copy token，不以過期 snapshot 假裝仍 authenticated；CLI 失敗若無穩定 typed 證據不能硬稱 auth expired。
4. **Account switch**：沒找到此 passive quota 來源提供受支援的 account-change event 或 stable 個人 opaque ID。authMethod／subscriptionType 不變的切換無法可靠偵測，CLI 重新啟動也不證明帳號相同。
5. **Privacy-safe identity**：status-line 沒有 account discriminator，auth probe 未回報，SDK AccountInfo 沒有文件化個人 opaque ID [S17]。organization 不是個人 account ID；email hash／token hash／credential file mtime 不作替代，也不持久化 email、raw response 或任何 auth secret。
6. **Stale implications**：reset／auth／contract 不明時，不保留為「目前帳號」數值或通知 baseline。明確 disable／reconfigure／runtime replacement／negative auth／source unavailable 應清 cache、取消 pending Claude notifications 並 re-baseline；這只處理已知失效，不能宣稱能偵測所有靜默 switch。

若 future 來源仍沒有可信帳號 binding，quota UI 必須明確是「所設定 Claude source 最後回報的樣本」。TTL 只能限制資料年齡，不能解決跨帳號錯置。**不得以 unknown continuity 啟用 completed-reset 通知**；只有新的受支援 continuity contract 或產品接受且驗證的更保守通知政策才能解除此 gate。

## 11. 與現有 abstractions 的 fit／capabilities／failure model

### 11.1 Normalization map

| 概念 | 分類 | Fit 與必要限制 |
| --- | --- | --- |
| UsageProvider | **DIRECT MATCH**（讀已投影 snapshot）／**PROVIDER SPECIFIC**（刷新語意） | `fetchUsage`可讀 file；Refresh 不代表向 Claude 服務 pull 新資料 |
| UsageSnapshot | **DIRECT MATCH** | 實際型別叫`ProviderUsageSnapshot`；只收可證明的 subscription windows |
| usedPercentage | **DIRECT MATCH** | 嚴格 finite 0…100；不沿用 clamp 掩蓋 contract error |
| remainingPercentage／progress | **SAFE DERIVATION** | 合格 used 的補數／比例；不是 token capacity |
| duration／5H／W label | **SAFE DERIVATION** | 只從官方 window ID／語意，非 array order／Codex primary secondary |
| resetAt／countdown | **DIRECT MATCH／SAFE DERIVATION** | epoch 轉 Date／顯示差值；不推論 reset 已發生 |
| capturedAt／freshness | **PROVIDER SPECIFIC** | local observedAt 與 upstream freshness 需不同概念；現有 single timestamp 不足 |
| RefreshCoordinator | **DIRECT MATCH** | coalescing／sequential provider I/O 可重用；不加 Claude poll loop |
| cached failure／notification lifecycle | **PROVIDER SPECIFIC** | account/source ambiguity 需 clear／re-baseline；目前通用 fail 保留 policy 不夠 |
| provider enablement／pin／status item／Settings | **DIRECT MATCH** | consent、support、availability 分開；R／activity 選項不能假裝 Claude 支持 |
| resetCycleIdentifier／stable account identity | **UNAVAILABLE**（選定來源） | 不生造 provider-cycle／account ID |
| Account Activity／Activity Insights | **UNAVAILABLE**（目前個人 subscription 來源） | 不註冊 Claude TokenActivitySource，不用 local session 補資料 |
| reserveBucket | **UNAVAILABLE** | usage credits／gateway spend 不是 Reserve |

### 11.2 Capability 建議：先設計，未實作

需要顯式能力模型，因 quota、活動與通知的證據不同。單純 Bool 無法同時表示「有條件文件化」「未完成 setup」「暫時無資料」。建議拆開：

- `ProviderCapabilities`：support 宣告與來源 scope，例如 supported／conditional／unsupported／unverified。
- runtime availability：installed/auth/source/version/window presence/freshness 的 typed 狀態。
- user consent 與 provider enablement：既有 preferences，不把它們當能力證明。

| Capability | Codex 目前 source wiring | Claude 契約能力 | Claude 本輪 runtime entitlement |
| --- | --- | --- | --- |
| quota | 已有 quota adapter | conditional：Pro/Max status-line | 未就緒（未登入／bridge missing） |
| reset time display | 已有 epoch／countdown | conditional | 未就緒 |
| resetNotifications | 已有本機 policy | conditional；M5 freshness/lifecycle gate 未滿足 | **false** |
| accountActivity | 已有獨立 CodexTokenActivitySource | unsupported：無合格個人 daily source | **false** |
| activityInsights | 已有 pure Insights + UI | unsupported，依賴 accountActivity | **false** |
| reserveBucket | Codex 限定 metadata presentation | unsupported | **false** |
| broad auth diagnostic | 不在本輪重設 Codex contract | conditional one-shot CLI | 可設計、未整合 App |

M0 應只引入必要的 support/availability 表達，不建立空 source/service。先在非即時測試裡固化 shape，再決定 UI。以既有 code 確認 Codex wiring，不以本輪 Claude 研究重宣稱 Codex 所有 live 語意。

### 11.3 可區別的 failure states

| 候選 state | 可可靠區分的證據 | 缺少證據時 |
| --- | --- | --- |
| notInstalled | 受限且完整的候選探索皆 missing | 候選 unreadable 不能當未安裝 |
| notAuthenticated | 所選支援 CLI 有效 JSON loggedIn=false + 合理 exit 1 | arbitrary nonzero 不是未登入；本輪此 state 已觀察 |
| unsupportedVersion | 可解析版本早於所選 feature minimum | parse/startup failure 列 runtimeFailure；未提供版本不猜 |
| unsupportedContract | 已識別 auth/source 模式沒有 subscription 契約，或已知不支援自有 schema | missing rate_limits 可能 first-response／資格／正常 expiry，不足以判斷 |
| temporarilyUnavailable | 已知 source 缺失／過期或 typed transient request/timeout | 無 bridge 需**notConfigured／awaitingSource**，不是暫時網路故障 |
| providerError | 執行失敗／bounded runner 錯誤等已分型 | 固定 safe code，不傳 stderr／provider body |
| contractChanged | 已知曾有效 contract 出現 incompatible schema／core-type 變化 | 不能僅 missing field 就稱 contract changed；分 invalidSnapshot／unsupportedSchema |
| permissionDenied | app-owned file 或 executable 操作明確 EACCES／EPERM | ELOOP／invalid file type／所有 unreadable 不應一概叫 permissionDenied |
| stale／continuityUnknown | 年齡／expiry／來源 generation 無法成立 | 不包裝成 no data／available，且不保留 notification entitlement |

目前 production reader 只精確辨識部分 file errors，尚無完整 runtime／auth states。Broad CLI probe 與 future failure model 的可行性不能寫成 App 已支持。

## 12. Process／resource 與 privacy 決策

| 模型 | CPU／memory／startup／latency | timeout／cancellation／cleanup／concurrency | 建議 |
| --- | --- | --- | --- |
| one-shot CLI | 有 startup 成本；auth status 一次 418ms；未 profile memory/CPU | 固定 argv、stdin closed、bounded stdout/stderr、10s 研究 timeout、kill/reap／close handles；合併同一次 diagnostic | 只適合按需安裝／broad auth 檢查；不增加每輪 quota subprocess |
| persistent Claude process／SDK | 持續 memory／背景工作成本未量測；沒有必要 passive quota getter | task ownership／pipes／cancel／child cleanup 複雜，可能 initialize hooks/MCP | **拒絕本輪方案**；不能照搬 Codex app-server |
| opt-in event bridge + local read | bridge 僅既有 Claude event 啟動；QuotaMew bounded 小檔；idle 無需另一個 Claude process | 原子 replace、permissions、generation fencing；讀取沿用單一 coalesced refresh；不加 global 秒 timer | **優先 future 候選**；手動 composition 優先於 installer |
| direct supported service | 訂閱第三方 supported service 未建立；API admin 涉及額外 credentials | 若未來真有 supported contract 才評估 transport／bounded response／typed errors | 現在拒絕 subscription 直連；不查 OAuth secret |

優先 Reliability > 低資源 > privacy > UX > extensibility；credentials/transcripts 禁區仍是硬限制，不因優先序允許突破。沒有 Release profile，因此不聲稱 idle CPU、RSS、持續 latency 或通知效率達標。

未來 bridge 必須先受限 stdin 大小再 decode；只投影兩個 subscription window 的數值、bridge schema、bounded Claude version、capture time。禁止 raw stdin 落盤，禁止先 dump 再 redact。API/gateway/未知欄位一律不進此 snapshot。

| Threat | 必要防線 |
| --- | --- |
| OAuth/API keys/session cookies | 不讀 Keychain／credential file、不 copy／hash／persist；CLI 自己管理 auth [S06] |
| Session／prompt／repo 洩漏 | 不 scan transcripts／history／debug／insights；bridge 立即 discard cwd、workspace、transcript_path、session/prompt IDs、model/cost/tokens/git/PR 及 unknown fields |
| Raw response／stderr | 在輸出邊界 typed allowlist；不保留 NSError.localizedDescription／stdout/stderr/raw payload；paths 僅安全 source category |
| Snapshot 替換／permissions | 同 UID owner-only 目錄 0700／file 0600，拒絕不可信祖先／leaf symlink／FIFO，atomic temp+rename、bounded regular file；race／concurrent writers 做 deterministic tests |
| 舊資料重播／捕捉時間偽 fresh | 原樣保留 observedAt；不以 mtime／讀取時間更新；future/upstream freshness 未知需明說，expired reset 拒絕 current 資格 |
| 帳號切換 | 不保存 account ID/email；已知 invalidations 清值／notification baseline，未知 continuity 不啟用 completed reset |
| Existing command | 不讀取／執行既有 script 做探測；不自動 wrapper installation；future composition 需 preview／可復原且不能打破原有 stdout |
| Remote upload | 不送 Claude state、usage、paths、workspace／session 資訊到外部；未啟用 OpenTelemetry；官方文件查詢只用公開 generic terms |

存在 statusLine.command 不代表同意讓 QuotaMew 覆寫它。Managed settings／trust／設定優先序要另外確認 [S14]。本輪未安裝 bridge、不讀現有 command 值，不新增 runtime dependency。

## 13. Bounded live 唯讀驗證與未驗證項目

已完成：native version／help／auth help，舊 npm metadata 與啟動錯誤類別，native auth status schema／negative 登入狀態，settings 結構、stats-cache known schema、private 目錄 stat、QuotaMew snapshot 缺失。後續 probes 限 8–12 秒、64–128KiB 輸出，stderr 先遮罩；沒有殘留 research subprocess。

未完成且未冒充：真實 Pro/Max rate_limits／window presence／reset value／account switch／auth expiry／permission failure／quota service 網路行為、bridge composition／atomic writer、UI 比對、notification delivery、Release profile。原因：本機 native CLI 未登入、snapshot 不存在，本輪禁止變更登入／設定／傳 prompt。沒有任何個人 usage percentage/reset timestamp／email／token 寫入文件或 fixture。

解除 live blocker 的具體證據：使用者日後自行正常使用已登入且符合資格的 Claude Code，於明確同意的最小 bridge 產生**只含允許 schema**的樣本；以結構化遮罩驗證 window presence／first-response／expiry／idle 行為。本輪不自動登入、不設排程等待，也不索取私密 payload。

## 14. 未來 deterministic test strategy

目前只有文件改動；下列是推薦新增的測試，不是本輪執行結果。

| Boundary | Synthetic／fake coverage |
| --- | --- |
| 官方 DTO→自有 projection | snake_case→typed fields；no/full/one window；missing/null 獨立；unknowns（內含假的 secret/prompt）不進入輸出；gateway/model/overage 不可混入 |
| Numeric contract | finite 0／fraction／100；negative／>100／NaN／Inf／string／bool／wrong type 拒絕；不能 clamp 後 available |
| Reset／freshness | epoch seconds 而非 milliseconds；nil／invalid／range overflow；past reset、future capture／clock skew；讀同檔不 renew；expiry 不能自動產生 0%或 completed reset |
| Version／schema | below 2.1.80、known idle-fix minimum、unknown future version、missing version；unsupported own schema 先 decode envelope，拒絕 changed payload |
| Filesystem | fake I/O；missing／EACCES／EPERM／symlink leaf/ancestor／FIFO／oversize／partial atomic write／owner/mode／concurrent writers；bounded read／handle close／cancellation |
| Command runner | fake version/help/auth JSON；exit 0/1/mismatch；malformed/oversize/timeout/stderr；no private output；native 與 npm 候選衝突；argv 不經 shell |
| Lifecycle／cache | disable/re-enable／source replacement／negative auth／failure clear／late completion publication fence；未知 same-account 不 eligible；不誤判修正／人工 reset |
| Capabilities／UI | Claude 無 Activity／Insights／Reserve；enablement≠support；窄版、英繁中、VoiceOver 與 keyboard 留獨立 manual acceptance |
| Notification | fake center/store／epoch 有而 freshness 不足也不得送；auth/source 失效清 pending；same window, different source 不能跨 baseline |

Fixtures 全部手寫 synthetic，有清楚 scope/provenance 標註；不從真實 account response「刪幾欄」後 commit。測試不需 real account、network、Keychain、私密 local state 或現有 Claude 設定。

## 15. 實作分類與 staged milestones

選擇且只選擇 **B — CLAUDE PROVIDER PARTIALLY IMPLEMENTABLE**。

| Capability | 可以開始的安全工作 | 不能現在宣稱 |
| --- | --- | --- |
| quota | 官方兩視窗 typed contract、嚴格 projection／parser 測試、availability scope | live 當前帳號 quota 可任意刷新 |
| reset time display | epoch/樣本 expiry 契約與純顯示 | reset 已完成、fixed local clock 推算 |
| reset notifications | 只設計 gates 與 failure tests | production reminders／completed reset 安全 |
| install/auth | isolated locator／fake command runner／safe 診斷設計 | App 已支援 auth 偵測／remote credential validity |
| account activity／daily history | 保持 unsupported／不註冊 source | 由 local stats 取得帳號活動 |
| activity insights／reserve | capability 禁用與隔離測試 | Claude 具備 Codex 對等功能 |

| Milestone | 有界交付與進入條件 | 完成證據 |
| --- | --- | --- |
| **M0 — contracts/capabilities** | 訂閱額度、本機活動與 API billing 分型；support 與 runtime availability 分開；來源 freshness／account unknown 明確表達 | synthetic capability/failure/privacy tests；無 live I/O。**推薦下一輪範圍** |
| **M1 — projection/parser hardening** | 官方 snake_case allowlist 投影、嚴格 0…100／reset／version／expired window；糾正現有 clamp 測試及 v1 schema 假設 | deterministic parser/filesystem tests；只有 non-live foundation |
| **M2 — opt-in source bridge** | M0/M1 完成，正常訂閱 session 被動 delivery 可驗證；先提供人工 composition，不自動修改 settings | minimal schema delivery、atomic write／owner/mode／bounded stdin、原 status line 輸出與可復原整合證據；先 Experimental |
| **M3 — provider/lifecycle** | 對 source age／failed/expired/unknown continuity 有明確產品 policy | 源失效 clear、coalescing／cancel／late completion、re-baseline；無 persistent Claude process |
| **M4 — capability UI** | M3 允許顯示的 snapshot 及局限已成立 | setup/version/auth/source/expired 區別；pin 與 5H/W 正確；activity/reserve 不開；獨立 manual UI 驗收 |
| **M5 — notifications** | **blocked**，須可信 source freshness 與足夠 continuity／安全 policy 實證；只有 epoch 不夠 | fake center 測試 + 正常使用中的有界 live acceptance；completed reset 另設更高 gate |
| **M6 — acceptance** | 該能力所有前置 gates 通過 | 支援版本／Pro 與 Max／nil/expiry/idle／settings/trust/composition、resource profile 與 privacy；成功後才修改 Supported status |

本輪未實作 optional foundation code：timestamp provenance、未知 account continuity 與 capability shape 需要先固化產品政策。沒有為了「有程式碼交付」建立空 abstraction 或整套架構。

## 16. 官方來源索引

各來源於 2026-10-05 查核。Docs/help center 是浮動文件，並不保證本機 2.1.246 具有所有較新欄位。S08 固定 changelog commit，其餘記錄訪問日與 section；不把非官方 mirror／社群說法當穩定 contract。

| ID | 直接來源與使用 section |
| --- | --- |
| S01 | [Customize your status line](https://code.claude.com/docs/en/statusline)：Available data、How status lines work、Rate limit usage、Spend limit fields |
| S02 | [CLI reference](https://code.claude.com/docs/en/cli-reference)：CLI commands、auth status、print/input/output flags |
| S03 | [Authentication](https://code.claude.com/docs/en/authentication)：credential management、precedence、expiry、Console/subscription 差異 |
| S04 | [Manage costs effectively](https://code.claude.com/docs/en/costs)：/usage、local plan breakdown、request failure／last-known bars、/insights |
| S05 | [Commands](https://code.claude.com/docs/en/commands)：/usage、/cost、/stats、/status |
| S06 | [Legal and compliance](https://code.claude.com/docs/en/legal-and-compliance#authentication-and-credential-use)：不得蒐集／儲存／轉介 Claude.ai 憑證、第三方不提供自己的 Claude.ai 登入 |
| S07 | [Agent SDK Python reference](https://code.claude.com/docs/en/agent-sdk/python#ratelimitinfo)：RateLimitEvent／RateLimitInfo、ResultMessage |
| S08 | [Official changelog at 2bfb629](https://github.com/anthropics/claude-code/blob/2bfb629dfaff0c8318047a4beb93cf1dc5b58b18/CHANGELOG.md)：2.1.41 auth commands、2.1.80 quota、2.1.243 idle fix、2.1.251 gateway、2.1.268 configDirectory、2.1.284 USD、2.1.286 auth classification fix |
| S09 | [What is the Pro plan?](https://support.claude.com/en/articles/8325606-what-is-the-pro-plan)：session／fixed weekly／額外限制 |
| S10 | [What is the Max plan?](https://support.claude.com/en/articles/11049741-what-is-the-max-plan)：session／fixed assigned weekly |
| S11 | [Usage and Cost API](https://platform.claude.com/docs/en/manage-claude/usage-cost-api)：組織 API usage、credential category、product separation |
| S12 | [Claude Code Analytics API](https://platform.claude.com/docs/en/manage-claude/claude-code-analytics-api)：daily aggregation／actors／組織 admin scope |
| S13 | [Analytics APIs](https://platform.claude.com/docs/en/manage-claude/analytics-api)：Admin vs Enterprise Analytics、primary owner key、plan/data freshness 限制 |
| S14 | [Settings files and precedence](https://code.claude.com/docs/en/settings)：settings locations、CLAUDE_CONFIG_DIR、.claude.json、managed/trust |
| S15 | [Claude pricing](https://claude.com/pricing)：rolling five-hour session、跨 web/desktop/mobile/Code 共享 pool |
| S16 | [Manage usage credits for paid Claude plans](https://support.claude.com/en/articles/12429409-manage-usage-credits-for-paid-claude-plans)：included allowance 與 paid credits 分開 |
| S17 | [Agent SDK TypeScript reference — AccountInfo](https://code.claude.com/docs/en/agent-sdk/typescript#accountinfo)：accountInfo／optional metadata／ModelUsage；web reader 失敗後從官方 HTML 直接唯讀查核，未執行 SDK |
| S18 | [What is a limit reset?](https://support.claude.com/en/articles/17007452-what-is-a-limit-reset)：人工 limit reset 與 regular weekly schedule 分開 |
| S19 | [Monitoring](https://code.claude.com/docs/en/monitoring-usage#security-and-privacy)：opt-in OTel／email／prompt attributes 風險 |

## 17. 本輪交付與 validation

- 新增本文件；更新 `ARCHITECTURE.md` 的 Claude 研究結論；舊 `docs/providers/claude-code.md` 加 historical／superseded note。
- Swift、tests、project metadata、README status、ROADMAP milestone、website、beta／release files 均不改。
- 文件檢查：`git diff --check`；另外確認變更檔案清單、App/test version 欄位與 beta ref 維持 baseline。沒有 source/test code，因此不跑 XCTest／Debug build／release validation。
- 建立單一 focused local documentation commit，不 push。實際 commit SHA 與最後 git state 由本輪最終報告回填到聊天；不把文件內自我引用當 commit 證據。
- 下一步：只執行 M0／M1 non-live contract 與 parser 工作；真實 source 需 M2 被動 delivery gate，通知需 M5 額外 gate。個人 Account Activity／Insights／Reserve 維持 unsupported。
