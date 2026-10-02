# QuotaMew 下一階段產品與架構研究

研究日期：2026-10-02。基準：本機 `3a63921`，工作目錄起始乾淨；README 為 v0.2.0 RC.2，部分架構／roadmap 文件仍保留較早版本描述。本研究是 **v0.2 stable 之後的提案**，沒有改變已凍結的 runtime、版本、既有 roadmap 或 release metadata。

證據標示：**VERIFIED**＝本次讀到的實作或第一方文件明確支持；競品的 VERIFIED 僅表示「已文件化」，不代表安裝實測或隱私稽核。**INFERRED**＝由證據推導、需要驗證；**UNKNOWN**＝本次未取得足夠證據，並非證明不存在。所有新整合均未做登入、真實帳號或裝置測試；沒有讀取本機 credentials、sessions、transcripts 或 private provider payload。

## 1. Executive conclusion

**建議方向：可信的本機 Limits + Usage 工具；Cost 是受資料品質約束的衍生能力。** 優先回答「還能用多少？最近用了多少？這個數字可信到什麼程度？」不把 token 多寡包裝成生產力，也不把 API 等值估算包裝成帳單。

| 決策 | 建議與關鍵理由 |
| --- | --- |
| v0.3 | Codex 每日 token 總量與 7／30 日趨勢，明確 opt-in、本機 aggregate history；不含成本、模型拆分、runway、sync |
| 第一個實作里程碑 | 驗證 `account/usage/read` 的相容／隱私契約，交付最小「每日總量 → 本機儲存 → 7 日 Usage 視窗」切片；不支援即 unavailable |
| 關鍵新證據 | [Codex 官方 app-server 文件](https://learn.chatgpt.com/docs/app-server#7-token-usage-chatgpt) 已列 `account/usage/read` 與 optional daily buckets；不必先讀 rollout JSONL 才能探索每日用量 |
| 不跨越的界線 | 不讀 credentials，不讀對話 body，不讀專案路徑；只保留 allowlisted counters、時間區間與 provenance |
| 差異化 | 不持有供應商憑證、不要求上傳歷史、呈現來源／涵蓋範圍／缺資料；成本有明確語意與可重算依據 |
| Reset Intelligence | 選 **B：Usage Intelligence first**，但 v0.3 的 intelligence 只限可觀測趨勢。保留 feed frozen contracts；不把 feed ingestion 和 token history 合併成巨大 foundation |
| Apple 生態系 | 先本機 widget，再評估 CloudKit private mirror；iPhone 不先做 direct provider client |

**Go/no-go：** `account/usage/read` 有文件不等於 RC.2 所用 runtime 支援，也不等於 daily bucket 的時區、服務涵蓋與修訂語意已清楚。若驗證失敗，縮小為 Claude quota bridge completion 的獨立版本；不改採 transcript fallback 來守住原訂功能名稱。

## 2. 現有架構值得保留的限制

| 現有責任與檔案 | 穩定邊界／自然演進 | 不應承擔的責任 |
| --- | --- | --- |
| [`UsageProvider`](../QuotaMew/Providers/UsageProvider.swift)、[`UsageWindow`](../QuotaMew/Domain/UsageWindow.swift)、[`ProviderUsageSnapshot`](../QuotaMew/Domain/ProviderUsageSnapshot.swift) | 現況額度百分比、reset、duration、capture time、source；保留 protocol 與 domain 語意 | token 流量、累計事件、價格、歷史資料庫 |
| [`ProviderID`](../QuotaMew/Domain/ProviderID.swift) | 目前 codex／claude enum；新增已實作 provider 才擴充，保留未知 raw preference | 把 OpenCode client、GLM backend、訂閱帳號、模型全混成同一 ID |
| [`UsageService`](../QuotaMew/Services/UsageService.swift)、[`RefreshCoordinator`](../QuotaMew/Services/RefreshCoordinator.swift) | actor、provider 依序刷新、eligibility、取消與 coalescing | 歷史掃描、OTLP receiver、pricing fetch、CloudKit upload |
| [`CodexProvider`](../QuotaMew/Providers/Codex/CodexProvider.swift) | 只把 rate limits DTO 映射成 windows；Codex 擁有 auth | 透過 token 反推 quota；自動接管工作 thread |
| [`ClaudeProvider`](../QuotaMew/Providers/Claude/ClaudeProvider.swift) | bounded、自有 snapshot reader；freshness 取自 bridge capture time | transcript／stats-cache quota fallback；status-line token 直接相加 |
| [`AppModel`](../QuotaMew/App/AppModel.swift) | 目前 provider states、刷新／lifecycle、完成後通知評估 | 每筆歷史 record 的 observable array、DB／價格計算 |
| [`SettingsStore`](../QuotaMew/Services/SettingsStore.swift) | typed local preferences、現有 keys、upgrade／onboarding 行為 | history／cost records、cloud credentials |
| [`MenuBarPresentation`](../QuotaMew/Features/MenuBar/MenuBarPresentation.swift)、[`ProviderWindowsPresentation`](../QuotaMew/Domain/UsageWindowPresentation.swift) | 純值 projection、穩定 identity、保守 Reserve、VoiceOver 共用語意 | 查詢 DB、啟動 CLI、藉 estimated history 改寫 available／reset |

實際平台已是 **一個 AppKit NSStatusItem + SwiftUI popover**，不應為 Widget 或 analytics 改回另一套選單列 host。[ARCHITECTURE](../ARCHITECTURE.md)、[v0.2 plan](V0_2_PLAN.md) 支持演進式增加獨立路徑。

實作／指示有一個需在未來工作規劃明講的差異：[PERFORMANCE](PERFORMANCE.md) 與 client source 目前允許單一健康 app-server child 重用，並有 bounded reader、timeout、disconnect／reap；AGENTS 的一般規則偏向不長駐。**本研究不改 lifecycle**；新增 analytics 也不能增加第二個常駐 child 或延長其生命週期。主 app 約 48 MB 的舊觀察缺少完整量測條件，不能作為 analytics／widget 的效能保證。

## 3. 競爭景觀

下表是第一方文件／README 的目前能力，不是把 landing page 的展示數字當成實測。

| 產品 | Providers／Limits | Tokens／Cost／History | Apple surfaces／Sync | 憑證／資料流／商業模式 | 證據狀態與產品啟示 |
| --- | --- | --- | --- | --- | --- |
| Nowdex | Codex、Claude、Cursor、Kimi、GLM、MiniMax、Grok、Qoder 等 | agent／model／day、年度 heatmap、tokens／cost；Usage 由 tokens.ci 提供 | Mac、iPhone、iPad；Home／Lock Screen、Usage widget；iCloud provider setup sync | Keychain 持有憑證，可同步 iCloud Keychain；free 一個 service／account，Pro 解鎖更多；確切區域 IAP 價格 UNKNOWN | **VERIFIED 文件**；credential mirror 與無憑證 snapshot mirror 是不同產品。成本是否 billed UNKNOWN。[產品](https://nowdex.app/)、[政策](https://nowdex.app/privacy/)、[App Store](https://apps.apple.com/ca/app/nowdex/id6791450777) |
| AgentPeek | 文件列 Claude、Codex、Cursor、Copilot、Kimi、OpenCode 等多種 agent，window 能力依來源 | local monthly／daily usage、provider-recorded tokens／cost；不保證各 agent 皆完整 | notch、menu bar、floating windows；其「widgets」是 app floating cards，非已驗證 WidgetKit；iOS／Watch／sync UNKNOWN | local logs／hooks／stores；Cursor／Kimi 重用 sign-in；license／trial network。$19.99／Mac 一次付費、3 日 trial 的公開頁面 | **VERIFIED 文件**；主要是 session workflow monitor，會讀 prompts／diffs／paths，不能照搬。[Usage](https://agentpeek.app/docs/usage/)、[Privacy](https://agentpeek.app/docs/privacy/)、[Widgets](https://agentpeek.app/docs/widgets/)、[價格](https://www.agentpeek.app/build-vs-buy/) |
| Tokenomics | Claude、Codex、Gemini；網站另列 Cursor／Copilot 等，與 repo 說明不完全一致 | 主要 quota／pacing；Gemini budget 明標 estimated；完整 model history／cost analytics UNKNOWN | Mac small／medium WidgetKit 已文件化；iOS／Watch／sync UNKNOWN | 讀 Keychain／auth config／session files；free、source available、捐款 | **VERIFIED 文件但 coverage 矛盾**；不能因列 provider 就視為各 metric 已完整。[README](https://github.com/rob-stout/Tokenomics)、[網站](https://trytokenomics.com/)、[Privacy](https://trytokenomics.com/privacy) |
| Tokcat | 多種 coding clients，含 Claude、Codex、Cursor、Copilot、Gemini、OpenCode；quota cards 僅部分 | local token／cost history、client 分頁、daily charts／3D graph、live velocity；model-price table | Mac menu bar；WidgetKit／iOS／Watch UNKNOWN；README 說無 cloud sync | local log parsing；Cursor usage opt-in network；quota 可能使用 local credentials；free MIT | **VERIFIED README**；低相依、native、local-first 已非獨有，差異須落在讀取界線與數值語意。[repo](https://github.com/handlecusion/tokcat) |
| VibeUsage | Codex、Claude、Gemini、OpenCode、Hermes、OpenClaw 等 token sources；不是已驗證 subscription-quota monitor | input／output／cache／reasoning、model／project、trends、cost estimates | hosted dashboard／public profiles／leaderboards；Apple native widgets／Watch UNKNOWN | local hooks／parsers → 30 分鐘 UTC aggregates → backend；可含 public repo attribution；MIT，服務商業價格 UNKNOWN | **VERIFIED README**；「不傳 transcript」仍不等於「不傳用量」。[repo](https://github.com/victorGPT/vibeusage) |
| CodexBar | 多 provider／account quota，有多種 CLI／OAuth／cookie／API strategies | local token-cost CLI 與 usage surfaces，細節依 provider | Mac WidgetKit；同一產品的 iPhone／Watch 本次未證實 | 本機解析；部分策略讀 cookie／token、可能需權限；MIT | **VERIFIED README**；廣度與 credential strategy 帶來維護面；QuotaMew 不應競逐相同 provider 數。[repo](https://github.com/steipete/CodexBar) |

**重要拆分：** Nowdex 政策說 iCloud 同步 connection metadata、可同步 credentials，但不以該路徑同步 usage snapshots。其 Usage tab 又連到 tokens.ci；[tokens.ci 政策](https://tokens.ci/privacy) 說 CLI 讀 local sessions、上傳每日 counters／估算 cost／model／client／date，並有 GitHub identity 和公開排行。**INFERRED：** Nowdex Usage 不是只靠純本機 quota source；其完整授權／私有資料存取流程仍 UNKNOWN。不要將「沒有 Nowdex backend」解讀為「所有 analytics 都不離開裝置」。

本次未找到上述產品可靠的 Apple Watch 支援證據，一律 UNKNOWN。Nowdex zh-TW URL 多次無法取得，使用同站英文產品、最新 privacy 與 App Store 交叉確認；未安裝任一競品。

## 4. Provider capability matrix

能力指 QuotaMew **在現有隱私政策下可探索的資料來源**；「供應商 API 存在」與「QuotaMew 可無憑證被動取得」分開。

| Ecosystem | Quota／limits | Tokens | Model | Cost | History | Source confidence | Privacy risk／決策 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Codex／ChatGPT | Verified：`account/rateLimits/read` | Possible：documented `account/usage/read` daily total；thread 細分僅 active thread events | daily endpoint 不提供；thread protocol 有，但非全帳號 monitor | daily total 無法算；細分／模型齊全才可能 | documented optional daily buckets；本機版本未驗證 | A quota；B activity；C rollout fields | 低（account protocol）；高（JSONL）；先驗證 B，不掃 logs |
| Claude Code | documented status-line，實際 QuotaMew bridge 未完成 | Possible：OTel metrics；status line 僅 current context | documented status-line／metrics | provider-reported **approximation**；非帳單 | opt-in metrics 只能從收集開始，無自動 backfill | B | 中：stdin／metric attributes 帶其他 metadata，須源頭 allowlist |
| Gemini CLI | `/stats model` 有 quota 資訊；無已證實第三方 pull contract | Possible：OTel counters／headless stats | documented metrics／result | public price × counters 可估；沒有證明 billed source | 新收集可行；session JSON 為 C／敏感 | B token；D 或 unavailable quota integration | 中高：telemetry `logPrompts` 預設 true；不啟用預設 logs |
| OpenCode | client 本身無共同訂閱 quota；Go／Console 是獨立服務 | Possible：v2 `stats --json`；legacy DB 結構 C | `stats --models`；schema 要驗證 | stats source 不等於帳單；Console usage API 明載 charged amount，但需 key | local stats，日別粒度未驗證 | B CLI；C DB；B credential API | CLI 優先；排除含 message parts 的 server route，先研究 v1/v2 |
| Cursor | documented Teams admin usage／spend；個人 quota pull UNKNOWN | Teams usage events 有 tokens；需 admin key | Teams usage events 有 | reported spend／events，有 billing basis 仍須辨認 | Teams API 可查；個人 local stores 不穩定 | B Teams；D 個人 dashboard | 高：credentials、team／email data；不排進近期 |
| GitHub Copilot | billing API 有 premium requests／AI credits；不等於即時 remaining quota | 本次未證實通用個人 input/output token history | billing report 有 model | reported netAmount／unitType，必須保留 billed units | 官方 billing reports；org metrics 另是 adoption telemetry | B authenticated billing；D internal quota | 拒絕直接 token access；可能 user-import report，但不做近期 provider |
| Kimi Code | 官方 `/usage`／console；第三方 machine contract UNKNOWN | API／CLI 整合可能；被動安全 source 未證實 | 可透過 client；本次未驗證 usage record schema | API-equivalent 需 counters；billing source 未證實 | CLI sessions 是敏感候選，拒絕近期掃描 | B 人工介面；D machine integration | 停在 quick research；不為補 quota 讀 sign-in token |
| GLM／Z.ai | Coding Plan 存在；本次未找到公開 quota pull contract | response `usage` 有 input/output/cache read | response 有 model | 可按 API 價格估，非訂閱實付 | 取決於承載 client 的安全 metrics；非獨立 history API | A response；D quota；X direct key access | 作為 future backend attribution，暫不做獨立 provider |
| MiniMax | 官方 plan page 展示 authenticated remains query；新舊 plan schema 未驗證 | API response 有 prompt／completion／reasoning | response 有 model | 可估；charged history 未證實 | 承載 client counters 或 credential API | B remains；A response；X direct key access | 不實作；不要混用 prompt count、weighted token pool 與百分比 |

### A–J 獨立欄位可得性

A=subscription quota，B=total tokens，C=input，D=output，E=cache read/write，F=model，G=actual API cost，H=subscription API-equivalent／allocation，I=session timing，J=project identity。`—` 是本次未找到可接受來源；`?` 是 schema／語意待驗證；J 即使可取得也 **reject**。以下不是全部欄位都會進入 domain。

| Provider | A | B | C | D | E | F | G | H | I | J |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Codex | Q1 | T1 total | T2? | T2? | T2 read?／write? | T2? | — | calculated only if T2 validated；T1 不可 | T1 最長 turn summary；session 非必要 | S1 transcript／reject |
| Claude | Q2 | T3 | T3 | T3 | T3 read/write；TTL 拆分? | T3／Q2 | —；cost metric 是 estimate | calculation／manual allocation | T3 active time；非完整 wall-clock | T3 attributes 可有 repo／reject |
| Gemini | Q3 interactive | T4 | T4 | T4 | T4 cache；write UNKNOWN | T4 | — | calculation／manual allocation | T4 latency 非完整 session | S2／metric resource metadata／reject |
| OpenCode | —（Console 不同） | T5? | T5? | T5? | T5?；T6 API 明載各維度 | T5 | T6 charged；requires key | calculation；subscription mapping? | T5?／S3 | S3／server session／reject |
| Cursor | Q4 partial | T7 | T7 | T7 | T7? | T7 | T7 spend 需辨 billing scope | estimate／manual allocation | — | T7可能 metadata／不收 |
| Copilot | Q5 billing units | — | — | — | — | Q5 | Q5 net billed amount，非 token price | 不由 request 猜 tokens；allocation 可手動 | — | org metrics 有 repo／reject |
| Kimi | Q6 interactive | ? client／API | ? | ? | ? | ? client | — | calculation if safe counters | ? CLI store | session store／reject |
| Z.ai | — | T8 | T8 | T8 | read T8；write — | T8 | — | calculation if client emits T8 safely | response timestamp 非 session | client only／reject |
| MiniMax | Q7 authenticated | T9 | T9 | T9 | UNKNOWN | T9 | — | calculation if safe counters | response created 非 session | client only／reject |

矩陣中的 API response 是**執行推論的 client 原本可收到的資料**，不是讓 QuotaMew 發出推論、攔截網路或讀 credentials 的授權。T7 使用 events 細節也必須先確認 plan、key permissions 與 cache dimensions。

## 5. 資料來源信心矩陣

| 等級 | 定義 | 採用門檻 |
| --- | --- | --- |
| A | documented stable API／local protocol | 仍驗版本、auth modes、缺值、scope；不是永不變 |
| B | documented but limited／conditional source | 必須呈現 coverage／freshness；缺失不得補猜 |
| C | provider-owned structured implementation detail | 只能獨立 experimental adapter、有版本 fixtures；不能預設 fallback |
| D | undocumented endpoint、UI scrape、internal auth behavior | 不作近期產品依賴 |
| X | 需要 QuotaMew 讀 credentials／conversation／project data，或網路攔截 | 按當前產品原則拒絕，即使能技術實作 |

| Key | 實際來源／來源類型 | 信心與可用界線 |
| --- | --- | --- |
| Q1／T1／T2 | [Codex app-server](https://learn.chatgpt.com/docs/app-server)：`account/rateLimits/read`、`account/usage/read`、`thread/tokenUsage/updated`；official local protocol | Q1 A；T1 B：optional daily total、auth 有條件；T2 B：active thread 不代表所有現存 sessions。不能假設新啟動 monitor 可旁聽別的 client |
| Q2 | [Claude status-line](https://code.claude.com/docs/en/statusline)：rate limits／model／context counters | B，event-driven／first response／plan-dependent。current context 不是 lifetime cumulative spend |
| T3 | [Claude Monitoring](https://code.claude.com/docs/en/monitoring-usage)：`claude_code.token.usage` 的 input/output/cacheRead/cacheCreation、model | B；需要 opt-in local metrics-only receiver，logs／traces 不收；cost counter 明標 approximation |
| Q3／T4 | [Gemini quota](https://geminicli.com/docs/resources/quota-and-pricing/)、[telemetry](https://geminicli.com/docs/cli/telemetry/)、[headless](https://geminicli.com/docs/cli/headless/) | quota interactive B、machine integration 未證；metrics input/output/thought/cache/tool B；headless 會帶 response，不能為量測啟動新推論 |
| T5／S3／T6 | [OpenCode v2 commands](https://opencode.ai/v2/docs/cli/commands/)、[v1 CLI](https://dev.opencode.ai/docs/cli/)、[server](https://opencode.ai/docs/server/)、[Console usage](https://opencode.ai/v2/docs/console/usage/) | T5 B：v2 stats JSON 已文件化、daily schema 未驗；S3 local SQLite C，message route 帶 `parts` 為 X；T6 B，service key 為 X under current policy |
| Q4／T7 | [Cursor Admin API](https://docs.cursor.com/en/account/teams/admin-api)：daily usage、filtered usage events、spend | B、Teams admin key required；不是個人 subscription no-secret protocol |
| Q5 | [GitHub billing usage](https://docs.github.com/en/rest/billing/usage)、[Copilot metrics](https://docs.github.com/en/copilot/concepts/billing-and-usage/copilot-usage-metrics/copilot-metrics) | B：user report 需 Plan read permission；org report 權限不同。units 是 requests／credits，非 token history；internal endpoints D |
| Q6 | [Kimi membership](https://www.kimi.com/code/docs/en/kimi-code/membership.html)、[CLI reference](https://www.kimi.com/code/docs/en/kimi-code-cli/reference/kimi-command.html) | B 人工 `/usage`；無本次可證安全第三方 pull source，CLI store 不自動升級成安全 contract |
| T8 | [Z.ai completion](https://docs.z.ai/api-reference/llm/chat-completion)、[Coding Tool Helper](https://docs.z.ai/devpack/extension/coding-tool-helper) | response usage A；helper 管理 keys／tools，不證明 public quota API；tokens 可從 future host metrics 匯入 |
| Q7／T9 | [MiniMax plan](https://platform.minimax.io/subscribe/coding-plan)、[text API](https://platform.minimax.io/docs/api-reference/text-post) | remains B、需 key；T9 A 但此 text endpoint 已標 deprecated，不能拿舊 schema 宣稱新 plan 相容 |
| S1／S2 | Codex rollout JSONL／Gemini session JSON，供應商生成 structured local files | C schema、X contents under current policy；立即 discard 不會讓「讀過 body」變成「從未讀 body」 |

**取捨：** 官方 counters-only pull > 官方 metrics bridge > 官方 sanitized CLI aggregate > 對特定 metadata 做 provider-side projection > internal DB > mixed transcript parsing。前三者才有機會進近期 milestone；每種均需 bounds、取消、timeout、拒絕未知 schema。runtime bundle discovery 是 C packaging detail，與 protocol 的 A／B 分開評估。

## 6. Privacy matrix

| Feature | Required data | Sensitive exposure | Persistence? | Explicit opt-in? | Recommended? |
| --- | --- | --- | --- | --- | --- |
| 現況 quota | normalized percent／reset／capture | 低；仍是個人活動線索 | current state／既有 bounded cycle state | provider enablement 沿用 | 是 |
| Codex daily history | date／reported total／scope／capture | 不需 body；每日活動可揭工作節奏 | daily aggregates | **是**，與 quota enablement 分開 | v0.3，有 protocol gate |
| input/output/cache/model | official numeric metrics／model | 原 payload 可能帶 user／session／repo attributes | normalized aggregates＋去重 metadata | **是**，provider 逐一 | 有條件 v0.4 |
| transcript-based token import | 混合 body／counters 的 session files | read 時已接觸 prompt／tool／code／paths | 可只存 aggregates，但讀取風險仍在 | opt-in 也不符合目前不讀 body 原則 | 否 |
| 趨勢／比較 | daily counters＋coverage | 低，不增加 content exposure | reuse history | 延用 history consent | 是 |
| quota pressure／runway | 同 cycle 的 observed quota samples／gap | 工作節奏；不需 token／repo | pressure 可 in-memory；runway 需短期 samples | 若持久化需另說明 | pressure 可先；runway 延後 |
| API-equivalent estimate | 已知 model、完整計價 counters／rates | 低；金額是推算 | rates／calculation provenance | history consent＋明顯 estimate 標示 | 資料充分才做 |
| subscription allocation | 使用者手動月費／period／allocation rule | 財務偏好 | 小型 local setting | 是 | 非必要，不先做 |
| project analytics | paths／repo identity／request linkage | 高、違背目前產品邊界 | project history | 不建議即使 opt-in | 否 |
| macOS widget | sanitized current snapshot／optional今日總量 | desktop 可被旁觀 | App Group cache | widget 添加＋history 各自 consent | 是 |
| iPhone／Apple sync | quota／capture／expiry／optional today aggregate | counters 離開 Mac，Apple account 可見 | private cloud mirror | **獨立 opt-in，預設 off** | 後續，需正式修改 no-cloud story |
| Reset Intelligence feed | 公開公告 metadata／source URL | network IP／request timing；不可帶 local usage | bounded public cache | 既有 setting 預設 off | 保留，非下一個主要版本 |

允許的 ingestion：**read bounded counters source → extract allowlisted fields → discard unknown metadata immediately → aggregate → persist normalized values**。對 mixed transcript，這條流程最多改善 retention，無法滿足不讀 conversation body。Bridge 輸入可能帶 paths，但 parser 只取 counters，禁止 raw logs／generic Codable payload cache／debug dumps；privacy QA 用 redacted synthetic sentinels，不用使用者對話。

「no telemetry」應繼續指沒有向 QuotaMew／第三方傳送產品或工作資料；若未來採 OTel local metrics 接收，必須明白標為「本機用量匯入」，不默默開啟 provider remote telemetry。源頭不能關閉 body/logs 或不能排除未許可 export destination，就不支援。

## 7. Token analytics domain proposal

新增獨立 **TokenActivitySource**（比 TokenUsageSource 更能容納每日 totals）；不改 `UsageWindow`。能力描述不是一個 `supportsTokens` boolean，而是 `quota / totalOnly / categorizedTokens / modelBreakdown / reportedAmount` 各有 source grade、scope、granularity、coverage 與 availability。

| 最小 record 欄位 | 語意／限制 |
| --- | --- |
| intervalStart／intervalEnd 或 source day label | absolute interval 有證據才填；日期無 timezone 時保留 source day，不假造 UTC midnight |
| providerKey／clientKey／modelKey? | economic provider 與 coding client 分開；unknown model 明確 nil；已知有限模型 ID allowlist，未知任意字串不直接呈現／sync |
| totalTokens? | 可只有供應商總量；不能把不知的 input/output 設 0 |
| inputTokens?／outputTokens? | 非負 Int64、checked arithmetic；adapter 明確 normalize input 是否含 cache、output 是否含 reasoning |
| cacheReadTokens?／cacheWriteTokens?／reasoningTokens? | 維度附 inclusion semantics；cache TTL／thinking 是 subset 或 disjoint 要有文件；禁止盲目全部相加 |
| additionalCategories | bounded typed categories（例如 tool tokens）；拒絕 generic provider JSON 或任意 key/value |
| sourceRef／schemaVersion／sourceGrade／capturedAt | protocol／metric／CLI、provider version、文件依據；不存完整 payload |
| scope／coverage／countingBasis | accountAggregate 或 localObserved；intervalBucket／cumulative／delta；missing／partial／complete／unknown，complete 只限明確 scope |

本機持久 record 不含 prompt、response、tool output、repo、path、session body。最小 ingestion 去重可以保留隨機 stream handle／opaque counter baseline，但不保留 provider session ID；HMAC 若真的需要也只是 pseudonym，不宣稱匿名，禁止 sync。

**Ownership：** adapter 負責 counter 語意與 source scope；`ActivityIngestionService` actor 驗數值、去重、處理修訂；`ActivityStore` 負責 transactions；`ActivityQueryService` 回傳有限 summaries；`CostCalculator` 純計算且另有 pricing input。protocol 是演進提案，第一階段只有需要的實體，勿先建空 service skeleton。

**Aggregation：** 在 ingestion 聚合，memory 只留 bounded pending batch／baseline，交易寫 aggregate；查詢時只算小型 view summaries。Daily snapshots 是 replacement/upsert，**不是每次 refresh append 後累加**。同一 scope 的 account totals 與 local client counters 永不相加；account total 無法可靠拆回 Codex CLI／Desktop／cloud 或 per-model。

## 8. Historical persistence recommendation

| 選項 | migration／integrity／retention | 成本與問題 | 決策 |
| --- | --- | --- | --- |
| SwiftData | native [schema migration](https://developer.apple.com/documentation/swiftdata/schemamigrationplan)、query；需要 migration fixtures | UI object graph 不是必要；若直接採 CloudKit integration，會讓 local store 和 mirror 耦合 | 可行，非首選 |
| 系統 SQLite | transactions、unique upsert、explicit schema version、bounded queries | C API wrapper 與 migrations 要自行測；多維 aggregate／修訂最清楚 | **建議**，無第三方 runtime |
| append-only JSONL | 易 export，需截斷／compaction／重放／dedup | raw-event retention 誘惑、重寫／索引成本、壞尾端 | 不適合主 history |
| 每日 atomic JSON files | 小規模 total-only 簡單，能重建 index | 多維／修訂／retention 需自己做；未來易變成檔案 DB | 若 v0.3 永久只做 total-only 可替代；不另維護雙 store |

初始唯一資料庫位於 app-owned Application Support；不是 provider DB，不放 UserDefaults、不複製到 widget／CloudKit。以 [`SQLite atomic transactions`](https://sqlite.org/atomiccommit.html) 的完整性為基礎；journal mode 依量測選擇，並行 readers 確有需求才選 WAL。backup 用 [SQLite online backup](https://sqlite.org/backup.html)，不能直接複製開啟中的 DB 而漏 journal/WAL。

| Granularity | Useful signal | 隱私／精確度 | 建議 |
| --- | --- | --- | --- |
| per request | billing tiers／短期 burst | request timing 可重建活動；儲存與去重高 | 不存；必要 calculation 只在 ingestion 暫存 |
| per session | 工作時段 | session link／restart／多模型複雜，使用價值不足 | 不存 |
| hourly | intraday trend／runway | 活動節奏、稀疏 samples；不能從 daily total 假拆 | 未來 opt-in，僅來源本來具該粒度 |
| daily | 7／30 日趨勢、平均／comparison | 最少活動資訊；不能精確 burst／runway | **v0.3 最低有用粒度** |

初始 key：`source scope + local stream generation + source day + provider/client + model? + measurement basis`；daily 修訂同 key transaction replacement，保存最新 observed provenance。未取得 bucket identity/timezone 契約前不可把 source 日期和裝置日期混合。account 切換若無安全 opaque context 訊號，要求清除／開新 local generation、避免混帳；不得讀 auth.json 或用 email 當 key。

保留策略提案：daily 90 天預設、使用者可選 30／90／365 天；future hourly 最多 7 天。初始只允許 bounded returned date range，不自動匯入 lifetime。資料／model cardinality 要有硬上限，DB 10 MiB warning、50 MiB stop ingestion 為**初始工程預算待量測**，不是實測 size 保證。Retention batch 在成功 ingestion 後／下次啟動執行，不開獨立 timer。

Migration transaction＋回復備份、future schema fail closed、integrity 檢查失敗隔離 DB並顯示恢復選項；history 壞掉不能阻擋 quota。Delete all 應先停 ingestion，再清 DB／journals／bridge baselines／widget activity cache，避免重送舊 bucket 自動重建；保留「不再匯入此日期以前」的 minimal consent watermark。CSV／JSON export 只出 aggregate／provenance，由使用者選檔，無自動 backup upload。標準檔案權限、依裝置 FileVault；不宣稱 app-level encryption 或 APFS／Time Machine 可保證 secure erase。

## 9. Cost semantics model

| Typed assessment | Required proof | UI label | 禁止推論 |
| --- | --- | --- | --- |
| `providerBilled` | provider 明確 charged/net amount、currency、billing interval、source | 實際費用／Actual cost | CLI `cost` 名稱本身不證明實付 |
| `apiCalculated` | API-mode counters＋精確 tariff／discount／tier 可得；不一定涵蓋 tax／tools | 依 API 價格計算 | 不等同 invoice |
| `subscriptionAPIEquivalent` | 訂閱 usage 有完整模型與計價 counters | 估算 API 等值／Estimated API-equivalent value | 不叫已花費、省下、ROI 或真正成本 |
| `subscriptionAllocation` | 手動月費、日期範圍、allocation rule（例如按 observed token share） | 訂閱費分攤 | 不代表邊際成本／provider quota conversion |
| `unavailable(reason)` | missing model／pricing／token dimension／unsupported category | 無法估算 | 不以 $0 取代未知 |

每一項帶 `Money(decimalAmount, currency)`、basis、interval、source provenance、pricingRevision、calculationVersion、completeness／assumptions；使用 Decimal／明確 rounding policy，不用 unqualified Double。不同 currency、不同 cost kinds 分開總計。未知 model／cache category 留 unavailable；部分涵蓋時顯示「已涵蓋部分」，不當成全日費用。

**v0.3 T1 daily total 不足以估成本。** 就算已知訂閱方案或使用者平常選某 model，也不能猜 input/output mix、cache、reasoning／rerouting。Claude metrics cost 是 approximation；OpenCode Console charged amount 是另一種 evidence，不能混用。[Claude cost monitoring](https://code.claude.com/docs/en/monitoring-usage#cost-monitoring)、[OpenCode Console usage](https://opencode.ai/v2/docs/console/usage/)。

## 10. Pricing catalog strategy

**採 app 隨附、版本化的 pricing catalog；估算功能成熟以前不需要 remote service。** 官方來源有不同 input/output/cache、context tier、service tier／batch／tool 定價，不存在本次已證實的跨 provider 統一歷史價格 API。[OpenAI pricing](https://developers.openai.com/api/docs/pricing)、[Anthropic pricing](https://platform.claude.com/docs/en/about-claude/pricing)、[Gemini pricing](https://ai.google.dev/gemini-api/docs/pricing)。

| 策略 | 決策 |
| --- | --- |
| 裸 hard-coded current constants | 拒絕；更新會改寫歷史解讀 |
| bundled versioned catalog | 首選；reviewed official links、離線可用、immutable revisions |
| small trusted static feed | 未來價格維護頻率證明有需求才加；opt-in、HTTPS／signature／bounds／last-known-good；無 local metadata |
| runtime scrape provider pricing | 拒絕 HTML scraping；官方 machine catalog 若可用，只作 reviewed candidate，不直接改舊估值 |
| manual override | 進階情境才做，local、explicit effective interval、custom label；不覆寫 official tariff |

每筆：`catalogRevision / rateID / provider / exact model or versioned alias / currency / unit denominator / dimensions / pricing tier predicates / effectiveFrom / effectiveUntil? / sourceURL / retrievedAt / evidence status`。dimensions 可含 uncached input、cache read、5m／1h write、output、reasoning inclusion、context threshold、service tier；不假設 reasoning 可另加一次。

effective date 未明確時記 unknown，retrievedAt 不是 effectiveFrom。計價 persist 不可變 rate snapshot／rateID 與算法版本；UI 可區分「當時估值」與「使用新 catalog 重估」，不可 silent reprice。daily aggregate 若跨 rate change 或 context pricing tier 且無足夠細節，**不可產生精確估值**；future detailed ingestion 先按同 tariff／category 計算並聚合金額，保留 rate 分桶，不必留每 request。初始維持 USD 原幣，不引入 FX feed。

## 11. Usage Intelligence opportunities

Observed＝來源回報／採樣；Calculated＝資料確定的算術；Estimated＝對未來或未知成本的假設。算式 deterministic 不代表預測是觀測事實。

| Feature | 類型／deterministic? | Required inputs | Privacy | Value／complexity | 決策 |
| --- | --- | --- | --- | --- | --- |
| daily／weekly trend | Calculated，是 | daily totals、day basis、coverage | 低 | 高／低 | v0.3 |
| historical comparison | Calculated，是 | 相同 scope 的等長已完成 intervals | 低 | 中高／低 | v0.3；partial today 不比 full yesterday |
| provider／model distribution | Calculated，是 | 同口徑、可去重的分項；unknown bucket | 低 | 中／中 | v0.4 gate；T1 無法做 |
| tokens/hour burn rate | Calculated observed interval；不可推到全天 | 有時間跨度的 counters／gap | 中 | 中／中 | daily source 不適用 |
| quota pressure | Calculated quota 使用與 window elapsed 比較 | window start／duration／reset、fresh quota | 低 | 高／低中 | 可先研究；rolling window／unknown start 不畫均勻 pacing 假事實 |
| exhaustion／runway | Estimated，規則可 deterministic | 同 cycle ≥3 fresh samples、穩定正斜率／observed span、reset | 中 | 高／中高 | 不排 v0.3；斜率以 percentage points/hour，不以 tokens→quota |
| API-equivalent value | Estimated，計算可 deterministic | 第 9／10 節的 complete dimensions | 低 | 中／中高 | v0.4 有條件 |
| unusual spike | Calculated 相對歷史門檻，不推論原因 | complete daily coverage、足夠基準天數 | 低 | 中／中 | 先 inline；無通知轟炸 |

runway policy 必須用 same cycle、拒絕 reset／負 delta／gap／stale／sampling 太少；先提出可校驗 policy，例如至少 30 分鐘跨度、區間而非秒級時間，UI 顯示「依最近 X 分鐘估算」。15 分鐘 quota cadence 不支持「live tokens/min」宣稱。沒有可靠 sample 就呈現 unavailable，不顯示 infinity。跨裝置／其他 client quota 增長不能歸因到目前本機 tokens。無需 ML、AI summaries、coding productivity score。

## 12. macOS information architecture

| Surface | Content | Boundary |
| --- | --- | --- |
| menu-bar popover：Limits | 目前 quota、remaining/reset、freshness、source status；opt-in 後一行今日總量與「Usage…」 | 開啟立即顯示 cached state；不查 DB／畫年度 heatmap |
| 專用 Usage window | 7／30 日 daily trend、coverage／source 說明；後續 model／client breakdown | v0.3 有 history 才建立；on demand query、有 bounds，不常駐 chart pipeline |
| Cost 區域 | 達到計價 gate 後才在 Usage window 顯示 typed assessments | 不先建立空 Cost tab；不混 actual／equivalent |
| Settings | 既有 General／Providers／Notifications；history consent／retention／delete/export 可作清楚子區域 | 保留現有 IA、keys、pin 與 onboarding，不為概念對稱重排 |
| widget | 一眼 quota／reset、freshness；optional today total | 無 chart dashboard，無 provider actions |

**獨立 analytics window 有理由**：history query／範圍切換需要空間與可重看解釋，且可讓平常關閉的 window 不影響選單列。Intelligence 是上述資料旁的結果，不另開功能總控台。

## 13. macOS Widget architecture

[WidgetKit](https://developer.apple.com/documentation/WidgetKit/) 支援 macOS；[Apple refresh guidance](https://developer.apple.com/documentation/widgetkit/keeping-a-widget-up-to-date) 說常見可見 widget 的日 budget 約 40–70，為動態預算，不是可承諾的刷新 SLA。

```text
Quota runtime ──> cached normalized current state ─┐
Activity query ─> bounded TodaySummary (opt-in) ──┤
                                                 v
                                   SharedSnapshotWriter
                                                 |
                                atomic App Group snapshot
                                                 |
                                     Widget timeline reader
```

| Size | 適合內容 | 建議 |
| --- | --- | --- |
| Small | 一 provider／一主要 window，remaining、reset、capture age | 先做 |
| Medium | 兩 windows 或兩 providers，reset、freshness；optional今日 tokens | 第二種可行；不要所有 metrics 擠一起 |
| Large | 較多 current windows；token／value 摘要需資料允許 | 無明顯新增價值，先不做 |

shared schema 帶 version、generatedAt、每個 source capturedAt／staleAfter、enabled status、display-safe values；快取上限提案 32 KiB，拒絕 future schema。App Group 是同裝置 app／extension container sharing，**不做跨 Mac/iPhone sync**；需 [App Groups capability／entitlements](https://developer.apple.com/documentation/xcode/configuring-app-groups)，extension sandbox、distribution provisioning 與保留現有 bundle ID 均需實際 package validation。

Widgets **永不啟動 CLI、永不連 app-server、永不讀 history DB 或 credentials**。主 app 在資料改變時 coalesce `WidgetCenter.reloadTimelines`；timeline 用已知 reset／stale boundary，不用 1 秒 polling。到 reset 時只顯示「已到重設時間，待確認」，不可把 percent 改 0／100。主 app 關閉後仍顯 last snapshot＋stale，不承諾 provider freshness。今日估算 value 只在 typed estimate 完整時可顯；T1 total-only widget 不含金額。

## 14. iPhone companion 比較與 Apple 原生選項

| Criteria | A：Direct Provider Client | B：Privacy-first Mirror |
| --- | --- | --- |
| security／credentials | 各 provider login／refresh／Keychain／可能 undocumented endpoint；擴大 secret surface | provider auth 留 Mac；手機僅 read normalized snapshot |
| Mac-online dependency | 成功提供官方 mobile API 的 provider 可獨立 | Mac 離線顯最後資料；不能遠端即時 query Mac |
| freshness | provider rate／mobile background 限制，亦非即時保證 | Mac capture → CloudKit eventual sync → iPhone cache；顯示 capture age |
| complexity／maintenance | 每 provider 移植與 auth policy；Codex stdio 不可直接搬 iOS | 一個 snapshot contract、CloudKit conflict／offline lifecycle |
| compatibility | 對沒有公開 mobile API 的 agents 無法保證 | 所有 Mac 可正規化來源可 mirror |
| privacy story | no-backend 可成立，但「不持有 credentials」不再成立 | 須將 no-cloud 改為「本機預設，Apple sync 明確 opt-in」 |
| App Store | login、權限、provider authorization、demo／功能完整性需審查 | 附 sample/demo mode、清楚 Mac dependency；仍不保證審查通過 |

**先嘗試 B，排在 macOS widget 與 distribution entitlement 驗證之後。** 不做 custom backend、不偷讀 token、不用 iPhone 的 provider CLI 模擬 quota API。[App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/) 要求可審查功能／demo；這是產品流程要求，不是本研究已取得上架資格。

| Apple mechanism | Fit | 決策 |
| --- | --- | --- |
| CloudKit private database | versioned records、offline cache、per-installation mirror、明確衝突／刪除 | **首選 mirror**；使用 [privateCloudDatabase](https://developer.apple.com/documentation/cloudkit/ckcontainer/privateclouddatabase)，評估 [encrypted fields](https://developer.apple.com/documentation/cloudkit/encrypting-user-data)；不宣稱所有 metadata 自動 end-to-end encrypted |
| iCloud key-value store | settings／少量 scalar；1 MiB／1024 keys，eventual propagation | 可同步非敏感偏好；不作 history／可靠 snapshot transport。[Apple KVS](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/UserDefaults/StoringPreferenceDatainiCloud/StoringPreferenceDatainiCloud.html) |
| App Groups | 同一 device app ↔ widget | iPhone 接收 CloudKit 後寫自己的 group cache，與 Mac group 不連通 |
| iCloud Drive file | 有同步／conflict／file coordination，適合 user export | 不作 primary mirror transport |
| local network／WatchConnectivity | 可另作 nearby transport | 不解決外出 freshness，不先加平行機制 |

first mirror 只存 `random installation ID / schema revision / monotonic generation / provider current windows / capturedAt / expiry / optional today total`，device name／account email 不存。多 Mac 不合計同帳號 quota：讓使用者選來源 Mac 的匿名 label；每個 installation 分開 record，以 source generation 防舊資料覆蓋。token totals 只有已證 disjoint local scopes 才能合計，account totals 不合。

sign-out、iCloud quota／disabled、offline、stale、device clock drift、schema upgrade 和 delete tombstone 都需可見狀態。sync opt-out 停 writer／reader；delete-cloud-data 明確刪 mirror並防其他 Mac resurrect。CloudKit 是 Apple cloud dependency，不再等於「資料從未離開 Mac」。[Apple Developer ID](https://developer.apple.com/developer-id/) 明載可使用 CloudKit；外部散布不用因此搬 Mac App Store，但 production signing／entitlements 還須實測。

### Lock Screen／Home Screen／Apple Watch

Home Screen `.systemSmall/.systemMedium`、Lock Screen accessory families、Watch Smart Stack／complications 都可沿用「phone cache → normalized timeline」概念。[Apple WidgetKit](https://developer.apple.com/documentation/WidgetKit/) 支持這些 surfaces；Watch transport／background cadence／supported families 需另驗，不能只靠 App Group 跨裝置。先 quota＋capture age，Lock Screen 可用 redacted mode；不顯金額／詳細模型活動為預設。沒有 mobile mirror 以前不建立 Watch target。

## 15. Reset Intelligence sequencing decision

既有 [frozen feed contract](RESET_INTELLIGENCE_FEED.md) 有實質價值：schema v1、publisher/sourceURL、revision、防 regression、correction/retraction、audience／verification、256 KiB／128 events、atomic candidate rejection、default-off networking。`DetectedQuotaReset` 和公開 `ResetEvent` 分開，feed failure 不影響 quota。這些全部保留。

| 選項 | user value／differentiation | dependency／maintenance／risk | 結論 |
| --- | --- | --- | --- |
| A：原 v0.3 Reset Intelligence | provider 特殊 reset／quota change 可能有用 | 資料發布頻率、publisher review、修正／撤回與 entitlement 解讀負擔；需先證明持續有足量官方事件 | 非優先 |
| B：Usage Intelligence first | 每日可用，且有不讀 transcript 的新官方候選 | daily protocol／persistence scope 可限制，無 editorial feed | **推薦**，v0.3 只 daily trends |
| C：兩者 foundation | 共用 freshness／confidence 概念 | token history 與 public feed 的 consistency／retention 不同；共同 remote scheduler 容易耦合 | 拒絕合併版本 |
| D：Claude quota completion first | 修復目前第二 provider 的真實缺口 | opt-in setup／command composability／eligible account 驗證 | T1 no-go 時的替代小版本；平時作獨立 v0.3.x workstream |

可重用 provenance／safe presentation pattern，不重用 feed schema 存 pricing 或 token records。外部 Reset Intelligence 不設必然 v0.4 日期；重新啟動條件是拿到可維護的官方來源樣本、事件 cadence 與 review owner。當下已決定暫不 build reader，並非等待更多 generic brainstorming。

## 16. Product differentiation

| 可採定位 | 可防守的行為 | 必須避免的宣稱 |
| --- | --- | --- |
| 「不用交出供應商憑證，也能看懂額度與最近用量」 | official local protocol／opt-in counters bridge、unsupported 就說不支援 | 全 provider／全帳號 history 都完整 |
| 「每個數字都有來源、時間與涵蓋範圍」 | observed／calculated／estimated、missing gaps／stale、可追溯 pricing | 精準預測、已花多少、coding ROI |
| 「平常安靜，需要時才展開分析」 | 小型 popover、on-demand window、bounded work、Release regression profiling | 尚未量測就說更省 RAM／最快 |

local-first、native、open source 都有競品做到。可防守組合是**不讀 secrets/content、用量不必上傳、能力誠實與成本語意可信**；接受較少 providers／較少細分，是此承諾的實際代價。

## 17. v0.3–v0.5 roadmap

提案不設定日期、不修改 ROADMAP；各版先滿足 gate 才承諾，v0.2 stable／distribution work 另行處理。

| Release | Goal／User value | Core features | Explicit non-goals | Technical foundation | Major risk | Acceptance criteria |
| --- | --- | --- | --- | --- | --- | --- |
| v0.3：Daily Usage | 最近用量與變化，不接觸對話紀錄 | Codex 官方每日 total、7／30 日趨勢、coverage／source、新 Usage window、opt-in／retention／delete/export | cost、per-model、hourly、runway、其他 token providers、widget、sync、feed reader | T1 adapter、daily aggregate store／query、capability／provenance | runtime 未支援、day/scope 不明、revisions／帳號切換 | method 缺失不 fallback；缺值≠0；重複讀取不重複計數；修訂 upsert；delete 不自動重建；history failure 不阻 quota；bounded Release work／新舊版本 fixtures |
| v0.4：Explain Usage | 在安全來源存在時，解釋 counters 與 API 等值 | **只新增一個**先通過 gate 的 categorized source（Claude metrics-only 或 OpenCode stats JSON），model/client breakdown、typed estimate、versioned pricing | 所有 provider 一次擴充、帳單整合、project/session UI、秒級 runway、remote pricing 服務 | normalization／category semantics／去重、cost 純計算、tariff provenance | bridge overhead／重送漏送／價格維度不足 | source 只帶允許的 counters／metadata；replay/restart 不重複；cache/reasoning 不雙算；unknown model unavailable；歷史估值可重現；manual live reconciliation＋Release profile |
| v0.5：Glance Anywhere on Mac | 桌面直接看可靠 current state | small／medium macOS widgets、stale／reset semantics、選擇 source | iPhone、Watch、CloudKit、large dashboard widget、provider CLIs in extension | versioned App Group projection／widget target、簽章與 package validation | extension 刷新預算／entitlements／主 app 離線 | 主 app 關閉時正確顯示 stale；reset 不偽造；schema fail-safe；light/dark／keyboard／VoiceOver／窄寬；signed packaged 實機新增與更新 |

Claude quota completion 是**高優先、可獨立交付的 v0.3.x 修補工作**：只 quota bridge、preview／恢復 existing command、符合資格帳號人工比對。不要把 OTel token bridge、quota setup、Widget／iPhone 全塞進同一版。iPhone mirror 為 v0.5 之後的條件式探索；若沒有外出看 quota 的需求證據，不必 build。

## 18. Feature prioritization

Value／Differentiation／Confidence／Privacy Fit：高／中／低；Maintenance／Implementation Cost：高表示昂貴。不加任意總分。Confidence 針對**符合本產品原則的整合**。

| Feature | User Value | Differentiation | Technical Confidence | Privacy Fit | Maintenance Cost | Implementation Cost | Priority／gate |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Codex daily token history | 高 | 高（counters-only） | 中：官方有、runtime待驗 | 高 | 低中 | 中 | **先做 feasibility → v0.3** |
| Claude quota completion | 高 | 中 | 中高：contract有、live未驗 | 高 | 中 | 中 | **高；獨立 v0.3.x** |
| usage trends | 高 | 中 | 高：聚合後算術 | 高 | 低 | 低中 | v0.3 |
| cost estimation | 中 | 高（語意可信） | 中低：T1不夠 | 高 | 中高（pricing） | 中 | v0.4 conditional |
| burn rate／runway | 高 | 中 | 中低：sampling／cycle | 中高 | 中 | 中高 | 不先；先驗quota samples |
| OpenCode | 中 | 中 | 中：v2 stats JSON | 中高（CLI gate） | 中 | 中 | v0.4單一source候選 |
| Gemini CLI | 中 | 低中 | 中 token／低 quota | 中（預設prompt logs） | 中高 | 高 | metrics-only研究，非committed version |
| Cursor | 中高 | 低 | 低（個人no-secret） | 低 | 高 | 高 | 不先 |
| Copilot | 中 | 低 | 低（無憑證current quota） | 低中（manual report可行） | 中高 | 高 | 不先 |
| macOS Widget | 高 | 中 | 高 framework／中 packaging | 高 | 低中 | 中 | v0.5 |
| iPhone companion | 中：外出需求待驗 | 高（no-secret mirror） | 中 | 中：需離開Mac | 中高 | 高 | widget之後，獨立scope |
| iCloud sync | 支援companion | 中 | 中高 platform／未測產品 | 中 opt-in | 中 | 高（conflicts／delete） | 不先sync history |
| Reset Intelligence | 中：事件頻率待證 | 高 | 中：contract有、feed無 | 高（公開資料） | 高（editorial） | 中高 | 保留freeze，暫不實作 |

Kimi／GLM／MiniMax 新 quota adapters 不在近期：安全 no-secret source 尚不足；GLM／MiniMax token attribution 日後可跟著 host counters source 支援，不等於完成訂閱額度整合。

## 19. Minimum architecture evolution

```text
既有 quota path（保持）
UsageProvider → UsageService → RefreshCoordinator → AppModel → Limits／Notifications

新增 activity path（opt-in、獨立failure）
TokenActivitySource → ActivityIngestionService → ActivityStore
                                                |
                                        ActivityQueryService
                                                |
                                   ActivityWindowModel（新 UI model）
                                                |
               PricingCatalog → CostCalculator → typed CostAssessment（v0.4）

純projection export（v0.5／之後）
current quota + TodaySummary → SharedSnapshot → Widget
                             MirrorSnapshot → CloudKit private → iPhone cache

既有獨立future path
ResetEventSource → ResetEventService → public source-linked presentation
```

| 明確問題 | 決策 |
| --- | --- |
| 1. UsageProvider 應保持 quota-specific？ | **是**。現有名稱保留，註明語意即可，無需重新命名造成 churn |
| 2. 另建 QuotaSource？ | **現在不要**。它與 UsageProvider 責任相同；未來新 callers 確有需求再考慮 alias／rename，不雙軌 |
| 3. TokenUsageSource 如何接入？ | 新增 capability-oriented TokenActivitySource，支援 total-only 與 categorized，各自 status／source，不把 DTO 暴露到 UI |
| 4. cost 如何消費 tokens？ | immutable normalized aggregates／必要計價分桶＋versioned rates → pure CostCalculator；來源實付另從 AmountSource 接，首次不建空 AmountSource |
| 5. 誰擁有 history？ | ActivityStore actor 由 AppDependencies 擁有；ingestion transaction 寫、query bounded 讀，SettingsStore 只留 consent／retention |
| 6. AppModel 觀察什麼？ | 保留 current provider states；最多觀察 compact TodaySummary／capability status。ActivityWindowModel 按需觀察 query results，不灌 history 到 AppModel |
| 7. widgets 可讀什麼？ | app 寫的 versioned current-state projection／optional 今日 aggregate；無 history DB、provider store、credentials |
| 8. iPhone 可 sync 什麼？ | 獨立 opt-in quota/current capture/expiry＋optional 今日 total；後續 aggregate history 必須再次作產品決策 |
| 9. NEVER sync？ | credentials／auth、provider account/email、prompt/response/tool/code、repo/path、session/request IDs、stream baselines、raw payload/logs、診斷私密路徑 |
| 10. v0.2 維持什麼？ | mapper／window IDs／Reserve semantics、notification/reset detector、pin/Used/Remaining/settings keys、onboarding migration、NSStatusItem/recovery、refresh/backoff/sleep/cancellation、bounded process cleanup／diagnostics |

第一版不建統一萬用 provider plugin framework。新 source 在 quota refresh cycle **完成之後**低優先排程、取消／timeout 獨立；quota 優先，analytics 慢或故障不能拖下一次 quota。若共享 Codex transport，必須驗證公平排程、method dispatch／response bounds；不假設現行 client 無修改就能處理第二種 response。**不要僅為 history 改寫現行 refresh coordinator**；integration 若要小幅增加 transport method，待實作任務提出最小 patch。

真正採用新 history、source 或 sync 時，才同步更新 ARCHITECTURE／provider research／privacy copy 與 ROADMAP verified status。本次只建立此提案，不將計畫寫成已實作能力。

## 20. Major unknowns requiring provider-specific follow-up

| Unknown | 為何會改變決策 | 本次證據界線 |
| --- | --- | --- |
| T1 runtime support／daily semantics | 決定 v0.3 可否無 transcript 交付；day timezone／範圍／修訂／null 會改 store/query | 官方文件有 method；本機既有 client 只讀 rate limits；沒有做 live probe |
| safe account context signal | 無法識別切帳會混 history，可能需限定 single-account／清除再啟用 | 禁止讀 auth.json；未證 opaque no-secret context signal |
| T2 cross-client token events | 若 monitor 只能看自己的 thread，則無法被動收完整 Codex 細分 | 文件指 active thread；沒有證實 global subscription stream |
| Claude numeric metrics delivery | request replay／counter temporality／多 session／fast mode／cache TTL 會影響去重與 cost | OTel official metrics documented；metrics-only 本機 adapter 未驗 |
| Claude quota bridge setup | command composition、trust、managed settings／field availability 決定 Supported 資格 | 現 snapshot reader 存在；bridge 與 eligible live account 未完成 |
| OpenCode v1/v2 stats payload | 如果 JSON 包含 paths／tool names、只 all-time 或啟動 server，會改採用順序 | v2 `--json` 有文件；JSON schema／privacy／day granularity 未驗 |
| Gemini metrics-only transport | 預設 prompt logging／resource attributes／local export 可否真正排除敏感欄位 | counters 有文件；未證可用零第三方常駐 runtime 完成安全 collection |

平台未知另列在 widget／sync gate，不擴成更多 provider research：App Group 簽章／外部散布、CloudKit 刪除衝突與 offline freshness、Watch transport 都未實測。競品政策不是 binary network audit，本研究也沒有證明各競品 data retention 的實際行為。

## 21. Recommended FIRST implementation milestone

**M1：Codex counters-only Daily Activity 契約驗證與最小產品切片。** 先驗證來源再寫 history feature，不先做通用 analytics framework。

| Gate／交付 | 可 review 結果／驗收 |
| --- | --- |
| 來源 fixtures 與 protocol compatibility | 以 public schema／synthetic fixtures 驗 method not found、null／missing、partial／future／oversized、numeric bounds；只記欄位存在／型別，不輸出私人用量 |
| 明確 semantic contract | daily 日期基準、service/account scope、bucket revision、可得 date range、account switch 政策寫清；未知則 feature 不開，不能猜 |
| live validation（實作任務另行執行） | provider 擁有 auth、read-only request、不開 thread、不做 inference；比較官方 usage 畫面／capture，不 dump raw response；記版本與 limitations |
| 最小 daily import | independent adapter、default off、範圍上限、bounded work、upsert、無 fallback；quota 仍正常 |
| 最小 store 與 window | 7 日總量／gap／source／last capture；delete／retention／export 先完整，不上 cost；之後同一版擴 30 日 |
| reliability/privacy | 重複 refresh／restart／revision 不雙計；missing≠0；sentinel 欄位不出 DB／logs／cache；corruption／cancel／timeout 不阻 quota；Release 量測新增 RSS／IO／wakeups 以及 App＋child |

M1 failure 時維持 quota-only 產品，下一個小版本改交付 Claude quota opt-in bridge。**不先 build：** transcript importer、provider credential manager、project analytics、全 provider cost dashboard、remote pricing backend、iPhone/Watch、cloud history sync、feed editorial automation、ML 預測／token 排行榜。

## NEXT RESEARCH TASKS

只保留會實質改變 provider adapter 設計的問題；前 3 項是下一輪重點。

1. **Codex：** 哪些正式／bundled runtime 支援 `account/usage/read`？daily timezone、coverage／account scope、nullable bucket、revision 和安全 account context 語意為何？可否在不讀 thread／session 的前提取得可信總量？
2. **Claude：** status-line quota bridge 如何 preview／compose／restore existing command 並通過 trust／managed settings 情境？metrics-only source 的 temporality、replay／multi-session、cache TTL／fast mode 是否足以產生不雙算且不帶 body／identity 的 aggregate？
3. **OpenCode：** v2 `stats --json` 的版本化 payload 是否只有允許的 counters／model／date？能否取得 daily buckets 而不啟動長駐 server、不讀 message parts、無 paths／tool names、成本來源語意清楚？
4. **Codex 細分（只有 v0.4 確需時）：** 是否存在文件化、跨 client、counters-only stream？active-thread notifications 無法代替 whole-account history；沒有就不 build 細分。
5. **Gemini（只有安全 source 候選出現時）：** 可否在 source 端完全關閉 logs／traces／prompt 與 identity attributes，僅以 local metrics snapshot 提供各類 token、實際 model 與 counter reset identity？quota 另是否有文件化 no-secret machine query？
