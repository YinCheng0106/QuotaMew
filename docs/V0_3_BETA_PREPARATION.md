# v0.3.0-beta.1 內部準備與驗收紀錄

2026-10-04；Stage 2 source metadata preparation。Beta 尚未發佈，候選 DMG
與 live release manifest 尚未產生。Stage 3 才開始候選產物準備。

## 已確認的發行身分

| 用途 | 決策 |
| --- | --- |
| GitHub tag | `v0.3.0-beta.1`（尚未建立） |
| Manifest version / channel | `0.3.0-beta.1` / `preview` |
| App MARKETING_VERSION / CFBundleShortVersionString | `0.3.0` |
| App CURRENT_PROJECT_VERSION / CFBundleVersion | `6` |
| Minimum macOS | `14.0` |
| Candidate artifact | `QuotaMew-v0.3.0-beta.1.dmg` |
| Manifest asset | `quotamew-release-manifest.json` |
| Signing | Apple Development；必須 codesign 驗證成功 |
| Developer ID / notarization / stapling | 本 beta 不使用／不執行；不改憑證、profile 或 signing infrastructure |

App Debug／Release 使用 `GENERATE_INFOPLIST_FILE = YES`，由 project settings
產生版本值，沒有另一份手寫 Info.plist。Test target 自有 `0.1.1 (1)` 不是
App 對外版本，不隨此次發行改動。Prerelease 字尾只存在 tag、manifest version
與 artifact filename；generator 強制 packaged app version 等於 tag core。

Apple 要求 [CFBundleShortVersionString](https://developer.apple.com/documentation/bundleresources/information-property-list/cfbundleshortversionstring)
為三段數字；[CFBundleVersion](https://developer.apple.com/documentation/bundleresources/information-property-list/cfbundleversion)
允許單一整數，並要求 macOS 新散布 build 遞增。本專案收斂為正整數 build。

## Build 歷史與後續順序

Git tags 的 app project settings：

| 歷史身分 | App core | Build |
| --- | --- | --- |
| `v0.2.0-beta.1`（QuotaPulse） | `0.2.0` | 1 |
| `v0.2.0-beta.2` | `0.2.0` | 2 |
| `v0.2.0-beta.3` | `0.2.0` | 3 |
| `v0.2.0-rc.1` | `0.2.0` | 4 |
| `v0.2.0-rc.2` | `0.2.0` | 5 |
| `v0.2.0` | `0.2.0` | 5（promote 相同 RC.2 commit／產物） |

歷史文件 `V0_2_PLAN.md` 的 release policy 同樣把 beta 字尾留在 tag／DMG，
而非 App version；其中舊版狀態文字是歷史紀錄，不是現在的 Stable 狀態。
Stable tag 與 RC.2 指向 `3a63921`；GitHub v0.2.0 release body 明確記錄不重建
promotion。此次有新的 v0.3 runtime，不能重用 build 5，故採下一個整數 **6**。

從本 beta 起，每個新散布 build 都使用大於先前所有散布 build 的整數，跨
marketing version、beta、RC、Stable 都不重設。未來 beta.2／RC／Stable 的新
build 依當時最大已用值遞增；不預先保留或提交假設數字。若只提升完全相同的
已驗證產物為 Stable，可沿用其 build，但不得改包或以較低 build 重建。

## Distribution 與 GitHub 政策

沿用 v0.2.0 的 Apple Development、codesign verified、未公證、未 staple
模型；初次啟動可能需「系統設定 → 隱私權與安全性 → 仍要打開」。Developer ID、
Hardened Runtime、公證及現代化散布驗證是另外的未來發行工作，不能藉此次 beta
偷偷導入。[Apple notarization workflow](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
與本專案 [manifest gate](RELEASE_MANIFEST.md) 保持分開的證據要求。

現有 repository 僅有 packaging script，沒有 draft-based upload CI；此次採
**候選最終驗收與明確發佈授權後才建立 Release**，不先建立 draft。
未來 Release 必須 `tag=v0.3.0-beta.1`、`prerelease=true`，在同一筆 prerelease
上傳唯一 `QuotaMew-v0.3.0-beta.1.dmg` 與唯一 `quotamew-release-manifest.json`。
不得只上傳 DMG。Tag／Release／push 均不屬 Stage 2。

## Public notes 與功能邊界

公開草稿存在既有 [CHANGELOG.md](../CHANGELOG.md) 的 `Unreleased` 區段。
未來 Release body 可直接取該 heading 後至 `0.2.0-rc.2` heading 前的內容；
只有最終驗收後才把「planned／pending」句子改成真實發佈狀態。
不建立另一套 changelog，不更改網站 Stable 文案。

與 Stable v0.2.0 的主要差異是 **Codex Account Activity／Codex 帳號活動**：
opt-in、Latest／7D／30D、每日 **provider-reported token activity／來源回報
Token 活動**、reported／zero／missing、coverage、手動 Refresh／Command-R、
獨立視窗。它與 quota monitor 分開，不代表帳務、費用、訂閱或額度消耗。
只保存 Activity consent；快照 memory-only，不新增 account/email tracking。
沒有 Reset Intelligence 或新的 Claude 整合發行承諾。

## 內部已知事項

- **帳號切換**：同一健康 app-server connection 仍存活的 silent switch 可能
  暫時留下先前快照。公開 notes 必須保留切換後手動 Refresh 的建議；不得
  宣稱完整帳號隔離或自動偵測全部切換。
- **QoS observation（internal-only）**：2026-10-03 readiness audit 記錄 synthetic
  transport cleanup tests 的 User-initiated waiting on Utility 警告；尚未展示
  UI、quota latency 或 shutdown 的使用者影響。此為先前 audit evidence，Stage 2
  不新增 runtime 修補、不宣稱已解決；Stage 3 重查並分類實際影響，不放公開 notes。
- **Source dates**：時區、完整性、retention 未完整公開；不用 Today 命名最近來源日期，
  不以缺少日期補零、不宣稱 7D／30D 永遠完整。
- **History**：單份 current fetched snapshot，重新擷取整份替換，沒有永久本機歷史。
- **Distribution**：Apple Development 不是 Developer ID／notarized distribution；
  codesign pass 不代表 Gatekeeper、下載隔離、通知或 Login Item 人工驗收通過。

## Stage 1 可攜性審查

已審查完整 `5587b7e6a0ee34defa5d7108af198f9301572184` 四個檔案。
Generator 僅 Python 標準函式庫及 macOS 系統工具；沒有使用者名稱、機器、固定
私人暫存路徑或兄弟 checkout 依賴。測試中的 `/Users/`、`/tmp/` 字串是 privacy
拒絕斷言，不是路徑存取。暫存位置由 tempfile 建立。
Normal deterministic tests 包含最小 app-side v1 contract expectation；website
parser cross-check 只有明確提供 `QUOTAMEW_WEBSITE_REPO` 時執行，否則 skip，
Bun 也僅 optional harness 需要。文件 `/path/to/…` 是 invocation placeholder。
不需要 Stage 1 修正，也沒有複製整套網站實作。

## Stage 3 必要候選驗證（全部待執行）

- [ ] 記錄乾淨 candidate commit；從該 commit clean Release build，重查 `0.3.0 (6)`、
  `dev.quotapulse.app`、macOS `14.0` 與 Apple Development signature。
- [ ] 將確定的 app 放入 `release/v0.3.0-beta.1/QuotaMew.app`，才執行既有 packaging
  script；檢查最終 DMG 唯一 app、Applications shortcut、version/build、codesign、
  Apple trust anchor、無有效 staple 及 SHA256。不得將 Stage 2 metadata build 當已驗收 DMG。
- [ ] 對最終 exact DMG 執行 generator dry-run，再產生固定名稱 manifest；確認
  build 6、preview、apple-development／verified true／notarized false／stapled false，
  determinism 與 clean detach；之後不改 app 或 DMG bytes。
- [ ] 執行 candidate deterministic gates 與 opt-in live quota／Activity gates；保留
  skip 與實際執行結果的區別。重查 QoS observation，若有實際影響則停止／重新分類。
- [ ] 人工驗收 exact installed candidate：opt-in/off、Latest／7D／30D、coverage、
  reported zero／missing、Refresh／Command-R、切換帳號後 Refresh、connection recovery、
  window close/reopen、light/dark、窄寬度、keyboard 與英／繁中 VoiceOver；記錄 quota regression。
- [ ] 下載／隔離與乾淨使用者 first-launch approval、通知送達、Launch at Login、
  child/pipe cleanup 與 Release idle/resource trend 分別記錄；不能由 unit tests 推論。
- [ ] 最終 diff、版本／signing／privacy、公開 notes、known limitations 與 artifact
  hashes 驗收；使用者明確授權後才 tag／push／建立 prerelease／上傳兩份資產。
- [ ] 發佈後核對 GitHub downloadable assets 的 size／SHA256、manifest 與 tag commit。

## 網站交接（發佈後，Stage 2 不觸發）

發布 beta 後網站 release-sync 預期保留 Stable `v0.2.0`，選取 Preview
`v0.3.0-beta.1`，從同筆 prerelease 的 DMG／manifest 合併 metadata，建立
Preview snapshot **review PR**。不自動 merge／deploy；不修改或啟動網站 workflow。

## Stage 2 驗證結果

- 起始 `main` / HEAD `5587b7e6a0ee34defa5d7108af198f9301572184`，
  `origin/main=4e0b2c50931b6904ed66c64641279cf7256ac95d`；乾淨、ahead 1／behind 0。
- 明確移除 website/Bun 環境變數後跑 `python3 -m unittest discover -s script/tests -v`：
  Stage 1 release-tool tests 14 passed／1 optional website cross-check skipped；
  Stage 2 version policy tests 4 passed。正常測試不讀網站 repository。
- Debug XCTest：`BrandingRegressionTests` 3 passed，
  `StatusItemControllerTests.testControllerCreatesOneStatusItemAndUsesIdentityScopedAutosaveName`
  1 passed；涵蓋 Debug／Release bundle ID、兩個 stable autosave names 及歷史 Beta 1 品牌。
- 隔離 DerivedData 的 `xcodebuild ... -configuration Release ... clean build` 成功。
  Built Release Info.plist 實讀 `CFBundleShortVersionString=0.3.0`、`CFBundleVersion=6`、
  `CFBundleIdentifier=dev.quotapulse.app`、`LSMinimumSystemVersion=14.0`；
  built Debug 也確認 `0.3.0 (6)` 與 `dev.quotapulse.development.app`。
- Release app `codesign --verify --deep --strict` 與 Apple generic trust anchor
  驗證通過；leaf category 是 Apple Development（不記錄個人憑證名稱）。
  唯讀 `stapler validate` exit 65：無有效 ticket；未執行 notarization／stapling，
  符合選定 distribution policy，不把 exit 65 單獨當作未公證證明。
- Build／test 唯一 warning 是未依賴 AppIntents.framework 的 metadata extraction
  skipped；無 compiler/linker error。未重跑 full 455-test suite、live provider、UI、
  Gatekeeper 或效能量測；沒有 runtime source change。
- 完整 Stage 2 diff review 與 `git diff --check` 通過。變更僅 project version/build、
  focused release tests、Unreleased 公開草稿及內部 release policy 文件；沒有祕密、
  quota／Activity runtime／UI／localization／signing infrastructure 變更。
- 沒有產生 beta DMG／live manifest、建立 tag／draft／Release、push、修改或觸發網站。
  網站 checkout 的 HEAD 與乾淨狀態維持不變。
