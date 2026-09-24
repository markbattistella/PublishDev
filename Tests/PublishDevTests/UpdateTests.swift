//
// Project: PublishDev
// Author: Mark Battistella
// Website: https://markbattistella.com
//

import Darwin
import Foundation
import Testing

@testable import PublishDev

@Test(arguments: ["v1.2.3", "1.2.3", "v0.1.0", "10.20.30"])
func acceptsStableReleaseTags(_ tag: String) {
    #expect(ReleaseVersion(tag: tag) != nil)
}

@Test(arguments: [
    "v1.2", "v1.2.3-rc.1", "v1.2.3+build", "v01.2.3", "v1..3", "main", "-1.2.3", "1.2.3/evil",
    "1.2.3\n", "v١.2.3",
])
func rejectsUnstableOrUnsafeReleaseTags(_ tag: String) {
    #expect(ReleaseVersion(tag: tag) == nil)
}

@Test func comparesReleaseVersionsNumerically() throws {
    #expect(try #require(ReleaseVersion(tag: "v1.10.0")) > #require(ReleaseVersion(tag: "v1.9.9")))
    #expect(ReleaseVersion(tag: "v1.2.3") == ReleaseVersion(tag: "1.2.3"))
    #expect(try #require(ReleaseVersion(tag: "v2.0.0")) > #require(ReleaseVersion(tag: "v1.99.99")))
}

@Test func handlesMissingAndInvalidGitHubReleases() throws {
    #expect(try UpdateChecker.decode(Data(), status: 404) == nil)
    #expect(throws: DevError.self) { try UpdateChecker.decode(Data(), status: 403) }
    #expect(throws: DevError.self) { try UpdateChecker.decode(Data(), status: 429) }
    let valid = Data(#"{"tag_name":"v0.2.0","draft":false,"prerelease":false}"#.utf8)
    #expect(try UpdateChecker.decode(valid, status: 200)?.version == ReleaseVersion(tag: "v0.2.0"))
    let prerelease = Data(#"{"tag_name":"v0.2.0","draft":false,"prerelease":true}"#.utf8)
    #expect(throws: DevError.self) { try UpdateChecker.decode(prerelease, status: 200) }
    let malformed = Data(#"{"tag_name":"main","draft":false,"prerelease":false}"#.utf8)
    #expect(throws: DevError.self) { try UpdateChecker.decode(malformed, status: 200) }
}

private var nextRelease: GitHubRelease {
    let current = ReleaseVersion.current
    let version = ReleaseVersion(
        major: current.major, minor: current.minor, patch: current.patch + 1)
    return GitHubRelease(tag: "v\(version)", draft: false, prerelease: false)
}

private actor FetchCounter {
    private(set) var count = 0
    func fetch(fail: Bool = false) throws -> GitHubRelease? {
        count += 1
        if fail { throw URLError(.notConnectedToInternet) }
        return nextRelease
    }
}

@Test func automaticChecksAreDailyButManualChecksAlwaysFetch() async throws {
    let folder = try updateTestFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let counter = FetchCounter()
    let checker = UpdateChecker(cache: folder.appendingPathComponent("check.json")) {
        try await counter.fetch()
    }
    let now = Date()
    #expect(try await checker.latest(automatic: true, now: now) != nil)
    #expect(try await checker.latest(automatic: true, now: now.addingTimeInterval(60)) == nil)
    #expect(await counter.count == 1)
    #expect(try await checker.latest(automatic: false, now: now.addingTimeInterval(120)) != nil)
    #expect(await counter.count == 2)
    #expect(try await checker.latest(automatic: true, now: now.addingTimeInterval(86_521)) != nil)
    #expect(await counter.count == 3)
}

@Test func offlineFailuresAreThrottledAndCorruptCachesRecover() async throws {
    let folder = try updateTestFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let cache = folder.appendingPathComponent("check.json")
    try Data("broken".utf8).write(to: cache)
    let counter = FetchCounter()
    let checker = UpdateChecker(cache: cache) { try await counter.fetch(fail: true) }
    let now = Date()
    await #expect(throws: URLError.self) { try await checker.latest(automatic: true, now: now) }
    #expect(try await checker.latest(automatic: true, now: now.addingTimeInterval(60)) == nil)
    #expect(await counter.count == 1)
    await #expect(throws: URLError.self) { try await checker.latest(automatic: false, now: now) }
    #expect(await counter.count == 2)
}

private func updateTestFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
        "PublishDev update test \(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

private func writeExecutable(_ text: String, at url: URL) throws {
    try Data(text.utf8).write(to: url)
    guard chmod(url.path, 0o755) == 0 else { throw POSIXError(.EACCES) }
}

private func testInstallation(in folder: URL) throws -> UpdateInstallation {
    let bin = folder.appendingPathComponent("bin")
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    try writeExecutable(
        "#!/bin/sh\n# publish-dev-shim: 1\n", at: bin.appendingPathComponent("publish"))
    try writeExecutable(
        "#!/bin/sh\necho original-publish\n", at: bin.appendingPathComponent("publish-cli"))
    let target = bin.appendingPathComponent("publish-dev")
    try writeExecutable("#!/bin/sh\necho original-dev\n", at: target)
    return UpdateInstallation(executable: target)
}

private enum BuildOutcome: Sendable, CaseIterable {
    case success, downloadFailure, buildFailure, wrongVersion
}

@Test(arguments: BuildOutcome.allCases)
private func updatesOnlyAfterTheReleaseBuildAndVersionCheckSucceed(_ outcome: BuildOutcome)
    async throws
{
    let folder = try updateTestFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let installation = try testInstallation(in: folder)
    let original = try Data(contentsOf: installation.executable)
    let candidate = folder.appendingPathComponent("publish-dev")
    let version =
        outcome == .wrongVersion
        ? ReleaseVersion.current.description : nextRelease.version!.description
    try writeExecutable("#!/bin/sh\necho 'PublishDev \(version)'\n", at: candidate)
    let installer = UpdateInstaller { arguments, directory, output in
        // Simulate release download/build; verification and atomic installation run real commands.
        if arguments.first == "/usr/bin/git" {
            return outcome == .downloadFailure && arguments.contains("fetch") ? 1 : 0
        }
        if arguments.first == "swift" {
            if outcome == .buildFailure { return 1 }
            if let output { try Data((folder.path + "\n").utf8).write(to: output) }
            return 0
        }
        return try await ChildProcess.run(arguments, in: directory, stdout: output)
    }
    let release = nextRelease
    if outcome == .success {
        try await installer.install(release, at: installation)
        #expect(try Data(contentsOf: installation.executable) == Data(contentsOf: candidate))
        #expect(FileManager.default.isExecutableFile(atPath: installation.executable.path))
    } else {
        await #expect(throws: DevError.self) {
            try await installer.install(release, at: installation)
        }
        #expect(try Data(contentsOf: installation.executable) == original)
    }
    let bin = installation.executable.deletingLastPathComponent()
    #expect(
        try String(contentsOf: bin.appendingPathComponent("publish-cli"), encoding: .utf8)
            == "#!/bin/sh\necho original-publish\n")
    #expect(
        try String(contentsOf: bin.appendingPathComponent("publish"), encoding: .utf8)
            == "#!/bin/sh\n# publish-dev-shim: 1\n")
    #expect(
        try FileManager.default.contentsOfDirectory(atPath: bin.path).sorted() == [
            "publish", "publish-cli", "publish-dev",
        ])
}

@Test func failedAtomicInstallKeepsTheExistingExecutable() async throws {
    let folder = try updateTestFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let installation = try testInstallation(in: folder)
    let original = try Data(contentsOf: installation.executable)
    let status = try await ChildProcess.run(
        [
            "/bin/sh", "-c", UpdateInstaller.replaceScript, "test-update",
            folder.appendingPathComponent("missing-binary").path, installation.executable.path,
        ], in: folder, stderr: folder.appendingPathComponent("error.log"))
    #expect(status != 0)
    #expect(try Data(contentsOf: installation.executable) == original)
    #expect(
        try FileManager.default.contentsOfDirectory(
            atPath: installation.executable.deletingLastPathComponent().path
        ).count == 3)
}

@Test func refusesToUpdateUnmanagedCopies() throws {
    let folder = try updateTestFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let target = folder.appendingPathComponent("publish-dev")
    try writeExecutable("#!/bin/sh\n", at: target)
    #expect(throws: DevError.self) { try UpdateInstallation(executable: target).validate() }
}

@Test func updateCancellationAndConcurrentAttemptsKeepTheInstalledCopy() async throws {
    let folder = try updateTestFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let installation = try testInstallation(in: folder)
    let original = try Data(contentsOf: installation.executable)
    let (building, continuation) = AsyncStream<URL>.makeStream(bufferingPolicy: .bufferingNewest(1))
    defer { continuation.finish() }
    let installer = UpdateInstaller { arguments, directory, _ in
        if arguments.first == "swift" {
            continuation.yield(directory)
            try await Task.sleep(for: .seconds(60))
        }
        return 0
    }
    let release = nextRelease
    let work = try await withThrowingTaskGroup(of: URL?.self) { group in
        defer { group.cancelAll() }
        group.addTask {
            try await installer.install(release, at: installation)
            return nil
        }
        group.addTask {
            for await work in building {
                await #expect(throws: DevError.self) {
                    try await installer.install(release, at: installation)
                }
                return work
            }
            return nil
        }
        let work = try #require(try await group.next() ?? nil)
        group.cancelAll()
        while !group.isEmpty { _ = await group.nextResult() }
        return work
    }
    #expect(try Data(contentsOf: installation.executable) == original)
    #expect(!FileManager.default.fileExists(atPath: work.path))
}

@Test func decliningAnUpdateSkipsInstallationAndSnoozesThePrompt() async throws {
    let folder = try updateTestFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let installation = try testInstallation(in: folder)
    let counter = FetchCounter()
    let checker = UpdateChecker(cache: folder.appendingPathComponent("check.json")) {
        try await counter.fetch()
    }
    let installer = UpdateInstaller { _, _, _ in
        Issue.record("Declining the update must not run an installation command.")
        return 1
    }
    let updated = try await UpdateCommand.offer(
        at: installation, checker: checker, installer: installer
    ) { question in
        #expect(question == "Update now?")
        return false
    }
    #expect(!updated)
    #expect(
        try await UpdateCommand.offer(at: installation, checker: checker, installer: installer) {
            _ in
            Issue.record("A declined update should not prompt again within 24 hours.")
            return false
        } == false)
    #expect(await counter.count == 1)
}

@Test func automaticUpdateFailuresLetThePreviewContinue() async throws {
    let folder = try updateTestFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let installation = try testInstallation(in: folder)
    let counter = FetchCounter()
    let offline = UpdateChecker(cache: folder.appendingPathComponent("offline.json")) {
        try await counter.fetch(fail: true)
    }
    #expect(
        try await UpdateCommand.offer(at: installation, checker: offline) { _ in
            Issue.record("Offline checks must not show an update prompt.")
            return true
        } == false)
    let available = UpdateChecker(cache: folder.appendingPathComponent("available.json")) {
        try await counter.fetch()
    }
    let failing = UpdateInstaller { _, _, _ in 1 }
    #expect(
        try await UpdateCommand.offer(at: installation, checker: available, installer: failing) {
            _ in true
        } == false)
    #expect(
        try String(contentsOf: installation.executable, encoding: .utf8)
            == "#!/bin/sh\necho original-dev\n")
}

@Test(.timeLimit(.minutes(2)))
func buildsAndInstallsAnActualTaggedSwiftRelease() async throws {
    let folder = try updateTestFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let installation = try testInstallation(in: folder)
    let repository = folder.appendingPathComponent("release-repository")
    let sources = repository.appendingPathComponent("Sources")
    try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
    let release = nextRelease
    let version = try #require(release.version)
    let manifest = """
        // swift-tools-version: 6.2
        import PackageDescription
        let package = Package(name: "UpdateFixture", products: [
            .executable(name: "publish-dev", targets: ["UpdateFixture"])
        ], targets: [.executableTarget(name: "UpdateFixture", path: "Sources")])
        """
    try Data(manifest.utf8).write(to: repository.appendingPathComponent("Package.swift"))
    try Data("print(\"PublishDev \(version)\")".utf8).write(
        to: sources.appendingPathComponent("main.swift"))
    let gitCommands = [
        ["init", "--quiet"],
        ["add", "Package.swift", "Sources"],
        [
            "-c", "user.name=PublishDev Tests", "-c", "user.email=tests@example.invalid", "-c",
            "commit.gpgsign=false", "commit", "--quiet", "-m", "fixture",
        ],
        ["-c", "tag.gpgsign=false", "tag", release.tag],
    ]
    for arguments in gitCommands {
        let status = try await ChildProcess.run(
            ["/usr/bin/git", "-c", "core.hooksPath=/dev/null"] + arguments, in: repository)
        try #require(status == 0)
    }
    let installer = UpdateInstaller { arguments, directory, output in
        // Use a local tagged repository; every download/build/verification/install command is real.
        let localArguments = arguments.map {
            $0 == "https://github.com/markbattistella/PublishDev.git" ? repository.path : $0
        }
        return try await ChildProcess.run(
            localArguments, in: directory, stdout: output,
            environment: ["GIT_TERMINAL_PROMPT": "0"])
    }
    try await installer.install(release, at: installation)
    let output = folder.appendingPathComponent("installed-version.txt")
    let status = try await ChildProcess.run(
        [installation.executable.path, "--version"], in: folder, stdout: output)
    #expect(status == 0)
    #expect(
        try String(contentsOf: output, encoding: .utf8).trimmingCharacters(
            in: .whitespacesAndNewlines) == "PublishDev \(version)")
}
