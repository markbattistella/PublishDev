//
// Project: PublishDev
// Author: Mark Battistella
// Website: https://markbattistella.com
//

import Darwin
import Foundation

/// One reader is used for startup questions, then for stopping the running session.
enum TerminalInput {
    static var isInteractive: Bool { isatty(STDIN_FILENO) == 1 }

    static func confirm(_ question: String) async throws -> Bool {
        guard isInteractive else { return false }
        log(question + " [y/N]")
        let answer = try await line()?.trimmingCharacters(in: .whitespaces).lowercased()
        return answer == "y" || answer == "yes"
    }

    /// Poll without blocking a cooperative executor or leaving a readLine thread behind.
    static func line() async throws -> String? {
        var bytes: [UInt8] = []
        while true {
            try Task.checkCancellation()
            var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
            let result = poll(&descriptor, 1, 0)
            if result < 0 {
                if errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            if result > 0 {
                var byte: UInt8 = 0
                let count = read(STDIN_FILENO, &byte, 1)
                if count == 0 { return nil }
                if count < 0 {
                    if errno == EINTR || errno == EAGAIN { continue }
                    // A closed pseudo-terminal can report EIO instead of EOF.
                    if errno == EIO { return nil }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                if byte == 10 { return String(decoding: bytes, as: UTF8.self) }
                if bytes.count < 4096 { bytes.append(byte) }
            } else {
                try await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    static func showStopHint() {
        if isInteractive {
            log("Watching inputs. Press Return or Ctrl+C to stop the server and exit.")
        } else {
            log("Watching inputs. Send SIGINT or SIGTERM to stop the server and exit.")
        }
    }
}
