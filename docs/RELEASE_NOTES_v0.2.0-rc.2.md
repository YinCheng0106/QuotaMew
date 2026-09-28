# QuotaMew v0.2.0 RC.2

QuotaMew v0.2.0 RC.2 restores Codex quota detection on recent ChatGPT Desktop releases after a change to the bundled Codex CLI packaging layout. It supports the new packaged runtime while retaining compatibility with the previous bundled runtime, legacy Codex.app installations, and supported standalone CLI fallbacks.

The existing Codex app-server quota protocol remains unchanged; this release does not change quota semantics.

## Distribution limitations

The RC.2 DMG is Apple Development signed. It is not Developer ID signed, notarized, or stapled with a notarization ticket. Gatekeeper may require supported manual approval through **System Settings → Privacy & Security → Open Anyway** on first launch.

Claude Code remains **Experimental / Unverified**. Reset Intelligence remains deferred to v0.3. RC.2 is a release candidate, not stable v0.2.0.

## 繁體中文

QuotaMew v0.2.0 RC.2 修復近期 ChatGPT Desktop 更改內附 Codex CLI 封裝配置後的 Codex 額度偵測。此版本支援新的 packaged runtime，同時保留對先前內附 runtime、舊版 Codex.app 安裝方式，以及支援的獨立 CLI 備援路徑的相容性。

既有 Codex app-server 額度協定維持不變；本次不更動額度語意。

### 散布限制

RC.2 DMG 使用 Apple Development 簽章，尚未使用 Developer ID 簽署、公證，也沒有 stapled notarization ticket。第一次啟動若 Gatekeeper 要求核准，請使用「系統設定 → 隱私權與安全性 → 仍要打開」。

Claude Code 仍為 **Experimental / Unverified**；Reset Intelligence 延至 v0.3。RC.2 是 release candidate，並非穩定版 v0.2.0。
