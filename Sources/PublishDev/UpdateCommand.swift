//
// Project: PublishDev
// Author: Mark Battistella
// Website: https://markbattistella.com
//

import Darwin
import Foundation

enum UpdateCommand {
    static let help = """
        Usage: publish dev update [--check | --yes]

          --check    Check for a newer stable GitHub release without installing it.
          --yes      Install a newer release without asking for confirmation.
          --help     Show this help.

        Builds the release from source and replaces the installed PublishDev executable.
        Requires Git and Swift 6.2 or newer. Your Publish CLI and websites are preserved.
        """

    static func run(arguments: [String]) async throws {
        guard arguments.isEmpty || arguments == ["--check"] || arguments == ["--yes"] else {
            throw DevError(
                "Use publish dev update, publish dev update --check, or publish dev update --yes.")
        }
        log("Installed: PublishDev \(ReleaseVersion.current)")
        guard let release = try await UpdateChecker().latest(automatic: false),
            let version = release.version
        else {
            log("No stable GitHub release is available yet.")
            return
        }
        guard version > ReleaseVersion.current else {
            log("PublishDev is up to date.")
            return
        }
        log("Available: PublishDev \(version)\n\(release.page)")
        if arguments == ["--check"] { return }
        let installation = try UpdateInstallation.current()
        log("Install location: \(installation.executable.path)")
        if arguments != ["--yes"] {
            guard TerminalInput.isInteractive else {
                throw DevError(
                    "Use publish dev update --yes to install without an interactive prompt, or --check to only check."
                )
            }
            guard try await TerminalInput.confirm("Build and install this update?") else {
                log("Update skipped.")
                return
            }
        }
        try await UpdateInstaller().install(release, at: installation)
    }

    /// Development checkouts and automation never make an automatic network request.
    static func offerIfNeeded(disabled: Bool) async throws -> UpdateInstallation? {
        guard !disabled, TerminalInput.isInteractive,
            ProcessInfo.processInfo.environment["PUBLISH_DEV_NO_UPDATE_CHECK"] != "1",
            let installation = try? UpdateInstallation.current()
        else { return nil }
        return try await offer(at: installation) ? installation : nil
    }

    static func offer(
        at installation: UpdateInstallation, checker: UpdateChecker = UpdateChecker(),
        installer: UpdateInstaller = UpdateInstaller(),
        confirm: @Sendable (String) async throws -> Bool = TerminalInput.confirm
    ) async throws -> Bool {
        let release: GitHubRelease
        do {
            guard let latest = try await checker.latest(automatic: true),
                let version = latest.version, version > ReleaseVersion.current
            else { return false }
            release = latest
        } catch {
            try Task.checkCancellation()
            return false  // Offline use and GitHub rate limits must not prevent previewing a site.
        }
        log("PublishDev \(release.version!) is available. You have \(ReleaseVersion.current).")
        log(release.page)
        guard try await confirm("Update now?") else { return false }
        do {
            try await installer.install(release, at: installation)
            return true
        } catch {
            try Task.checkCancellation()
            log("Update failed: \(error.localizedDescription) Continuing with the current session.")
            return false
        }
    }

    static func restart(_ installation: UpdateInstallation, arguments: [String]) throws -> Never {
        let argv =
            ([installation.executable.path] + arguments + ["--no-update-check"]).map { strdup($0) }
            + [nil]
        defer { for pointer in argv { free(pointer) } }
        argv.withUnsafeBufferPointer { buffer in
            _ = execv(installation.executable.path, buffer.baseAddress!)
        }
        throw DevError(
            "The update was installed, but PublishDev could not restart. Run your preview command again."
        )
    }
}
