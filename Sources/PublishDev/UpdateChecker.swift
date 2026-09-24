//
// Project: PublishDev
// Author: Mark Battistella
// Website: https://markbattistella.com
//

import Foundation

struct GitHubRelease: Decodable, Sendable {
    let tag: String
    let draft: Bool
    let prerelease: Bool

    enum CodingKeys: String, CodingKey {
        case tag = "tag_name"
        case draft, prerelease
    }

    var version: ReleaseVersion? {
        guard !draft, !prerelease else { return nil }
        return ReleaseVersion(tag: tag)
    }

    var page: String { "https://github.com/markbattistella/PublishDev/releases/tag/\(tag)" }
}

struct UpdateChecker: Sendable {
    typealias Fetch = @Sendable () async throws -> GitHubRelease?
    private struct Check: Codable {
        let date: Date
        let installedVersion: String
    }

    let cache: URL
    let fetch: Fetch

    init(cache: URL = Self.defaultCache, fetch: @escaping Fetch = Self.fetchLatest) {
        self.cache = cache
        self.fetch = fetch
    }

    static var defaultCache: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PublishDev/update-check.json")
    }

    /// Cache attempts, including offline failures, so starting a preview does not keep retrying.
    /// Manual checks always contact GitHub. Only the timestamp is trusted from the local cache.
    func latest(automatic: Bool, now: Date = Date()) async throws -> GitHubRelease? {
        if automatic, let data = try? Data(contentsOf: cache),
            let previous = try? JSONDecoder().decode(Check.self, from: data),
            previous.installedVersion == ReleaseVersion.current.description,
            (0..<86_400).contains(now.timeIntervalSince(previous.date))
        {
            return nil
        }
        let check = Check(date: now, installedVersion: ReleaseVersion.current.description)
        if let data = try? JSONEncoder().encode(check) {
            try? FileManager.default.createDirectory(
                at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: cache, options: .atomic)
        }
        return try await fetch()
    }

    static func fetchLatest() async throws -> GitHubRelease? {
        // Use macOS's HTTP client, matching the command-line environment used by Git downloads.
        // Keep output separate so HTTP errors can be distinguished from connection failures.
        let work = FileManager.default.temporaryDirectory.appendingPathComponent(
            "publish-dev-release-check-\(UUID())")
        try FileManager.default.createDirectory(
            at: work, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: work) }
        let body = work.appendingPathComponent("release.json")
        let statusFile = work.appendingPathComponent("status.txt")
        let errors = work.appendingPathComponent("error.txt")
        let result = try await ChildProcess.run(
            [
                "/usr/bin/curl", "--silent", "--show-error", "--location",
                "--proto", "=https", "--proto-redir", "=https", "--max-time", "3",
                "--header", "Accept: application/vnd.github+json",
                "--user-agent", "PublishDev/\(ReleaseVersion.current)",
                "--output", body.path, "--write-out", "%{http_code}",
                "https://api.github.com/repos/markbattistella/PublishDev/releases/latest",
            ], in: work, stdout: statusFile, stderr: errors)
        guard result == 0 else {
            throw DevError(
                result == 28
                    ? "The GitHub release check timed out. Try again later."
                    : "Could not connect to GitHub to check releases (curl exit \(result)). Try again later."
            )
        }
        let status = try String(contentsOf: statusFile, encoding: .utf8).trimmingCharacters(
            in: .whitespacesAndNewlines)
        guard let code = Int(status) else {
            throw DevError("GitHub returned an invalid release response. Try again later.")
        }
        return try decode(Data(contentsOf: body), status: code)
    }

    static func decode(_ data: Data, status: Int) throws -> GitHubRelease? {
        if status == 404 { return nil }
        guard status == 200 else {
            throw DevError("Could not check GitHub releases (HTTP \(status)). Try again later.")
        }
        let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
        guard release.version != nil else {
            throw DevError("The latest GitHub release is not a stable version such as v0.1.0.")
        }
        return release
    }
}
