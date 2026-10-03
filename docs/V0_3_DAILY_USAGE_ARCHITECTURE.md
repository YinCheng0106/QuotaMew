# v0.3 — Codex Account Activity 架構設計

架構核准狀態（M0 實作前）：**READY TO IMPLEMENT v0.3 M0**。2026-10-02；設計不代表承諾 v0.3 發行。檔名沿用指定名稱；產品名稱不是 Daily Usage／History。

M0 implementation note（2026-10-02）：transport 已加入兩種 closed method、single active slot、每種 method 各一個 coalesced pending batch 與 quota priority。Caller interests（active + pending）合計最多 128；超限明確回報 `requestCapacityExceeded`，不 silently drop quota。每個 caller 可獨立取消，最後一個 active interest 撤銷才關閉 RPC／child，cleanup 完成才放行下一筆。`readAccountUsageTransport()` 只重用健康 quota connection；2 秒 timeout 可獨立注入，不含 queue 等待。M0 DTO 僅保留 optional daily collection 的 typed wire fields，不保留 summary／threadUsage，不做 M1 語意驗證。完整匹配 usage error 保留 child；壞 stream 仍完整 reap／await reader，再由下一個 quota demand 重連。其餘本文保持核准的後續設計，auth lifecycle signals／activity adapter／service／store／UI 尚未實作。

M0 gates：16 個新增 deterministic transport tests 通過，mixed stress 最大 active RPC = 1、quota pending priority 通過；完整 XCTest 353 passed／0 failed／2 預期 opt-in skips；clean Debug／Release build 通過；既有 Live Codex quota test（`CodexProvider().fetchUsage()`，packaged ChatGPT runtime）1 passed／0 skipped。未做 live account activity 驗證或效能量測。**目前狀態：READY TO IMPLEMENT v0.3 M1**；M1+ 功能仍未實作。

M1 implementation note（2026-10-02）：已實作 `ProviderCalendarDate`、`ActivityBucket`、`ProviderActivitySnapshot`、靜態 `ActivitySource`、`ActivityFetchResult`／`ActivityFetchError`，以及獨立 `TokenActivitySource`／`CodexTokenActivitySource`（下文計畫名稱 `CodexActivitySource` 的實作名稱）。Adapter 僅注入既有 M0 reader，沒有預設建立 client，也沒有接入 production assembly。日期為 year 0001…9999 的合法 Gregorian 10-byte ASCII source string，使用 civil components 驗證／字串排序，不轉換 `Date` 或 timezone。Token 是非負 `Int64`；snapshot 唯一遞增排序、相同值重複去重、衝突拒絕，成功完整驗證後才擷取時間。

M1 保留 §6 核准 result 契約：missing／null／empty collection 各回傳帶成功擷取時間的 `.noDailyBuckets` reason；empty 是合法「未回報 daily buckets」，missing／null 是 daily data unavailable，三者均不代表零。只有 explicit bucket 的 `0` 才表示供應商回報零；日期 gaps 保持缺席。不存在任何 history accumulation、query totals 或 store。`-32601` 映射 activity `.unsupported`，其他錯誤正規化為 `fetchFailed`／`timedOut`／`invalidData`／`limitExceeded`／`providerUnavailable`，cancellation 原樣保持；不使用 quota status。DTO 保留 missing/null presence bit，增量解碼最多 366 原始 entries（去重前），超限在 M0 decoding boundary 正規化為 `invalidData`；domain 容量超限與 transport byte/waiter 超限為 `limitExceeded`。既有 M0 1 MiB response bound 與 request lifecycle 沒有更動。Summary、threadUsage 與未知 fields 均不解碼或保留。

M1 gates：domain 9、adapter 15 個 deterministic tests 通過，新增 1 個 adapter→M0 共享 transport 回歸測試通過；既有 16 個 M0 multi-method、14 個 app-server client、13 個 quota provider deterministic tests 全通過。合成 privacy fixture 與 raw-error sentinels 未進入 DTO 投影、domain 或正規化錯誤。完整平行 XCTest **378 passed／0 failed／3 預期 opt-in skips**；clean Debug／Release build、`git diff --check` 通過。獨立 opt-in live M1 adapter probe 通過：**55 buckets**（未輸出 token 值），日期／值／排序／capture／Codex provenance 通過；同一 client 在 activity 後可再次讀取 quota，child／reader 不重建，shutdown 後 child 已 reap、reader = 0。既有 Live Codex quota test 隨後另行通過（packaged ChatGPT runtime）。未做效能量測、UI、通知送達、notarization 或 distribution 驗證。**目前狀態：READY TO IMPLEMENT v0.3 M2**；M2+ store／service／model／query／Settings／scheduling／UI 仍未實作。

M2 implementation note（2026-10-02）：`ActivitySnapshotStore` 與 `ActivityService` 已實作為獨立 actor，Runtime 持有兩者；store 只留 provider-keyed 的單份 current normalized snapshot，完整替換、不合併日期、不留 history/status/error、不寫磁碟。Store 另留至多每 provider 一個短生命週期 UUID publication fence；不是 identity，不進 snapshot、設定或 diagnostics。Refresh 開始先清舊值，只有已驗證、provider 相符且 consent/generation 仍有效的成功結果可發布；missing/null/empty `.noDailyBuckets`、unsupported、unavailable、invalidData、failure、timeout、disable/invalidate 全部不留舊數字。M1 的 explicit zero／missing／source-date／duplicate semantics 不變；synthetic empty snapshot 合法，Codex empty collection 仍回 `.noDailyBuckets(.emptyCollection)`。

M2 service API：`refresh(provider:) async throws -> ActivityFetchResult`、`setCodexAccountActivityEnabled(_:)`、`invalidate(provider:)`、`shutdown()`。沿用同一 result enum，增加 application `.disabled`、`.unavailable(ActivityFetchError)`、`.failed(ActivityFetchError)`；不另建平行狀態 hierarchy。每 provider 一個 shared task，overlapping callers 共用 acquisition/publication；caller cancellation 不取消 shared source task，等 bounded operation 完成後向該 caller 回 `CancellationError`。Explicit invalidation 先撤銷 generation、取消 activity task、清 store；cancellation-insensitive late candidate 同樣無法復活。Shutdown 停止 admission、取消／drain 當下 owned work 並清所有 snapshots，**不關閉共用 transport**。

M2 consent：SettingsStore 保存唯一新 Bool `activity.codex.account.enabled`，missing／非 CFBoolean 的值預設 false，不覆寫未知值；既有使用者同樣 opt-in。Source I/O 入場前與 publication 前重新檢查 consent + quota provider eligibility。應用層 enable/disable 經 service 方法，SettingsStore 仍是 persistence owner；enable 不自動 fetch，disable 清值與取消／invalidate。直接更改 SettingsStore 的測試也驗證 final admission/publication recheck，但未接入任何 Settings UI。

M2 production ownership：`makeRuntime()` 明確建立唯一 `CodexAppServerClient`，注入 `CodexProvider` 與 `CodexTokenActivitySource`；測試可注入相同 client 與隔離 SettingsStore。Runtime 僅保留 activity service/store，不新增 AppModel activity state。既有 client 內 `CodexConnectionLifecycle` 保留唯一 transport termination/deinit/shutdown cleanup 責任；service 不持有 client shutdown API。Process 結束即丟棄所有 activity memory；App termination 仍由既有 transport observer 終止並 reap child/reader。建構、啟動、enable、quota refresh 均不要求 activity；沒有 timer、background loop、piggyback、cooldown/query/model/UI。Future visible demand/cooldown 屬 M3/M4 後續範圍。

M2 account-context 邊界：M0 request generation 是 RPC batch generation，不能充當 connection/account discriminator；本次未加 connection observer 或 auth identity tracking，也不宣稱能偵測所有外部帳號切換。已暴露 `invalidate(provider:)` 供 future auth/runtime/provider-unavailable lifecycle 接點使用；目前 every explicit activity refresh 先清舊值，成功全份取代、任何失敗清空。Quota-only disconnect/reconnect 不會主動通知 idle activity store；尚無 activity UI，因此不將留存值宣稱為「目前帳號」。M3 接 UI 前必須處理 display/demand lifecycle 與 context invalidation，不能以此 snapshot 推論帳號連續性。

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

M3 實作採單一 `ActivityModelState` enum：`disabled`、`idle`、`loading`、`available(ActivityProjection)`、`noReportedBuckets(source:capturedAt:reason:)`、`unsupported`、`unavailable(ActivityFetchError)`、`failed(ActivityFetchError)`。沒有 raw Error／任意字串、quota ProviderStatus 或額外 capability cache。下方兩軸 capability／runtime retry 描述保留為後續設計，不代表 M3 已實作；目前只有使用者明確要求才 refresh。

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

M1 source 回傳 `ActivityFetchResult` 的 `.snapshot(ProviderActivitySnapshot)`、`.noDailyBuckets(source: ActivitySource, capturedAt: Date, reason: NoDailyBucketsReason)`、`.unsupported`；暫時性／validation error 為 typed `ActivityFetchError`，cancellation 保持 `CancellationError`。M2 同 enum 增加 service-level `.disabled`、`.unavailable(ActivityFetchError)`、`.failed(ActivityFetchError)`，Codex adapter 不產生這三種 application outcomes。Service 驗證 result provider，不接受錯 provider snapshot。

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
| Isolation | M2 已實作為獨立 actor，無 Observation／stream subscription；後續 M3 必須以實際 actor read boundary 設計 model |
| Lifetime | runtime lifetime；snapshot 僅存在於 consent + 可見 demand 的短生命週期，process 結束不保留 |
| State | 每 supported provider 至多一份 current snapshot 與一個 transient publication UUID；不保存 status/error/history/account identity |
| Mutation | Production writer 為 ActivityService；store actor 同步完整 replace／clear 與 generation-fenced publication；沒有 UI writer |
| Reads | read-only state 與 bounded pure query；完整 buckets 不進 AppModel 或 Dashboard |
| Replacement | 候選完整驗證 + eligibility/generation 再檢查後單次 replace；noDailyBuckets 也清除舊資料 |
| Bounds | 366 buckets／snapshot，最多一份已發布值 + 一份 bounded 解碼候選；no archive、append、launch restore |

M2 consent/context 撤銷先移除 service current generation 並取消 async task，再 await store clear；store 同 actor 的 publication fence 防止跨 actor suspension 競態。I/O/publication 前重新檢查 generation、consent、Codex enabled。M2 尚無 model/projection/visible demand，後續需另接。Generation 是本機短生命週期控制值，不是帳號 ID，也不進 snapshot、settings 或 logs。

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
| values | 固定 N 個 source-date slots：存在 → reported(value)，不存在 → missing；下限 0001 年無法構成 range 則 query 拋出 invalidData／model failed，不假造日期 |
| coverage count | distinct reported dates／N；explicit zero 算 reported date |
| missing count | N − reported count；這只是 snapshot 沒報告該日期，不證明 provider 原始資料遺失 |
| reportedTotal | 使用 checked Int64 sum；任一 window overflow → query 拋出 `invalidData`，model 為 failed 並移除所有投影，不 wrap／clamp／轉 Double。部分涵蓋時只代表範圍內已回報值合計；`completePeriodTotal` 僅在所有來源日期都有回報時非 nil，仍不保證 provider bucket finality 或完整帳戶消耗 |
| all N dates reported | 可顯示「7／30 個來源日期已回報值合計」，仍註明 provider source completeness unknown，不稱完整帳戶消耗 |
| average／comparison | v0.3 不提供；不對缺日補零、除以 N 或做成長率 |

無 buckets 時無 latest／range anchor，顯示 noDailyBuckets，不生成空白的 today chart。Coverage 全日期有值與資料完全涵蓋帳號是兩回事；初版永不產生 `.completeAccountHistory`。

M3 `ActivityModel` 只暴露精確 normalized 值與語意 metadata，不格式化數字／日期或產生使用者文案。M4 才負責 metric 說明、age／provenance labels、零點／gap／VoiceOver 與擷取時間的本地化；來源日期仍不轉為本機「今日」。

## 12. Settings／consent

唯一新設定：`isCodexAccountActivityEnabled`，key `activity.codex.account.enabled`，預設 false；missing／非 Bool／未知型別都視為 false，不覆寫未知值。只保存 Bool，沒有 retention control、database location、帳號 key、last snapshot、capture time 或 activity values。

Settings 文案説明 opt-in 向 Codex 讀取帳號聚合活動、只留記憶體、不保證完整／即時。`SettingsModel` 同步保存並呼叫 service 的 enablement transition；停用時先讓 UI 消失、清 store、提升 generation，再取消工作；I/O 入場前與 publish 前再查 consent。Provider enablement 仍是 quota 原設定；Codex disabled 時 activity 不讀取，consent 可保留以尊重使用者選擇，但重新 enabled 且無可見 demand 也不讀取。

## 13. Observable UI state ownership

**M3 `ActivityModel`：`@Observable @MainActor`，由 AppDependencies.Runtime 持有。** 只依賴 `ActivityService`，將明確 refresh 的 service outcome 經 pure `ActivityProjection.query` 轉成 atomic observable state；不讀取 store internals、不持有完整 raw snapshot 或 transport，也不接 AppModel。Actor `ActivitySnapshotStore` 是 acquisition snapshot owner，model 僅持有 Latest／7D／30D 的 bounded 投影。沒有 store observer、custom multicast、range selection、timer 或 background task loop。

API 為 `refresh() async throws`、`setEnabled(_:) async`、`invalidate() async`。建構由 composition 傳入當下 eligibility，只設 disabled／idle，不建立 task 或 fetch；enable 同樣只進 idle。所有 UI intent 在 MainActor 先清 projections／撤銷 generation，再將 lifecycle transitions 依序送往 service；consent Bool 唯一 writer 仍是 SettingsStore。Refresh 等待進行中的 transition，overlapping callers 共用同一 loading cycle；取消單一 caller 只在 bounded cycle 完成後向該 caller 回 `CancellationError`，不取消共用 source work。Disable／invalidate 取消 model-owned task 並透過 service 清除 snapshot，late completion 由 model + service 雙層 generation fence 擋下。

M4 必須經這份共用 model 呼叫 UI refresh／consent／display invalidation，不能直接改 store。外部帳號切換仍無可靠 identity signal；M3 不宣稱能偵測所有 account changes。下方 AppModel callbacks／window demand／UI 保留為後續設計，M3 未加入。

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
| local resources | 一個 child／reader／active slot、各一個 pending method、一個 service task、366 published buckets + 至多一份候選、7 + 30 projection slots；CPU／RSS 需 M5 Release 量測 |

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
| `QuotaMew/Domain/Activity/ActivityProjection.swift` | 已實作 Latest／7/30 projection、explicit gaps、coverage、checked reported sums | pure domain；依 snapshot |
| `QuotaMew/Providers/TokenActivitySource.swift` | 獨立能力介面 | integration boundary；依 activity domain |
| `QuotaMew/Providers/Codex/CodexAccountActivityDTO.swift` | typed result、core validation、reader contract | Codex adapter layer；不被 UI/service 匯入 |
| `QuotaMew/Providers/Codex/CodexActivitySource.swift` | DTO→allowlisted snapshot、擷取時間 | source adapter；依 private reader + domain |
| `QuotaMew/Services/ActivitySnapshotStore.swift` | 已實作 actor bounded current snapshot | Runtime 持有；ActivityService 唯一 writer；依 domain |
| `QuotaMew/Services/ActivityService.swift` | consent/demand、coalescing、invalidation、generation guard | Runtime 持有；依 source/store + injected closures；不依通知/reset |
| `QuotaMew/Features/Activity/ActivityModel.swift` | 已實作 observable projections、refresh／enable／invalidate intents | Runtime 持有；只依 service + pure query；不依 store internals／Codex DTO |
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
| M2 — memory store/service | memory-only actor full replacement、default-off consent、final I/O eligibility、generation-fenced invalidation、per-provider coalescing、single client sharing；純 on-demand API／開發 tests opt-in，不新增可見設定；無 cooldown 或 quota lifecycle callbacks |
| M3 — observable model | pure projections、7/30 partial coverage、capture attribution、refresh／enable／invalidate immediate clearing；synthetic deterministic tests；沒有可見 UI／previews 或自動 refresh |
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

M2 gates（2026-10-02）：新增 17 個 deterministic tests（store 3、service 10、consent/privacy 2、production shared-transport 2）通過；定向 regression 共 106 passed，M0/M1/domain/SettingsStore/quota tests 全部維持通過。完整平行 XCTest **395 passed／0 failed／4 預期 opt-in skips**，clean Debug／Release build、`git diff --check` 通過。Late success 在 disable 後不能復活，old completion 不能覆寫已完成的 new generation，20 個 overlapping callers 僅一次 source acquisition；caller cancellation 保留其他 callers，queued activity disable 不發 RPC 且保留 active quota。Production assembly startup/enable 零 activity I/O、service shutdown 保留 quota transport、只有 consent Bool 新 persistence 均由 deterministic tests 驗證。

獨立 opt-in Live M2 production-style service probe **1 passed／0 skipped**，隔離設定 domain、明確 enable、on-demand refresh 得到 **56 buckets**（只報 count，未輸出 token 值），store/returned snapshot 相符、排序通過；quota→activity→quota 共用 **1 child／1 stdout reader**，disable 清 store、disabled refresh 不進 transport，service shutdown 不關閉 quota，最終 client shutdown 後 child 已 reap、reader = 0。隨後另行執行既有 Live Codex quota test **1 passed／0 skipped**（packaged ChatGPT runtime）。未做效能 soak、manual UI、通知送達、簽章/notarization/distribution；沒有 M3+ model/view/query 或新設定 UI。

**M2 checkpoint：READY TO IMPLEMENT v0.3 M3。** M2 gates 已完成；不是 v0.3 已通過 release gates 或已承諾發行。

## M3 implementation／validation checkpoint（2026-10-02）

已實作 `ActivityProjection`、`ActivityWindowProjection`、`ActivityCoverage`、`ActivityPresentationPoint`，以及獨立的 `ActivityModel`／`ActivityModelState`。純查詢只用當次 snapshot，以 latest provider source date 作 anchor，7D = anchor−6…anchor、30D = anchor−29…anchor；不使用最後 N 筆 buckets、不轉 Asia/Taipei、不填零或回補較舊日期。Latest explicit zero 仍是 reported；empty snapshot 回無 projection，model 保留 successful capture/source 與 empty reason，不等於 unsupported／disabled／failed。4／7 regression 明確得到 4 reported、7 expected、3 missing、partial reportedTotal，`completePeriodTotal == nil`。

日期使用 timezone-free proleptic Gregorian ordinal，支援正負加日與日距；year 0001…9999、month/year/leap-century boundaries、Int offset overflow 都驗證。任一 7D／30D sum overflow 或不可表示範圍拒絕整份 query，model 為 failed(invalidData)，不保留單日／範圍數字；不更動 M1 非負 Int64 validation。日期涵蓋完整不保證 provider bucket finality、完整帳戶歷史、帳務 tokens 或 subscription quota 消耗。

Model 以 enum atomic publication 提供八種狀態；只依 service／query，Runtime 組裝唯一 model/service/store，quota/activity 繼續共享唯一 Codex client。`refresh` 純 user intent；construction／enable 零 source I/O，re-enable 為 idle，disable／invalidate 先移除 observable projections。Model generation 擋下 old completion，overlapping refresh 共用 loading task；transition 自己先發布 eligibility，再完成 task，避免等待 transition 的 refresh 與 setter completion 互相覆寫。Caller cancellation 不取消共用 acquisition。沒有新增 store observer、account identity read、AppModel callback、timer、formatting、UI、persistence 或其他 provider integration；future M4 需經 model 接 display/consent lifecycle，M3 不宣稱能感知所有外部帳號切換。

新增 **20 個 deterministic tests**（projection/date 8、model 12）通過；涵蓋 shuffled Latest／zero／empty、7D 缺日 regression、complete／partial 30D、月界／年界／閏日、全部合法年份 month-boundary round trips、exact Int64 checked sums／overflow；模型涵蓋 observation、loading／success／empty reasons／所有失敗、no raw-error sentinel、no token persistence、disable/re-enable、late completion／newer generation、20 overlapping callers／one canceled waiter、refresh during enable transition。既有 production shared-transport regression 增加 Runtime model startup／enable 零 I/O、共用 child、model refresh／invalidate checks。M0／M1／M2 全部維持通過。

定向 domain／query／model／store／service／consent／SettingsStore／Codex adapter／M0 multi-method transport／app-server／quota provider 回歸 **126 passed／0 failed／2 預期 opt-in skips**。完整平行 XCTest **415 passed／0 failed／5 預期 opt-in skips**；clean Debug／Release build、`git diff --check` 通過。獨立 sanitized Live ActivityModel probe **1 passed／0 skipped**：隔離 test settings，enable 未啟動 app-server；quota demand 建立健康共用 child 後，明確 model refresh 得到 **56 buckets、7D 7／7、30D 30／30**，只輸出 bucket／coverage counts，沒有 token 值。Projection deterministic equality／coverage reconciliation、activity 不更動 settings persistence、disable model/store 清除、同 client quota afterward PASS、shutdown 後 child 已 reap／reader = 0。其後另行 Live Codex quota test **1 passed／0 skipped**，packaged ChatGPT runtime、2 quota windows；使用 test-runner 環境變數明確 opt-in，非 skipped gate。

沒有 manual UI、效能／RSS／CPU、通知送達、簽章／notarization／distribution 驗證；M3 不加入可見介面，M4 尚未開始。ROADMAP、README、Fumadocs、release metadata 與 v0.2.0-rc.2 history 未變更。

**FINAL STATUS：READY TO IMPLEMENT v0.3 M4。** 這是 M3 implementation checkpoint，仍不是 v0.3 release-ready 承諾。

## 23. M4 介面與驗收

### 實作範圍與 ownership

M4 加入第一個可見的 **Codex Account Activity／Codex 帳號活動** 介面，保持 `CodexTokenActivitySource → ActivityService → ActivitySnapshotStore → ActivityModel → ActivityProjection` 架構。Production `Runtime` 持有唯一活動 model/service/store，quota 與 activity 共用同一個 Codex client、child、reader；不將 Activity state 加入 AppModel，也不讓 Dashboard 解析 snapshots。

新增 `ActivityPresentation.swift`（pure formatting／localized semantics）、`ActivityWindowView.swift`（SwiftUI／Charts）、`ActivityWindowController.swift`（native window ownership）與 `ActivityWindowPreviews.swift`（synthetic fixtures only）。Application delegate retains controller，既有 `SettingsSceneRoute` action container 增加 `openActivity` callback，右鍵選單順序為 Refresh Now → Account Activity… → Settings… → separator → Quit QuotaMew。維持唯一 NSStatusItem，左鍵 Dashboard、quota Refresh Now、Settings route、Quit／teardown 均維持原路徑。

視窗使用 NSWindow + NSHostingController、標準 title bar 與 native Refresh toolbar。預設 content 560×680、最小 420×460，可縮放／最小化，重複開啟同一視窗置前；關閉釋放 hosting content／window reference，重新開啟建立 presentation，仍使用原 ActivityModel。Activity open 不改 activation policy，不新增 permanent Dock icon；與既有 Onboarding／Recovery 的 policy ownership 分開。關閉保留當次記憶體 snapshot，退出／重啟只恢復 consent，沒有 token snapshot restore。

**本節採用 M4 核准的 refresh／close policy，取代上方設計提案的最後 demand 關閉清除、Dashboard 入口與未實作 lifecycle／cooldown 建議。** 不因關閉視窗清除 snapshot，也不新增背景輪詢、account identity reads 或 quota callbacks；更完整 lifecycle/privacy/performance hardening 保留原 M5 範圍。

### Settings 同意與刷新政策

Settings → Providers 新增 Codex Account Activity section，`ActivityConsentView` 的 Binding getter 直接讀共享 SettingsStore 的 Bool，setter 只呼叫共享 `ActivityModel.setEnabled`。無第二份 persisted／observable consent Boolean。Codex provider 關閉時 toggle disabled，原同意偏好仍可保留；SettingsModel 接到同一 ActivityModel，只轉送 provider eligibility invalidation，不持有活動數值。

| 動作／狀態 | 結果 |
| --- | --- |
| 全新／既有安裝 | 預設 disabled；開啟視窗顯示簡潔說明與 Open Settings，零活動 I/O |
| 啟用同意 | 只 persist consent，model = enabled/idle；不擷取 |
| enabled + idle 明確開啟視窗 | 建立／置前視窗，最多一次 shared model refresh；重疊 open coalesce |
| available 重新開啟 | 立即顯示當次記憶體資料，不重抓 |
| failed／unavailable／unsupported／empty 重新開啟 | 不自動重試；在可用狀態提供明確 Refresh／Retry |
| 手動 Refresh／Command-R | 僅經 ActivityModel.refresh；model/service coalesce，loading 先移除舊值 |
| 關閉同意 | 立即清除 observable projection；invalidate 活動工作／memory snapshot，拒絕晚到結果；future activity I/O = 0 |
| 關閉 Codex provider | SettingsModel 同步清畫面，service 重新驗證 provider eligibility；活動同意偏好保留 |
| 重新啟用 Codex provider | consent 為 true 時 model 回到 idle，無活動 I/O |
| App launch／Dashboard／Settings／quota scheduler | 不呼叫活動 refresh；既有 quota scheduler 不變 |

Settings 說明指出只在啟用後明確開啟／刷新活動視窗才擷取，不儲存 activity history 到磁碟，退出 App 清除數值；此功能不讀 prompts、threads、source code 或 credentials。不宣稱 Codex runtime 沒有網路通訊，也不加入 iCloud／cloud sync。

### 呈現／accessibility 語意

| 內容 | M4 行為 |
| --- | --- |
| period | native segmented Picker：Latest／7D／30D；只影響 presentation，預設 Latest，不持久化、不觸發 I/O |
| Latest | 最新 provider source date + provider-reported tokens；explicit zero 正常顯示 0，不稱 local Today／Yesterday |
| 7D／30D | M3 anchor−6／anchor−29 calendar ranges，顯示 **Reported total／已回報總量**、source-date range、reported/expected coverage；partial 不宣稱完整 period total |
| 正值／零／缺日 | Swift Charts 長條／baseline circle／baseline cross 日期標記；missing 不建立 zero bucket，不計 missing-day average，不插值 |
| date detail | disclosure 最多 7／30 列，exact localized token integer 或 Not reported，stable source-date identity |
| chart accessibility | chart visual hidden；本地化 summary 包含 period、range、full total、coverage／missing，逐日 rows 有完整 reported／missing label；不靠顏色區分 |
| number | 保留 Int64；<1K localized integer，其餘 native compact notation 至多 1 位小數，遵守 locale（例如英文 K／M／B、繁中萬）；metric VoiceOver 為 full integer |
| source date | 使用驗證後 YYYY-MM-DD 原字串，不建立 Date／timezone／relative-day labels |
| capture | static localized Fetched／擷取時間，僅表示 QuotaMew capture；不加 timer |
| state | disabled／idle／loading／available／no reported buckets／unsupported／unavailable／failed 各有純 presentation mapping，不顯示 raw error、method ID 或 provider metadata；failure 不保留舊數值 |
| keyboard | native period selector、Refresh button／Command-R；逐日與 help disclosure 可用鍵盤；實際閱讀順序仍需人工 VoiceOver |
| theme／size | 系統 semantic styles；根視圖和 NSWindow 同一 minimum；ScrollView 容納窄高視窗內容 |

String Catalog 補齊英文與臺灣繁體中文，7D／30D 保留語言中立標籤。About these values 清楚說明 provider counters 可能不是精確帳務／訂閱額度，來源日期不一定是本機今天，history 可能不完整。Synthetic previews 包含 disabled、Latest zero、7D zero/missing、30D complete、繁中 dark/minimum width、unsupported、failed，所有 preview source 均為記憶體合成資料，不建立 provider 或 persistence。

### 人工驗收結果

**M4 MANUAL ACCEPTANCE COMPLETE** — 以下結果由使用者完成並回報；此紀錄不由自動 rendering、constraints 或 keyboard checks 推導。

- [x] 7D 一般寬度：PASS。
- [x] 30D 一般寬度：PASS。
- [x] 30D 最小寬度：PASS。
- [x] 30D 加寬視窗：PASS。
- [x] Light Mode、Dark Mode、繁體中文與 English：PASS。
- [x] VoiceOver 逐日資料點導覽：PASS。
- [x] x 軸標籤不再重疊；30D 保留全部每日資料點，同時只顯示疏朗、易讀的刻度。
- [x] y 軸不再使用科學記號。
- [x] explicit zero 與 missing-data 語意仍可區分。
- [x] Account Activity 開啟、重新開啟、重新整理與停用行為維持正確。

M4 只交付此 presentation milestone；未加入 persistent history、成本／價格、model/thread/project analytics、burn rate／runway、widgets、notifications、background activity polling、其他 providers 或 Reset Intelligence。ROADMAP、README、公眾 Fumadocs、release notes、RC.2 version/build/tag/release records 不改動。

### 自動驗證紀錄（2026-10-02）

起始 `main` HEAD = `6b9b02dda5f89342e75629a59188fe5a4d3e3858`，`origin/main` = `3a63921fced7ed7fd68b4ddbc9c5b09e8c97be95`（`v0.2.0-rc.2`），乾淨 worktree、ahead 6。M4 僅建立本機 Conventional Commit，不 push／tag／release，也不修改 RC.2 metadata。

| Gate | 實際結果／證據範圍 |
| --- | --- |
| 定向 regressions | **174 passed／0 failed／2 expected opt-in skips**；ActivityProjection／ActivityModel／service／store／consent、SettingsStore／SettingsIntegration、presentation／window、StatusItem、Codex adapter／transport／quota provider |
| 新增 deterministic cases | **18 passed**：presentation／formatter 7 + window／settings／native layout／Command-R／rapid re-enable 11；原 StatusItem tests 同步擴充 action／ordering assertions |
| M0／M1／M2／M3 regression | full parallel suite 全部通過；projection／domain、malformed／privacy、multi-method transport、disable／coalescing／late completion 均維持 |
| 完整平行 XCTest | **433 passed／0 failed／6 expected opt-in skips**（439 total）；live gates 後續獨立明確啟用，沒有把 skip 當 PASS |
| 原生 host／layout | English + zh-Hant、Light + Dark、Latest／7D／30D、420／560／760 widths 可 host/layout；minimum 420×460、close/reopen、toolbar 存在、Command-R key equivalent 實際到 shared model/source。不是人工畫面品質／VoiceOver PASS |
| Clean Debug／Release | 兩個隔離 DerivedData 的 clean build 均 **BUILD SUCCEEDED**；version/build/project metadata 不改動 |
| Sanitized Live M4 window | **1 passed／0 skipped**；隔離 Settings domain、production Runtime／shared client／service／model／native window；disabled open／enable 不啟動 runtime，明確 quota demand 建立共用 transport 後 enabled/idle open 擷取成功 |
| Live Activity coverage | **56 buckets、7D 7／7、30D 30／30**；Latest 與 snapshot 最新 source bucket 相符，native hosting 逐一呈現 Latest／7D／30D，coverage 與 points reconcile；不輸出真實 token 值 |
| Live reopen／manual／disable | available close/reopen 保留當次 projection；manual refresh 成功；disable 清 model／store，disabled refresh/open 不進活動 request queue；settings persistent domain 除 consent 外維持相同。另以 deterministic fixture 證明 rapid disable/re-enable 後新的 idle open 不被尚未完成的舊 window waiter 阻擋 |
| Shared client／cleanup | quota → activity → quota 共用 **1 child／1 stdout reader**；同 client quota afterward PASS；service／client shutdown 後 PID 存在性確認已 reap、reader = **0** |
| 獨立 Live Codex quota afterward | **1 passed／0 skipped**，在活動 gate 後另行執行既有 live provider case；未更動 quota mapping／refresh policy |
| 零 automatic activity I/O | Runtime construction、Dashboard／Settings 建構與 Settings 系統／diagnostics refresh、enable 均未啟動 app-server／排入活動 queue；既有 production fake transport startup/coalescing tests 維持通過；quota scheduler source 未接任何 activity action |
| persistence／privacy | default false、唯一 consent Bool、restart = enabled/idle 且 store 空、memory-only、failure/disable 清舊值、late completion 不復活；source/model/privacy regressions 通過；UI／AX 只用 normalized dates/counts 與 static/sanitized copy，diagnostics／logs 不加入活動數值 |
| `git diff --check` | PASS |
| 人工 visual／VoiceOver | **M4 MANUAL ACCEPTANCE COMPLETE**；7D／30D 一般與最小／加寬視窗、Light／Dark、繁中／English、VoiceOver 逐日導覽、軸標籤／刻度／科學記號、zero／missing 語意及 Account Activity 開啟／重開／刷新／停用均 PASS。沒有效能 soak、通知送達、Developer ID／notarization／distribution 驗證 |

最終 gate logs 保留在隔離暫存路徑：`/tmp/QuotaMew-M4-regression.log`、`/tmp/QuotaMew-M4-full-verified.log`、`/tmp/QuotaMew-M4-clean-debug.log`、`/tmp/QuotaMew-M4-clean-release.log`、`/tmp/QuotaMew-M4-live-activity.log`、`/tmp/QuotaMew-M4-live-quota.log`。Live 只列 bucket／coverage counts 與 PASS flags；這些暫存檔案不 commit，不是 activity history persistence。初次測試抓到 native hosting minimum 設定順序與 fixture yield 等待競態，均修正並以最終全 suite 零失敗確認。

**M4 COMPLETE — MANUAL ACCEPTANCE COMPLETE; READY FOR v0.3 M5**

## M5 reliability／privacy／resource checkpoint（2026-10-03）

本 checkpoint 僅涵蓋 v0.3 feature hardening；不是 v0.3 發行、signing／notarization／distribution 驗證，也不開始 M6。M4 人工外觀／VoiceOver 驗收維持上方獨立紀錄；M5 自動 smoke 不取代人工驗收。

### 發現與最小修正

**HIGH — quota-only reconnect 可能保留不可信的舊 Account Activity。** 原本 Activity 清除依賴明確 Activity refresh／disable，quota 自己造成斷線與 replacement 時沒有進入 Activity generation／memory clearing。現在共享 client 在 reader EOF、壞 framing、timeout／active cancellation、stale replacement 與 shutdown 經單一 callback 失效 Activity；runtime 以弱參照綁定共用 model，沿用既有 model／service／store invalidate。這刻意改變 connection continuity 中斷時的 Activity 顯示清除政策，不更動 quota mapping、Remaining／Used、Luna Reserve、cadence／backoff、stale threshold、reset detection、notification 或 pin semantics。

Connection generation 為不含身分、不持久化的 UInt64；短暫 connection UUID 排除舊 reader callback。單一 continuity barrier 等待 model／store 清除後才釋放 active slot／啟動後續 RPC；舊 child reaped 才可建立 replacement。Barrier 不串成 task chain、不要求 Activity 擷取，ActivityService 仍不擁有 client shutdown。Idle EOF 與 quota-only reconnect 都有 production-style runtime 回歸；明確 gate 證明 clearing 未完成時 replacement RPC 不開始。

### 可靠性、隱私與 I/O

| 項目 | 最終證據 |
| --- | --- |
| 共用所有權 | Production makeRuntime 只有 1 Codex client、ActivityModel／service／store；quota／Activity source 共用 client。實際 Release 結構檢查各只有 1，status item／window controller 各 1 |
| Active RPC／quota 優先 | max active 1；5 輪 active Activity 25 callers＋waiting quota 32＋waiting Activity 32（取消 16），quota 下一個先執行、各 queues 最終 0；Activity timeout 維持 2 秒 |
| Failure／recovery | success→method-not-found→success→timeout→success→malformed→success→oversized→success→EOF→success→cancel→success；各次 fixture 允許的 quota 均成功。Quota failure 後 Activity 不自行 reconnect，quota 恢復後 Activity 成功 |
| Disable／refresh／window | 100 enable／disable（含 late completion）清 model／store、disabled refresh 零 I/O；100 快速 callers 合併 1 acquisition、callers 100→0，既有取消 waiter 不污染共享工作；100 controller＋100 native window 循環，reopen 不擷取、舊 window／host 弱參照全 0 |
| Relaunch | 隔離 Settings domain、synthetic snapshot、shutdown、重建 runtime-like store／service／model；consent true，enabled／idle、snapshot 空、source reads 0 |
| Persistence inventory | 唯一 Activity app-managed persisted state：嚴格 Bool activity.codex.account.enabled。UserDefaults／SettingsStore、file／Codable writes、SQLite／SwiftData／Core Data／CloudKit、logs／diagnostics／pasteboard／state restoration 均無 Activity values／dates／snapshot／capturedAt／coverage／identity writes；quota notification state 獨立 |
| Error privacy | Secret-bearing transport→source→service→model 測試僅得到 typed failed.fetchFailed，舊 snapshot 清除；UI／AX 共用 presentation、diagnostics／settings 無 email／account／thread／session／workspace／repo／prompt／raw payload sentinels；quota afterward 成功 |
| Layered bounds | 1,048,576-byte valid envelope 接受、1,048,577 拒絕且 quota 恢復；366 buckets 在 dedup 前檢查；Latest／7D／30D projections 有界；未知 future 欄位忽略、不保留 raw response |
| Startup zero I/O | Runtime／Dashboard／Settings construction、Settings system／diagnostics refresh、consent enable、背景 quota refresh 均 0 Activity I/O；enabled／idle window 首次明確開啟只有 1 coalesced acquisition。無 Activity timer／polling |

### Release 資源量測

使用本機 macOS／arm64、Release optimization，所有壓力均合成來源。Native scaffold 使用正常 AppKit run loop，複製 app／project 到暫存目錄並只替換複製本 entry point，使用獨立 bundle ID／Settings domain，再由 LaunchServices 開啟；不修改 production entry point／project，也不呼叫 provider。可重現入口為 scripts/profile-m5-activity.sh，fixture 為 scripts/fixtures/M5NativeResourceHarness.swift；以 /bin/bash 執行即可。CPU 為 2 秒 getrusage／ContinuousClock sample，RSS 為 proc_pidinfo resident bytes；以下 MB 採十進位。

| 情境 | 實際量測／判讀 |
| --- | --- |
| Synthetic idle | RSS 33.5 MB、CPU 0.09%、FD 3、threads 8、children 0 |
| Existing snapshot window | RSS 84.5 MB、CPU 0.52%、FD 3、threads 11、children 0 |
| 100 native close／reopen | 第 25／50／75／100 次 RSS 99.75／100.50／100.58／100.42 MB；每批舊 windows／hosts = 0，FD 3，threads 最後穩定 16。無持續單調成長 |
| Closed／100 refresh | 關閉後 2 秒 CPU 1.04%（短暫 framework／animation 影響，不當成長期 idle）；settled RSS 96.11 MB，第 25／50／75／100 refresh 均同值，FD 3、threads 15、children 0；總 reads 101、reopen reads 0 |
| 100 failure／reconnect | Release optimized XCTest＋DEBUG counters／ENABLE_TESTABILITY：baseline 86.8 MB、FD 6／threads 6／children 0；25→100 RSS 114.44→114.74 MB、FD 10／threads 10–11、child／reader 1；100 舊 PIDs 均 reaped、無 overlap；teardown FD 6、threads 10、child／reader 0 |

Hosted XCTest 曾在 main-thread autorelease pool 保留 99 個 native windows，造成 RSS 持續增加。Content-disabled heap reference graph 證明保留根在測試宿主；所有試驗性 production window 修改已撤回，正常 AppKit run loop 量測釋放全部 window／host 並達平台期。未將 allocator caching 或宿主保留誤報成產品洩漏。以上是 bounded regression detection，不是長期 production soak 或整體 idle <50 MB 保證。

### Gates 與驗證邊界

| Gate | 結果 |
| --- | --- |
| Targeted suites | 11 個既有 transport／provider／store／service／projection／model／window／consent／status suites：133 passed／0 failed／3 expected opt-in skips（136 total）；context menu 在 StatusItemControllerTests |
| Full parallel XCTest | 4 workers：448 passed／0 failed／7 expected opt-in skips（455 total）；M0–M4 regressions 全綠。3 個 runtime QoS inversion warnings；無 compiler errors／Swift 6 concurrency warnings |
| Strict clean Debug／Release | 兩個隔離 DerivedData clean build PASS；code signing disabled。Shell syntax／Python fixture AST／git diff --check PASS，無新增 lint/runtime dependency 或 analyzer 配置 |
| Live shared transport | 最終明確 opt-in window gate 1 passed／0 skipped；packagedChatGPT runtime、56 buckets、7D 7/7、30D 30/30；2 次明確 Activity fetch、quota before／after PASS、同 1 child／reader；shutdown child reaped、reader 0。未輸出實際 token 值 |
| Live quota | 活動 gate 後獨立 Debug provider gate 1 passed／0 skipped、2 valid quota windows。一次 Release host 不符合既有 Debug bundle assertion，該次不計成功，修正 host 後通過 |
| Actual Release LaunchServices smoke | PASS：以 open 啟動隔離 clean Release app，Mach-O SHA256 dea9ebdd17f372d86b4fafe9caa0906a8f062e0f97ecf32f61d38375daa8efc1。同 M5 artifact 的 Dashboard AX 顯示 Codex available、兩個正常 quota windows；另次啟動由使用者從選單開啟 Codex 帳號活動，AX 顯示 disabled 說明／disabled refresh。最後程序 39731、同一 child 39734，開啟 Activity 不新增 child；content-disabled heap 結構確認 client／connection／model／service／store／window controller／Activity host／status item 各 1。Quit 後 app／child 在 5 秒 bound 內皆已 reap，恢復原安裝 app；不算 M4 人工外觀／VoiceOver 再驗收 |

初次與最終 live window gates、quota host 修正合計 4 Activity／6 explicit quota reads，另有 smoke app 既有 startup quota 行為；未用真實 backend 做 stress。實際 response limit fixture 改由 child 接收短指令後產生 1 MiB 回應，避免將巨大測試控制資料寫進 FIFO 造成測試 writer blocking；最終 edge gate PASS。首次人工開啟的是舊 M4 Release，透過程序路徑／Mach-O UUID 核對後排除；完成 smoke 的是上述 M5 clean Release artifact。

主要暫存證據：/tmp/QuotaMew-M5-complete-final.xcresult、/tmp/QuotaMew-M5-targeted-final2.xcresult、/tmp/QuotaMew-M5-boundary-final.xcresult、/tmp/QuotaMew-M5-resource-final2.xcresult、/tmp/QuotaMew-M5-native-final.log、/tmp/QuotaMew-M5-final-live-activity.xcresult、/tmp/QuotaMew-M5-final-live-quota-debug2.xcresult、/tmp/QuotaMew-M5-final-debug.log、/tmp/QuotaMew-M5-final-release.log。這些合成／sanitized 驗證紀錄不是 app-managed Activity history。

### Git、範圍與剩餘限制

起始 main HEAD = 1e93f56c00958c2eabc3088391a316633311706a，origin/main = 3a63921fced7ed7fd68b4ddbc9c5b09e8c97be95（RC.2），ahead 9；唯一本來的 dirty work 為 QuotaMew/Localizable.xcstrings。其 SHA256 = c2d67c222908e979bfece7476675d7562a099a07f96baede57df1fe1b9dfefc2，253 既有 entries 全部語意未改，僅既有新增 Reported tokens／Reported zero／Source date 與排序／序列化差異；M5 前後 hash 一致，新增 delta 0，不納入 commit。

尚無穩定且隱私安全的帳號身分訊號；失去 connection continuity 只使舊 Activity 失效，不代表已證明帳號改變，也不能保證偵測健康連線內所有外部靜默換帳號。重新顯示需要健康 connection 上的明確 Activity 擷取。Memory-only 證據限 app-managed persistence，不對 swap／OS 行為作不存在保證。Activity request 仍可占用共享 active slot 至原 2 秒 timeout；QoS warnings 保留於後續 release-readiness 審查，不藉此更動 quota scheduling。

僅本機 Conventional Commit；無 push／tag／release／版本修改，RC.2／0.2.0／build 5 不變；README／ROADMAP／Fumadocs 不改。沒有新增持久歷史、成本／價格、analytics、burn rate／runway、polling、Activity notifications、widgets、cloud、iPhone、provider、Reset Intelligence 或介面 redesign。

**V0.3 FEATURE HARDENING COMPLETE — READY FOR RELEASE-READINESS AUDIT**
