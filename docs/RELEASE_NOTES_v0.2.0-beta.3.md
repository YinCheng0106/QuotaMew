# QuotaMew v0.2.0 Beta 3

QuotaMew v0.2.0 Beta 3 is a stabilization and UX beta focused on making quota state easier to understand directly from the macOS menu bar, while improving first-run setup and lifecycle polish.

## Highlights

### Configurable Menu Bar quota display

Choose **Single** or **Overview** mode. Single can show **5-hour**, **Weekly**, or **Luna Reserve**. Overview shows both regular windows together, such as `5H 86% · W 71%`; Luna Reserve appears only under the existing conservative prominence rules.

### Clearer quota naming

Quota windows consistently use **5-hour** and **Weekly** names instead of ambiguous primary/secondary labels.

### First-run Onboarding

The native onboarding flow introduces provider status, privacy boundaries, Remaining / Used presentation, provider pinning, Launch at Login, and optional notifications. Notification permission is requested only after an explicit user action.

### Native Menu Bar improvements

The status item now provides a native right-click menu with **Refresh Now**, **Settings…**, and **Quit QuotaMew**, alongside improved intrinsic-width presentation and VoiceOver semantics.

### Luna Reserve

QuotaMew detects and presents the reserve quota bucket conservatively when the existing trusted presentation rules allow it. This presentation does not claim that QuotaMew can determine whether Codex is actively routing work through Luna Reserve.

## Known limitations

- Claude Code remains **Experimental / Unverified**; the opt-in status-line bridge and live subscribed-account validation are not implemented.
- Reset Intelligence remains planned for v0.3; this beta does not add an event feed, external reset notifications, analytics, telemetry, or new networking.
- The distributed DMG is not Developer ID signed or notarized. On first launch, use macOS **System Settings → Privacy & Security → Open Anyway** if macOS requests approval.
- Automatic updates, cloud sync, usage history, and iOS support are not included.

## 繁體中文

QuotaMew v0.2.0 Beta 3 是一次穩定性與 UX beta，重點是讓使用者能直接從 macOS 選單列理解額度狀態，並改善首次啟動與生命週期體驗。

### 亮點

- **可設定的選單列額度顯示**：可選擇 Single 或 Overview；Single 可顯示 5 小時、每週或 Luna Reserve，Overview 可顯示 `5H 86% · W 71%`，Reserve 仍遵守既有保守顯示規則。
- **更清楚的額度命名**：統一使用「5 小時」與「每週」，不再使用容易混淆的主要／次要週期名稱。
- **首次啟動 Onboarding**：介紹 provider 狀態、隱私邊界、剩餘／已使用、provider 固定、登入時啟動與選用通知；只有使用者明確操作後才會要求通知權限。
- **原生選單列改善**：右鍵提供「立即重新整理」、「設定…」與「退出 QuotaMew」，並改善 intrinsic width 與 VoiceOver 語意。
- **Luna Reserve**：在既有可信的顯示條件成立時，以保守方式偵測並呈現 reserve quota bucket；不宣稱能判定 Codex 是否正主動透過 Luna Reserve 路由工作。

### 已知限制

- Claude Code 仍為 **Experimental / Unverified**；opt-in status-line bridge 與即時訂閱帳號驗證尚未實作。
- Reset Intelligence 仍屬 v0.3；本 beta 不新增 event feed、外部重設通知、分析、telemetry 或新網路功能。
- 發行 DMG 尚未使用 Developer ID 簽署或公證；首次啟動若 macOS 要求核准，請使用「系統設定 → 隱私權與安全性 → 仍要打開」。
- 尚未提供自動更新、雲端同步、用量歷史或 iOS App。
