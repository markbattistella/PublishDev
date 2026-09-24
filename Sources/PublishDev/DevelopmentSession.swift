//
// Project: PublishDev
// Author: Mark Battistella
// Website: https://markbattistella.com
//

import CryptoKit
import Darwin
import Foundation

struct DevelopmentSession {
    let options: Options

    func run() async throws {
        try await runSession()
        log("PublishDev stopped.")
    }

    private func runSession() async throws {
        let siteID = Self.siteID(options.site.path)
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(
            "publish-dev-\(getuid())-\(siteID)")
        guard let process = ProcessIdentity(getpid()) else {
            throw DevError("Could not identify this development session.")
        }
        let siteLock = try SessionLock(path: base.path + ".lock")
        try await siteLock.acquire(for: .site(options.site.path))
        try siteLock.write(.init(process: process, site: options.site.path, port: options.port))
        let (port, portLock) = try await reservePort(process: process)
        // Keep both locks until all server and build cleanup has completed.
        defer { withExtendedLifetime((siteLock, portLock)) {} }
        try siteLock.write(.init(process: process, site: options.site.path, port: port))
        let serverLog = base.appendingPathComponent("server.log")
        let preview = try Preview(base: base)
        defer { try? FileManager.default.removeItem(at: base) }

        let (changes, continuation) = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1))
        defer { continuation.finish() }
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await PreviewServer.run(
                    directory: preview.live, port: port, log: serverLog)
            }
            group.addTask {
                try await PreviewServer.waitUntilListening(port: port, log: serverLog)
                log("Preview: http://localhost:\(port)")
                log("Website: \(options.site.path)")
                TerminalInput.showStopHint()
                try await InputWatcher(paths: options.inputs).run(changes: continuation)
            }
            group.addTask {
                for await _ in changes {
                    try Task.checkCancellation()
                    let started = ContinuousClock.now
                    defer { if !Task.isCancelled { TerminalInput.showStopHint() } }
                    do {
                        let product = try await ChildProcess.executable(
                            in: options.site, requested: options.product)
                        log("Building \(product)…")
                        let status = try await ChildProcess.run(
                            ["swift", "run", product], in: options.site)
                        try Task.checkCancellation()
                        guard status == 0 else {
                            log(
                                "Build failed (exit \(status)). Keeping the previous preview; save an input to retry."
                            )
                            continue
                        }
                        let pages = try preview.publish(
                            output: options.site.appendingPathComponent("Output"))
                        log(
                            "Preview updated in \(started.duration(to: .now)) (\(pages) pages)."
                        )
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        log(
                            "Build failed: \(error.localizedDescription) Keeping the previous preview; save an input to retry."
                        )
                    }
                }
            }
            if TerminalInput.isInteractive {
                group.addTask { _ = try await TerminalInput.line() }
            }
            do {
                try await group.next()
            } catch {
                group.cancelAll()
                throw error
            }
            group.cancelAll()
            // Cancellation during normal shutdown is expected.
            while !group.isEmpty { _ = await group.nextResult() }
        }
    }

    private func reservePort(process: ProcessIdentity) async throws -> (UInt16, SessionLock) {
        var port = options.port
        while true {
            try Task.checkCancellation()
            let path = FileManager.default.temporaryDirectory.appendingPathComponent(
                "publish-dev-\(getuid())-port-\(port).lock"
            ).path
            let lock = try SessionLock(path: path)
            try await lock.acquire(for: .port(port))
            do {
                try PreviewServer.checkPort(port)
            } catch let error as DevError {
                guard TerminalInput.isInteractive,
                    let alternative = try PreviewServer.availablePort(after: port)
                else { throw error }
                log(error.localizedDescription)
                guard try await TerminalInput.confirm("Use port \(alternative) instead?") else {
                    throw CancellationError()
                }
                port = alternative
                continue
            }
            try lock.write(.init(process: process, site: options.site.path, port: port))
            return (port, lock)
        }
    }

    private static func siteID(_ path: String) -> String {
        // A stable filename; do not use Swift's randomly seeded Hasher for a process lock.
        SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
