//
// Project: PublishDev
// Author: Mark Battistella
// Website: https://markbattistella.com
//

import Darwin
import Foundation

/// Persistent lock files coordinate both a website's output and a preview port.
/// Never unlink a lock file: waiters must continue locking the same inode.
final class SessionLock {
    struct Record: Codable, Equatable {
        let process: ProcessIdentity
        let site: String
        let port: UInt16
    }

    enum Resource {
        case site(String)
        case port(UInt16)

        func matches(_ record: Record) -> Bool {
            switch self {
            case .site(let site): record.site == site
            case .port(let port): record.port == port
            }
        }
    }

    private let descriptor: Int32
    private var ownsLock = false

    init(path: String) throws {
        descriptor = open(path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            throw DevError("Could not open the development session lock.")
        }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_uid == getuid(),
            info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o077 == 0, info.st_nlink == 1
        else {
            throw DevError("The development session lock has an unexpected owner or permissions.")
        }
    }

    deinit {
        if ownsLock { _ = ftruncate(descriptor, 0) }
        close(descriptor)
    }

    func acquire(for resource: Resource) async throws {
        if try takeLock() { return }
        // Another session may have taken the lock but not written its identity yet.
        var record = readRecord()
        for _ in 0..<10 where record == nil {
            try await Task.sleep(for: .milliseconds(50))
            if try takeLock() { return }
            record = readRecord()
        }
        guard let record, resource.matches(record), record.process.pid != getpid(),
            record.process.user == getuid(), record.process.isRunning,
            let executable = ProcessIdentity(getpid())?.executable,
            record.process.executable == executable
        else {
            throw DevError(
                "Another session holds the development lock. Its owner could not be verified; stop that session and retry."
            )
        }
        log(
            "PublishDev is already serving \(record.site) on port \(record.port) (PID \(record.process.pid))."
        )
        guard TerminalInput.isInteractive else {
            throw DevError(
                "Stop the existing session before restarting. Session replacement needs an interactive terminal."
            )
        }
        guard try await TerminalInput.confirm("Stop that session and restart here?") else {
            throw CancellationError()
        }
        try Task.checkCancellation()
        if try takeLock() { return }
        guard readRecord() == record, record.process.isRunning,
            record.process.executable == executable, record.process.send(SIGTERM)
        else {
            throw DevError(
                "The existing session changed or could not be stopped. Run the command again.")
        }
        log("Waiting for the existing session to stop…")
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            if try takeLock() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw DevError(
            "The existing session did not stop within 10 seconds. Stop it in its terminal and retry."
        )
    }

    func write(_ record: Record) throws {
        precondition(ownsLock)
        let data = try JSONEncoder().encode(record)
        let written = data.withUnsafeBytes { pwrite(descriptor, $0.baseAddress, $0.count, 0) }
        guard written == data.count, ftruncate(descriptor, off_t(data.count)) == 0 else {
            throw DevError("Could not save the development session identity.")
        }
    }

    private func takeLock() throws -> Bool {
        if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
            ownsLock = true
            return true
        }
        guard errno == EWOULDBLOCK else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return false
    }

    private func readRecord() -> Record? {
        var bytes = [UInt8](repeating: 0, count: 16_384)
        let count = pread(descriptor, &bytes, bytes.count, 0)
        guard count > 0, count < bytes.count else { return nil }
        return try? JSONDecoder().decode(Record.self, from: Data(bytes.prefix(count)))
    }
}
