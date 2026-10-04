import Foundation
import Darwin

enum ClaudeSnapshotWriteError: Error, Equatable, Sendable {
    case unsafePath, busy, ioFailure
}

// Atomic replacement creates a new inode. This marker describes only this local delivery;
// it is neither an account ID nor a reset-cycle ID, and is never serialized.
struct ClaudeSnapshotGeneration: Equatable, Sendable {
    let device: Int32
    let inode: UInt64
    let changedSeconds: Int
    let changedNanoseconds: Int

    init(_ metadata: stat) {
        device = metadata.st_dev
        inode = metadata.st_ino
        changedSeconds = metadata.st_ctimespec.tv_sec
        changedNanoseconds = metadata.st_ctimespec.tv_nsec
    }
}

struct ClaudeSnapshotWriter: Sendable {
    enum Phase: Sendable { case temporaryCreated, written, beforeReplace }
    let fileURL: URL
    var checkpoint: @Sendable (Phase) throws -> Void = { _ in }

    init(fileURL: URL = ClaudeSnapshotReader.defaultSnapshotURL(),
         checkpoint: @escaping @Sendable (Phase) throws -> Void = { _ in }) {
        self.fileURL = fileURL
        self.checkpoint = checkpoint
    }

    func write(_ sample: ClaudeValidatedQuotaSample) throws -> ClaudeSnapshotGeneration {
        try Task.checkCancellation()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(sample.snapshotDocument())
        guard data.count <= ClaudeStatusLineParser.maximumBytes else { throw ClaudeSnapshotWriteError.ioFailure }
        let directory = try openDirectory()
        defer { Darwin.close(directory) }
        // Contending invocations fail safely rather than waiting indefinitely. The previous
        // snapshot stays intact, and downstream rendering is independent of this result.
        guard flock(directory, LOCK_EX | LOCK_NB) == 0 else { throw ClaudeSnapshotWriteError.busy }
        defer { _ = flock(directory, LOCK_UN) }
        let leaf = fileURL.lastPathComponent
        try validateLeaf(directory, leaf)
        let temporary = ".quotamew-\(UUID().uuidString).tmp"
        let descriptor = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw ClaudeSnapshotWriteError.ioFailure }
        defer {
            Darwin.close(descriptor)
            _ = unlinkat(directory, temporary, 0)
        }
        guard fchmod(descriptor, 0o600) == 0 else { throw ClaudeSnapshotWriteError.ioFailure }
        try checkpoint(.temporaryCreated)
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                try Task.checkCancellation()
                let count = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw ClaudeSnapshotWriteError.ioFailure }
                offset += count
            }
        }
        try checkpoint(.written)
        guard fsync(descriptor) == 0 else { throw ClaudeSnapshotWriteError.ioFailure }
        try checkpoint(.beforeReplace)
        try Task.checkCancellation()
        try validateLeaf(directory, leaf)
        guard renameat(directory, temporary, directory, leaf) == 0 else { throw ClaudeSnapshotWriteError.ioFailure }
        // Parent fsync persists the directory entry. Failure here means durability is
        // uncertain, but the committed file is still complete; do not undo the rename.
        guard fsync(directory) == 0 else { throw ClaudeSnapshotWriteError.ioFailure }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else { throw ClaudeSnapshotWriteError.ioFailure }
        return .init(metadata)
    }

    private func openDirectory() throws -> Int32 {
        guard fileURL.isFileURL, fileURL.path.utf8.count <= 4_096 else { throw ClaudeSnapshotWriteError.unsafePath }
        let components = Array(fileURL.pathComponents.dropFirst())
        guard components.count >= 2, !components.contains(".."), !components.contains(".") else {
            throw ClaudeSnapshotWriteError.unsafePath
        }
        var directory = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard directory >= 0 else { throw ClaudeSnapshotWriteError.ioFailure }
        do {
            for (index, component) in components.dropLast().enumerated() {
                var next = openat(directory, component, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
                if next < 0 && errno == ENOENT {
                    if mkdirat(directory, component, 0o700) != 0 && errno != EEXIST {
                        throw ClaudeSnapshotWriteError.ioFailure
                    }
                    next = openat(directory, component, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
                }
                guard next >= 0 else { throw ClaudeSnapshotWriteError.unsafePath }
                var metadata = stat()
                let valid = fstat(next, &metadata) == 0
                    && Self.safeDirectory(metadata, final: index == components.count - 2, uid: geteuid())
                guard valid else {
                    Darwin.close(next)
                    throw ClaudeSnapshotWriteError.unsafePath
                }
                Darwin.close(directory)
                directory = next
            }
            return directory
        } catch {
            Darwin.close(directory)
            throw error
        }
    }

    static func safeDirectory(_ metadata: stat, final: Bool, uid: uid_t) -> Bool {
        guard metadata.st_mode & S_IFMT == S_IFDIR else { return false }
        if final { return metadata.st_uid == uid && metadata.st_mode & 0o777 == 0o700 }
        guard metadata.st_uid == 0 || metadata.st_uid == uid else { return false }
        // Root-owned sticky temporary ancestors are accepted for synthetic fixtures.
        return metadata.st_mode & 0o022 == 0 || (metadata.st_uid == 0 && metadata.st_mode & S_ISVTX != 0)
    }

    private func validateLeaf(_ directory: Int32, _ leaf: String) throws {
        var metadata = stat()
        if fstatat(directory, leaf, &metadata, AT_SYMLINK_NOFOLLOW) != 0 {
            guard errno == ENOENT else { throw ClaudeSnapshotWriteError.ioFailure }
            return
        }
        guard metadata.st_mode & S_IFMT == S_IFREG, metadata.st_uid == geteuid(),
              metadata.st_mode & 0o777 == 0o600, metadata.st_nlink == 1 else {
            throw ClaudeSnapshotWriteError.unsafePath
        }
    }
}
