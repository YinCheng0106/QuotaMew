# Provider 資料來源策略

狀態：2026-08-24 provider research review。此文件只決定 Codex 與 Claude Code 的 production 資料來源、fallback 與 unavailable policy，不代表 UI wiring、bridge 安裝或其他實作授權。

## 1. 決策原則

QuotaMew 的資料來源必須同時滿足：

- 回傳 provider 的實際用量，不由 token count、活動量或方案名稱推估
- 可取得 provider 提供的 reset timestamp；缺少時保持 unavailable
- 不讀取或複製 authentication secrets
- 不掃描 prompt、conversation、原始碼、tool output 或 repository metadata
- 可設定明確的輸入大小上限、timeout 與 freshness policy
- 不需要積極輪詢，也不維持不必要的長駐 process
- provider contract 改變時能安全失敗，而不是顯示看似合理的錯誤數值

資料來源的「格式穩定性」與「是否適合 QuotaMew」是兩個不同判斷。例如 Claude Agent SDK 的 `RateLimitEvent` 有官方文件，但為了取得 event 而啟動 active agent session 並不適合被動 menu bar App。

## 2. 分類定義

| 分類 | 定義 | Production policy |
| --- | --- | --- |
| Stable / documented | Provider 官方文件明確定義 machine-readable method、event 或欄位語意 | 可作主要來源，但仍需版本、錯誤與缺欄位處理 |
| Reliable but undocumented | 本機或 protocol evidence 顯示數值是真實 provider data，但沒有相容性承諾 | 不作預設 contract；只有必要且有明確風險標示時才評估 |
| Fragile | 依賴 TUI、畫面文案、終端輸出、bundle path 或其他 presentation detail | 不作自動資料來源 |
| Experimental | 有技術可行性，但 freshness、schema、privacy 或 deployment assumptions 尚未充分驗證 | 預設關閉；必須 opt-in、bounded 且可移除 |
| Not suitable for production | 無法提供真實 quota、需要碰 credential、會接觸高敏感資料，或成本／政策風險不可接受 | 禁止使用；無資料時顯示 unavailable |

## 3. Codex 與 Claude Code 總覽

| 比較項目 | Codex | Claude Code |
| --- | --- | --- |
| 建議主要來源 | 官方 `codex app-server` 的 `account/rateLimits/read` | 官方 status-line stdin JSON 的 `rate_limits`，經 explicit opt-in bridge 寫入 QuotaPulse-owned snapshot |
| 主要來源分類 | Stable / documented | Stable / documented contract；delivery 為條件式，bridge setup 仍屬 Experimental |
| 實際用量百分比 | `usedPercent` | `five_hour.used_percentage`、`seven_day.used_percentage` |
| Reset timestamp | `resetsAt` | `five_hour.resets_at`、`seven_day.resets_at` |
| Freshness model | QuotaMew 可按需啟動 app-server 取得新資料 | 只能在 Claude Code status-line event 發生時更新；可能 stale |
| Authentication | 必要，但由 Codex process 管理；QuotaMew 不讀 token | 產生資料時需要合資格的 Claude.ai session；bridge 與 provider 不讀 token |
| Provider 私有檔案 | 不需要 | bridge setup 需要明確處理 settings；runtime provider 只讀 QuotaMew snapshot |
| 私密內容風險 | 低，只解碼指定 response 且不保存 raw output | status-line raw JSON 含 workspace/session 等欄位；bridge 必須立即白名單化並捨棄其餘欄位 |
| Polling | 不需要；啟動、資料過期或手動刷新時按需查詢 | 不需要；event-driven capture，QuotaMew 只在需要時讀小型 snapshot |
| Production readiness | 兩者中較高；已有官方 pull-style machine contract 與 sanitized live probe | 較低；需要可逆 bridge setup、支援版本、方案資格、first-response 與缺欄位處理 |
| 建議 fallback | QuotaMew last-known normalized snapshot，標示 stale | QuotaMew last-known bridge snapshot，標示 stale |
| Provider-native fallback | 無；Codex session JSONL 預設停用 | 無；不得 fallback 到 transcript、`/usage` scraping 或 credential-backed endpoint |

官方 contract 參考：[Codex App Server](https://learn.chatgpt.com/docs/app-server)、[Claude Code status line](https://code.claude.com/docs/en/statusline)。

## 4. Codex 資料來源逐項評估

表格縮寫：

- 「Auth」表示取得或產生資料是否需要 authentication。
- 「Local files」表示 QuotaMew 是否必須讀取本機檔案。
- 「Polling」的「否」包含使用者刷新、資料過期時的按需查詢，以及 provider 事件驅動更新。

| 資料來源 | 分類 | 實際 % | Reset | Auth | Local files | 私密資訊暴露 | 無預警變更風險 | Polling | 可 bounded／高效率 | Production 決策 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `account/rateLimits/read` | Stable / documented | 是 | 是 | 是，由 Codex 管理 | 否 | 低；不得保存 raw stdout/stderr | 低至中；需相容解碼與版本測試 | 否，按需 | 是；單一健康 process 重用、timeout、單筆 response buffer、stdout 上限 | **Primary** |
| QuotaMew last-known normalized snapshot | Stable / documented（QuotaMew 自有 schema） | 是，來自上次成功結果 | 是，若來源曾提供 | 讀取時否 | 是，只讀 App 自有小檔 | 低；只含正規化 quota fields | 低，由 QuotaMew 版本化 | 否 | 是；小型原子檔 | **Fallback**，必須標示 capture time 與 stale |
| `sessions/**/*.jsonl` 的 `rate_limits` event | Reliable but undocumented；作為產品功能時屬 Experimental | 是，fresh event 可含實際值 | 是，fresh event 可含 timestamp | 讀取時否；產生時需要 Codex session | 是 | 極高；與 prompt、tool output、conversation 混存 | 高；persisted schema 沒有 contract | 可不輪詢，但需找最新檔案／event | 只有 bounded tail read 才勉強可接受 | 預設停用；官方 app-server 存在時沒有合理 fallback 必要 |
| 互動式 `/status` 畫面 | Fragile | 畫面可能有 | 畫面可能有 | 是 | 否 | 中；可能同時顯示 account/session metadata | 極高；文案、版面、ANSI、終端寬度可變 | 需要反覆啟動／scrape | 可限制輸出，但語意仍不穩定 | 不使用，只供人工比對 |
| `config.toml` | Not suitable for production | 否 | 否 | 否 | 是 | 中；可能含 command、environment、本機 path | 中 | 否 | 檔案通常小，但沒有 quota value | 不使用 |
| `auth.json` | Not suitable for production | 否 | 否 | 本身就是 credential | 是 | 極高；authentication secret | 高且政策風險不可接受 | 否 | 大小不是問題，存取本身即違反邊界 | 永不讀取 |
| `session_index.jsonl` | Not suitable for production | 否 | 否 | 否 | 是 | 高；含 thread metadata | 高；internal schema | 否 | 可 bounded，但沒有 quota | 不使用 |
| logs SQLite／通用 log body | Not suitable for production | 沒有專用欄位 | 沒有專用欄位 | 否 | 是 | 高；通用 body 可能含敏感內容 | 高；internal schema | 若要更新就需查詢 | Database 可分頁，但沒有可靠語意 | 不查 row body，不使用 |
| state、thread-history SQLite、model/application caches | Not suitable for production | 未發現 | 未發現 | 否 | 是 | 高；thread/project/application state | 高；internal schema | 否 | 技術上可查 schema，但沒有 quota contract | 不使用 |
| 由 token totals／活動量推估 | Not suitable for production | 否，只能猜測 | 否 | 否 | 通常要讀 sessions/logs | 高；需讀 coding history | Provider weighting 可隨時改變 | 可能需要持續累計 | 即使可增量，結果仍不可信 | 禁止 |
| 逆向未文件化 HTTP endpoint 並重用 token | Not suitable for production | 可能 | 可能 | 是，且需取得 credential | 可能 | 極高；secret、政策與帳號風險 | 極高 | 需要 network polling | request 本身小，但安全與相容性不可接受 | 禁止 |

### Codex 建議

**Primary source**

使用 `codex app-server` 的 `account/rateLimits/read`。QuotaMew 只在啟動、使用者手動刷新，或 snapshot 超過 freshness threshold 時按需查詢；健康時重用唯一 process，timeout、cancellation、connection failure 或 App termination 時完整關閉並 reap。它不讀 `~/.codex`，也不保存 raw stdout/stderr。

**Fallback source**

保留上次成功取得的 QuotaMew-owned normalized snapshot 於記憶體。若新查詢 timeout、offline 或暫時失敗，顯示 last-known values、capture time 與 `stale`。在 snapshot 不存在時顯示 unavailable。

Codex session JSONL 不應作 production fallback。它只能列為未來的 explicit experimental investigation，且只有官方 contract 長期無法使用時才重新評估。

**必須顯示 unavailable 的欄位／狀態**

- response 沒有 `usedPercent`：整個對應 window unavailable，不推論 0%
- 沒有 `resetsAt`：reset time 與 countdown unavailable
- 沒有 `windowDurationMins`：duration unavailable，不由 bucket name 推測
- `secondary` window 缺少：只顯示存在的 primary，不自行建立 secondary
- `rateLimitsByLimitId` 某個 bucket 缺少：不由其他 bucket 複製
- provider 沒有穩定 `limitName`：使用中性 window label，不猜方案名稱
- executable 不存在、未登入、authentication mode 不支援、offline、timeout 或 protocol 不相容：使用明確 provider status，不顯示假資料
- reset timestamp 已過：舊 snapshot 標示 stale，不宣稱額度已重設或 usage 已歸零

## 5. Claude Code 資料來源逐項評估

| 資料來源 | 分類 | 實際 % | Reset | Auth | Local files | 私密資訊暴露 | 無預警變更風險 | Polling | 可 bounded／高效率 | Production 決策 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| status-line stdin `rate_limits` | Stable / documented；delivery 條件式 | 是 | 是 | 產生時是；bridge 不碰 credential | capture 本身否 | Raw JSON 風險高，含 workspace/session 等；白名單化後低 | 中；欄位有文件，但受版本、方案、first response 與已知缺欄位問題影響 | 否，event-driven | 是；stdin 與 decode 設上限，立即捨棄未知欄位 | **Primary capture source** |
| QuotaPulse-owned versioned snapshot | Stable / documented（QuotaMew 自有 schema）；bridge setup 屬 Experimental | 是，來自 status-line | 是，若來源提供 | 讀取時否 | 是，只讀 App 自有小檔 | 低；只保存白名單 quota fields | 低，由 QuotaMew 控制；上游仍可能缺欄位 | 否 | 是；小型、owner-only、atomic replace | **Primary runtime source 與 fallback** |
| `/usage`、`/cost`、`/stats` TUI | Fragile | 是，畫面含 plan bars | 是，畫面可顯示 reset | 是 | 可能使用內部 cache，但 QuotaMew 不需讀 | 中至高；同畫面有 account、activity、cost data | 極高；interactive layout 與文案可變 | 若自動化就需反覆開啟 | 可限制 process output，但無 machine contract | 不解析；只供使用者人工確認 |
| Agent SDK `RateLimitEvent` | Stable / documented，但不適合被動查詢 | 有時有 `utilization` | 有時有 `resets_at` | 是 | 否 | 中；active agent session 會產生 conversation／event data | 低至中；SDK type 有 contract | 需等待 active session event | event 可 bounded，但啟動 agent 的成本不合理 | 不為 quota monitor 啟動 Agent SDK |
| `stats-cache.json` | Not suitable for production | 否；只有活動／token stats | 否 | 否 | 是 | 中；使用行為 metadata | 高；internal cache | 若追蹤就需重讀 | 檔案小，但不能代表跨裝置 plan quota | 不使用、不推估 |
| `projects/**/*.jsonl` transcripts | Not suitable for production | 未承諾 | 未承諾 | 讀取時否 | 是 | 極高；prompt、response、tool、workspace 資料 | 極高；internal transcript schema | 可不輪詢，但需搜尋大量檔案 | 不符合；本機樣本接近 90 MiB，最大單檔超過 30 MiB | 永不掃描 |
| `history.jsonl` | Not suitable for production | 否 | 否 | 否 | 是 | 極高；prompt history | 高 | 否 | 可 bounded，但沒有 quota | 永不讀取 |
| `~/.claude.json`、credential files、Keychain | Not suitable for production | 否；主要是 auth/state | 否 | 本身就是 authentication state | 是 | 極高；OAuth、API key、project/trust metadata | 高且政策風險不可接受 | 否 | 大小不是問題，存取本身即違反邊界 | 永不讀取／搜尋 |
| debug logs、`usage-data` reports | Not suitable for production | 未承諾 | 未承諾 | 否 | 是 | 極高；工作行為、錯誤或 session 摘要 | 高；internal/report format | 若更新就需重讀 | 可分段，但沒有 quota contract | 不使用 |
| claude.ai usage page screen scraping | Fragile | 是 | 通常是 | 是 | 否 | 高；account、billing、activity metadata | 極高；Web UI 可隨時改變 | 是 | DOM 可局部讀，但需 web session／web view | 不使用 |
| 未文件化 Claude.ai usage endpoint | Not suitable for production | 可能 | 可能 | 是，需重用或取得 OAuth credential | 可能 | 極高；credential、政策與帳號風險 | 極高 | 需要 network polling | request 小，但安全／政策不可接受 | 禁止 |
| 為觸發 status line 而送出 synthetic Claude request | Not suitable for production | 可能在 response 後取得 | 可能 | 是 | 否 | 高；會建立 conversation／傳送資料 | 中；副作用與計費可變 | 每次 freshness 都要 request | 資源可控但會消耗額度，違反被動監看目的 | 禁止 |

### Claude Code 建議

**Primary source**

使用 official status-line `rate_limits` 作 capture source，但透過 explicit opt-in bridge 立即轉為 QuotaPulse-owned minimal snapshot。Runtime `ClaudeProvider` 只讀該 snapshot，不讀 `~/.claude`。

Bridge 必須：

- 不靜默取代現有 `statusLine.command`
- 提供設定 preview、existing-command composition 或人工整合方式，以及可復原流程
- 對 stdin 設定嚴格大小上限
- 只保留 `five_hour`／`seven_day` 的 `used_percentage`、`resets_at`、Claude Code version、schema version 與 capture time
- 立即捨棄 workspace、cwd、repository、transcript、session、prompt、model、token、cost、git、PR、worktree 與 unknown fields
- 使用 owner-only directory 與 atomic replace

**Fallback source**

同一份 QuotaPulse-owned snapshot 也是唯一可接受的 fallback。Claude Code 沒有新 status-line event，或某次 event 缺少 `rate_limits` 時，可保留先前 snapshot 並標示 stale；不能用新的空 event 把 last-known values 誤寫成 0%。

沒有可接受的 provider-native machine fallback。`/usage` 只能讓使用者人工確認；transcripts、stats cache、credentials 與未文件化 endpoint 都不得使用。

**必須顯示 unavailable 的欄位／狀態**

- first API response 之前沒有 `rate_limits`：顯示 unavailable／waiting for first response
- authentication mode、plan 或 Claude Code version 不提供該欄位：顯示 unsupported 或 unavailable
- `five_hour` 缺少：5-hour usage、reset 與 countdown 全部 unavailable
- `seven_day` 缺少：7-day usage、reset 與 countdown 全部 unavailable
- window 有 percentage、沒有 `resets_at`：只顯示 percentage；reset 與 countdown unavailable
- 兩個 windows 都缺少：不建立空卡片數值，不以 context percentage、session cost 或 activity 代替
- API key、Bedrock、Vertex、Foundry、Team／Enterprise 等未被 status-line contract 明確涵蓋的情境：在實測與文件確認前不猜支援
- overage、model-specific weekly limits、plan name、hard cap、remaining credits 等不在選定 status-line schema 的欄位：unavailable
- snapshot 太舊或 reset timestamp 已過：顯示 stale；不宣稱 quota 已重設
- bridge 未設定、workspace trust 阻擋、existing command 無法安全組合：顯示 notConfigured，不自動改設定

## 6. 共用刷新與 persistence 策略

兩個 providers 應共用下列政策：

1. UI 只接收 `ProviderUsageSnapshot`，不理解 provider DTO、process 或檔案位置。
2. 同一時間只允許一個 refresh task；providers 依序執行。
3. Codex 使用按需 pull；Claude 使用 event-driven capture 加小型 snapshot read。
4. 不使用全域秒級 timer，也不積極輪詢 provider。
5. 每份可持久化 snapshot 必須包含 provider、capture time、schema version 與實際存在的 windows。
6. last-known snapshot 必須有 freshness threshold；超過門檻仍可顯示，但狀態必須是 stale。
7. 過期的 reset timestamp 不是「已成功重設」的證據。
8. malformed、future-schema、oversized、missing 或 unsupported input 必須安全失敗。
9. 不保存 raw provider payload、error body、stdout/stderr、conversation 或 credential。
10. Remote Reset Intelligence 將來仍走獨立 service，不接收本機 usage snapshot。

## 7. 建議實作順序

**先完成 Codex。**

理由：

- `account/rateLimits/read` 是官方、machine-readable、pull-style contract。
- 可以在不修改使用者 Codex 設定、不讀 credential 與不掃描 session files 的情況下取得 fresh usage。
- refresh、timeout、process cleanup 與 missing executable/authentication states 都能在 provider 邊界內明確處理。
- 已有 sanitized live probe 證明本機版本可回傳預期欄位型別。
- Claude Code 還需要可逆的 status-line bridge 安裝設計、existing-command composition、最低版本與方案 eligibility 檢查，而且資料只在 session event 後更新。
- Claude 官方欄位雖有文件，仍有實務上的 missing-field reports；先完成 Codex 可讓共用 stale、error 與 persistence UX 在較穩定的來源上定型。

Claude Code 應排在 Codex 後面，先完成 bridge 設定 preview／復原與 redacted live fixture validation，再進入 UI wiring。兩個 providers 都不應先啟用 raw local-file fallback。
