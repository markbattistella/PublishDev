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
        let siteID = Self.siteID(options.site.path)
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(
            "publish-dev-\(getuid())-\(siteID)")

        // Prevent two sessions from generating the same Output concurrently.
        let lock = open(base.path + ".lock", O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard lock >= 0 else { throw DevError("Could not open the development session lock.") }
        defer { close(lock) }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else {
            throw DevError("PublishDev is already watching this website. Stop that session first.")
        }
        guard fcntl(lock, F_SETFD, FD_CLOEXEC) == 0 else {
            throw DevError("Could not configure the development session lock.")
        }

        try PreviewServer.checkPort(options.port)
        let preview = try Preview(base: base)
        defer { try? FileManager.default.removeItem(at: base) }

        let (changes, continuation) = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1))
        defer { continuation.finish() }
        let stop = Self.stopEvents()
        defer { for source in stop.sources { source.cancel() } }

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await PreviewServer.run(
                    directory: preview.live, port: options.port,
                    log: base.appendingPathComponent("server.log"))
            }
            group.addTask {
                try await PreviewServer.waitUntilListening(port: options.port)
                log("Preview: http://localhost:\(options.port)")
                log("Website: \(options.site.path)")
                log("Watching inputs. Press ENTER to stop the server and exit.")
                try await InputWatcher(paths: options.inputs).run(changes: continuation)
            }
            group.addTask {
                for await _ in changes {
                    try Task.checkCancellation()
                    let started = ContinuousClock.now
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
            group.addTask {
                for await _ in stop.stream { break }
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
        log("PublishDev stopped.")
    }

    /// ENTER, Control-D, Control-C, or SIGTERM all end the session.
    private static func stopEvents() -> (
        stream: AsyncStream<Void>, sources: [any DispatchSourceSignal]
    ) {
        let (stream, continuation) = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1))
        let sources = [SIGINT, SIGTERM].map { number in
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler { continuation.yield(()) }
            source.resume()
            return source
        }
        // Without a terminal there is no ENTER to wait for, and readLine would return immediately.
        if isatty(STDIN_FILENO) == 1 {
            DispatchQueue.global(qos: .background).async {
                _ = readLine()
                continuation.yield(())
            }
        }
        return (stream, sources)
    }

    private static func siteID(_ path: String) -> String {
        // A stable filename; do not use Swift's randomly seeded Hasher for a process lock.
        SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
