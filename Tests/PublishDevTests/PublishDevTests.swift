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

    let port = try #require(
        (8730...8780).first { port in
            (try? PreviewServer.checkPort(UInt16(port))) != nil
        }.map(UInt16.init))

    try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask {
            try await PreviewServer.run(
                directory: preview.live, port: port,
                log: folder.appendingPathComponent("server.log"))
        }
        defer { group.cancelAll() }

        let session = URLSession(configuration: .ephemeral)
        func get(_ path: String) async throws -> (String, HTTPURLResponse) {
            let url = try #require(URL(string: "http://127.0.0.1:\(port)\(path)"))
            let (data, response) = try await session.data(from: url)
            return (
                String(decoding: data, as: UTF8.self), try #require(response as? HTTPURLResponse)
            )
        }

        var revision = ""
        for _ in 0..<100 {
            if let (body, response) = try? await get("/\(Preview.revisionPath)"),
                response.statusCode == 200
            {
                revision = body
                break
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(!revision.isEmpty)
        #expect(throws: DevError.self) { try PreviewServer.checkPort(port) }

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

        try write("<html><body>Second version</body></html>", to: "index.html", in: output)
        try preview.publish(output: output)
        let (updated, _) = try await get("/")
        let (next, _) = try await get("/\(Preview.revisionPath)")
        #expect(updated.contains("Second version"))
        #expect(next != revision)

        group.cancelAll()
        while !group.isEmpty { _ = await group.nextResult() }
    }
}
