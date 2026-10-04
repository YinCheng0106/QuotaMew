import Foundation
import XCTest
@testable import QuotaMew

final class LocalResetDetectorTests: XCTestCase {
    private let detector = LocalResetDetector.standard
    private let start = Date(timeIntervalSince1970: 2_000_000_000)

    func testDetectsGenuineFiveHourResetTransition() {
        let oldReset = start.addingTimeInterval(60 * 60)
        let before = state(
            providerID: .codex,
            windowID: "five-hour",
            usedPercentage: 82,
            resetAt: oldReset,
            capturedAt: start,
            duration: .seconds(5 * 60 * 60)
        )
        let baseline = detector.evaluate(
            [before], state: LocalResetDetectionState(), now: start
        )
        let afterCapture = oldReset.addingTimeInterval(60)
        let after = state(
            providerID: .codex,
            windowID: "five-hour",
            usedPercentage: 1,
            resetAt: oldReset.addingTimeInterval(5 * 60 * 60),
            capturedAt: afterCapture,
            duration: .seconds(5 * 60 * 60)
        )

        let evaluation = detector.evaluate([after], state: baseline.state, now: afterCapture)

        XCTAssertEqual(evaluation.resets.count, 1)
        XCTAssertEqual(evaluation.resets.first?.identity.providerID, .codex)
        XCTAssertEqual(evaluation.resets.first?.identity.windowID, "five-hour")
    }

    func testDetectsGenuineWeeklyResetTransition() {
        let oldReset = start.addingTimeInterval(60 * 60)
        let baseline = detector.evaluate(
            [state(
                providerID: .codex,
                windowID: "weekly",
                usedPercentage: 94,
                resetAt: oldReset,
                capturedAt: start,
                duration: .seconds(7 * 24 * 60 * 60)
            )],
            state: LocalResetDetectionState(),
            now: start
        )
        let afterCapture = oldReset.addingTimeInterval(30)

        let evaluation = detector.evaluate(
            [state(
                providerID: .codex,
                windowID: "weekly",
                usedPercentage: 2,
                resetAt: oldReset.addingTimeInterval(7 * 24 * 60 * 60),
                capturedAt: afterCapture,
                duration: .seconds(7 * 24 * 60 * 60)
            )],
            state: baseline.state,
            now: afterCapture
        )

        XCTAssertEqual(evaluation.resets.count, 1)
        XCTAssertEqual(evaluation.resets.first?.windowDuration, .seconds(7 * 24 * 60 * 60))
    }

    func testPercentageDecreaseWithoutNewWindowDoesNotCountAsReset() {
        let resetAt = start.addingTimeInterval(4 * 60 * 60)
        let baseline = detector.evaluate(
            [state(usedPercentage: 82, resetAt: resetAt, capturedAt: start)],
            state: LocalResetDetectionState(),
            now: start
        )
        let nextCapture = start.addingTimeInterval(15 * 60)

        let evaluation = detector.evaluate(
            [state(usedPercentage: 30, resetAt: resetAt, capturedAt: nextCapture)],
            state: baseline.state,
            now: nextCapture
        )

        XCTAssertTrue(evaluation.resets.isEmpty)
    }

    func testStaleSnapshotDoesNotTriggerOrReplaceBaseline() {
        let oldReset = start.addingTimeInterval(60 * 60)
        let baseline = detector.evaluate(
            [state(usedPercentage: 82, resetAt: oldReset, capturedAt: start)],
            state: LocalResetDetectionState(),
            now: start
        )
        let staleCapture = start.addingTimeInterval(60)
        let evaluationTime = start.addingTimeInterval(17 * 60)

        let evaluation = detector.evaluate(
            [state(
                usedPercentage: 1,
                resetAt: oldReset.addingTimeInterval(5 * 60 * 60),
                capturedAt: staleCapture
            )],
            state: baseline.state,
            now: evaluationTime
        )

        XCTAssertTrue(evaluation.resets.isEmpty)
        XCTAssertEqual(evaluation.state, baseline.state)
    }

    func testSameWindowCannotEmitTwice() throws {
        let (firstReset, firstState) = firstDetectedReset()

        let duplicate = detector.evaluate(
            [state(
                usedPercentage: 1,
                resetAt: firstReset.resetAt,
                capturedAt: firstReset.detectedAt.addingTimeInterval(60)
            )],
            state: firstState,
            now: firstReset.detectedAt.addingTimeInterval(60)
        )

        XCTAssertTrue(duplicate.resets.isEmpty)
    }

    func testNextWindowCanEmitExactlyOnceAfterIntermediateObservations() throws {
        let (firstReset, firstState) = firstDetectedReset()
        let firstResetAt = firstReset.resetAt
        var state = firstState

        for offset in [60 * 60, 2 * 60 * 60, 3 * 60 * 60, 4 * 60 * 60] {
            let capture = firstReset.detectedAt.addingTimeInterval(TimeInterval(offset))
            state = detector.evaluate(
                [self.state(
                    usedPercentage: 40,
                    resetAt: firstResetAt,
                    capturedAt: capture
                )],
                state: state,
                now: capture
            ).state
        }

        let nextCapture = firstResetAt.addingTimeInterval(30)
        let nextResetAt = firstResetAt.addingTimeInterval(5 * 60 * 60)
        let next = detector.evaluate(
            [self.state(
                usedPercentage: 0,
                resetAt: nextResetAt,
                capturedAt: nextCapture
            )],
            state: state,
            now: nextCapture
        )
        let duplicate = detector.evaluate(
            [self.state(
                usedPercentage: 0,
                resetAt: nextResetAt,
                capturedAt: nextCapture.addingTimeInterval(60)
            )],
            state: next.state,
            now: nextCapture.addingTimeInterval(60)
        )

        XCTAssertEqual(next.resets.count, 1)
        XCTAssertTrue(duplicate.resets.isEmpty)
    }

    func testClaudeContinuityUnknownCannotEnterCodexResetDetection() {
        let oldReset = start.addingTimeInterval(60 * 60)
        let baseline = detector.evaluate(
            [
                state(providerID: .codex, usedPercentage: 80, resetAt: oldReset, capturedAt: start),
                state(providerID: .claude, usedPercentage: 70, resetAt: oldReset, capturedAt: start),
            ],
            state: LocalResetDetectionState(),
            now: start
        )
        let afterCapture = oldReset.addingTimeInterval(30)
        let nextReset = oldReset.addingTimeInterval(5 * 60 * 60)

        let evaluation = detector.evaluate(
            [
                state(providerID: .codex, usedPercentage: 1, resetAt: nextReset, capturedAt: afterCapture),
                state(providerID: .claude, usedPercentage: 2, resetAt: nextReset, capturedAt: afterCapture),
            ],
            state: baseline.state,
            now: afterCapture
        )

        XCTAssertEqual(Set(evaluation.resets.map(\.identity.providerID)), [.codex])
        XCTAssertFalse(evaluation.state.entries.contains { $0.providerID == .claude })
    }

    func testTemporaryMissingResetTimestampDoesNotDestroyPriorEvidence() {
        let oldReset = start.addingTimeInterval(60 * 60)
        var baseline = detector.evaluate(
            [state(usedPercentage: 82, resetAt: oldReset, capturedAt: start)],
            state: LocalResetDetectionState(),
            now: start
        )
        let missingCapture = start.addingTimeInterval(15 * 60)
        baseline = detector.evaluate(
            [state(usedPercentage: 50, resetAt: nil, capturedAt: missingCapture)],
            state: baseline.state,
            now: missingCapture
        )
        let afterCapture = oldReset.addingTimeInterval(30)

        let evaluation = detector.evaluate(
            [state(
                usedPercentage: 1,
                resetAt: oldReset.addingTimeInterval(5 * 60 * 60),
                capturedAt: afterCapture
            )],
            state: baseline.state,
            now: afterCapture
        )

        XCTAssertEqual(evaluation.resets.count, 1)
    }

    func testLongObservationGapRebaselinesWithoutReset() {
        let oldReset = start.addingTimeInterval(60 * 60)
        let baseline = detector.evaluate(
            [state(usedPercentage: 82, resetAt: oldReset, capturedAt: start)],
            state: LocalResetDetectionState(),
            now: start
        )
        let reconnectCapture = start.addingTimeInterval(3 * 60 * 60)

        let evaluation = detector.evaluate(
            [state(
                usedPercentage: 1,
                resetAt: oldReset.addingTimeInterval(5 * 60 * 60),
                capturedAt: reconnectCapture
            )],
            state: baseline.state,
            now: reconnectCapture
        )

        XCTAssertTrue(evaluation.resets.isEmpty)
        XCTAssertEqual(evaluation.state.entries.first?.usedPercentage, 1)
    }

    func testExplicitProviderCycleChangeIsStrongResetEvidence() {
        let resetAt = start.addingTimeInterval(4 * 60 * 60)
        let baseline = detector.evaluate(
            [state(
                usedPercentage: 50,
                resetAt: resetAt,
                capturedAt: start,
                resetCycleIdentifier: "cycle-a"
            )],
            state: LocalResetDetectionState(),
            now: start
        )
        let nextCapture = start.addingTimeInterval(15 * 60)

        let evaluation = detector.evaluate(
            [state(
                usedPercentage: 49,
                resetAt: resetAt.addingTimeInterval(10 * 60),
                capturedAt: nextCapture,
                resetCycleIdentifier: "cycle-b"
            )],
            state: baseline.state,
            now: nextCapture
        )

        XCTAssertEqual(evaluation.resets.count, 1)
        XCTAssertEqual(evaluation.resets.first?.identity.cycleIdentifier, "provider:cycle-b")
    }

    func testPersistedStateRemainsBounded() {
        let states = (0..<40).map { index in
            state(
                windowID: "window-\(index)",
                usedPercentage: 50,
                resetAt: start.addingTimeInterval(5 * 60 * 60),
                capturedAt: start
            )
        }

        let evaluation = detector.evaluate(
            states,
            state: LocalResetDetectionState(),
            now: start
        )

        XCTAssertEqual(evaluation.state.entries.count, 32)
    }

    private func firstDetectedReset() -> (DetectedQuotaReset, LocalResetDetectionState) {
        let oldReset = start.addingTimeInterval(60 * 60)
        let baseline = detector.evaluate(
            [state(usedPercentage: 82, resetAt: oldReset, capturedAt: start)],
            state: LocalResetDetectionState(),
            now: start
        )
        let afterCapture = oldReset.addingTimeInterval(30)
        let evaluation = detector.evaluate(
            [state(
                usedPercentage: 1,
                resetAt: oldReset.addingTimeInterval(5 * 60 * 60),
                capturedAt: afterCapture
            )],
            state: baseline.state,
            now: afterCapture
        )
        return (evaluation.resets[0], evaluation.state)
    }

    private func state(
        providerID: ProviderID = .codex,
        windowID: String = "five-hour",
        usedPercentage: Double?,
        resetAt: Date?,
        capturedAt: Date,
        duration: Duration = .seconds(5 * 60 * 60),
        resetCycleIdentifier: String? = nil
    ) -> ProviderState {
        ProviderState(
            providerID: providerID,
            status: .available,
            snapshot: ProviderUsageSnapshot(
                providerID: providerID,
                windows: [
                    UsageWindow(
                        id: windowID,
                        label: "5-hour window",
                        usedPercentage: usedPercentage,
                        resetAt: resetAt,
                        duration: duration,
                        resetCycleIdentifier: resetCycleIdentifier
                    )
                ],
                capturedAt: capturedAt,
                source: UsageSource(
                    kind: providerID == .codex ? .codexAppServer : .claudeStatusLineSnapshot,
                    label: "Test",
                    documentationURL: nil
                )
            )
        )
    }
}
