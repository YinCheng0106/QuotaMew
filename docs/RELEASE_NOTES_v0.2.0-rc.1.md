# QuotaMew v0.2.0 RC.1

QuotaMew v0.2.0 RC.1 is the first release candidate for v0.2.0. Feature development for v0.2.0 is complete; this candidate focuses on final release validation and stability.

## Product experience carried into RC.1

- Native macOS menu bar experience with an AppKit status-item shell.
- Codex quota monitoring with semantic **5-hour** and **Weekly** windows.
- **Remaining / Used** presentation in **Single / Overview** menu-bar modes.
- Provider pinning and conservative **Luna Reserve** presentation.
- Native first-run onboarding, Settings, Launch at Login, and local notifications.
- Accessibility and English／Traditional Chinese localization improvements.
- Recovery lifecycle improvements for provider refresh and menu-bar presentation.

Claude Code remains **Experimental / Unverified**. The opt-in status-line bridge and live validation with an eligible subscribed account are not implemented.

## Validation

- The feature scope is frozen for the v0.2.0 release candidate.
- Deterministic XCTest validation passes with the two opt-in live tests skipped in the normal suite.
- Live Codex validation and live system notification validation have completed successfully.
- No known release-blocking correctness issue remains in the audited candidate baseline.

## Distribution limitations

The RC.1 DMG is Apple Development signed. It is not Developer ID signed, notarized, or stapled with a notarization ticket. Gatekeeper may require supported manual approval through **System Settings → Privacy & Security → Open Anyway** on first launch.

Reset Intelligence remains deferred to v0.3. Automatic updates, cloud sync, usage history, and iOS support are not included.

## 繁體中文

QuotaMew v0.2.0 RC.1 是 v0.2.0 的第一個 release candidate。v0.2.0 功能開發已完成；本候選版專注於最終發行驗證與穩定性。

### RC.1 延續的產品體驗

- 使用 AppKit status-item shell 的原生 macOS 選單列體驗。
- Codex 額度監控，以及語意化的「5 小時／每週」視窗。
- 「剩餘／已使用」呈現，支援「單一／總覽」選單列模式。
- Provider 固定與保守的 Luna Reserve 呈現。
- 原生首次啟動 Onboarding、設定、登入時啟動與本機通知。
- 無障礙與英文／繁體中文在地化改善。
- Provider 刷新與選單列呈現的生命週期復原改善。

Claude Code 仍為 **Experimental / Unverified**；opt-in status-line bridge 與符合資格之真實訂閱帳號驗證尚未實作。

### 驗證

- v0.2.0 功能範圍已為 release candidate 凍結。
- Deterministic XCTest 通過；正常 suite 跳過 2 個 opt-in live tests。
- Live Codex 與 live system notification 驗證均已成功完成。
- 已稽核的候選版基線沒有已知的 release-blocking correctness issue。

### 散布限制

RC.1 DMG 使用 Apple Development 簽章，尚未使用 Developer ID 簽署、公證，也沒有 stapled notarization ticket。第一次啟動若 Gatekeeper 要求核准，請使用「系統設定 → 隱私權與安全性 → 仍要打開」。

Reset Intelligence 延至 v0.3；未包含自動更新、雲端同步、用量歷史或 iOS App。
