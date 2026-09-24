//
// Project: PublishDev
// Author: Mark Battistella
// Website: https://markbattistella.com
//

import Darwin
import Foundation

/// The local web server, using the same Python module that `publish run` starts.
enum PreviewServer {
    /// Serves `directory` until the task is cancelled; returns only if Python stops on its own.
    ///
    /// The server logs every request, and the reload client polls several times a second, so its
    /// output goes to `log` instead of the terminal. That log is only surfaced if Python stops.
    static func run(directory: URL, port: UInt16, log: URL) async throws {
        try? FileManager.default.removeItem(at: readyFile(for: log))
        defer { try? FileManager.default.removeItem(at: readyFile(for: log)) }
        let status = try await ChildProcess.run(
            [
                "python3", "-u", "-c", serverScript, String(getpid()), String(port),
                directory.path, readyFile(for: log).path,
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

    // The watchdog lives inside Python, so it still runs after PublishDev is force-killed.
    // getppid changes when the parent dies; no PID-only lookup or extra daemon is needed.
    private static let serverScript = """
        import functools, http.server, os, pathlib, sys, threading, time

        parent, port = int(sys.argv[1]), int(sys.argv[2])

        def watch_parent():
            while os.getppid() == parent:
                time.sleep(0.1)
            os._exit(0)

        if os.getppid() != parent:
            sys.exit(0)
        threading.Thread(target=watch_parent, daemon=True).start()

        class PreviewHandler(http.server.SimpleHTTPRequestHandler):
            def end_headers(self):
                # Every rebuild can replace the same URLs, including pages and assets.
                self.send_header("Cache-Control", "no-store")
                super().end_headers()

        handler = functools.partial(PreviewHandler, directory=sys.argv[3])
        with http.server.ThreadingHTTPServer(("127.0.0.1", port), handler) as server:
            pathlib.Path(sys.argv[4]).write_text("ready")
            server.serve_forever()
        """

    private static func readyFile(for log: URL) -> URL {
        log.appendingPathExtension("ready")
    }

    /// A successful bind by our own Python process proves readiness. Connecting to the port alone
    /// could mistake a competing process for our server if it wins the race after checkPort.
    static func waitUntilListening(
        port: UInt16, log: URL, timeout: Duration = .seconds(10)
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            if FileManager.default.fileExists(atPath: readyFile(for: log).path) { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw DevError("The preview server did not start on port \(port) within the expected time.")
    }

    static func availablePort(after port: UInt16) throws -> UInt16? {
        guard port < UInt16.max else { return nil }
        for candidate in (Int(port) + 1)...min(Int(port) + 100, Int(UInt16.max)) {
            do {
                try checkPort(UInt16(candidate))
                return UInt16(candidate)
            } catch is DevError {
                continue
            }
        }
        return nil
    }

    /// Reports an occupied port before Python prints a traceback about it.
    static func checkPort(_ port: UInt16) throws {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { close(descriptor) }
        // Python's server sets the same option, so this mirrors the bind it will attempt.
        var reuse: Int32 = 1
        guard
            setsockopt(
                descriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
                == 0
        else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
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
            guard errno == EADDRINUSE else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            throw DevError(
                "Port \(port) is already in use. Another `publish dev` or `publish run` session may be running; use --port for a different one."
            )
        }
    }
}
