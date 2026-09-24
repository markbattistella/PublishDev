//
// Project: PublishDev
// Author: Mark Battistella
// Website: https://markbattistella.com
//

import Darwin
import Foundation
import Testing

@testable import PublishDev

@Test(.timeLimit(.minutes(1)))
func cancellationStopsDescendantsInTheirOwnProcessGroups() async throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let ready = folder.appendingPathComponent("child.pid")
    let (changes, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    defer { continuation.finish() }
    let child = try await withThrowingTaskGroup(of: pid_t?.self) { group in
        defer { group.cancelAll() }
        group.addTask {
            _ = try await ChildProcess.run(
                ["/bin/bash", "-c", "set -m; /bin/sleep 120 & echo $!; wait"],
                in: folder, stdout: ready)
            return nil
        }
        group.addTask {
            try await InputWatcher(paths: [ready]).run(changes: continuation)
            return nil
        }
        group.addTask {
            for await _ in changes {
                if let text = try? String(contentsOf: ready, encoding: .utf8),
                    let first = text.split(separator: "\n").first,
                    let pid = pid_t(first)
                {
                    return pid
                }
            }
            return nil
        }
        let child = try #require(try await group.next() ?? nil)
        #expect(getpgid(child) == child)
        group.cancelAll()
        while !group.isEmpty { _ = await group.nextResult() }
        return child
    }
    #expect(kill(child, 0) == -1 && errno == ESRCH)
}

private func temporaryFolder() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
        "PublishDev-test-\(UUID())")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func write(_ text: String, to path: String, in folder: URL) throws {
    let url = folder.appendingPathComponent(path)
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url, options: .atomic)
}

@Test func detectsSafeSavesRenamesDeletionsAndAdditionalInputs() throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    try write("one", to: "Content/page.md", in: folder)
    try write("one", to: "metadata.json", in: folder)
    let watcher = InputWatcher(paths: [folder])
    let initial = try watcher.scan()
    try write("noise", to: "Output/index.html", in: folder)
    try write("noise", to: ".build/file", in: folder)
    try write("noise", to: ".publish/Caches/file", in: folder)
    #expect(try watcher.scan() == initial)
    try write("two", to: "Content/page.md", in: folder)
    let edited = try watcher.scan()
    #expect(edited != initial)
    try FileManager.default.moveItem(
        at: folder.appendingPathComponent("Content/page.md"),
        to: folder.appendingPathComponent("Content/renamed.md"))
    let renamed = try watcher.scan()
    #expect(renamed != edited)
    try FileManager.default.removeItem(at: folder.appendingPathComponent("Content/renamed.md"))
    let deleted = try watcher.scan()
    #expect(deleted != renamed)
    try write("two", to: "metadata.json", in: folder)
    #expect(try watcher.scan() != deleted)
}

@Test func resolvesWatchPathsAgainstSiteRegardlessOfArgumentOrder() throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    try write("", to: "website/Package.swift", in: folder)
    let options = try Options(
        arguments: ["--watch", "../metadata.json", "--site", "website", "--port", "9000"],
        directory: folder)
    #expect(
        options.site.path == folder.appendingPathComponent("website").resolvingSymlinksInPath().path
    )
    #expect(
        options.extraPaths.map(\.path) == [
            folder.appendingPathComponent("metadata.json").resolvingSymlinksInPath().path
        ])
    #expect(options.port == 9000)
    #expect(throws: DevError.self) { try Options(arguments: ["--port", "0"], directory: folder) }
    #expect(throws: DevError.self) {
        try Options(arguments: ["--site", "website", "--watch", "Output"], directory: folder)
    }
    #expect(throws: DevError.self) { try Options(arguments: ["--site"], directory: folder) }
}

@Test func runsChildrenWithLiteralArgumentsAndReportsFailure() async throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let output = folder.appendingPathComponent("output with spaces.txt")
    let literal = "$(not-a-command) `also-not-a-command` with spaces"
    let status = try await ChildProcess.run(["printf", "%s", literal], in: folder, stdout: output)
    #expect(status == 0)
    #expect(try String(contentsOf: output, encoding: .utf8) == literal)
    #expect(try await ChildProcess.run(["false"], in: folder) == 1)
}

private func makePreview() throws -> (preview: Preview, base: URL, output: URL) {
    let folder = try temporaryFolder()
    let output = folder.appendingPathComponent("Output")
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    return (try Preview(base: folder.appendingPathComponent("preview")), folder, output)
}

private func read(_ path: String, in folder: URL) throws -> String {
    try String(contentsOf: folder.appendingPathComponent(path), encoding: .utf8)
}

@Test func stagesPagesWithoutModifyingOutput() throws {
    let (preview, folder, output) = try makePreview()
    defer { try? FileManager.default.removeItem(at: folder) }

    let waiting = try read("index.html", in: preview.live)
    #expect(waiting.contains("Waiting for a successful build"))
    #expect(waiting.contains("/\(Preview.reloadPath)?revision="))
    #expect(try read(Preview.reloadPath, in: preview.live).contains("location.reload"))

    let original = "<html><body>First version</body></html>"
    try write(original, to: "index.html", in: output)
    try write("body {}", to: "assets/main.css", in: output)
    #expect(try preview.publish(output: output) == 1)

    let staged = try read("index.html", in: preview.live)
    let revision = try read(Preview.revisionPath, in: preview.live)
    #expect(staged.contains("First version"))
    #expect(staged.contains("<script src=\"/\(Preview.reloadPath)?revision=\(revision)\" defer>"))
    #expect(staged.contains("</script></body></html>"))  // The script sits inside the body.
    #expect(try read("assets/main.css", in: preview.live) == "body {}")
    #expect(try read("index.html", in: output) == original)
}

@Test func keepsTheLastSuccessfulPreviewWhenABuildIsInvalid() throws {
    let (preview, folder, output) = try makePreview()
    defer { try? FileManager.default.removeItem(at: folder) }
    try write("<html><body>First version</body></html>", to: "index.html", in: output)
    try write("Guide", to: "help/index.html", in: output)
    try preview.publish(output: output)
    let first = try read(Preview.revisionPath, in: preview.live)

    try FileManager.default.removeItem(at: output.appendingPathComponent("index.html"))
    #expect(throws: DevError.self) { try preview.publish(output: output) }
    #expect(try read("index.html", in: preview.live).contains("First version"))
    #expect(try read(Preview.revisionPath, in: preview.live) == first)

    try write("<html><body>Recovered</body></html>", to: "index.html", in: output)
    try FileManager.default.removeItem(at: output.appendingPathComponent("help"))
    try preview.publish(output: output)
    #expect(try read("index.html", in: preview.live).contains("Recovered"))
    #expect(try read(Preview.revisionPath, in: preview.live) != first)
    #expect(
        FileManager.default.fileExists(
            atPath: preview.live.appendingPathComponent("help/index.html").path) == false)
}

@Test func rejectsOutputSymlinks() throws {
    let (preview, folder, output) = try makePreview()
    defer { try? FileManager.default.removeItem(at: folder) }
    try write("<html><body>Home</body></html>", to: "index.html", in: output)
    try FileManager.default.createSymbolicLink(
        at: output.appendingPathComponent("secret"),
        withDestinationURL: URL(fileURLWithPath: "/etc/passwd"))
    #expect(throws: DevError.self) { try preview.publish(output: output) }
    #expect(try read("index.html", in: preview.live).contains("Waiting for a successful build"))
}

@Test(.timeLimit(.minutes(1)))
func servesTheStagedWebsiteWithPython() async throws {
    let (preview, folder, output) = try makePreview()
    defer { try? FileManager.default.removeItem(at: folder) }
    try write("<html><body>First version</body></html>", to: "index.html", in: output)
    try write("<html><body>Guide</body></html>", to: "help/index.html", in: output)
    try write("body {}", to: "assets/main.css", in: output)
    try preview.publish(output: output)

    try await withPreviewServer(preview, in: folder) { port in
        // Keep normal HTTP caching enabled: the server must prevent stale previews itself.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = URLCache(memoryCapacity: 1_048_576, diskCapacity: 0)
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        func get(_ path: String) async throws -> (String, HTTPURLResponse) {
            let url = try #require(URL(string: "http://127.0.0.1:\(port)\(path)"))
            let (data, response) = try await session.data(from: url)
            let http = try #require(response as? HTTPURLResponse)
            #expect(http.value(forHTTPHeaderField: "Cache-Control") == "no-store")
            return (String(decoding: data, as: UTF8.self), http)
        }

        let (revision, revisionResponse) = try await get("/\(Preview.revisionPath)")
        try #require(revisionResponse.statusCode == 200)
        try #require(!revision.isEmpty)
        #expect(throws: DevError.self) { try PreviewServer.checkPort(port) }
        await #expect(throws: DevError.self) {
            try await PreviewServer.waitUntilListening(
                port: port, log: folder.appendingPathComponent("another-server.log"),
                timeout: .milliseconds(75))
        }

        let (home, homeResponse) = try await get("/")
        #expect(homeResponse.statusCode == 200)
        #expect(home.contains("First version"))
        #expect(home.contains("/\(Preview.reloadPath)?revision=\(revision)"))
        let (guide, _) = try await get("/help/")
        #expect(guide.contains("Guide"))
        let (css, cssResponse) = try await get("/assets/main.css")
        #expect(css == "body {}")
        #expect(cssResponse.value(forHTTPHeaderField: "Content-Type") == "text/css")
        let (script, _) = try await get("/\(Preview.reloadPath)")
        #expect(script.contains("location.reload"))

        var previousRevision = revision
        for version in ["Second", "Third", "Fourth"] {
            try write("<html><body>\(version) version</body></html>", to: "index.html", in: output)
            try write("/* \(version) */", to: "assets/main.css", in: output)
            try preview.publish(output: output)
            let (updated, _) = try await get("/")
            let (next, _) = try await get("/\(Preview.revisionPath)")
            let (updatedCSS, _) = try await get("/assets/main.css")
            #expect(updated.contains("\(version) version"))
            #expect(next != previousRevision)
            #expect(updated.contains("/\(Preview.reloadPath)?revision=\(next)"))
            #expect(updatedCSS == "/* \(version) */")
            previousRevision = next
        }
        let (_, missingResponse) = try await get("/missing.html")
        #expect(missingResponse.statusCode == 404)
    }
}

/// Race the HTTP checks against server failure, so an exited Python process cannot be hidden
/// behind a readiness timeout. Always cancel and reap the server before removing its fixtures.
private func withPreviewServer(
    _ preview: Preview, in folder: URL,
    runServer: @escaping @Sendable (URL, UInt16, URL) async throws -> Void = {
        try await PreviewServer.run(directory: $0, port: $1, log: $2)
    },
    check: @escaping @Sendable (UInt16) async throws -> Void
) async throws {
    // Let the OS choose and bind a port, avoiding a check-then-bind race between parallel tests.
    let port: UInt16 = 0
    let serverLog = folder.appendingPathComponent("server.log")
    do {
        try await withThrowingTaskGroup(of: Void.self) { group in
            defer { group.cancelAll() }
            group.addTask {
                try await runServer(preview.live, port, serverLog)
            }
            group.addTask {
                try await PreviewServer.waitUntilListening(port: port, log: serverLog)
                let boundPort = try #require(
                    UInt16(
                        String(
                            contentsOf: serverLog.appendingPathExtension("ready"), encoding: .utf8))
                )
                try #require(boundPort > 0)
                try await check(boundPort)
            }
            try await group.next()
        }
    } catch {
        if let output = try? String(contentsOf: serverLog, encoding: .utf8) {
            print("Preview server log:\n\(output)")
        }
        throw error
    }
}

@Test(.timeLimit(.minutes(1)))
func previewStartsWithoutDNSResolution() async throws {
    let (preview, folder, _) = try makePreview()
    defer { try? FileManager.default.removeItem(at: folder) }
    try await withPreviewServer(
        preview, in: folder,
        runServer: { directory, port, log in
            let noDNS = """
                import socket
                def unavailable_dns(*args, **kwargs):
                    raise RuntimeError("Preview startup must not require DNS")
                socket.getfqdn = unavailable_dns
                socket.gethostbyaddr = unavailable_dns

                """
            let status = try await ChildProcess.run(
                [
                    "python3", "-u", "-c", noDNS + PreviewServer.serverScript,
                    String(getpid()), String(port), directory.path,
                    log.appendingPathExtension("ready").path,
                ], in: directory, stdout: log, stderr: log)
            throw DevError(
                "Preview server exited before the DNS-independent check (exit \(status)).")
        },
        check: { port in
            let url = try #require(URL(string: "http://127.0.0.1:\(port)/"))
            let session = URLSession(configuration: .ephemeral)
            defer { session.invalidateAndCancel() }
            let (data, response) = try await session.data(from: url)
            #expect((response as? HTTPURLResponse)?.statusCode == 200)
            #expect(
                String(decoding: data, as: UTF8.self).contains("Waiting for a successful build"))
        })
}

@Test func staleSessionMetadataDoesNotBlockRestart() async throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let path = folder.appendingPathComponent("session.lock").path
    try Data("stale metadata".utf8).write(to: URL(fileURLWithPath: path))
    #expect(chmod(path, 0o600) == 0)
    let lock = try SessionLock(path: path)
    try await lock.acquire(for: .site(folder.path))
    try lock.write(
        .init(process: try #require(ProcessIdentity(getpid())), site: folder.path, port: 8000))
    withExtendedLifetime(lock) {}
}

@Test func rejectsSessionLockSymlinksWithoutModifyingTheirTarget() throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let target = folder.appendingPathComponent("target")
    let link = folder.appendingPathComponent("session.lock")
    try Data("keep me".utf8).write(to: target)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    #expect(throws: DevError.self) { try SessionLock(path: link.path) }
    #expect(try String(contentsOf: target, encoding: .utf8) == "keep me")
}
