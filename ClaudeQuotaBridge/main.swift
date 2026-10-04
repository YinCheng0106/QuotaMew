import Foundation
import Darwin

// Explicit invocation only. There is no installer, settings discovery or live probing.
func runBridge() -> Int32 {
    let arguments = Array(CommandLine.arguments.dropFirst())
    var downstream: ClaudeBridgeDownstreamCommand?
    var snapshotURL = ClaudeSnapshotReader.defaultSnapshotURL()
    guard arguments.count % 2 == 0 else { return 64 }
    var seen = Set<String>()
    for offset in stride(from: 0, to: arguments.count, by: 2) {
        guard seen.insert(arguments[offset]).inserted else { return 64 }
        if arguments[offset] == "--snapshot-file" {
            // Explicit synthetic/dev output override. Never inferred from provider input.
            guard arguments[offset + 1].hasPrefix("/") else { return 64 }
            snapshotURL = URL(fileURLWithPath: arguments[offset + 1])
            continue
        }
        guard arguments[offset] == "--downstream-file" else { return 64 }
        // Reuse the no-follow opener, then validate a regular, owner-only command file.
        // The file is setup-owned opaque command configuration, not provider data.
        do {
            guard arguments[offset + 1].hasPrefix("/") else { return 64 }
            let handle = try ClaudeSnapshotFileOpener().openSnapshot(at: URL(fileURLWithPath: arguments[offset + 1]))
            defer { try? handle.close() }
            var metadata = stat()
            guard fstat(handle.fileDescriptor, &metadata) == 0,
                  ClaudeSnapshotFileOpener.hasSafeMetadata(metadata, effectiveUID: geteuid()),
                  metadata.st_mode & 0o777 == 0o600, metadata.st_size <= 8_192 else { return 64 }
            let data = try handle.read(upToCount: 8_193) ?? Data()
            guard data.count <= 8_192, let command = String(data: data, encoding: .utf8),
                  !command.isEmpty, !command.utf8.contains(0) else { return 64 }
            downstream = .userAuthoredShell(command)
        } catch { return 64 }
    }
    let bytes: Data
    do { bytes = try ClaudeBridgeInput.read(descriptor: STDIN_FILENO) }
    catch is CancellationError { return 130 }
    catch { return 3 }
    let result = ClaudeBridgeComposition.execute(
        originalBytes: bytes, bridge: .init(writer: .init(fileURL: snapshotURL)), downstream: downstream
    ) { try FileHandle.standardOutput.write(contentsOf: $0) }
    return result.exitCode
}

exit(runBridge())
