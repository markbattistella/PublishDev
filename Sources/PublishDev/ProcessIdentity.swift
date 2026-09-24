//
// Project: PublishDev
// Author: Mark Battistella
// Website: https://markbattistella.com
//

import Darwin
import Foundation

/// A PID alone is insufficient: macOS can reuse it after a process exits.
struct ProcessIdentity: Codable, Equatable, Sendable {
    let pid: pid_t
    let seconds: UInt64
    let microseconds: UInt64
    let user: uid_t

    init?(_ pid: pid_t) {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        self.pid = pid
        seconds = info.pbi_start_tvsec
        microseconds = info.pbi_start_tvusec
        user = info.pbi_uid
    }

    var isRunning: Bool { ProcessIdentity(pid) == self }

    var executable: String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(
            decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    @discardableResult
    func send(_ signal: Int32) -> Bool {
        guard isRunning else { return false }
        return kill(pid, signal) == 0
    }
}
