// PublishDev — Created by Mark Battistella

import Darwin
import Foundation

/// The local web server, using the same Python module that `publish run` starts.
enum PreviewServer {
    /// Serves `directory` until the task is cancelled; returns only if Python stops on its own.
    ///
    /// The server logs every request, and the reload client polls several times a second, so its
    /// output goes to `log` instead of the terminal. That log is only surfaced if Python stops.
    static func run(directory: URL, port: UInt16, log: URL) async throws {
        let status = try await ChildProcess.run(
            [
                "python3", "-m", "http.server", String(port),
                "--bind", "127.0.0.1", "--directory", directory.path,
            ], in: directory, stdout: log, stderr: log)
        guard status != 127 else {
            throw DevError(
                "python3 was not found on your PATH. The local preview server needs Python 3, the same as `publish run`."
            )
        }
        let reason =
            (try? String(contentsOf: log, encoding: .utf8))?
            .split(separator: "\n").suffix(5).joined(separator: " ") ?? ""
        throw DevError(
            "The preview server stopped unexpectedly (exit \(status)). \(reason)"
                .trimmingCharacters(in: .whitespaces))
    }

    /// Waits for Python to accept connections, so the printed address works when it appears.
    static func waitUntilListening(port: UInt16) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            if connects(to: port) { return }
            try await Task.sleep(for: .milliseconds(25))
        }
    }

    private static func connects(to port: UInt16) -> Bool {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        } == 0
    }

    /// Reports an occupied port before Python prints a traceback about it.
    static func checkPort(_ port: UInt16) throws {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        // Python's server sets the same option, so this mirrors the bind it will attempt.
        var reuse: Int32 = 1
        setsockopt(
            descriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            throw DevError(
                "Port \(port) is already in use. Another `publish dev` or `publish run` session may be running; use --port for a different one."
            )
        }
    }
}
