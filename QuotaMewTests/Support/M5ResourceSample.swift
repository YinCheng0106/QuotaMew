import Darwin
import Foundation
import XCTest

/// Bounded process counters only. Never accepts provider values or raw errors.
struct M5ResourceSample {
    let residentBytes: UInt64
    let threads: Int
    let descriptors: Int
    let children: Int
    let cpuSeconds: Double

    static func capture() throws -> Self {
        var info = proc_taskinfo()
        let taskBytes = proc_pidinfo(getpid(), PROC_PIDTASKINFO, 0, &info,
                                     Int32(MemoryLayout<proc_taskinfo>.size))
        guard taskBytes == MemoryLayout<proc_taskinfo>.size else { throw ProbeError.unavailable }
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: 1024)
        let fdBytes = fds.withUnsafeMutableBytes {
            proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count))
        }
        guard fdBytes > 0, fdBytes < fds.count * MemoryLayout<proc_fdinfo>.size else {
            throw ProbeError.unavailable
        }
        var childPIDs = [pid_t](repeating: 0, count: 128)
        let childBytes = childPIDs.withUnsafeMutableBytes {
            proc_listchildpids(getpid(), $0.baseAddress, Int32($0.count))
        }
        guard childBytes >= 0 else { throw ProbeError.unavailable }
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { throw ProbeError.unavailable }
        let cpu = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
        return Self(residentBytes: info.pti_resident_size, threads: Int(info.pti_threadnum),
                    descriptors: Int(fdBytes) / MemoryLayout<proc_fdinfo>.size,
                    children: childPIDs.filter { $0 > 0 }.count, cpuSeconds: cpu)
    }

    func line(_ phase: String) -> String {
        "phase=\(phase) rss_bytes=\(residentBytes) fds=\(descriptors) threads=\(threads) children=\(children)"
    }

    static func report(_ lines: [String], in test: XCTestCase) {
        let report = lines.joined(separator: "\n")
        let attachment = XCTAttachment(string: report)
        attachment.name = "M5 bounded resource counters"
        attachment.lifetime = .keepAlways
        test.add(attachment)
        print(report)
    }

    private enum ProbeError: Error { case unavailable }
}
