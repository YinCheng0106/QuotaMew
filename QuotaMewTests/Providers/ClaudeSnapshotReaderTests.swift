import Foundation
import Darwin
import XCTest
@testable import QuotaMew

final class ClaudeSnapshotReaderTests: XCTestCase {
    func testReadsVersionedMinimalSnapshotAndIgnoresUnknownFields() async throws {
        let fileURL = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let data = Data(#"{"schemaVersion":1,"capturedAt":"2033-05-18T03:33:20Z","claudeCodeVersion":"2.1.80","rateLimits":{"fiveHour":{"usedPercentage":12.5,"resetsAt":2000003600},"sevenDay":null},"workspace":"must-not-be-modeled","unknown":{"prompt":"must-not-be-modeled"}}"#.utf8)
        try data.write(to: fileURL)
        let reader = ClaudeSnapshotReader(fileURL: fileURL)

        let snapshot = try await reader.readSnapshot()

        XCTAssertEqual(snapshot.schemaVersion, 1)
        XCTAssertEqual(snapshot.capturedAt, Date(timeIntervalSince1970: 2_000_000_000))
        XCTAssertEqual(snapshot.claudeCodeVersion, "2.1.80")
        XCTAssertEqual(snapshot.rateLimits.fiveHour?.usedPercentage, 12.5)
        XCTAssertNil(snapshot.rateLimits.sevenDay)
        XCTAssertFalse(String(reflecting: snapshot).contains("must-not-be-modeled"))
    }

    func testRejectsUnsupportedSchemaVersion() async {
        let fileURL = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let data = Data(#"{"schemaVersion":2,"capturedAt":"2033-05-18T03:33:20Z","rateLimits":{"fiveHour":null,"sevenDay":null}}"#.utf8)
        try? data.write(to: fileURL)
        let reader = ClaudeSnapshotReader(fileURL: fileURL)

        do {
            _ = try await reader.readSnapshot()
            XCTFail("Expected an unsupported schema error")
        } catch {
            XCTAssertEqual(error as? ClaudeSnapshotReaderError, .unsupportedSchema(version: 2))
        }
    }

    func testRejectsFutureSchemaBeforeDecodingItsChangedPayload() async {
        let fileURL = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let data = Data(#"{"schemaVersion":2,"replacementPayload":{}}"#.utf8)
        try? data.write(to: fileURL)
        let reader = ClaudeSnapshotReader(fileURL: fileURL)

        do {
            _ = try await reader.readSnapshot()
            XCTFail("Expected an unsupported schema error")
        } catch {
            XCTAssertEqual(error as? ClaudeSnapshotReaderError, .unsupportedSchema(version: 2))
        }
    }

    func testReportsMissingSnapshotWithoutInspectingClaudeFiles() async {
        let reader = ClaudeSnapshotReader(fileURL: temporaryFileURL())

        do {
            _ = try await reader.readSnapshot()
            XCTFail("Expected a missing snapshot error")
        } catch {
            XCTAssertEqual(error as? ClaudeSnapshotReaderError, .snapshotNotFound)
        }
    }

    func testRejectsSymbolicLinkSnapshot() async throws {
        let targetURL = temporaryFileURL()
        let linkURL = temporaryFileURL()
        defer {
            try? FileManager.default.removeItem(at: linkURL)
            try? FileManager.default.removeItem(at: targetURL)
        }

        let data = Data(#"{"schemaVersion":1,"capturedAt":"2033-05-18T03:33:20Z","rateLimits":{"fiveHour":{"usedPercentage":12.5,"resetsAt":2000003600},"sevenDay":null}}"#.utf8)
        try data.write(to: targetURL)
        try FileManager.default.createSymbolicLink(
            at: linkURL,
            withDestinationURL: targetURL
        )
        let reader = ClaudeSnapshotReader(fileURL: linkURL)

        do {
            _ = try await reader.readSnapshot()
            XCTFail("Expected a symbolic link snapshot to be rejected")
        } catch {
            XCTAssertEqual(error as? ClaudeSnapshotReaderError, .snapshotUnreadable)
        }
    }

    func testRejectsNamedPipeSnapshotWithoutWaitingForAWriter() async throws {
        let fileURL = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL) }

        XCTAssertEqual(mkfifo(fileURL.path, S_IRUSR | S_IWUSR), 0)
        let reader = ClaudeSnapshotReader(fileURL: fileURL)

        do {
            _ = try await reader.readSnapshot()
            XCTFail("Expected a named pipe snapshot to be rejected")
        } catch {
            XCTAssertEqual(error as? ClaudeSnapshotReaderError, .snapshotUnreadable)
        }
    }

    func testRejectsMalformedOrPartialSnapshot() async {
        let fileURL = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL) }

        try? Data(#"{"schemaVersion":1,"capturedAt":"2033-05-18T03:33:20Z""#.utf8)
            .write(to: fileURL)
        let reader = ClaudeSnapshotReader(fileURL: fileURL)

        do {
            _ = try await reader.readSnapshot()
            XCTFail("Expected an invalid snapshot error")
        } catch {
            XCTAssertEqual(error as? ClaudeSnapshotReaderError, .invalidSnapshot)
        }
    }

    func testRejectsOversizedSnapshotBeforeDecoding() async {
        let fileURL = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL) }

        try? Data(repeating: 0x20, count: 65).write(to: fileURL)
        let reader = ClaudeSnapshotReader(fileURL: fileURL, maximumBytes: 64)

        do {
            _ = try await reader.readSnapshot()
            XCTFail("Expected an oversized snapshot error")
        } catch {
            XCTAssertEqual(error as? ClaudeSnapshotReaderError, .snapshotTooLarge)
        }
    }

    func testRejectsAncestorSymlink() async throws {
        let directory = temporaryFileURL()
        let link = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: directory); try? FileManager.default.removeItem(at: link) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try validData(used: 10).write(to: directory.appendingPathComponent("sample.json"))
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: directory)
        do {
            _ = try await ClaudeSnapshotReader(fileURL: link.appendingPathComponent("sample.json")).readSnapshot()
            XCTFail("Ancestor symlinks are not trusted")
        } catch { XCTAssertEqual(error as? ClaudeSnapshotReaderError, .snapshotUnreadable) }
    }

    func testOwnerAndModePolicyAndErrnoEvidence() {
        var metadata = stat()
        metadata.st_mode = S_IFREG | S_IRUSR | S_IWUSR
        metadata.st_uid = 123
        XCTAssertTrue(ClaudeSnapshotFileOpener.hasSafeMetadata(metadata, effectiveUID: 123))
        XCTAssertFalse(ClaudeSnapshotFileOpener.hasSafeMetadata(metadata, effectiveUID: 124))
        metadata.st_mode |= S_IWGRP
        XCTAssertFalse(ClaudeSnapshotFileOpener.hasSafeMetadata(metadata, effectiveUID: 123))
        metadata.st_mode = S_IFIFO | S_IRUSR
        XCTAssertFalse(ClaudeSnapshotFileOpener.hasSafeMetadata(metadata, effectiveUID: 123))
        for code in [EACCES, EPERM] {
            XCTAssertEqual(ClaudeSnapshotFileOpener.error(for: code), .permissionDenied)
        }
        XCTAssertEqual(ClaudeSnapshotFileOpener.error(for: ELOOP), .snapshotUnreadable)
    }

    func testRejectsWritableByOtherModeOnRealFile() async throws {
        let file = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: file) }
        try validData(used: 10).write(to: file)
        XCTAssertEqual(chmod(file.path, S_IRUSR | S_IWUSR | S_IWOTH), 0)
        do {
            _ = try await ClaudeSnapshotReader(fileURL: file).readSnapshot()
            XCTFail("Other-user writable samples are not trusted")
        } catch { XCTAssertEqual(error as? ClaudeSnapshotReaderError, .snapshotUnreadable) }
    }

    func testPermissionErrorsAndUnknownErrorsAreSanitizedBeforeOutput() async {
        for code in [EACCES, EPERM] {
            do {
                _ = try await ClaudeSnapshotReader(fileURL: temporaryFileURL(), opener: DeniedSnapshotOpener(code: code)).readSnapshot()
                XCTFail("Expected permission failure")
            } catch { XCTAssertEqual(error as? ClaudeSnapshotReaderError, .permissionDenied) }
        }
    }

    func testAtomicReplacementReadsPinnedFileAndNextReadUsesReplacement() async throws {
        let file = temporaryFileURL()
        let replacement = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: file); try? FileManager.default.removeItem(at: replacement) }
        try validData(used: 10).write(to: file)
        try validData(used: 30).write(to: replacement)
        let reader = ClaudeSnapshotReader(fileURL: file, opener: ReplacingSnapshotOpener(replacement: replacement))
        let pinned = try await reader.readSnapshot()
        XCTAssertEqual(pinned.rateLimits.fiveHour?.usedPercentage, 10)
        let next = try await ClaudeSnapshotReader(fileURL: file).readSnapshot()
        XCTAssertEqual(next.rateLimits.fiveHour?.usedPercentage, 30)
        XCTAssertEqual(pinned.capturedAt, next.capturedAt)
    }

    func testReadAgainAndMtimeDoNotRenewObservation() async throws {
        let file = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: file) }
        try validData(used: 10).write(to: file)
        let reader = ClaudeSnapshotReader(fileURL: file)
        let first = try await reader.readSnapshot()
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
        let second = try await reader.readSnapshot()
        XCTAssertEqual(first, second)
        let provider = ClaudeProvider(reader: reader, now: { Date(timeIntervalSince1970: 2_000_004_000) })
        let sample = try await provider.fetchUsage()
        XCTAssertEqual(sample.validity, .stale)
        XCTAssertEqual(sample.capturedAt, first.capturedAt)
    }

    func testCancellationBeforeOpen() async {
        let reader = ClaudeSnapshotReader(fileURL: temporaryFileURL())
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await reader.readSnapshot()
        }
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testCancellationAfterOpenClosesDescriptor() async throws {
        let file = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: file) }
        try validData(used: 10).write(to: file)
        let handle = try ClaudeSnapshotFileOpener().openSnapshot(at: file)
        let descriptor = handle.fileDescriptor
        let reader = ClaudeSnapshotReader(fileURL: file, opener: CancelOnOpenSnapshotOpener(handle: handle))
        let task = Task { try await reader.readSnapshot() }
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(fcntl(descriptor, F_GETFD), -1)
        XCTAssertEqual(errno, EBADF)
    }

    func testInvalidOwnedPercentagesVersionsAndPrivateErrors() async throws {
        let file = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: file) }
        for used in [-1.0, 140] {
            try validData(used: used).write(to: file)
            do { _ = try await ClaudeSnapshotReader(fileURL: file).readSnapshot(); XCTFail("Expected invalid percentage") }
            catch { XCTAssertEqual(error as? ClaudeContractError, .invalidPercentage) }
        }
        let privateData = Data(#"{"schemaVersion":1,"capturedAt":"2033-05-18T03:33:20Z","claudeCodeVersion":"synthetic-secret","rateLimits":{}}"#.utf8)
        try privateData.write(to: file)
        do { _ = try await ClaudeSnapshotReader(fileURL: file).readSnapshot(); XCTFail("Expected unverified version") }
        catch {
            XCTAssertEqual(error as? ClaudeContractError, .unverifiedVersion)
            XCTAssertFalse(String(reflecting: error).contains("synthetic-secret"))
        }
    }

    private func validData(used: Double) -> Data {
        Data("{\"schemaVersion\":1,\"capturedAt\":\"2033-05-18T03:33:20Z\",\"claudeCodeVersion\":\"2.1.246\",\"rateLimits\":{\"fiveHour\":{\"usedPercentage\":\(used),\"resetsAt\":2000003600}}}".utf8)
    }

    private func temporaryFileURL() -> URL {
        URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appending(path: UUID().uuidString)
            .appendingPathExtension("json")
    }
}

private struct DeniedSnapshotOpener: ClaudeSnapshotOpening {
    let code: Int32
    func openSnapshot(at url: URL) throws -> FileHandle { throw ClaudeSnapshotFileOpener.error(for: code) }
}

private struct CancelOnOpenSnapshotOpener: ClaudeSnapshotOpening {
    let handle: FileHandle
    func openSnapshot(at url: URL) throws -> FileHandle {
        withUnsafeCurrentTask { $0?.cancel() }
        return handle
    }
}

private struct ReplacingSnapshotOpener: ClaudeSnapshotOpening {
    let replacement: URL
    func openSnapshot(at url: URL) throws -> FileHandle {
        let handle = try ClaudeSnapshotFileOpener().openSnapshot(at: url)
        guard rename(replacement.path, url.path) == 0 else {
            try? handle.close()
            throw ClaudeSnapshotReaderError.snapshotUnreadable
        }
        return handle
    }
}
