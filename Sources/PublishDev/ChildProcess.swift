// PublishDev — Created by Mark Battistella

import Darwin
import Foundation

enum ChildProcess {
    /// Own the build's process group and clean up descendants that create their own groups.
    static func run(
        _ arguments: [String], in directory: URL, stdout: URL? = nil, stderr: URL? = nil
    ) async throws -> Int32 {
        try Task.checkCancellation()
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        try check(posix_spawn_file_actions_init(&actions))
        defer { posix_spawn_file_actions_destroy(&actions) }
        try check(posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }

        try check(posix_spawn_file_actions_addchdir_np(&actions, directory.path))
        try check(
            posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0))
        if let stdout {
            try check(
                posix_spawn_file_actions_addopen(
                    &actions, STDOUT_FILENO, stdout.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600))
        }
        if let stderr {
            try check(
                posix_spawn_file_actions_addopen(
                    &actions, STDERR_FILENO, stderr.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600))
        }
        var defaults = sigset_t()
        sigemptyset(&defaults)
        sigaddset(&defaults, SIGINT)
        sigaddset(&defaults, SIGTERM)
        var mask = sigset_t()
        sigemptyset(&mask)
        try check(posix_spawnattr_setsigdefault(&attributes, &defaults))
        try check(posix_spawnattr_setsigmask(&attributes, &mask))
        try check(posix_spawnattr_setpgroup(&attributes, 0))
        try check(
            posix_spawnattr_setflags(
                &attributes,
                Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK)))

        let argv = (["/usr/bin/env"] + arguments).map { strdup($0) } + [nil]
        let env =
            ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            for pointer in argv { free(pointer) }
            for pointer in env { free(pointer) }
        }
        var pid: pid_t = 0
        try argv.withUnsafeBufferPointer { args in
            try env.withUnsafeBufferPointer { environment in
                try check(
                    posix_spawn(
                        &pid, "/usr/bin/env", &actions, &attributes, args.baseAddress!,
                        environment.baseAddress!))
            }
        }

        do {
            while true {
                try Task.checkCancellation()
                if let status = try reap(pid) { return status }
                try await Task.sleep(for: .milliseconds(50))
            }
        } catch {
            let descendants = descendants(of: pid)
            for descendant in descendants { descendant.send(SIGTERM) }
            kill(-pid, SIGTERM)
            // Await shielded cleanup: the calling task is already cancelled.
            let childPID = pid
            await Task.detached {
                try? await Task.sleep(for: .milliseconds(500))
                for descendant in descendants { descendant.send(SIGKILL) }
                kill(-childPID, SIGKILL)
                var status: Int32 = 0
                while waitpid(childPID, &status, 0) == -1 && errno == EINTR {}
            }.value
            throw error
        }
    }

    private struct Identity: Equatable, Sendable {
        let pid: pid_t
        let seconds: UInt64
        let microseconds: UInt64

        init?(_ pid: pid_t) {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
            self.pid = pid
            seconds = info.pbi_start_tvsec
            microseconds = info.pbi_start_tvusec
        }

        func send(_ signal: Int32) {
            // A descendant can exit and have its PID reused during the grace period.
            if Identity(pid) == self { kill(pid, signal) }
        }
    }

    private static func descendants(of pid: pid_t) -> [Identity] {
        let capacity = max(16, Int(proc_listchildpids(pid, nil, 0)) + 16)
        var children = [pid_t](repeating: 0, count: capacity)
        let count = children.withUnsafeMutableBytes { buffer in
            proc_listchildpids(pid, buffer.baseAddress, Int32(buffer.count))
        }
        return children.prefix(max(0, Int(count))).filter { $0 > 0 }.flatMap { child in
            descendants(of: child) + [Identity(child)].compactMap { $0 }
        }
    }

    private static func reap(_ pid: pid_t) throws -> Int32? {
        var status: Int32 = 0
        let result = waitpid(pid, &status, WNOHANG)
        if result == 0 || (result == -1 && errno == EINTR) { return nil }
        guard result == pid else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ECHILD) }
        let signal = status & 0x7f
        return signal == 0 ? (status >> 8) & 0xff : 128 + signal
    }

    private static func check(_ code: Int32) throws {
        guard code == 0 else { throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EINVAL) }
    }

    static func executable(in site: URL, requested: String?) async throws -> String {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(
            "publish-dev-manifest-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: output) }
        let status = try await run(["swift", "package", "dump-package"], in: site, stdout: output)
        guard status == 0 else { throw DevError("Could not read Package.swift (exit \(status)).") }

        struct Manifest: Decodable {
            struct Product: Decodable {
                let name: String
                let type: [String: [String]?]
            }
            let products: [Product]
        }
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: output))
        let executables = manifest.products.filter { $0.type.keys.contains("executable") }.map(
            \.name)
        if let requested, executables.contains(requested) { return requested }
        if requested == nil, executables.count == 1 { return executables[0] }
        throw DevError(
            "Choose an executable with --product. Available: \(executables.joined(separator: ", "))."
        )
    }
}
