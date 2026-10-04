# Activity Insights foundation（未發行）

2026-10-04。決策：**IMPLEMENT V1 NOW**，先純領域、測試與語意，再小幅呈現。這是 v0.3.0-beta.1 發布後的新功能開發，不是發行準備。

起點為乾淨 `main`，HEAD／origin/main／遠端 main 都是 `87485c2e1ac65c90718a091cb2e521d8443519b3`，左右差距 0／0。工作分支 `feat/activity-insights-foundation`。App metadata 保持 `MARKETING_VERSION = 0.3.0`、`CURRENT_PROJECT_VERSION = 6`；不更動 beta tag／Release、公開 release notes、網站或散布產物。

## 現行資料流與邊界稽核

```text
one CodexAppServerClient (quota first, serialized, bounded)
  -> CodexTokenActivitySource (allowlisted daily dates / nonnegative Int64)
  -> ProviderActivitySnapshot (unique sorted ActivityBucket; at most 366 raw entries)
  -> ActivityService / ActivitySnapshotStore (one current memory snapshot)
  -> ActivityProjection (Latest / source-date 7D / 30D)
     -> ActivityWindowProjection / ActivityCoverage / ActivityPresentationPoint
     -> ActivityInsights (same snapshot, pure queries)
  -> ActivityModel (@MainActor @Observable, one available state)
  -> ActivityPresentation / ActivityWindowView (English / zh-Hant, exact AX text)
```

Source 不建立 client；Activity 只重用健康 quota connection，不自行重連。Client 仍為單一 active RPC、每 method 一個 coalesced pending batch、quota priority、128 interests 上限、1 MiB line bound；Activity write 起 2 秒 timeout。Stream 失敗會 reap child／drain reader，下一次 quota demand 才重建。Connection continuity callback 清除 model／service memory，barrier 完成才放行後續 RPC；不推論帳號身分或所有外部帳號切換。

Consent 唯一保存在 SettingsStore Bool；service 在 I/O 與 publication 前檢查 consent + provider eligibility。每次 refresh 先清舊數值，generation fence 排除晚到結果。Snapshot 全份替换、不 append／merge。停用、失敗、失效、shutdown 清值；視窗關閉釋放 rendering，但可保留同一 app session 的 current snapshot。Construction、enable、period selection 與 insights expansion 都不 fetch。既有 Domain／Projection、Source、Store、Service、Consent、Model、Presentation、Window 與 transport tests 提供相應回歸點；fixtures／previews 皆使用合成資料。

## Provider 契約重新查證

**VERIFIED（本機）**：ChatGPT packaged `codex-cli 0.160.0`，非先前版本。使用該 binary 的非 experimental `app-server generate-ts`，`account/usage/read` 仍存在。Params 只有 optional `threadId`；不提供 date range、cursor、page size 或 pagination。Account 查詢不傳 threadId。

Response 為 `summary`、nullable `dailyUsageBuckets`、optional nullable `threadUsage`。每日 bucket 為 `startDate: string`／`tokens: bigint`。Summary 有 nullable `lifetimeTokens`、`peakDailyTokens`、`longestRunningTurnSec`、`currentStreakDays`、`longestStreakDays`。沒有採用更多欄位：其範圍／時間窗／streak 與日 bucket 對應不明，且不符合本功能「只從 daily buckets 衍生」的邊界。Thread usage 也不讀取、保留或推論。

**VERIFIED（bounded live）**：initialize 後一次無 params 的 account/usage/read 成功；未開 experimental API、未碰 credential file、未請求 thread。Probe 的總時間上限 12 秒、每行 1 MiB、累計 4 MiB，stderr 丟棄；finally 關閉 pipes／reap child。Raw response 僅在 probe memory 中處理，未寫檔或輸出，未輸出任何私密 token 值。

本次 metadata：57 buckets／57 unique source dates，2026-02-03…2026-10-03，跨度 243 個曆日。7D current／previous 都是 7／7；30D current 30／30、previous 26／30。日期皆合法 YYYY-MM-DD、tokens 皆非負 Int64。這是一次 observation，不是 retention／continuous history guarantee，也不代表有 57 個連續日期。

**VERIFIED（官方）**：[App Server 官方文件](https://learn.chatgpt.com/docs/app-server#7-token-usage-chatgpt) 仍稱為 ChatGPT token-activity summary／optional daily buckets，說明 nullable fields。相較既有研究，文件並未建立日期時區、日界線、零代表 inactivity、finality、固定保留長度或完整帳務語意。

**UNKNOWN**：provider bucket completeness、修訂、freshness、timezone/day boundary、跨裝置涵蓋、與 billing／API／quota 的關係。維持 provider calendar date，latest 不稱 Today。不能把 summary 名稱當成更強的產品契約。

## 候選指標與最小 V1

| 候選 | 決策與誠實名稱 | 缺日／零／稀疏歷史與算術政策 |
| --- | --- | --- |
| A 已回報總量 | 沿用 Reported total／已回報總量 | 只加已回報 buckets；完整／部分日期涵蓋分開；零加入；全缺為無資料，非 0；checked sum overflow 不出數字 |
| B 已回報日期平均 | V1 Daily reported average／每日回報平均 | 分母為 reported days，包含明確零；部分涵蓋可用但必須顯示分母與涵蓋；單日就是該日值；全缺無資料；sum overflow 為 overflow |
| C 曆日視窗平均 | 不納入 V1 | 完整時等同 B；部分／零混缺／稀疏時 sum ÷ expected days 會使未回報日期被隱含當零，應不可用；全缺無資料；完整但 sum overflow 不可用。不能靜默替代 B |
| D 前期比較 | V1 Compared with previous period／與前一期間相比 | 必須 current + previous 全部日期有回報；部分、全缺、零混缺或歷史不足均 suppress numeric comparison；完整零期仍可比較；overflow 不出 totals/delta；零基期不造百分比 |
| E 最高回報日 | V1 Highest reported day／最高回報日 | 只選已回報日，包含零；部分時不是全期間 peak；全零選最新來源日期、附 tie count；全缺無資料；sum overflow 不影響可獨立判定的最高 bucket |
| F 最低非零回報日 | 不納入 V1 | 排除零即改變所問問題；全零是「無非零回報」而非無資料；部分／稀疏不代表期間 minimum；全缺無資料。單值選擇不會 overflow，但目前沒有足够產品價值 |
| G 趨勢 | 不納入 V1 | first/second half 不等天數與缺日會偏移；rolling average 需標示每段分母，slope 對缺日／短樣本／極值敏感；完整零序列最多只能說回報值持平，不能推論行為。全缺無資料，部分／稀疏不輸出趨勢；checked half/rolling sums 與 slope 數值政策尚未定義 |
| H 已回報日期 | 沿用 Coverage／涵蓋情形 | counts 包含零、不包含缺日；全部缺為 0 個已回報日（不是活動值 0）；bounded dates 不會 count overflow。不得稱 Active days／活躍日 |

V1 僅用 7D／30D：B、D、E，加既有 A／H。Latest 不重複加平均、最高日與比較。任何需要永久歷史的跨 refresh retention、長期 rolling baseline、streak 或行為／價值分析都列為 FUTURE，沒有 persistence 實作。

## 純領域設計與缺日政策

`ActivityInsights.query(snapshot, period:)` 只接收 normalized `ProviderActivitySnapshot`，不依賴 SwiftUI、network、store、settings、clock 或 timezone。期間 enum 只允许 7／30。空 snapshot 回 `ActivityInsightsQuery.noReportedData`，不是 optional 0；無法建立合法 civil range 回 `sourceDateOutOfRange`。

Available insights 帶 current／previous 的 typed windows。每個 window 帶 source start/end、既有 `ActivityCoverage` 與 `ActivityInsightValue<Value>`：`available(value)`、`noReportedData`、`overflow`。零是 available(0)。只有前期 civil range 超出日期 domain 時 `previous` 為 nil，同時 comparison 明確為 sourceDateOutOfRange，不能以 nil 隱藏原因。

完整日期涵蓋只表示該期間每個來源日期有 bucket，**不表示 provider values 完整、最終、精確帳務或最新來源日已結束**。平均與最高日一律限定已回報集合；部分日期平均不可直接當成完整期間平均或跨期比較。

平均保存 Int64 分子與 reportedDays 分母，顯示以整數 quotient/remainder 取最接近整個 token、half 向上。分母非零且 sum 非負時，rounding 不超過 Int64.max；不使用浮點近似。

最高日保留 bucket 與 tiedReportedDays；同值時取最新來源日期。全零是合法回報集合，會有最高值 0 與 tie count；絕不說那些日期沒有使用。

## 比較政策與整數安全

本期為 `[anchor − N + 1, anchor]`，前期為 `[anchor − 2N + 1, anchor − N]`，沒有 overlap，不取前 N 筆 buckets。Anchor 是當次 snapshot 最新來源日期。

`ActivityPeriodComparison` 有 `available(change)`、`insufficientCoverage(current:previous:)`、`noReportedData`、`overflow`、`sourceDateOutOfRange`。兩期日期全回報才比較 reported totals；即使 incomplete totals 都是 0，仍不足以比較。Current 無資料為 noReportedData；previous 全缺但 current 有值時為 insufficientCoverage，保留兩期分母。

Sum 使用 checked Int64 addition。每一期独立，前期 sum overflow 不影響本期 average／highest。Delta 使用 checked subtraction；非負 Int64 endpoints 使 delta 落在 −Int64.max…Int64.max，不先加兩期 totals。

百分比是 `abs(delta) × 100 ÷ previousTotal`，以 UInt64 full-width multiply/divide 與 checked rounding 計算，避免中間乘法溢位；最接近整數、half 向上。非零但不足 1% 回 `lessThanOnePercent`，不把它顯示成持平或 0%。Rounded result 超出 Int64 為 percentage overflow，但 exact delta 仍可用。Direction 從 exact delta 判斷，中性 increased／decreased／unchanged。

前期 0／本期 0 是 unchanged；前期 0／本期 >0 為 zeroBaseline，顯示 exact change 並說明百分比不可用，不顯示無限大、100% 或假零。百分比不可用不代表 exact delta 不可用。

7D 需 14 個連續 source dates；本次 live 已足够。30D 需 60 個連續 source dates；56-day 合成案例只有 previous 26／30，本次 live 也是 26／30。30D 是條件可用，不能保證；不補歷史、不新增 requests，也不因前期不足隱藏本期指標。

既有 ActivityProjection 本期 7／30 日 sum overflow 仍會使 ActivityModel 進 failed(.invalidData)，整個畫面不留數字。新的純領域 query 額外保留各 metric overflow state，UI 可對前期或 percentage overflow 說明原因；沒有改變既有 failure policy。

## UI 與本地化設計

選 C：Coverage 下方、chart 上方加入預設收合的 Activity Insights／活動洞察 DisclosureGroup。內容垂直列出平均（含精確分母與 rounding 說明）、最高日（exact source date/value/ties）、前期來源範圍與比較／不可用原因。避免卡片 dashboard；維持 420 minimum／560 default／760 wider。窄寬度文字換行，不提高 minimum width。

文案沿用「回報／來源日期／涵蓋」；Compared with previous period／與前一期間相比、Increased／增加、Decreased／減少、Unchanged／無變化、Not enough reported dates to compare／回報日期不足，無法比較。任何增減都不是好壞；不加綠／紅語意、視覺箭頭或效率／成本評分。

每列使用完整在地化 accessibility label，包含數值、source date、denominator、兩期 coverage 或原因；不只讀 up/down。數字供 VoiceOver 使用 exact localized integers。原生 disclosure 可鍵盤展開，既有 Command-R 繼續只叫 shared model。Synthetic previews、host layout 與 AX/text tests 與真人 VoiceOver 驗收分開記錄。

## 隱私、生命週期與影響

Insights 全部從**同一份 current memory snapshot**衍生，在 ActivityProjection 發布前計算。No persistence：Activity 只保存 consent，沒有新 keys、files、SQLite、SwiftData、Core Data、CloudKit 或永久 history。沒有新 network／RPC／timer／polling／background task／identity／raw payload／prompt／repo/workspace inference。Quota、transport、consent、notification 與 refresh scheduling 完全沿用既有邊界。

## 測試設計（實作前 gate）

決定性矩陣：完整 7D、部分 7D、current 完整／previous 部分、current 部分／previous 完整、explicit zeros、mixed zero/missing、全零、空 snapshot、previous 全缺、單日、highest ties、high Int64、sum overflow、previous overflow、delta extremes、percentage overflow／zero baseline／<1%／half-up、歷史不足、56／60 dates、稀疏舊 history、leap／month／year boundaries、civil-date underflow、snapshot 全份 replacement。

後續整合 gate：新增 tests + 既有 projection／model／window／localization／privacy／transport 回歸，完整 deterministic XCTest、clean Debug／Release build、catalog validation、git diff --check。Build 關閉 String Catalog extraction 以避免 unrelated churn。Live metadata probe 與 deterministic tests 分開；不以 compile、host layout 或 AX strings 宣稱真人 VoiceOver／視覺／散布驗收。

驗證結果、focused commits 與人工驗收範圍於完成本輪後記錄；公開 release notes 不更新。
