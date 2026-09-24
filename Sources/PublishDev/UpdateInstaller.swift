//
// Project: PublishDev
// Author: Mark Battistella
// Website: https://markbattistella.com
//

import CryptoKit
import Darwin
import Foundation

struct UpdateInstallation: Sendable {
    let executable: URL

    static func current() throws -> Self {
        guard let path = ProcessIdentity(getpid())?.executable else {
            throw DevError("Could not locate PublishDev. Reinstall it with make install.")
        }
        let installation = Self(executable: URL(fileURLWithPath: path).resolvingSymlinksInPath())
        try installation.validate()
        return installation
    }

    func validate() throws {
        let bin = executable.deletingLastPathComponent()
        let shim = try? String(contentsOf: bin.appendingPathComponent("publish"), encoding: .utf8)
        guard executable.lastPathComponent == "publish-dev",
            shim?.split(separator: "\n").contains("# publish-dev-shim: 1") == true,
            FileManager.default.isExecutableFile(
                atPath: bin.appendingPathComponent("publish-cli").path)
        else {
            throw DevError(
                "This copy is not managed by the PublishDev installer. Run make install from your checkout to install or update it."
            )
        }
    }
}

struct UpdateInstaller: Sendable {
    typealias Runner = @Sendable ([String], URL, URL?) async throws -> Int32
    let run: Runner

    init(run: @escaping Runner = Self.runCommand) {
        self.run = run
    }

    func install(_ release: GitHubRelease, at installation: UpdateInstallation) async throws {
        guard let version = release.version, version > ReleaseVersion.current else {
            throw DevError(
                "The selected release is not newer than PublishDev \(ReleaseVersion.current).")
        }
        guard geteuid() != 0 else {
            throw DevError(
                "Run publish dev update without sudo. Only the final installation requests administrator access if needed."
            )
        }
        try installation.validate()
        let target = installation.executable
        let fingerprint = try Self.fingerprint(target)
        let identifier = SHA256.hash(data: Data(target.path.utf8)).map {
            String(format: "%02x", $0)
        }.joined()
        let lockPath = FileManager.default.temporaryDirectory.appendingPathComponent(
            "publish-dev-\(getuid())-update-\(identifier).lock"
        ).path
        let lock = open(lockPath, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lock >= 0 else { throw DevError("Could not open the update lock.") }
        defer { close(lock) }
        var info = stat()
        guard fstat(lock, &info) == 0, info.st_uid == getuid(),
            info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o077 == 0, info.st_nlink == 1
        else { throw DevError("The update lock has an unexpected owner or permissions.") }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else {
            throw DevError("Another PublishDev update is running. Wait for it to finish.")
        }

        let work = FileManager.default.temporaryDirectory.appendingPathComponent(
            "publish-dev-update-\(UUID())")
        try FileManager.default.createDirectory(
            at: work, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: work) }
        let source = work.appendingPathComponent("source")
        log("Downloading PublishDev \(version)…")
        try await command(
            ["/usr/bin/git", "-c", "core.hooksPath=/dev/null", "init", "--quiet", source.path],
            in: work)
        try await command(
            [
                "/usr/bin/git", "-c", "core.hooksPath=/dev/null", "-C", source.path, "fetch",
                "--quiet", "--depth", "1", "--no-tags",
                "https://github.com/markbattistella/PublishDev.git", "refs/tags/\(release.tag)",
            ], in: work, timeout: .seconds(60))
        try await command(
            [
                "/usr/bin/git", "-c", "core.hooksPath=/dev/null", "-C", source.path, "checkout",
                "--quiet", "--detach", "FETCH_HEAD",
            ],
            in: work)

        log("Building PublishDev \(version)…")
        try await command(
            ["swift", "build", "--package-path", source.path, "-c", "release"], in: work)
        let output = work.appendingPathComponent("command-output.txt")
        try await command(
            [
                "swift", "build", "--package-path", source.path, "-c", "release", "--show-bin-path",
            ], in: work, output: output)
        let binPath = try String(contentsOf: output, encoding: .utf8).trimmingCharacters(
            in: .whitespacesAndNewlines)
        guard binPath.hasPrefix("/"), !binPath.contains("\n") else {
            throw DevError("The release build did not report a valid output directory.")
        }
        let binary = URL(fileURLWithPath: binPath).appendingPathComponent("publish-dev")
        try await command([binary.path, "--version"], in: work, output: output)
        let builtVersion = try String(contentsOf: output, encoding: .utf8).trimmingCharacters(
            in: .whitespacesAndNewlines)
        guard builtVersion == "PublishDev \(version)" else {
            throw DevError(
                "Release \(release.tag) built an unexpected version (\(builtVersion)). The installed copy was kept."
            )
        }
        try Task.checkCancellation()
        guard try Self.fingerprint(target) == fingerprint else {
            throw DevError(
                "The installed copy changed during the build. Run publish dev update again.")
        }
        try installation.validate()
        var arguments = [
            "/bin/sh", "-c", Self.replaceScript, "publish-dev-update", binary.path, target.path,
        ]
        if !FileManager.default.isWritableFile(atPath: target.deletingLastPathComponent().path) {
            log(
                "Administrator access is needed to install into \(target.deletingLastPathComponent().path)."
            )
            arguments = ["/usr/bin/sudo"] + (TerminalInput.isInteractive ? [] : ["-n"]) + arguments
        }
        try await command(arguments, in: work)
        log("Updated PublishDev to \(version).")
    }

    // Stage beside the destination, then rename on the same filesystem. The old executable stays
    // usable through download, compilation, verification, and even a failed installation.
    static let replaceScript = """
        set -eu
        stage=$(/usr/bin/mktemp "${2}.update.XXXXXX")
        trap '/bin/rm -f "$stage"' EXIT
        trap 'exit 1' HUP INT TERM
        /usr/bin/install -m 755 "$1" "$stage"
        /bin/mv -f "$stage" "$2"
        """

    private struct Fingerprint: Equatable {
        let device: dev_t
        let inode: ino_t
        let modified: Int
        let nanoseconds: Int
    }

    private static func fingerprint(_ url: URL) throws -> Fingerprint {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            throw DevError("The installed executable is missing or is not a regular file.")
        }
        return Fingerprint(
            device: info.st_dev, inode: info.st_ino,
            modified: info.st_mtimespec.tv_sec, nanoseconds: info.st_mtimespec.tv_nsec)
    }

    private func command(
        _ arguments: [String], in directory: URL, output: URL? = nil, timeout: Duration? = nil
    ) async throws {
        let status: Int32
        if let timeout {
            status = try await withThrowingTaskGroup(of: Int32.self) { group in
                defer { group.cancelAll() }
                group.addTask { try await run(arguments, directory, output) }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    throw DevError(
                        "The release download timed out. Try publish dev update again later.")
                }
                return try await group.next()!
            }
        } else {
            status = try await run(arguments, directory, output)
        }
        guard status == 0 else {
            throw DevError(
                "The update command \(arguments[0]) failed (exit \(status)). The installed copy was kept."
            )
        }
    }

    private static func runCommand(_ arguments: [String], _ directory: URL, _ output: URL?)
        async throws -> Int32
    {
        try await ChildProcess.run(
            arguments, in: directory, stdout: output,
            terminalInput: arguments.first == "/usr/bin/sudo" && TerminalInput.isInteractive,
            environment: ["GIT_TERMINAL_PROMPT": "0"])
    }
}
