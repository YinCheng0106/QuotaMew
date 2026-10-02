# v0.3 — Codex Account Activity 架構設計

架構核准狀態（M0 實作前）：**READY TO IMPLEMENT v0.3 M0**。2026-10-02；設計不代表承諾 v0.3 發行。檔名沿用指定名稱；產品名稱不是 Daily Usage／History。

M0 implementation note（2026-10-02）：transport 已加入兩種 closed method、single active slot、每種 method 各一個 coalesced pending batch 與 quota priority。Caller interests（active + pending）合計最多 128；超限明確回報 `requestCapacityExceeded`，不 silently drop quota。每個 caller 可獨立取消，最後一個 active interest 撤銷才關閉 RPC／child，cleanup 完成才放行下一筆。`readAccountUsageTransport()` 只重用健康 quota connection；2 秒 timeout 可獨立注入，不含 queue 等待。M0 DTO 僅保留 optional daily collection 的 typed wire fields，不保留 summary／threadUsage，不做 M1 語意驗證。完整匹配 usage error 保留 child；壞 stream 仍完整 reap／await reader，再由下一個 quota demand 重連。其餘本文保持核准的後續設計，auth lifecycle signals／activity adapter／service／store／UI 尚未實作。

M0 gates：16 個新增 deterministic transport tests 通過，mixed stress 最大 active RPC = 1、quota pending priority 通過；完整 XCTest 353 passed／0 failed／2 預期 opt-in skips；clean Debug／Release build 通過；既有 Live Codex quota test（`CodexProvider().fetchUsage()`，packaged ChatGPT runtime）1 passed／0 skipped。未做 live account activity 驗證或效能量測。**目前狀態：READY TO IMPLEMENT v0.3 M1**；M1+ 功能仍未實作。

## 1. 範圍與非目標

**GO WITH EXPLICIT LIMITATIONS**：使用 stable `account/usage/read`，不提供 `threadId`、不開啟 experimental API，取得 **Codex Account Activity** snapshot。數值名稱為 **Provider-reported token activity**（供應商回報的 token 活動量）。採 explicit opt-in、獨立能力判定、memory-only、整份替換。

不承諾完整涵蓋、即時更新、固定保留期間、精確每日帳務、訂閱消耗或本機裝置專屬用量。不做永久跨帳號歷史、成本估算、模型／thread 分析、export、雲端同步、其他 provider、credential／session／transcript fallback、Reset Intelligence。7／30 日只查詢單次回應，不累積跨回應資料。

依據：本次任務提供的已完成 feasibility 結論；[既有產品研究](QUOTAMEW_NEXT_PRODUCT_RESEARCH.md) §7–9 的廣泛持久化提案在本功能由本文件收斂取代；不重新開啟來源調查。[Codex provider 文件](providers/codex.md) 與 [App Server 官方文件](https://learn.chatgpt.com/docs/app-server) 保留來源參照。本文的 timeout／容量／UI age 門檻是工程政策，並非 provider 契約。

Repository baseline：`main`，HEAD `3fdf8af462715a7241db3fe87e7dd9fac3446739`（本機產品研究），`origin/main` 與 `v0.2.0-rc.2` commit 均為 `3a63921fced7ed7fd68b4ddbc9c5b09e8c97be95`；開始時工作樹乾淨。不得更動 RC.2、release metadata、tag、ROADMAP 或 runtime。未來實作須另外接受 implementation gates。

## 2. 既有架構限制

只列影響設計的 source constraints，不重新整理現有文件：

| 實際接點 | v0.3 必須遵守的限制 |
| --- | --- |
| `UsageProvider` → `UsageService` → `RefreshCoordinator` → `AppModel` | 完整保留 quota pipeline；activity 不進任何 quota result、status、reset 或 notification input |
| `UsageService.refresh` | 依序讀取 providers，I/O 前再次檢查 provider enablement；activity 必須有自己的 consent 最終檢查 |
| `RefreshCoordinator` | 合併單一 quota task；不改成兩種業務的共同 coordinator |
| `AppModel` | 擁有 quota cadence、backoff、lifecycle generation、快取與通知評估；activity 失敗不得進 `finishRefresh` 或 retry 計數 |
| `AppDependencies`／`CodexProvider` | 目前 default provider initializer 私有建立 client；live assembly 須改為建立一個共享 client，透過既有 reader initializer 注入 quota adapter |
| `CodexAppServerClient` | 現行 coalescing task、response envelope／stream 都是 rate-limit-specific；actor await 期間可重入，不能直接加第二個 RPC 方法便認定已序列化 |
| `ManagedCodexConnection`／stdout reader | 一個 expected ID、一筆 bounded response、1 MiB line limit；timeout／cancellation 現在會停整個 child；保留 cleanup 與單 reader 邊界 |
| `runtimeDiagnostic()` | 目前 `lastRequestSucceeded`／failure 表示 quota 相容性；activity 不可覆寫這些欄位 |
| `SettingsStore`／`SettingsModel` | typed UserDefaults + MainActor observable settings；新增一個獨立 consent，不改既有 provider／notification preferences |
| `DashboardView` | 348 × 500 的額度 popover；不塞入完整圖表或完整 bucket arrays |
| 既有 tests | 已有 reuse／coalescing／reap、15 分鐘 cadence、通知完成後 schedule、backoff、disabled／countdown no-I/O 回歸點；M0 起維持 |

```text
UNCHANGED QUOTA
UsageProvider -> UsageService -> RefreshCoordinator -> AppModel -> Limits / Notifications
        CodexProvider ----\
                          > one CodexAppServerClient / one sequential request slot
 CodexActivitySource ----/
        ^
TokenActivitySource <- ActivityService -> ActivitySnapshotStore <- ActivityModel <- Activity UI
                        demand / consent      memory only           projections
```

無 activity → `UsageWindow`／`ProviderUsageSnapshot`／`LocalResetDetector`／`NotificationService` 的 dependency。

## 3. Activity domain

全部為 typed、`Equatable`、`Sendable` value；不採 generic metadata dictionary，不需要 `Codable` persistence。

| 名稱／欄位 | 語意 |
| --- | --- |
| `ProviderCalendarDate` | 驗證後原樣保留 ASCII `YYYY-MM-DD`；year 0001…9999 的 Gregorian 合法日期。不是 absolute instant，沒有 timezone |
| `ActivityBucket.sourceDate` | `ProviderCalendarDate`；bucket stable identity 是日期，來源在 snapshot 層 |
| `ActivityBucket.reportedTokens` | 非負 `Int64`；0 是明確回報零；缺日期不建立 bucket；null／缺少 token 值不能變成 0 |
| `ProviderActivitySnapshot.providerID` | 沿用 `ProviderID`；live 初版只有 `.codex`，不新增 provider registry |
| `ProviderActivitySnapshot.source` | `ActivitySource`：typed kind `.codexAccountUsage`／`.synthetic`、scope `.accountAggregate`、basis `.providerReportedTotal`；靜態程式控制的文件 URL／說明 |
| `ProviderActivitySnapshot.capturedAt` | 注入的 clock 在成功接收並驗證完整 snapshot 時產生；代表 QuotaMew 擷取完成時間，不是 provider generation time |
| `ProviderActivitySnapshot.buckets` | 唯一、遞增 source date 的 bounded array |
| `ActivitySource` 的 confidence | live 為 `.providerReported`、fixture 為 `.synthetic`；不設「精確帳務／完整」信任等級 |
| `ActivityCoverage` | 每個 query 的 `reportedDateCount`、`missingDateCount`、requested range 與 `.allDatesReported`／`.partial`；source completeness 固定 `.unknown` |
| `ActivityAvailability` | 獨立於 capability，見 §5；unknown／unavailable 絕不是 numeric value |

日期比較與加減以 checked Gregorian civil-date arithmetic 實作，包含 leap-year 測試；不得轉為 midnight `Date` 再用裝置 timezone 計算。顯示保持 source string，不把它改成臺灣日曆日期、不以本機 today 推論 bucket。

三態對 query 使用 `ActivityDateValue.reported(Int64)`／`.missing`；整個 query 另有 `.unavailable(reason)`。Unavailable query 不產生一排 missing 日期，reported(0) 必須仍顯示 0。

## 4. Snapshot 語意

`ProviderActivitySnapshot` 是單次成功回應的 allowlisted 投影，不是 history。驗證全部 core buckets 後才建值；按日期排序，完全相同重複值去重，衝突拒絕。成功 snapshot 整份替換；新回應缺少舊日期時，舊日期立即消失。不得 append、逐日 merge、把修訂相加或保留 previous snapshots。

Equality 比較所有 typed 欄位（含 `capturedAt`），不使用 random UUID／clock-derived bucket IDs；相同 fixture + clock 產生 deterministic equality。相同 buckets 的兩次擷取有不同 capture metadata 是預期行為。未知 optional provider fields 忽略；未來經 review 的 typed optional 欄位可加入，缺少時保持 nil，不先建立空 breakdown／pricing 欄位。

合法但 null／缺少／empty daily collection 是成功 method 回應，回報 `noDailyBuckets` 並清除 prior snapshot；保留成功擷取 metadata、typed reason（`nullCollection`／`missingCollection`／`emptyCollection`），不代表零活動或 provider unsupported。合法非空 collection 中任何 bucket 缺 core date／token 值則拒絕整份候選。

## 5. Capability／status model

不擴充 quota `ProviderStatus`。兩個小 enum，避免把所有組合做成多重狀態：

| 狀態軸 | 值與轉移 |
| --- | --- |
| `ActivityCapability` | `.unknown` → `.supported` 或 `.unsupported`；只在同一 runtime generation 記憶體快取，runtime 變更重設 unknown |
| `ActivityAvailability` | `.disabled`、`.idle`、`.loading`、`.available`、`.noDailyBuckets(reason)`、`.unavailable(reason)` |

`loading + unknown` 已足以表示 checking，不增加 checking capability。Known supported + fetch timeout 仍是 supported／unavailable；method-not-found 是 unsupported／unavailable(methodUnsupported)；no buckets 是 supported／noDailyBuckets；consent off 是 disabled，可保留非個人化 capability hint，但不做探測。未取得可理解回應的 failure 不證明 supported，也不證明 unsupported。

Failure reason 僅 allowlisted：`methodUnsupported`、`fetchFailed`、`timedOut`、`invalidData`、`limitExceeded`、`contextInvalidated`、`providerUnavailable`；正常撤銷需求／cancel 回 idle，不顯示 raw error。Unsupported 在 runtime 更換前不重試；同 runtime 手動刷新亦不無限探測。

## 6. Source adapter contract

精確名稱 **`TokenActivitySource`**，以 token 活動能力命名，保持與 `UsageProvider.id` 一致。最小介面宣告如下（契約，非實作）：

```swift
protocol TokenActivitySource: Sendable {
    var id: ProviderID { get }
    func fetchActivity() async throws -> ActivityFetchResult
}
```

`ActivityFetchResult` 只有 `.snapshot(ProviderActivitySnapshot)`、`.noDailyBuckets(source: ActivitySource, capturedAt: Date, reason: NoDailyBucketsReason)`、`.unsupported`。暫時性／validation error 為 typed `ActivityFetchError`，cancellation 保持 `CancellationError`。Service 驗證 result provider 與 source 契約，不接受錯 provider snapshot。

`CodexActivitySource` 依賴 provider-private `CodexAccountActivityReading.readAccountActivity()`，使用同一 client。DTO 解碼與 mapping 留在 `Providers/Codex/`，UI／service 不接收 DTO、任意 strings、JSON 或 Codex error bodies。Capability 由 `ActivityService` 根據這次低優先 activity request 的結果判定；不新增 discovery RPC，不把它放入 quota runtime health。Shared transport 可發送 typed lifecycle invalidation，與業務 source protocol 分開。

## 7. App-server transport 最小演進

只支援兩個業務 method，不建立 concurrent JSON-RPC framework。

| 決策 | 最小機制 |
| --- | --- |
| 共用 child | 一個健康 child、一個 stdout reader、一個 active request；activity 禁止另開 child。無健康 quota connection 時先顯示 unavailable，等待正常 quota lifecycle 建立後的下一次 demand，不讓 activity 自行啟動／重連 runtime |
| 全 request serialization | client 內明確的 bounded admission gate：至多一個 active、各一個 coalesced pending quota／activity；從 connection 準備、write、read、decode 至必要 cleanup 都持有 request slot，await 不釋出 slot |
| Method-aware decode | expected response descriptor = connection generation + ID + `.rateLimits`／`.accountActivity`；先讀 envelope ID/error code，再只解碼匹配 method 的 typed result。非匹配回應立即丟棄，不用 rate-limit DTO 解碼所有輸入 |
| 通知 | 只識別已知 auth lifecycle method 名稱，產生 `.authenticationContextChanged`，不解碼／保存 account payload；未知 notification 立即丟棄，無 transcript subscription |
| Quota priority | gate 每次空閒先取 quota；有 quota pending 不發 activity。活動只在 quota cycle（含 notification 評估）完成且無新 quota demand 時入場 |
| 已在 wire 上的活動 | 不能安全搶占 bytes；quota 到達後不再接續活動，等待本次至多 2 秒剩餘時間與必要 cleanup，下一個必為 quota。不為正常 priority 切換殺 child；不宣稱零延遲搶占 |
| Timeout | quota 保留現有 5 秒政策；activity 從 write 起獨立 2 秒 timeout，不計 queue 等待。撤銷 queued request 不影響 child |
| Buffer bounds | 保留每行 1 MiB 限制與只保留一個目標 response；活動候選另有 bucket count 上限。不增 raw-message queue／response map |
| 可隔離 error | 完整匹配 envelope 的 method-not-found、其他 server error、完整已消費 activity result 的 core validation 失敗：只結束該 request，保留 healthy child |
| Stream 不確定 | timeout、active cancellation、EOF、oversize 或壞 envelope：停止並 reap 舊 child、清空 expected/buffer、等 stdout reader 結束才放行 quota；quota 自己的下一次 request 建立 replacement，不在 activity service 自動 restart |
| Cancellation | coalesced callers 撤銷只移除自己的 interest；取消 queued activity 不得呼叫現行全 connection cancellation handler。active activity 在 consent/demand 撤銷時取消並走安全 cleanup；不能取消 quota task |
| Diagnostics | quota success/failure 欄位只由 quota 更新；connection connected/disconnected 仍忠實表示 physical 狀態。Activity 有獨立 typed capability／availability，不寫 usage values |

避免遲到 response 污染：timeout／active cancellation 後不重用同一 stream；ID 只在該 generation 有效；release gate 必須等待 cleanup，generation mismatch 回應不能 publish。初始化 envelope 不可誤判為 activity；matching malformed result 和 malformed framing 分別測試。

此方案承認共享 child 的物理失效可能需要 replacement，不能承諾 activity timeout 後「原 child 保留」。承諾的是**下一個 quota request 可正常運作**，quota state、backoff 與通知不被 activity outcome 直接修改。共享 stream 帶來的最長 2 秒活動等待是明示工程取捨；M5 量測此延遲，不更動 quota cadence／quota timeout。

## 8. Scheduling policy

選 **A：on-demand only**。7／30 日資料由一次回應提供，不需要先累積 30 天。先不加 hourly task，也不對每輪 quota refresh piggyback。

Scheduling owner 是 **`ActivityService`（`@MainActor`）**，一個 owned coalesced task、有限 demand 狀態；clock／source 可注入。不是 AppModel 的第二種 refresh。`ActivityModel` 只送 visible-demand／manual intents。

| Trigger | 政策 |
| --- | --- |
| Consent 開啟 | 只啟用入口，沒有可見活動需求則零 activity I/O |
| 活動 window 初次開啟 | consent + Codex enabled + demand + healthy connection + 非 unsupported 才要求一次；quota 忙時合併 pending demand，完成後再檢查資格 |
| Dashboard 開啟 | 僅入口，沒有自動活動讀取 |
| 活動 manual refresh | 合併相同 in-flight；活動 refresh 開始先清舊值；不用 quota refresh/backoff API |
| Quota refresh 開始／完成 | AppModel 小型 typed callback 通知 busy／idle、Codex availability；不等待 activity。僅喚醒既有 pending visible demand，不產生新的 activity refresh |
| 本機 countdown／切 7D 與 30D | 純 projection，零 I/O |
| 最後活動 surface 關閉 | 立即撤銷 demand、清 snapshot、取消活動 task；沒有 pending background refresh |
| 活動失敗 | 不自動 retry loop；一次手動要求才重試 temporary failure，rapid manual actions 合併。每次完成後至少 30 秒工程 cooldown；unsupported 不重試 |

Visible view 不持有 scheduler/timer。擷取超過 60 分鐘只呈現「較早擷取」與 capture time，不以此啟動 I/O、不暗示 60 分鐘 provider freshness 保證。關閉重開會重新擷取；cooldown 中保持 unavailable/idle 並提示稍後重試，不能重顯示被清除的舊值。排程 interval 使用 monotonic clock；capturedAt 顯示使用 wall clock，clock rollback 顯示 age unknown，不補造來源時間。

## 9. Memory snapshot ownership

名稱 **`ActivitySnapshotStore`**；不用 HistoryStore、Repository 或暗示 disk 的 ActivityStore。

| 項目 | 決策 |
| --- | --- |
| Owner | `AppDependencies.Runtime` 建立並透過 service／model 持有單一 instance |
| Isolation | `@Observable @MainActor`；現有 UI／settings 在同一 actor，不需要額外 store actor 與 stream subscription |
| Lifetime | runtime lifetime；snapshot 僅存在於 consent + 可見 demand 的短生命週期，process 結束不保留 |
| State | 至多一個 Codex snapshot、capability、availability、successful capture metadata、local generation counter；不是 provider → history map |
| Mutation | 只有 ActivityService 能 replace／clear／改 status；MainActor 同步 atomic assignment；UI 無寫入權限 |
| Reads | read-only state 與 bounded pure query；完整 buckets 不進 AppModel 或 Dashboard |
| Replacement | 候選完整驗證 + eligibility/generation 再檢查後單次 replace；noDailyBuckets 也清除舊資料 |
| Bounds | 366 buckets／snapshot，最多一份已發布值 + 一份 bounded 解碼候選；no archive、append、launch restore |

每次 consent/demand/context 撤銷先同步提升 service generation 並清 store/model projection，再取消 async task。Task 在所有 await 後、尤其 publish 前重新檢查 generation、consent、Codex enabled 與 demand，防止已關閉後的 late result 復活。Generation 是本機短生命週期控制值，不是帳號 ID，也不進 snapshot、settings 或 logs。

## 10. Account-context invalidation

**選 A：清除 snapshot，再呈現 unavailable/contextInvalidated 等待新成功值。** 不以 unavailable 包裝仍可讀的舊數字。少一份 stale UI，但不讓舊帳號資料延續為新帳號狀態。

清除觸發：connection disconnect／reconnect（含 cleanup）、已知 provider auth lifecycle 通知、任何可安全得知的 logout／login completion、Codex unavailable／disabled、runtime replacement、app termination、sleep／wake、活動 window 關閉、App 離開 active、新 activity refresh 開始／失敗、consent off。重新 active 只喚醒仍存在的 visible demand；不做全域 background request。

現行 QuotaMew 沒有登入／登出流程；不得為偵測帳號新增 account identity read。已知通知只抽 typed lifecycle signal；不假造這些事件目前已被實作或必定送達。Runtime replacement／connection generation 由 client 邊界同步失效，在下一次讀取或 publication 前可檢查；AppModel eligibility 與 provider unavailable 經組裝層 callback 傳到 activity service，不逆向污染 quota。

**Invariant：無法證明連續性的舊 snapshot 不可被顯示成「目前帳號」的資料。** 即使 connection generation 相同，也不證明帳號相同。UI 一律描述「最近一次擷取的 Codex 帳號活動」，不顯示帳號身分或「目前帳號」斷言；新 fetch 成功只代表該次已驗證 request 的結果。所有 query 僅在同一份 snapshot 內運作。

Lifecycle 無法偵測所有外部帳號切換；即使持續開著畫面也可能發生 silent switch。這是公開限制，不用 local generation 偽裝解決。短 display lifetime、關閉/失敗清除、每次 refresh 不保留舊值以及 capture attribution 降低風險；**不因此允許永久 history**。

## 11. Query／coverage 與呈現語意

`ActivityQueries` 是 bounded 純函式，無 I/O、timer、locale/date timezone conversion。UI range 精確稱「截至最後回報來源日期的 7／30 日」。

| Query | 規則 |
| --- | --- |
| latestReportedBucket | 唯一排序 array 的最後一筆；不是 Today，不推論尚未報告的後續日期 |
| range(7／30) | end = latest source date；start = end − (N−1) civil days；不是「最後 N 筆 buckets」，也不是本機 today 回推 |
| values | 固定 N 個 source-date slots：存在 → reported(value)，不存在 → missing；下限 0001 年無法構成 range 則 unavailable(rangeNotRepresentable)，不假造日期 |
| coverage count | distinct reported dates／N；explicit zero 算 reported date |
| missing count | N − reported count；這只是 snapshot 沒報告該日期，不證明 provider 原始資料遺失 |
| total | 使用 checked Int64 sum；overflow → aggregateUnavailable，不影響有效單日值。部分涵蓋時不顯示「7D／30D total」；可顯示「已回報 4／7 日合計 X」，並列 missing count |
| all N dates reported | 可顯示「7／30 個來源日期已回報值合計」，仍註明 provider source completeness unknown，不稱完整帳戶消耗 |
| average／comparison | v0.3 不提供；不對缺日補零、除以 N 或做成長率 |

無 buckets 時無 latest／range anchor，顯示 noDailyBuckets，不生成空白的 today chart。Coverage 全日期有值與資料完全涵蓋帳號是兩回事；初版永不產生 `.completeAccountHistory`。

`ActivityModel` 產生靜態產品名稱、metric 說明、source-reported date、capture time、coverage count、missing count、age label、provenance explanation。零值可畫零點／0 標籤；missing 使用 gap／獨立符號與 VoiceOver「未回報」；unavailable 是獨立整體狀態。來源說明保留「供應商回報／涵蓋可能不完整／非即時／非帳務或額度消耗」。沒有 source timezone 故不使用「今日」摘要；latest bucket 明列來源日期。擷取時間可用本機時區顯示，須與來源日期分開標示。

## 12. Settings／consent

唯一新設定：`isCodexAccountActivityEnabled`，key `activity.codex.account.enabled`，預設 false；missing／非 Bool／未知型別都視為 false，不覆寫未知值。只保存 Bool，沒有 retention control、database location、帳號 key、last snapshot、capture time 或 activity values。

Settings 文案説明 opt-in 向 Codex 讀取帳號聚合活動、只留記憶體、不保證完整／即時。`SettingsModel` 同步保存並呼叫 service 的 enablement transition；停用時先讓 UI 消失、清 store、提升 generation，再取消工作；I/O 入場前與 publish 前再查 consent。Provider enablement 仍是 quota 原設定；Codex disabled 時 activity 不讀取，consent 可保留以尊重使用者選擇，但重新 enabled 且無可見 demand 也不讀取。

## 13. Observable UI state ownership

**`ActivityModel`：`@Observable @MainActor`，由 AppDependencies.Runtime 持有。** 觀察同 actor 的 observable store state，提供 computed bounded projections，避免維護第二份完整 snapshot。切換 range 只變本機 selection。Service 非 UI observable source，store 是唯一資料狀態來源；不新增 custom multicast/event infrastructure。

AppModel 繼續觀察 quota provider states／quota refreshing／quota capture metadata；不接 activity buckets、capability、錯誤或 refresh task。允許少量 outbound callback 通知 activity quota busy／idle、Codex unavailable／eligibility，與 quota 結果無關；callback 不 await activity、不影響 notification completion／schedule deadline。

最小 UI：Dashboard 新增開啟 **Codex Account Activity** 的入口（consent off 時沒有入口）；原生獨立 `ActivityWindowView` 持有 7／30 source-date projection、latest source bucket、capture／coverage／來源説明與 activity refresh 按鈕。選單列數字、quota card、progress、通知全部不加入活動指標。Dashboard 不做 Today 摘要或自動讀取；若日後加入 tiny recent 摘要只能讀既有 projection，沒有 I/O 與 current-account 斷言。此版不做巨大 analytics popover。

Window demand 經明確 open/close lifecycle 到 service，不依賴 SwiftUI body 求值。所有 surface 共用 model；最後 demand 消失即清除，最多固定 dashboard/window 兩個已知 demand flags，不累積任意 consumer IDs。

## 14. Failure isolation

採最保守 **不保留失敗後的 activity stale values**；來源連續性未解決，不複製 AppModel 的 quota stale fallback。畫面上成功值變舊可顯示 age/capture metadata，但重新讀取或 failure 後立即無數字。

| 組合 | Activity 行為 | Quota 行為 |
| --- | --- | --- |
| quota success + activity success | atomic full replacement | 正常額度、通知、reset |
| quota success + unsupported | clear；unsupported，該 runtime 不再探測 | 完全不變 |
| quota success + activity timeout | clear；unavailable(timedOut)；安全關閉壞 stream | 不改既有 quota snapshot／backoff；下次 quota 可重連 |
| quota success + malformed core | clear；unavailable(invalidData)；完整 framing 可留 child | 完全不變 |
| quota success + disabled | 無入口、無 snapshot、零 activity I/O | 完全不變 |
| quota success + null/missing/empty collection | clear；supported + noDailyBuckets | 完全不變 |
| quota failure + previous activity | clear，context continuity 不足；不保留舊數值 | 沿用既有 quota stale／backoff 規則 |
| activity cancellation／late completion | generation guard 禁止復活 | 不能取消 quota task |

Activity 無 automatic retry／restart、不能 suppress quota notifications、不能呼叫 reset detector 或 notification evaluation。共享 transport 的壞 stream cleanup 是必要且有限的例外，不是 provider lifecycle 無條件重啟策略。

## 15. Privacy invariants

1. 正規化資料只允許 provider enum、來源日期、非負 token aggregate、擷取時間與 typed provenance／status；永不保存 email、account ID、credential、auth token、thread/session ID、model、workspace/path、repository、prompt、response、tool output、source code 或 raw payload。
2. Request 只送固定 method／request ID，不提供 threadId／local metadata；initialize 延用既有必要 client metadata，不加活動值。沒有 QuotaMew telemetry／upload。
3. 原始 bytes 只能在 bounded transport/decoder transient buffer 中處理，匹配完成／失敗立即釋放；不是 raw cache。非 allowlisted DTO fields 不建立通用 JSON object graph，不捕捉 account notification bodies。
4. Error mapping 只用 typed code/category，禁止 `localizedDescription`、server message、decoder debugDescription、payload／command output dump。stderr 維持 null device；debug/release 同樣受限。
5. Activity diagnostics 僅 consent、supported／unsupported、available／unavailable、last capture minute（分鐘化）；不包含 source date list、tokens、counts、raw codes、帳號／local generation。UI 可以顯示 normalized 值，但不可被 diagnostics copy／log renderer 共用輸出。
6. Settings 僅新增 Bool；snapshot/store 不提供 disk encoding、export、crash attachment 或 restore API。不將活動值送入現有 runtime diagnostics hooks。

## 16. Defensive validation bounds

所有上限是初版工程預算，不能由單次 live 的 55 buckets 推論保留期限或 protocol 上限；超限顯示 unavailable，不能 silent truncate 後聲稱涵蓋完整。

| 輸入 | 上限／處理 |
| --- | --- |
| stdout line／response | 保持 1,048,576 bytes；append 前檢查，拒絕 oversized；只有一筆 matching buffered response |
| daily buckets | 原始 collection 最多 366 entries，去重前計算，防 duplicate flood；超過拒絕整份。366 是容量，不是來源天數承諾 |
| source date | 精確 10 ASCII bytes，合法 YYYY-MM-DD；不接受 trim、time suffix、Unicode 數字、locale parsing 或假 timezone |
| token 值 | JSON integer 可 losslessly 表示的 0…Int64.max；reject negative、fraction、string、Bool、overflow、null／missing core value。不經 Double 中轉；range sum 使用 checked arithmetic |
| duplicate date | same-value 合併一筆（不是相加）；conflicting values 拒絕整份，無「最後一筆勝」 |
| malformed bucket／core collection type | 任一 malformed core 拒絕整份；不跳過錯誤 row 後補零 |
| unknown extra fields | typed Decodable 忽略，不保存、不顯示；byte bound 限制未知字段佔用。深層未知 JSON 超過 decoder 能力也安全失敗，不擴大 parser |
| unsolicited stream output | 無匹配 ID 的合法 envelope／未知 notification 即丟棄；request timeout 不因 unsolicited data 延長。不得排隊保存 |
| local resources | 一個 child／reader／active slot、各一個 pending method、一個 service task、366 published buckets + 至多一份候選、30 projection slots；CPU／RSS 需 M5 Release 量測 |

## 17. Test architecture（僅計畫，尚未寫 tests）

fixture 均為 synthetic/redacted；測試不讀 auth、真實帳號或 transcripts。fake app-server boundary 延用現有 tests，clock／source／consent／lifecycle 可注入。

| 層 | 必測 cases／assertions |
| --- | --- |
| Domain | 日期格式／leap year／年界／range underflow；explicit zero vs missing vs unavailable；partial coverage；source 日期在 timezone/locale 改變後原樣；snapshot deterministic equality／排序 |
| DTO | valid；null、missing、empty collection 的三種 noDailyBuckets；negative、overflow、fraction、Bool／string；null core token；malformed date；duplicate same-value／conflict；unknown future fields；1 MiB boundary／oversize；366／367 entries（含 duplicates） |
| Transport | rateLimits→activity、activity→rateLimits；多 caller 同 method coalesce；gate await reentrancy；quota pending wins；active activity bounded wait；timeout／queued 與 active cancel；method-not-found 保留 child；malformed core 與 framing；wrong ID／late response；下次 quota 健康；one child／one reader／reap／shutdown |
| Service/store | disabled 零 I/O；no visible demand 零 I/O；unsupported 不影響 quota；replace removes old dates／不累加；failure 清舊值；refresh start 清舊值；reconnect/auth／runtime generation invalidation；late result 不復活；rapid manual coalesce/cooldown；no launch restore |
| Scheduling regression | activity outcome 不改 quota backoff、15 分鐘 schedule／notification ordering；pending activity 不阻塞 quota callback；countdown／range selection 無 RPC；quota cancellation 不被活動 caller 擴大；無 activity-created child／retry loop |
| UI model | 0／missing／unavailable 的文字、accessibility 與 projection；4／7、30 日 gaps；partial sum label；capture metadata/age unknown；no Today；disable/close 清畫面；clock rollback |
| Privacy | synthetic sentinel email/account/thread/session/model/path/repo/prompt/tool/code/raw JSON 出現在 unknown fields／error body／notification；normalized model、settings、diagnostics、debug/release logs 皆不能出現；只有 Bool 新 persistence，無 snapshot files |

M5 另做 native window／menu light/dark、narrow width、keyboard、VoiceOver、reduced motion 與 Release RSS/CPU、2 秒 contention、反覆開關/重連 soak。Compilation、XCTest、manual UI、live capability、process cleanup、performance、signing/notarization 必須分開記錄；不由設計／fixtures 宣稱完成 live 驗證。

## 18. Proposed file／component layout

不先建立大 framework 或多 provider hierarchy。下列是未來計畫；本次只建立本文件。

| 新檔案 | Responsibility | Owner／dependency direction |
| --- | --- | --- |
| `QuotaMew/Domain/Activity/ProviderCalendarDate.swift` | 日期驗證、比較、civil arithmetic | domain；只依 Foundation/value helpers |
| `QuotaMew/Domain/Activity/ProviderActivitySnapshot.swift` | snapshot、bucket、source、fetch result／typed status/error | domain；依 ProviderID／ProviderCalendarDate；不依 DTO/UI |
| `QuotaMew/Domain/Activity/ActivityQueries.swift` | 7/30 projection、coverage、checked reported sums | pure domain；依 snapshot |
| `QuotaMew/Providers/TokenActivitySource.swift` | 獨立能力介面 | integration boundary；依 activity domain |
| `QuotaMew/Providers/Codex/CodexAccountActivityDTO.swift` | typed result、core validation、reader contract | Codex adapter layer；不被 UI/service 匯入 |
| `QuotaMew/Providers/Codex/CodexActivitySource.swift` | DTO→allowlisted snapshot、擷取時間 | source adapter；依 private reader + domain |
| `QuotaMew/Services/ActivitySnapshotStore.swift` | observable bounded memory state | Runtime 持有；ActivityService 唯一 writer；依 domain |
| `QuotaMew/Services/ActivityService.swift` | consent/demand、coalescing、invalidation、generation guard | Runtime 持有；依 source/store + injected closures；不依通知/reset |
| `QuotaMew/Features/Activity/ActivityModel.swift` | range selection、read-only UI projections、demand intents | Runtime 持有；依 store/query + service；不依 Codex DTO |
| `QuotaMew/Features/Activity/ActivityWindowView.swift` | minimal 原生活動 window、來源與 gap 呈現 | App scene 持有；依 ActivityModel |

Tests 對應 domain、source、service/model 新 suites 與合成 fixtures，transport cases 放入既有 `CodexAppServerClientTests`；不建立空未來 provider/persistence/cost files。Typed lifecycle signal 與 request gate 初版留在既有 client 檔案，不拆 generic RPC package。

| 預期小幅修改既有檔案 | 限定內容 |
| --- | --- |
| `Providers/Codex/CodexAppServerClient.swift` | 兩個 method descriptor／typed readers、serialization gate、timeout/cancel isolation、typed lifecycle signal；這是 M0 主要且必要的修改 |
| `App/AppDependencies.swift` | 明確共享一個 client；新增 store/service/model；preview 注入合成 activity、不做 I/O |
| `App/AppModel.swift` | 僅 outbound quota busy/idle、Codex unavailable lifecycle callback；不改 quota algorithm 或持有活動 state |
| `Services/SettingsStore.swift` | 一個獨立 default-off Bool/key，嚴格型別讀取 |
| `Features/Settings/SettingsModel.swift`／`SettingsView.swift` | consent transition／說明；Codex enablement 轉送活動 eligibility |
| `Features/MenuBar/DashboardView.swift` | 一個活動 window 入口，不變額度 header/refresh 意義 |
| `App/QuotaMewApp.swift`／既有 scene 組裝 | 注入 ActivityModel，原生 window 開關 demand／app active lifecycle；依實際 scene 接點保持最小修改 |
| String Catalog／project file | 僅必要本地化與新 source/test membership，不改 release version/build／deployment target |
| `ARCHITECTURE.md`（未來 implementation） | 新 contract/privacy boundary 真正實作時對齊；本次不修改 |

明確維持 untouched：`UsageProvider.swift`、`UsageService.swift`、`RefreshCoordinator.swift`、`CodexProvider.swift` 的 quota mapping、`UsageWindow.swift`、`ProviderUsageSnapshot.swift`、`ProviderStatus.swift`、`LocalResetDetector`、`NotificationService`／notification policy、`RefreshPolicy`、Claude adapter、`MenuBarPresentation`、release metadata、RC.2 tags。`CodexProvider` 既有注入 initializer 已足夠，不需要改名／雙能力 conformance。

## 19. Implementation milestones

每個 M 都可獨立編譯與 review，使用各自小 commit，quota regression 必須通過。M0–M3 不暴露未完成 feature；M4 才加入 default-off consent/入口的 user-facing behavior。

| Stage | Deliverable／focused gate |
| --- | --- |
| M0 — transport capability + fixtures | 先 synthetic two-method fake server fixtures、single-slot quota priority、method-aware decoding、2 秒 activity timeout、cancellation／cleanup isolation；無 UI／consent／activity background I/O。先證明失敗後下一個 quota request 成功，再接 live adapter |
| M1 — Codex activity adapter | date/domain/query 值 + typed DTO + TokenActivitySource／CodexActivitySource；所有 validation fixtures 與 privacy sentinels；production activity 尚不呼叫 |
| M2 — memory store/service | memory-only full replacement、disabled/no-demand zero-I/O、generation invalidation、coalescing/cooldown、client sharing；quota lifecycle callbacks 注入；開發／tests opt-in，不新增可見設定 |
| M3 — observable model | read-only projections、7/30 partial coverage、capture attribution、disable/close immediate clearing；mock previews；仍不向使用者宣稱可用 |
| M4 — minimal UI | consent Bool + 原生活動 window／Dashboard 入口、visible demand、localization、keyboard／VoiceOver；預設 off、unsupported/no buckets/failure 正確顯示；只有這時對使用者可啟用 |
| M5 — reliability/privacy/performance | 全 quota regressions、activity fault matrix、privacy checks、Release resource/priority measurements、manual UI、sanitized opt-in live checks分列；未滿足前不承諾 v0.3 ready-to-release |

沒有追加來源 feasibility blocker。尚待 implementation 的 hard gates：request serialization／next-quota recovery、帳號不確定性下不重顯舊值、零 opt-out I/O、privacy sentinel、Release bounded-resource validation。Account isolation 是**未來 persistence 的硬阻擋**，不是 memory-only v0.3 M0 的阻擋。

## 20. Future persistence seam

只有安全 stable account isolation 契約與獨立 consent／privacy review 成立後，才能在 `ActivityService` 的 validated result→store publication 邊界引入 `ActivityPersistence`。Adapter 繼續產生 normalized snapshot，UI 繼續使用 coverage／availability 語意；持久化的 account partition/key/migration/retention 需另設計，不以本機 generation 冒充 account key。

目前不預建 persistence protocol、schema、SwiftData/SQLite tables、migrations、retention settings 或 export。將來 persistence 不必改 provider DTO；如果新增跨回應 query，必須明示與本次 single-response snapshot 的差異，不靜默提高涵蓋保證。

## 21. Future cost seam

**v0.3 Daily Activity totals 不是成本計算的充分輸入。** 未來 `richer token breakdown → PricingCatalog → CostCalculator` 需要經證實的 model、input/output、cache/reasoning inclusion、tier 等資訊與 pricing revision；應使用獨立更豐富 record。不要從 v0.3 totals、訂閱方案或使用者偏好猜 breakdown；不加 cost/pricing/model 欄位，不研究價格，不用 token 活動量換算額度。

## 22. Explicit architecture decisions

| 問題 | 決定 |
| --- | --- |
| 1. Exact source protocol | `TokenActivitySource` |
| 2. Exact snapshot domain | `ProviderActivitySnapshot` + `ActivityBucket` + `ProviderCalendarDate` |
| 3. Current snapshot owner | AppDependencies.Runtime 持有的 `ActivitySnapshotStore`；ActivityService 唯一 writer |
| 4. Disk persistence in v0.3 | **沒有活動資料 persistence**；僅保存 consent Bool |
| 5. Scheduling owner | `ActivityService`；on-demand only、單 task、無第二輪詢 loop |
| 6. Reuse app-server child | 是；共享已健康 child；activity 不另啟／重連 child |
| 7. Cross-method serialization | client 內 explicit single request slot + 各一個 coalesced pending method；cleanup 完成才 release |
| 8. Quota priority | quota 先 admission；activity 排在 quota cycle 後；已在 wire 上最多 2 秒 bounded wait，不承諾零延遲 preemption |
| 9. Clears activity | consent/provider off、最後 demand 關閉、refresh start/failure/no buckets、auth lifecycle、provider unavailable、disconnect/reconnect/runtime replacement、inactive/sleep/wake/termination |
| 10. AppModel observes | 原 quota state；不觀察 activity，只輸出小型 lifecycle callbacks |
| 11. Activity UI model observes | memory store 的 typed capability/availability/capture 與 bounded source-date query projections |
| 12. SettingsStore changes | 一個 `activity.codex.account.enabled` default-off Bool；無 retention／account／snapshot keys |
| 13. v0.2 preserved | UsageProvider／UsageService／RefreshCoordinator、quota domain／mapping、RefreshPolicy、reset detector／notifications、Claude、quota menu presentation、release history |
| 14. Persistence seam | validated normalized result 與 store publication 之間；安全 account isolation 成立才引入 ActivityPersistence |
| 15. Explicit exclusions | 永久 history、完整帳務／訂閱消耗、成本、model/thread analytics、cloud／export／fallback／其他 provider／Reset Intelligence |

**FIRST IMPLEMENTATION TASK：M0 以 synthetic two-method fake app-server fixtures 先驗證 single-slot request gate、quota pending priority，以及 activity timeout／cancel 後下一個 quota request 的健康恢復。**

**FINAL STATUS：READY TO IMPLEMENT v0.3 M0。** 這是架構可進入實作的判定，不是 v0.3 已實作、通過 release gates 或已承諾發行。
