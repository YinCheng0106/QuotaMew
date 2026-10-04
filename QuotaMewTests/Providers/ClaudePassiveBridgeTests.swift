import Foundation
import Darwin
import XCTest
@testable import QuotaMew

final class ClaudePassiveBridgeTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)
    private let valid = Data(#"{"version":"2.1.246","rate_limits":{"five_hour":{"used_percentage":12.5,"resets_at":2000003600},"seven_day":{"used_percentage":25,"resets_at":2000604800}}}"#.utf8)

    private func location() throws -> URL {
        let directory = URL(fileURLWithPath: "/private/tmp/quotamew-m2a-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("Claude/usage-v1.json")
    }

    private func sample(_ data: Data? = nil) throws -> ClaudeValidatedQuotaSample {
        try ClaudeStatusLineParser.parse(data ?? valid, observedAt: now, now: now)
    }

    private func capture(_ bytes: Data, at url: URL) -> ClaudeBridgeCaptureResult {
        ClaudePassiveBridge(writer: .init(fileURL: url)).capture(bytes, clock: { now })
    }

    func testValidMinimalEventRoundTripsExistingV1Contract() async throws {
        let url = try location()
        guard case .captured = capture(valid, at: url) else { return XCTFail("Expected capture") }
        let document = try await ClaudeSnapshotReader(fileURL: url).readSnapshot()
        XCTAssertEqual(document, try sample().snapshotDocument())
        XCTAssertEqual(document.schemaVersion, 1)
    }

    func testFullEventDiscardsEverySyntheticPrivateField() throws {
        let url = try location()
        var event = try XCTUnwrap(JSONSerialization.jsonObject(with: valid) as? [String: Any])
        let markers = ["FAKE_EMAIL@example.invalid", "FAKE_TOKEN", "/fake/transcript", "/fake/cwd",
                       "FAKE_PROMPT", "FAKE_SESSION", "FAKE_NESTED_SECRET"]
        event["email"] = markers[0]; event["token"] = markers[1]
        event["transcript_path"] = markers[2]; event["cwd"] = markers[3]
        event["prompt"] = markers[4]; event["session_id"] = markers[5]
        event["workspace"] = ["repo": ["secret": markers[6]]]
        event["cost"] = ["total_cost_usd": 123]
        event["model"] = ["id": "FAKE_MODEL"]
        event["context_window"] = ["total_input_tokens": 999]
        guard case .captured = capture(try JSONSerialization.data(withJSONObject: event), at: url) else {
            return XCTFail("Expected capture")
        }
        let output = try Data(contentsOf: url)
        let text = try XCTUnwrap(String(data: output, encoding: .utf8))
        for marker in markers + ["FAKE_MODEL", "rate_limits", "context_window", "workspace"] {
            XCTAssertFalse(text.contains(marker))
        }
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: output) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["schemaVersion", "capturedAt", "claudeCodeVersion", "rateLimits"])
    }

    func testMalformedEmptyAndInvalidUTF8NeverRefreshPreviousSnapshot() throws {
        let url = try location()
        _ = capture(valid, at: url)
        let previous = try Data(contentsOf: url)
        for bytes in [Data(), Data("{FAKE_SECRET".utf8), Data([0xff, 0xfe]),
                      Data(#"{"version":"2.1.246","rate_limits":{"five_hour":{"used_percentage":"FAKE_SECRET"}}}"#.utf8)] {
            let result = capture(bytes, at: url)
            XCTAssertEqual(result, .invalidQuota)
            XCTAssertFalse(String(reflecting: result).contains("FAKE_SECRET"))
            XCTAssertEqual(try Data(contentsOf: url), previous)
        }
    }

    func testOversizedEventRejectedBeforeDecode() throws {
        XCTAssertEqual(capture(Data(repeating: 32, count: 16_385), at: try location()), .inputTooLarge)
    }

    func testMissingNullAndEmptyLimitsDoNotReplaceOrRenewOldSnapshot() throws {
        let url = try location()
        _ = capture(valid, at: url)
        let previous = try Data(contentsOf: url)
        for suffix in ["", ",\"rate_limits\":null", ",\"rate_limits\":{}",
                       ",\"rate_limits\":{\"five_hour\":null,\"seven_day\":null}",
                       ",\"rate_limits\":{\"five_hour\":{}}"] {
            let bytes = Data(("{\"version\":\"2.1.246\"" + suffix + "}").utf8)
            XCTAssertEqual(capture(bytes, at: url), .noRateLimits)
            XCTAssertEqual(try Data(contentsOf: url), previous)
        }
    }

    func testNoLimitsDoesNotCreateSnapshot() throws {
        let url = try location()
        XCTAssertEqual(capture(Data(#"{"version":"2.1.246"}"#.utf8), at: url), .noRateLimits)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testFiveHourOnlyAndSevenDayOnlyPreserveMissingWindows() async throws {
        for name in ["five_hour", "seven_day"] {
            let url = try location()
            let data = Data(("{\"version\":\"2.1.246\",\"rate_limits\":{\"" + name
                             + "\":{\"used_percentage\":0,\"resets_at\":2000003600}}}").utf8)
            guard case .captured = capture(data, at: url) else { return XCTFail("Expected capture") }
            let document = try await ClaudeSnapshotReader(fileURL: url).readSnapshot()
            XCTAssertEqual(document.rateLimits.fiveHour == nil, name == "seven_day")
            XCTAssertEqual(document.rateLimits.sevenDay == nil, name == "five_hour")
        }
    }

    func testInvalidPercentageAndResetRejectWholeEvent() throws {
        let url = try location()
        _ = capture(valid, at: url)
        let previous = try Data(contentsOf: url)
        for fields in ["\"used_percentage\":-1", "\"used_percentage\":101", "\"used_percentage\":true",
                       "\"resets_at\":2000003600000", "\"resets_at\":-1"] {
            let event = Data(("{\"version\":\"2.1.246\",\"rate_limits\":{\"five_hour\":{" + fields + "}}}").utf8)
            XCTAssertEqual(capture(event, at: url), .invalidQuota)
            XCTAssertEqual(try Data(contentsOf: url), previous)
        }
    }

    func testExpiredResetIsPreservedAndRemainsStale() async throws {
        let url = try location()
        let bytes = Data(#"{"version":"2.1.246","rate_limits":{"five_hour":{"used_percentage":99,"resets_at":1999999999}}}"#.utf8)
        guard case .captured = capture(bytes, at: url) else { return XCTFail("Expected capture") }
        let document = try await ClaudeSnapshotReader(fileURL: url).readSnapshot()
        XCTAssertEqual(document.rateLimits.fiveHour?.usedPercentage, 99)
        XCTAssertEqual(document.rateLimits.fiveHour?.resetsAt, 1_999_999_999)
        XCTAssertTrue(try sample(bytes).isStale(at: now))
    }

    func testVersionPolicyUsesOfficialVersionFieldAndStillValidatesFutureSchema() throws {
        let url = try location()
        for (version, expected) in [("", ClaudeBridgeCaptureResult.unverifiedVersion),
                                    (",\"version\":\"FAKE_SECRET\"", .unverifiedVersion),
                                    (",\"version\":\"2.1.79\"", .unsupportedVersion)] {
            let bytes = Data(("{\"rate_limits\":{\"five_hour\":{\"used_percentage\":1}}" + version + "}").utf8)
            XCTAssertEqual(capture(bytes, at: url), expected)
        }
        let future = Data(#"{"version":"99.0.0","rate_limits":{"five_hour":{"used_percentage":1}}}"#.utf8)
        guard case .captured = capture(future, at: url) else { return XCTFail("Expected future version capture") }
        XCTAssertEqual(capture(Data(#"{"version":"99.0.0","rate_limits":{"five_hour":{"used_percentage":101}}}"#.utf8), at: url), .invalidQuota)
    }

    func testRepeatedSamePayloadIsNewObservationAndGenerationNotAccountOrCycle() async throws {
        let url = try location()
        let bridge = ClaudePassiveBridge(writer: .init(fileURL: url))
        guard case .captured(let first) = bridge.capture(valid, clock: { now }) else { return XCTFail("Capture") }
        let reader = ClaudeSnapshotReader(fileURL: url)
        let read1 = try await reader.readObservation()
        let read2 = try await reader.readObservation()
        XCTAssertEqual(read1, read2)
        XCTAssertEqual(read1.generation, first)
        let later = now.addingTimeInterval(1)
        guard case .captured(let second) = bridge.capture(valid, clock: { later }) else { return XCTFail("Capture") }
        let read3 = try await reader.readObservation()
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(read3.document.capturedAt, later)
        XCTAssertEqual(read3.document.rateLimits, read1.document.rateLimits)
        XCTAssertEqual(try sample().provenance.accountContinuity, .unknown)
        for capability in [ProviderCapability.resetNotifications, .accountActivity, .activityInsights, .reserveBucket] {
            XCTAssertEqual(ProviderID.claude.capabilities.support(for: capability), .unsupported)
        }
    }

    func testObservedAtIsTakenAfterSuccessfulValidation() async throws {
        let url = try location()
        var calls = 0
        let bridge = ClaudePassiveBridge(writer: .init(fileURL: url))
        _ = bridge.capture(valid) { calls += 1; return now.addingTimeInterval(Double(calls)) }
        let document = try await ClaudeSnapshotReader(fileURL: url).readSnapshot()
        XCTAssertEqual(document.capturedAt, now.addingTimeInterval(2))
    }

    func testWriterSetsOwnerOnlyDirectoryAndFileModes() throws {
        let url = try location()
        _ = try ClaudeSnapshotWriter(fileURL: url).write(sample())
        for (path, mode) in [(url.path, mode_t(0o600)), (url.deletingLastPathComponent().path, mode_t(0o700))] {
            var metadata = stat()
            XCTAssertEqual(lstat(path, &metadata), 0)
            XCTAssertEqual(metadata.st_uid, geteuid())
            XCTAssertEqual(metadata.st_mode & 0o777, mode)
        }
    }

    func testFailureAndCancellationAtEveryPrecommitPhaseCleanTemporaryAndPreserveFinal() throws {
        let url = try location()
        _ = try ClaudeSnapshotWriter(fileURL: url).write(sample())
        let previous = try Data(contentsOf: url)
        for phase in [ClaudeSnapshotWriter.Phase.temporaryCreated, .written, .beforeReplace] {
            for cancel in [false, true] {
                let writer = ClaudeSnapshotWriter(fileURL: url) {
                    if $0 == phase {
                        if cancel { throw CancellationError() }
                        throw ClaudeSnapshotWriteError.ioFailure
                    }
                }
                XCTAssertThrowsError(try writer.write(sample()))
                XCTAssertEqual(try Data(contentsOf: url), previous)
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path), ["usage-v1.json"])
            }
        }
    }

    func testFailureOnFirstWriteNeverCreatesPartialFinalFile() throws {
        let url = try location()
        let writer = ClaudeSnapshotWriter(fileURL: url) { if $0 == .written { throw ClaudeSnapshotWriteError.ioFailure } }
        XCTAssertThrowsError(try writer.write(sample()))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path).isEmpty)
    }

    func testAtomicReplacementPinnedOldDescriptorRemainsComplete() throws {
        let url = try location()
        _ = try ClaudeSnapshotWriter(fileURL: url).write(sample())
        let old = try FileHandle(forReadingFrom: url)
        defer { try? old.close() }
        let oldBytes = try Data(contentsOf: url)
        let newer = try ClaudeStatusLineParser.parse(valid, observedAt: now.addingTimeInterval(2), now: now)
        _ = try ClaudeSnapshotWriter(fileURL: url).write(newer)
        XCTAssertEqual(try old.read(upToCount: 16_385), oldBytes)
        XCTAssertNotEqual(try Data(contentsOf: url), oldBytes)
    }

    func testWriterRejectsAncestorAndLeafSymlinkFIFOAndHardLink() throws {
        let url = try location()
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let target = directory.appendingPathComponent("target")
        try Data("unchanged".utf8).write(to: target)
        XCTAssertEqual(chmod(target.path, 0o600), 0)
        XCTAssertEqual(symlink(target.path, url.path), 0)
        XCTAssertThrowsError(try ClaudeSnapshotWriter(fileURL: url).write(sample()))
        XCTAssertEqual(try Data(contentsOf: target), Data("unchanged".utf8))
        XCTAssertEqual(unlink(url.path), 0)
        XCTAssertEqual(mkfifo(url.path, 0o600), 0)
        XCTAssertThrowsError(try ClaudeSnapshotWriter(fileURL: url).write(sample()))
        XCTAssertEqual(unlink(url.path), 0)
        XCTAssertEqual(link(target.path, url.path), 0)
        XCTAssertThrowsError(try ClaudeSnapshotWriter(fileURL: url).write(sample()))
        let alias = directory.deletingLastPathComponent().appendingPathComponent("alias")
        XCTAssertEqual(symlink(directory.path, alias.path), 0)
        XCTAssertThrowsError(try ClaudeSnapshotWriter(fileURL: alias.appendingPathComponent("usage-v1.json")).write(sample()))
    }

    func testWriterRejectsUnsafeDirectoryAndLeafPermissionsAndMetadataOwner() throws {
        let url = try location()
        _ = try ClaudeSnapshotWriter(fileURL: url).write(sample())
        XCTAssertEqual(chmod(url.path, 0o644), 0)
        XCTAssertThrowsError(try ClaudeSnapshotWriter(fileURL: url).write(sample()))
        XCTAssertEqual(chmod(url.path, 0o600), 0)
        XCTAssertEqual(chmod(url.deletingLastPathComponent().path, 0o755), 0)
        XCTAssertThrowsError(try ClaudeSnapshotWriter(fileURL: url).write(sample()))
        var metadata = stat()
        metadata.st_mode = mode_t(S_IFDIR) | 0o700
        metadata.st_uid = geteuid() + 1
        XCTAssertFalse(ClaudeSnapshotWriter.safeDirectory(metadata, final: true, uid: geteuid()))
    }

    func testPinnedDirectoryCannotBeRedirectedByAncestorReplacement() throws {
        let url = try location()
        let directory = url.deletingLastPathComponent()
        let parent = directory.deletingLastPathComponent()
        let moved = parent.appendingPathComponent("moved")
        let unrelated = parent.appendingPathComponent("unrelated")
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        let writer = ClaudeSnapshotWriter(fileURL: url) { phase in
            if phase == .beforeReplace {
                guard rename(directory.path, moved.path) == 0, symlink(unrelated.path, directory.path) == 0 else {
                    throw ClaudeSnapshotWriteError.ioFailure
                }
            }
        }
        _ = try writer.write(sample())
        XCTAssertTrue(FileManager.default.fileExists(atPath: moved.appendingPathComponent("usage-v1.json").path))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: unrelated.path).isEmpty)
    }

    func testLeafSymlinkInsertedBeforeReplaceIsRejectedAndTargetUnchanged() throws {
        let url = try location()
        let target = url.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("target")
        try Data("safe".utf8).write(to: target)
        let writer = ClaudeSnapshotWriter(fileURL: url) { phase in
            if phase == .beforeReplace, symlink(target.path, url.path) != 0 { throw ClaudeSnapshotWriteError.ioFailure }
        }
        XCTAssertThrowsError(try writer.write(sample()))
        XCTAssertEqual(try Data(contentsOf: target), Data("safe".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path), ["usage-v1.json"])
    }

    func testConcurrentWritersCommitCompleteSnapshotsOrFailBusy() async throws {
        let url = try location()
        let initial = try sample()
        _ = try ClaudeSnapshotWriter(fileURL: url).write(initial)
        let results = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    do { _ = try ClaudeSnapshotWriter(fileURL: url).write(initial); return true }
                    catch ClaudeSnapshotWriteError.busy { return false }
                    catch { XCTFail("Unexpected categorized writer failure"); return false }
                }
            }
            var results = [Bool]()
            for await result in group { results.append(result) }
            return results
        }
        XCTAssertTrue(results.contains(true))
        let document = try await ClaudeSnapshotReader(fileURL: url).readSnapshot()
        XCTAssertEqual(document, initial.snapshotDocument())
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path), ["usage-v1.json"])
    }

    func testCancelledTaskWritesNothing() async throws {
        let url = try location()
        let initial = try sample()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do { _ = try ClaudeSnapshotWriter(fileURL: url).write(initial); return false }
            catch is CancellationError { return true }
            catch { return false }
        }
        let cancelled = await task.value
        XCTAssertTrue(cancelled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testBoundedInputCompleteEmptyOversizeAndExactLimit() throws {
        let url = try location().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("input")
        for data in [valid, Data(), Data(repeating: 32, count: 65_536), Data(repeating: 32, count: 65_537)] {
            try data.write(to: url)
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            if data.count > 65_536 {
                XCTAssertThrowsError(try ClaudeBridgeInput.read(descriptor: handle.fileDescriptor)) {
                    XCTAssertEqual($0 as? ClaudeBridgeInputError, .oversized)
                }
            } else { XCTAssertEqual(try ClaudeBridgeInput.read(descriptor: handle.fileDescriptor), data) }
        }
    }

    func testInputDurationIsBoundedForNeverClosedPipe() throws {
        let pipe = Pipe()
        defer { try? pipe.fileHandleForReading.close(); try? pipe.fileHandleForWriting.close() }
        XCTAssertThrowsError(try ClaudeBridgeInput.read(descriptor: pipe.fileHandleForReading.fileDescriptor, duration: 0.02)) {
            XCTAssertEqual($0 as? ClaudeBridgeInputError, .timedOut)
        }
    }

    func testCompositionForwardsByteIdenticalStdinAndPreservesStdout() throws {
        let url = try location()
        let bytes = Data(" \n{\"version\":\"2.1.246\",\"rate_limits\":null,\"prompt\":\"$(exit 88); ' FAKE\"}\t\n".utf8)
        var output = Data()
        let result = ClaudeBridgeComposition.execute(originalBytes: bytes, bridge: .init(writer: .init(fileURL: url)),
            downstream: .userAuthoredShell("/bin/cat"), clock: { now }) { output.append($0) }
        XCTAssertEqual(output, bytes)
        XCTAssertEqual(result.capture, .noRateLimits)
        XCTAssertEqual(result.downstream, .exited(0))
        XCTAssertEqual(result.exitCode, 0)
    }

    func testCaptureFailureDoesNotDestroySuccessfulRendererOutput() throws {
        var output = Data()
        let result = ClaudeBridgeComposition.execute(originalBytes: Data("FAKE_MALFORMED".utf8),
            bridge: .init(writer: .init(fileURL: try location())),
            downstream: .userAuthoredShell("printf 'renderer-only\\n'"), clock: { now }) { output.append($0) }
        XCTAssertEqual(output, Data("renderer-only\n".utf8))
        XCTAssertEqual(result.capture, .invalidQuota)
        XCTAssertEqual(result.exitCode, 0)
    }

    func testWriteFailureDoesNotDestroySuccessfulRendererOutput() throws {
        var output = Data()
        let writer = ClaudeSnapshotWriter(fileURL: try location()) { _ in throw ClaudeSnapshotWriteError.ioFailure }
        let result = ClaudeBridgeComposition.execute(originalBytes: valid, bridge: .init(writer: writer),
            downstream: .userAuthoredShell("printf OK"), clock: { now }) { output.append($0) }
        XCTAssertEqual(output, Data("OK".utf8))
        XCTAssertEqual(result.capture, .writeFailed)
        XCTAssertEqual(result.exitCode, 0)
    }

    func testDownstreamFailurePreservesOutputCaptureAndExitSuppressesStderr() throws {
        let url = try location()
        var output = Data()
        let result = ClaudeBridgeComposition.execute(originalBytes: valid, bridge: .init(writer: .init(fileURL: url)),
            downstream: .userAuthoredShell("printf visible; printf FAKE_SECRET >&2; exit 7"), clock: { now }) { output.append($0) }
        guard case .captured = result.capture else { return XCTFail("Capture") }
        XCTAssertEqual(output, Data("visible".utf8))
        XCTAssertEqual(result.downstream, .exited(7))
        XCTAssertEqual(result.exitCode, 7)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testNoDownstreamCaptureProducesNoStdout() throws {
        var output = Data()
        let result = ClaudeBridgeComposition.execute(originalBytes: valid,
            bridge: .init(writer: .init(fileURL: try location())), downstream: nil, clock: { now }) { output.append($0) }
        XCTAssertTrue(output.isEmpty)
        XCTAssertNil(result.downstream)
        XCTAssertEqual(result.exitCode, 0)
    }

    func testRendererTimeoutLaunchFailureAndOutputBoundHaveSafeCategories() {
        XCTAssertEqual(ClaudeBridgeComposition.render(valid, command: .userAuthoredShell("/bin/sleep 3"), duration: 0.03) { _ in }, .timedOut)
        XCTAssertEqual(ClaudeBridgeComposition.render(valid,
            command: .init(executable: URL(fileURLWithPath: "/fake/missing-renderer"), arguments: [])) { _ in }, .launchFailed)
        XCTAssertEqual(ClaudeBridgeComposition.render(valid, command: .userAuthoredShell("/usr/bin/yes x")) { _ in }, .outputTooLarge)
    }

    func testDownstreamCancelledTaskDoesNotLaunchRenderer() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return ClaudeBridgeComposition.render(Data(), command: .userAuthoredShell("exit 99")) { _ in }
        }
        let result = await task.value
        XCTAssertEqual(result, .cancelled)
    }

    func testCancellationAfterSpawnTerminatesAndReapsOwnedChild() async {
        let task = Task {
            var child: pid_t = 0
            let result = ClaudeBridgeComposition.render(Data(), command: .userAuthoredShell("exec /bin/sleep 3"),
                spawned: { pid in child = pid; withUnsafeCurrentTask { $0?.cancel() } }) { _ in }
            return (result, child)
        }
        let (result, child) = await task.value
        XCTAssertEqual(result, .cancelled)
        XCTAssertGreaterThan(child, 0)
        XCTAssertEqual(kill(child, 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }

    func testSimultaneousInputOutputDoesNotDeadlock() {
        let bytes = Data(repeating: 65, count: 16_384)
        var output = Data()
        let command = ClaudeBridgeDownstreamCommand.userAuthoredShell("/usr/bin/head -c 32768 /dev/zero; /bin/cat")
        XCTAssertEqual(ClaudeBridgeComposition.render(bytes, command: command) { output.append($0) }, .exited(0))
        XCTAssertEqual(output, Data(repeating: 0, count: 32_768) + bytes)
    }

    func testOversizedCaptureStillForwardsCompleteBoundedEventToRenderer() throws {
        let bytes = Data(repeating: 32, count: 32_768)
        var output = Data()
        let result = ClaudeBridgeComposition.execute(originalBytes: bytes,
            bridge: .init(writer: .init(fileURL: try location())), downstream: .userAuthoredShell("/bin/cat"),
            clock: { now }) { output.append($0) }
        XCTAssertEqual(result.capture, .inputTooLarge)
        XCTAssertEqual(result.downstream, .exited(0))
        XCTAssertEqual(output, bytes)
    }

    func testPreviewPreservesSyntheticCommandAndRollsBackExactOriginalBytes() throws {
        let original = Data("{ \"statusLine\": {\"type\":\"command\",\"command\":\"printf 'SYNTHETIC'\",\"padding\":2}, \"other\": true }\n".utf8)
        let preview = try ClaudeBridgeSetupPreview.make(originalSettings: original,
            helperPath: "/synthetic/QuotaMew.app/Contents/Helpers/ClaudeQuotaBridge",
            downstreamReference: "/synthetic/command", editability: .editable)
        XCTAssertTrue(preview.hasExistingRenderer)
        XCTAssertTrue(preview.mayProposeActivation)
        XCTAssertEqual(preview.originalSettings, original)
        XCTAssertEqual(try preview.rollback(currentSettings: preview.proposedSettings), original)
        XCTAssertThrowsError(try preview.rollback(currentSettings: Data("{}".utf8)))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: preview.proposedSettings) as? [String: Any])
        let status = try XCTUnwrap(object["statusLine"] as? [String: Any])
        XCTAssertEqual(status["padding"] as? Int, 2)
        XCTAssertEqual(object["other"] as? Bool, true)
        XCTAssertFalse((status["command"] as? String ?? "").contains("SYNTHETIC"))
    }

    func testPreviewAbsentRendererAndManagedShadowedUnknownStates() throws {
        for state in [ClaudeSettingsEditability.editable, .managed, .shadowed, .unknown] {
            let preview = try ClaudeBridgeSetupPreview.make(originalSettings: Data("{}".utf8),
                helperPath: "/synthetic/helper ' $(fake)", downstreamReference: "/synthetic/reference", editability: state)
            XCTAssertFalse(preview.hasExistingRenderer)
            XCTAssertEqual(preview.mayProposeActivation, state == .editable)
            XCTAssertEqual(try preview.rollback(currentSettings: preview.proposedSettings), Data("{}".utf8))
            XCTAssertFalse(String(decoding: preview.proposedSettings, as: UTF8.self).contains("--downstream-file"))
        }
    }

    func testSettingsPrecedenceAndExecutionPoliciesRequireCompleteEvidence() {
        for source in [ClaudeStatusLineSettingsSource.absent, .user, .sharedProject, .localProject, .commandLine, .managed, .unknown] {
            let expected: ClaudeSettingsEditability
            switch source {
            case .absent, .user: expected = .editable
            case .sharedProject, .localProject, .commandLine: expected = .shadowed
            case .managed: expected = .managed
            case .unknown: expected = .unknown
            }
            let evidence = ClaudeStatusLineSettingsEvidence(effectiveSource: source, sourcesAndTrustKnown: true,
                allowManagedHooksOnly: false, disableAllHooksOutsideManaged: false)
            XCTAssertEqual(evidence.userSettingsEditability, expected)
        }
        XCTAssertEqual(ClaudeStatusLineSettingsEvidence(effectiveSource: .user, sourcesAndTrustKnown: false,
            allowManagedHooksOnly: false, disableAllHooksOutsideManaged: false).userSettingsEditability, .unknown)
        XCTAssertEqual(ClaudeStatusLineSettingsEvidence(effectiveSource: .user, sourcesAndTrustKnown: true,
            allowManagedHooksOnly: nil, disableAllHooksOutsideManaged: false).userSettingsEditability, .unknown)
        XCTAssertEqual(ClaudeStatusLineSettingsEvidence(effectiveSource: .user, sourcesAndTrustKnown: true,
            allowManagedHooksOnly: true, disableAllHooksOutsideManaged: false).userSettingsEditability, .managed)
        XCTAssertEqual(ClaudeStatusLineSettingsEvidence(effectiveSource: .user, sourcesAndTrustKnown: true,
            allowManagedHooksOnly: false, disableAllHooksOutsideManaged: true).userSettingsEditability, .managed)
    }

    func testBundledHelperSyntheticNoDownstreamAndComposition() async throws {
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/ClaudeQuotaBridge")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: helper.path))
        let url = try location()
        var output = Data()
        let arguments = ["--snapshot-file", url.path]
        XCTAssertEqual(ClaudeBridgeComposition.render(valid, command: .init(executable: helper, arguments: arguments)) {
            output.append($0)
        }, .exited(0))
        XCTAssertTrue(output.isEmpty)
        let document = try await ClaudeSnapshotReader(fileURL: url).readSnapshot()
        XCTAssertEqual(document.rateLimits, try sample().snapshotDocument().rateLimits)
        let commandFile = url.deletingLastPathComponent().appendingPathComponent("synthetic-command")
        try Data("/bin/cat".utf8).write(to: commandFile)
        XCTAssertEqual(chmod(commandFile.path, 0o600), 0)
        XCTAssertEqual(ClaudeBridgeComposition.render(valid,
            command: .init(executable: helper, arguments: arguments + ["--downstream-file", commandFile.path])) {
            output.append($0)
        }, .exited(0))
        XCTAssertEqual(output, valid)
    }
}
