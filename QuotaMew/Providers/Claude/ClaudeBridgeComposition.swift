import Foundation
import Darwin

enum ClaudeBridgeComposition {
    static let downstreamTimeout: TimeInterval = 2
    static let maximumOutputBytes = 65_536

    static func execute(
        originalBytes: Data, bridge: ClaudePassiveBridge,
        downstream: ClaudeBridgeDownstreamCommand?, clock: () -> Date = Date.init,
        output: (Data) throws -> Void
    ) -> ClaudeBridgeExecutionResult {
        let capture = bridge.capture(originalBytes, clock: clock)
        guard let downstream else { return .init(capture: capture, downstream: nil) }
        // Even malformed/invalid quota JSON goes to the renderer unchanged, provided the
        // input boundary successfully received the entire bounded event.
        let result = render(originalBytes, command: downstream, output: output)
        return .init(capture: capture, downstream: result)
    }

    static func render(
        _ bytes: Data, command: ClaudeBridgeDownstreamCommand,
        duration: TimeInterval = downstreamTimeout, spawned: (pid_t) -> Void = { _ in },
        output: (Data) throws -> Void
    ) -> ClaudeBridgeDownstreamResult {
        if Task.isCancelled { return .cancelled }
        guard bytes.count <= ClaudeBridgeInput.maximumBytes else { return .ioFailed }
        var input: [Int32] = [0, 0]
        var stdout: [Int32] = [0, 0]
        guard pipe(&input) == 0 else { return .launchFailed }
        defer { for fd in input where fd >= 0 { Darwin.close(fd) } }
        guard pipe(&stdout) == 0 else { return .launchFailed }
        defer { for fd in stdout where fd >= 0 { Darwin.close(fd) } }
        let null = open("/dev/null", O_WRONLY | O_CLOEXEC)
        guard null >= 0 else { return .launchFailed }
        defer { Darwin.close(null) }
        for fd in input + stdout { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { return .launchFailed }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_init(&attributes) == 0 else { return .launchFailed }
        defer { posix_spawnattr_destroy(&attributes) }
        guard posix_spawn_file_actions_adddup2(&actions, input[0], STDIN_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&actions, stdout[1], STDOUT_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&actions, null, STDERR_FILENO) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0,
              posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0 else {
            return .launchFailed
        }
        let argv = ([command.executable.path] + command.arguments).map { strdup($0) }
        defer { argv.forEach { free($0) } }
        var arguments = argv + [nil]
        var pid: pid_t = 0
        guard posix_spawn(&pid, command.executable.path, &actions, &attributes, &arguments, environ) == 0 else {
            return .launchFailed
        }
        Darwin.close(input[0]); input[0] = -1
        Darwin.close(stdout[1]); stdout[1] = -1
        _ = fcntl(input[1], F_SETFL, O_NONBLOCK)
        _ = fcntl(stdout[0], F_SETFL, O_NONBLOCK)
        // F_SETNOSIGPIPE avoids changing the hosting app's global signal disposition.
        _ = fcntl(input[1], F_SETNOSIGPIPE, 1)
        var status: Int32 = 0
        var reaped = false
        defer {
            // Terminate the dedicated group too: a shell may have left descendants with
            // inherited pipes. This group belongs solely to this one invocation.
            _ = kill(-pid, SIGKILL)
            if !reaped {
                _ = kill(pid, SIGKILL)
                while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
            }
        }
        spawned(pid)
        let deadline = ProcessInfo.processInfo.systemUptime + min(max(duration, 0), downstreamTimeout)
        var offset = 0
        var totalOutput = 0
        var eof = false
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            if Task.isCancelled { return .cancelled }
            if !reaped {
                let waited = waitpid(pid, &status, WNOHANG)
                if waited == pid { reaped = true }
                else if waited < 0 && errno != EINTR { return .ioFailed }
            }
            if reaped && eof {
                let signal = status & 0x7f
                return .exited(signal == 0 ? (status >> 8) & 0xff : 128 + signal)
            }
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { return .timedOut }
            if offset == bytes.count && input[1] >= 0 {
                Darwin.close(input[1]); input[1] = -1
            }
            var items = [pollfd(fd: input[1], events: Int16(POLLOUT), revents: 0),
                         pollfd(fd: eof ? -1 : stdout[0], events: Int16(POLLIN), revents: 0)]
            let ready = poll(&items, 2, Int32(min(remaining * 1_000, 50)))
            if ready < 0 && errno == EINTR { continue }
            guard ready >= 0 else { return .ioFailed }
            if input[1] >= 0 && items[0].revents != 0 {
                let count = bytes.withUnsafeBytes {
                    Darwin.write(input[1], $0.baseAddress!.advanced(by: offset), bytes.count - offset)
                }
                if count > 0 { offset += count }
                else if count < 0 && errno != EAGAIN && errno != EINTR {
                    // A renderer can intentionally exit without consuming all stdin.
                    Darwin.close(input[1]); input[1] = -1
                }
            }
            if !eof && items[1].revents != 0 {
                let count = Darwin.read(stdout[0], &buffer, buffer.count)
                if count == 0 { eof = true }
                else if count > 0 {
                    totalOutput += count
                    guard totalOutput <= maximumOutputBytes else { return .outputTooLarge }
                    do { try output(Data(buffer.prefix(count))) } catch { return .ioFailed }
                } else if errno != EAGAIN && errno != EINTR { return .ioFailed }
            }
        }
    }
}
