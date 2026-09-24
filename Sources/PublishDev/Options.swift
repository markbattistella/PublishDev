//
// Project: PublishDev
// Author: Mark Battistella
// Website: https://markbattistella.com
//

import Foundation

struct DevError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct Options: Sendable {
    var site: URL
    var product: String?
    var port: UInt16 = 8000
    var noUpdateCheck = false
    var extraPaths: [URL] = []

    static let help = """
        publish dev — rebuild and preview a Publish website as you save.

        Usage: publish dev [--site PATH] [--product NAME] [--port NUMBER] [--watch PATH ...]
               publish dev update [--check | --yes]

          --site PATH      Website package directory (default: current directory).
          --product NAME   Executable product (auto-detected if there is only one).
          --port NUMBER    Local HTTP port (default: 8000).
          --watch PATH     Additional input file or directory; repeat for more paths.
                           Relative paths are resolved against the website directory.
          --no-update-check  Skip the automatic GitHub release check.
          --version       Show the installed PublishDev version.
          --help, -h       Show this help.

        Watches Content, Resources, Sources, Package.swift, and Package.resolved.
        Serves http://localhost:8000 by default, using the same Python web server
        as `publish run`. Press Return or Ctrl+C to stop the server and exit.
        """

    init(
        arguments: [String],
        directory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    ) throws {
        site = directory.standardizedFileURL.resolvingSymlinksInPath()
        var iterator = arguments.makeIterator()
        var watchPaths: [String] = []
        while let flag = iterator.next() {
            if flag == "--no-update-check" {
                noUpdateCheck = true
                continue
            }
            guard ["--site", "--product", "--port", "--watch"].contains(flag) else {
                throw DevError("Unknown option: \(flag). Use --help for usage.")
            }
            guard let value = iterator.next(), !value.isEmpty, !value.hasPrefix("--") else {
                throw DevError("Missing value for \(flag).")
            }
            switch flag {
            case "--site": site = Self.url(value, relativeTo: directory)
            case "--product":
                guard !value.hasPrefix("-") else {
                    throw DevError("Invalid executable product: \(value).")
                }
                product = value
            case "--port":
                guard let number = UInt16(value), number > 0 else {
                    throw DevError("Port must be a number between 1 and 65535.")
                }
                port = number
            default: watchPaths.append(value)
            }
        }
        extraPaths = watchPaths.map { Self.url($0, relativeTo: site) }
        guard
            FileManager.default.fileExists(
                atPath: site.appendingPathComponent("Package.swift").path)
        else {
            throw DevError(
                "No Package.swift found in \(site.path). Pass --site with a website package directory."
            )
        }
        let generated = ["Output", ".build", ".publish", ".git"].map {
            site.appendingPathComponent($0).path
        }
        for path in extraPaths {
            guard !generated.contains(where: { path.path == $0 || path.path.hasPrefix($0 + "/") })
            else {
                throw DevError(
                    "Cannot watch generated directory: \(path.path). Watch its source files instead."
                )
            }
        }
    }

    var inputs: [URL] {
        ["Content", "Resources", "Sources", "Package.swift", "Package.resolved"]
            .map { site.appendingPathComponent($0) } + extraPaths
    }

    private static func url(_ path: String, relativeTo directory: URL) -> URL {
        URL(
            fileURLWithPath: (path as NSString).expandingTildeInPath,
            relativeTo: URL(fileURLWithPath: directory.path, isDirectory: true)
        )
        .standardizedFileURL.resolvingSymlinksInPath()
    }
}
