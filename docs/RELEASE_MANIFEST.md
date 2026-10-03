# Release manifest v1：App 端產物驗證

此工具只準備 release metadata，不建置、封裝、改版本、上傳、推送、建立 tag
或 Release。Manifest 是每次候選 DMG 驗證後產生的發行資產，不是 source metadata，
不提交 live manifest。App runtime、Activity、quota、UI 與網站均不依賴此工具。

## 權威契約與相容性清單

讀取的網站契約：`YinCheng0106/quotamew-docs` commit
`7f376675dc8720a4b9277ed2b6374d33e3f16566`：

- `scripts/releases/contract.ts`：`manifestFilename`、`mergeManifest`、`githubFacts`。
- `src/lib/release-metadata.ts`：型別、平台／build／signing 驗證。
- `src/lib/semver.ts`：支援的 tag 文法，不接受 build metadata。
- `docs/release-metadata.md`：Phase 2 來源責任、Stable bootstrap 與未來流程。

以下全部是必填，沒有 optional manifest fields；所有層級的未知欄位及未知
schemaVersion 都拒絕。此為合成 fixture（build `42` 不代表下一版 build 決策）：

```json
{
  "schemaVersion": 1,
  "tag": "v0.3.0-beta.1",
  "version": "0.3.0-beta.1",
  "build": 42,
  "channel": "preview",
  "minimumMacOS": "14.0",
  "bundleID": "dev.quotapulse.app",
  "artifact": { "filename": "QuotaMew-v0.3.0-beta.1.dmg" },
  "signing": {
    "type": "apple-development",
    "codesignVerified": true,
    "notarized": false,
    "stapled": false
  }
}
```

| 檢查 | v1 規則與 App 端實作 |
| --- | --- |
| 資產名稱 | 固定 `quotamew-release-manifest.json`，最多 64 KiB |
| Schema | 整數 `1`；精確九個 root fields、單一 artifact field、四個 signing fields |
| Tag/version | tag 必須是 `v` + 完整 SemVer；version 是去掉 `v` 的完整字串 |
| SemVer | core 三個非負十進位整數，不得前導零；prerelease 是 ASCII alphanumeric/hyphen dot-separated identifiers，純數字不得前導零；不接受 `+metadata` |
| Channel | `stable` 或 `preview`；final → stable，所有合法 prerelease → preview，包括 alpha/beta/RC |
| Build | JSON 非負 safe integer ≤ 9007199254740991；不接受 Bool、字串或浮點數 |
| 平台 | minimumMacOS 字串，1–3 段十進位數字，保留 artifact 中的 `14.0` 等原始形式 |
| Bundle | 固定 `dev.quotapulse.app`，拒絕 Debug identity |
| DMG | 只有 `QuotaMew-<tag>.dmg`，取自實際輸入 basename，不重新命名 |
| Signing | enum：`unsigned`、`apple-development`、`developer-id`；其餘三欄必須 Bool；stapled 必須 notarized；unsigned 不可 claim codesignVerified/notarized |

網站 parser 可接受 unsigned 的誠實 metadata；本工具的 release gate 更嚴格，
必須 codesign 驗證成功且為可辨識的 Apple 簽章，故 unsigned/ad-hoc 不產生 manifest。
工具只驗證 identity，不需要版本排序；未來 channel 升級排序由網站的 SemVer
parser/comparator 負責，絕不使用字典序判斷新舊。

Manifest 擁有 schema、release identity、build、platform、bundle ID、filename 與
signing facts。GitHub 擁有 release URL、publishedAt、draft/prerelease、DMG
download URL、byte size 與 SHA256。Manifest 不重複後者，也不含文案、release notes、
機器資訊或時間戳。網站合併後的 snapshot 可有 optional `publishedAt`，這不表示
manifest 可有該欄。v0.2.0 的 bootstrap 例外只存在網站；不補上傳歷史 manifest。

## 版本不變量

沿用 `docs/V0_2_PLAN.md` 的既有政策：beta/RC 字尾存在 Git tag 與 DMG 名稱，
packaging script 不改 Info.plist。

- Release `vX.Y.Z[-prerelease]` → manifest version `X.Y.Z[-prerelease]`。
- 實際 `CFBundleShortVersionString` 必須等於 tag 的 core `X.Y.Z`，不含 prerelease。
- 實際 `CFBundleVersion` 必須為 canonical 非負整數字串，轉成 safe integer。
  不接受 Apple 在其他產品可使用的 dotted/suffixed build；未來變更此政策需明確
  修改工具及契約測試，不能截斷或猜測。

Apple 對 [CFBundleShortVersionString](https://developer.apple.com/documentation/bundleresources/information-property-list/cfbundleshortversionstring)
要求三段整數；網站的 release SemVer 因而與 bundle version 分別驗證，無語意衝突。
Stage 1 當時保留 source `0.2.0` / build `5`。Stage 2 已採用 app core
`0.3.0` / build `6`，完整政策與候選 gates 見
[v0.3 beta 準備紀錄](V0_3_BETA_PREPARATION.md)。這不代表 beta 已發行。

## CLI 與 exact-artifact flow

需現有開發環境的 Python 3.9+ 與 Xcode Apple CLI tools；僅使用 Python 標準函式庫，
沒有新增 app runtime 或套件依賴。

```sh
python3 script/release_manifest.py \
  --tag v0.3.0-beta.1 --channel preview \
  --dmg /path/to/QuotaMew-v0.3.0-beta.1.dmg \
  --output /path/to/quotamew-release-manifest.json

python3 script/release_manifest.py \
  --tag v0.3.0-beta.1 --channel preview \
  --dmg /path/to/QuotaMew-v0.3.0-beta.1.dmg --dry-run
```

以上路徑是未來候選範例，不宣稱 beta artifact 已存在。`--dry-run` 與 `--output`
互斥；前者仍執行全部檢查，只印出 sanitized candidate JSON，不寫檔。

1. 驗證 tag/channel/basename、候選為存在的 regular file（非 symlink）。
2. `hdiutil verify -nocache`：不寫 checksum cache xattr。唯讀 attach 加上
   `-noverify`，因為已獨立驗證，避免預設 verification cache 修改輸入。
3. 唯讀、隱藏且不自動開啟的私人暫存 mountpoint；root 必須有唯一
   `QuotaMew.app` 與指向 `/Applications` 的 shortcut。僅容許既有 packaging 的
   Finder/system metadata；其他 app/root items、nested 同名 app、symlink app 都拒絕。
   Layout traversal 限制 10000 entries。
4. 從該 app 的有界 Info.plist 讀取 `CFBundleShortVersionString`、`CFBundleVersion`、
   `CFBundleIdentifier`、`LSMinimumSystemVersion`。拒絕 symlink metadata/Contents。
5. 檢查簽章及 ticket，產生 candidate 並驗證 v1。
6. `finally` detach；一般 detach 失敗時嘗試 force detach。SIGINT/SIGTERM 會引發
   sanitized failure 並執行 cleanup；SIGKILL/系統崩潰不可能保證 cleanup。
   detach 仍失敗時不刪除掛載內容，保留 mountpoint 並失敗，需人工 detach。
7. 比對輸入檔案 device/inode/size/mtime/ctime，拒絕檢查期間被更換或修改的候選。
   所有 cleanup 成功後才允許寫 output。

每個 Apple subprocess timeout 30 秒、combined output 最多 64 KiB，有界暫存擷取，
終止/reap child process group。只讀取必要 signing coarse facts，不輸出 command
diagnostics、Authority 個人名稱、email、帳號、憑證、主機或路徑。不要在此流程
並行修改、staple 或重新封裝候選。

## Signing evidence policy

共同 gate：`codesign --verify --deep --strict`，另以 `-R=anchor apple generic`
驗證 Apple trust anchor，再從有界 `codesign --display --verbose=4` 擷取 leaf
Authority 類型。Authority 是 artifact 證據，不讀 source `CODE_SIGN_IDENTITY`，
不持久化個人憑證名稱。`spctl` 不作本工具公證證據。

App 與 DMG 都執行 `xcrun stapler validate`。exit 0 是有效 ticket；exit 65
代表無可用 ticket（可含不存在或無效），不是一般性的「未公證」證明。
其他 exit、tool timeout、缺工具或未知簽章一律失敗。

| 已驗證簽章及 ticket | 產出／失敗政策 |
| --- | --- |
| Apple Development，app/DMG 均無有效 ticket | `apple-development`、codesignVerified true、notarized false、stapled false；依 Apple notarization 的 Developer ID 前提與既有 development distribution policy |
| Apple Development 出現有效 ticket | 證據與 distribution model 不一致，失敗 |
| Developer ID Application，app 有有效 staple，DMG 有／無有效 ticket | `developer-id`、codesignVerified/notarized/stapled 全 true；manifest 的 signing/stapled 描述 packaged app，DMG ticket 另外驗證但不混用 |
| Developer ID Application，app 無有效 staple（即使 DMG 有） | 無法確定 installed app 的 notarization/stapling，失敗；先取得 release verification evidence 並為 exact app staple、重新封裝及驗證，再重跑 |
| unsigned/ad-hoc/其他 identity／codesign 失敗 | 不支援此 release gate，失敗 |

不接受手動 boolean override 或不綁定 exact artifact 的 notary receipt。未來
Developer ID unstapled 流程若需支援，必須另外定義強證據驗證，不能在 v1 猜測。
此保守政策依據 Apple 的
[notarization 前提](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
與 [ticket/stapler 工作流程](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)。
這不取代 downloaded/quarantined app、Gatekeeper 或 clean-user distribution acceptance。

## Determinism、atomicity 與驗證

固定 field ordering、兩格縮排、UTF-8、恰一個 trailing newline；無 timestamp、
machine path、username、host、email 或個人簽章 identity。保留 `minimumMacOS`
原始 artifact 值。相同 identity 與 artifact facts → byte-identical JSON。
先完整驗證，再在 output 同目錄建立 exclusive temporary file、flush/fsync、
`os.replace`，並清除 temporary file；驗證／寫入／rename 失敗保留既有 output。
Output 必須使用固定 manifest basename，不接受 output symlink。

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s script/tests -v

# Optional：用現有 Bun 直接讀取網站 parser；不寫網站，不呼叫網路。
QUOTAMEW_WEBSITE_REPO=/path/to/quotapulse-docs \
  BUN_BINARY=/path/to/bun PYTHONDONTWRITEBYTECODE=1 \
  python3 -m unittest discover -s script/tests -v
```

獨立 app-side contract 測試不依賴網站 checkout。Optional harness 直接執行
該 checkout 的 `mergeManifest`/`githubFacts`，使用生成的 beta/RC/stable/
Developer ID 合成 metadata 與合成 GitHub facts；包含 malformed/unknown fields
拒絕測試。未提供 checkout 時只 skip 該交叉測試，不影響 generator runtime。
網站 schema 升級時需刻意更新 App 端契約與測試；不得自動忽略 drift。

## 未來 release pipeline 接點

目前只有 packaging script，沒有 release-preparation/upload CI。
保留既有 `script/create-dmg.sh` 行為，以明確 invocation 作為未來必要 gate：

1. Stage 2 決定並檢查 source version/build 與 channel policy；再 clean Release build。
2. 將已驗證 app 放入 `release/v<release-version>/QuotaMew.app`。
3. 需要 Developer ID 時先簽章、公證、staple app，再 packaging；不在唯讀檢查中修補。
4. `./script/create-dmg.sh <release-version>`；如需 DMG staple，先完成它。
5. 對最終 `dist/QuotaMew-v<release-version>.dmg` 執行 generator dry-run，再生成
   `dist/quotamew-release-manifest.json`。從這一步之後不能再更改 candidate。
6. 完成獨立 candidate/distribution acceptance；未來取得發佈授權後，同一 Release
   上傳唯一 DMG 與唯一 manifest，並確認 GitHub asset SHA256。
7. 網站 Phase 2 將 GitHub facts 與 manifest 合併，在 review PR 驗證後更新
   checked-in snapshots；App 端不寫網站、不觸發部署。

本 Stage 1 不改 README、changelog、版本設定或歷史 release checklist。

## Stage 1 本機驗證紀錄（2026-10-04）

- 起始 app `main` / `origin/main` 都是
  `4e0b2c50931b6904ed66c64641279cf7256ac95d`，乾淨、ahead/behind 0/0。
- 工具測試 15 passed，含直接執行網站 v1 parser 的 optional cross-check；
  合成 future beta、RC、stable、Developer ID accepted，conflicts/unknown schema
  與欄位 rejected。合成 build `42` 不代表下一版 build。
- 既有 `BrandingRegressionTests`：3 passed。未修改 runtime，未重跑 live provider、
  全套 deterministic XCTest、UI 或效能量測。
- Clean Release build passed；唯一 warning 為沒有 AppIntents.framework 的 metadata
  extraction skipped。Built app 的產品版本 `0.2.0`、build `5`、bundle ID
  `dev.quotapulse.app`、minimum macOS `14.0`，實際 Apple Development 簽章 extractor passed。
- 既有 RC.2 DMG bytes 的 SHA256
  `6e4e11d5fb033943a38ed418415d2886771d9138a38efdddf808c29de8e66230`
  與 read-only GitHub `v0.2.0` 的唯一 DMG asset digest 相同，size 2663814。
  在 repository 外以 Stable basename 的暫存副本執行完整檢查。
- 歷史副本 `hdiutil verify`、唯讀 mount、layout、bundle metadata、codesign、
  trust anchor、stapler、detach 及網站 parser 全通過。Derived version/build/bundle/
  platform 是 `0.2.0` / `5` / `dev.quotapulse.app` / `14.0`；signing 為
  apple-development / verified true / notarized false / stapled false。
- 連續兩次生成 byte-identical；privacy scan 通過；錯誤 filename、損壞 DMG 與
  mock rename/fsync 失敗保留既有 output；測試 interruption 與 detach retry cleanup。
  真實候選 bytes SHA256 未變，沒有遺留工具 mount。
- 歷史 manifest 僅存於 repository 外測試暫存位置；沒有 live manifest 提交或上傳。
  沒有 v0.3 beta DMG、版本/build bump、push、tag、Release mutation 或網站改動。
- 下一階段：審查本機 tooling commit，決定 v0.3 release core、build number 與
  distribution policy，才開始版本準備與候選建置。
