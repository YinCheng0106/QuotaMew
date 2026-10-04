import Foundation
import Darwin

protocol ClaudeUsageSnapshotReading: Sendable {
    func readSnapshot() async throws -> ClaudeUsageSnapshotDocument
}

enum ClaudeSnapshotReaderError: Error, Equatable, Sendable {
    case snapshotNotFound
    case snapshotUnreadable
    case permissionDenied
    case snapshotTooLarge
    case invalidSnapshot
    case unsupportedSchema(version: Int)
}

#if !CLAUDE_BRIDGE
extension ClaudeSnapshotReaderError: ProviderStatusProvidingError {
    var providerStatus: ProviderStatus {
        switch self {
        case .snapshotNotFound:
            .notConfigured
        case .snapshotUnreadable, .permissionDenied, .snapshotTooLarge, .invalidSnapshot, .unsupportedSchema:
            .failed(.refreshFailed)
        }
    }

    var runtimeAvailability: ProviderRuntimeAvailability {
        switch self {
        case .snapshotNotFound: .unavailable(.awaitingSource)
        case .permissionDenied: .unavailable(.permissionDenied)
        case .snapshotUnreadable: .unavailable(.providerError)
        case .snapshotTooLarge, .invalidSnapshot: .unavailable(.invalidData)
        case .unsupportedSchema: .unavailable(.unsupportedSchema)
        }
    }
}
#endif

protocol ClaudeSnapshotOpening: Sendable {
    func openSnapshot(at url: URL) throws -> FileHandle
}

struct ClaudeSnapshotFileOpener: ClaudeSnapshotOpening {
    func openSnapshot(at url: URL) throws -> FileHandle {
        guard url.isFileURL, url.path.utf8.count <= 4_096 else {
            throw ClaudeSnapshotReaderError.snapshotUnreadable
        }
        // Walk pinned directory descriptors. Reject symlinks in every component;
        // do not resolve an untrusted ancestor and then mistake it for a safe path.
        let components = url.pathComponents.dropFirst()
        guard !components.isEmpty, !components.contains("..") else {
            throw ClaudeSnapshotReaderError.snapshotUnreadable
        }
        var directory = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard directory >= 0 else { throw Self.error(for: errno) }
        defer { Darwin.close(directory) }
        for component in components.dropLast() {
            let next = openat(directory, component, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            guard next >= 0 else { throw Self.error(for: errno) }
            Darwin.close(directory)
            directory = next
        }
        let descriptor = openat(directory, components.last!, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw Self.error(for: errno) }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    static func error(for code: Int32) -> ClaudeSnapshotReaderError {
        switch code {
        case ENOENT: .snapshotNotFound
        case EACCES, EPERM: .permissionDenied
        default: .snapshotUnreadable
        }
    }

    static func hasSafeMetadata(_ metadata: stat, effectiveUID: uid_t) -> Bool {
        metadata.st_mode & S_IFMT == S_IFREG
            && metadata.st_uid == effectiveUID
            && metadata.st_mode & (S_IWGRP | S_IWOTH) == 0
    }
}

private struct ClaudeSnapshotEnvelope: Decodable {
    let schemaVersion: Int
}

struct ClaudeSnapshotObservation: Equatable, Sendable {
    let document: ClaudeUsageSnapshotDocument
    let generation: ClaudeSnapshotGeneration
}

struct ClaudeSnapshotReader: ClaudeUsageSnapshotReading, Sendable {
    static let supportedSchemaVersion = 1

    private let fileURL: URL
    private let maximumBytes: Int
    private let opener: any ClaudeSnapshotOpening

    init(
        fileURL: URL = Self.defaultSnapshotURL(),
        maximumBytes: Int = 16_384,
        opener: any ClaudeSnapshotOpening = ClaudeSnapshotFileOpener()
    ) {
        self.fileURL = fileURL
        self.maximumBytes = min(max(maximumBytes, 1), 16_384)
        self.opener = opener
    }

    func readSnapshot() async throws -> ClaudeUsageSnapshotDocument {
        try await readObservation().document
    }

    func readObservation() async throws -> ClaudeSnapshotObservation {
        try Task.checkCancellation()

        let handle: FileHandle
        do {
            handle = try opener.openSnapshot(at: fileURL)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ClaudeSnapshotReaderError {
            throw error
        } catch {
            throw ClaudeSnapshotReaderError.snapshotUnreadable
        }
        defer { try? handle.close() }

        var before = stat()
        guard fstat(handle.fileDescriptor, &before) == 0,
              ClaudeSnapshotFileOpener.hasSafeMetadata(before, effectiveUID: geteuid()) else {
            throw ClaudeSnapshotReaderError.snapshotUnreadable
        }
        guard before.st_size <= maximumBytes else { throw ClaudeSnapshotReaderError.snapshotTooLarge }

        let data: Data
        do {
            data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        } catch {
            throw ClaudeSnapshotReaderError.snapshotUnreadable
        }

        try Task.checkCancellation()

        guard data.count <= maximumBytes else {
            throw ClaudeSnapshotReaderError.snapshotTooLarge
        }
        var after = stat()
        guard fstat(handle.fileDescriptor, &after) == 0,
              before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              ClaudeSnapshotFileOpener.hasSafeMetadata(after, effectiveUID: geteuid()) else {
            throw ClaudeSnapshotReaderError.invalidSnapshot
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let envelope: ClaudeSnapshotEnvelope
        do {
            envelope = try decoder.decode(ClaudeSnapshotEnvelope.self, from: data)
        } catch {
            throw ClaudeSnapshotReaderError.invalidSnapshot
        }

        guard envelope.schemaVersion == Self.supportedSchemaVersion else {
            throw ClaudeSnapshotReaderError.unsupportedSchema(version: envelope.schemaVersion)
        }

        let document: ClaudeUsageSnapshotDocument
        do {
            document = try decoder.decode(ClaudeUsageSnapshotDocument.self, from: data)
        } catch {
            throw ClaudeSnapshotReaderError.invalidSnapshot
        }
        // Validate before emitting a DTO; canonical version output cannot retain arbitrary text.
        // Use observed time here only for validation, never to renew freshness on a read.
        do {
            let document = try ClaudeQuotaValidation.sample(
                fiveHour: document.rateLimits.fiveHour, sevenDay: document.rateLimits.sevenDay,
                observedAt: document.capturedAt, version: document.claudeCodeVersion,
                now: document.capturedAt
            ).snapshotDocument()
            return .init(document: document, generation: .init(after))
        } catch let error as ClaudeContractError {
            throw error
        } catch {
            throw ClaudeSnapshotReaderError.invalidSnapshot
        }
    }

    static func defaultSnapshotURL() -> URL {
        FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        .appending(path: "QuotaPulse/Providers/Claude/usage-v1.json")
    }
}
