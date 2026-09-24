//
// Project: PublishDev
// Author: Mark Battistella
// Website: https://markbattistella.com
//

import Darwin
import Foundation

/// Covers startup questions, update builds, and preview sessions with the same cleanup path.
enum SignalMonitor {
    static func run(_ operation: @escaping @Sendable () async throws -> Void) async throws {
        let (stream, continuation) = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1))
        signal(SIGPIPE, SIG_IGN)
        let sources = [SIGINT, SIGTERM, SIGHUP].map { number in
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler { continuation.yield(()) }
            source.resume()
            return source
        }
        defer {
            continuation.finish()
            for source in sources { source.cancel() }
        }
        try await withThrowingTaskGroup(of: Bool.self) { group in
            defer { group.cancelAll() }
            group.addTask {
                try await operation()
                return true
            }
            group.addTask {
                for await _ in stream { break }
                return false
            }
            if try await group.next() == false {
                log("Stopping PublishDev…")
                group.cancelAll()
                while !group.isEmpty { _ = await group.nextResult() }
                log("PublishDev stopped.")
            }
        }
    }
}
