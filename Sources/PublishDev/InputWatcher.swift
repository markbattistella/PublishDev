//
// Project: PublishDev
// Author: Mark Battistella
// Website: https://markbattistella.com
//

import Foundation

struct InputWatcher: Sendable {
    let paths: [URL]
    static let ignored: Set<String> = [
        "Output", ".build", ".publish", ".git", ".swiftpm", ".DS_Store",
    ]

    struct Stamp: Equatable, Sendable {
        let modified: Date?
        let size: UInt64?
        let inode: UInt64?
    }

    func scan() throws -> [String: Stamp] {
        var result: [String: Stamp] = [:]
        for path in paths {
            try collect(path, into: &result)
        }
        return result
    }

    private func collect(_ path: URL, into result: inout [String: Stamp]) throws {
        guard !Self.ignored.contains(path.lastPathComponent) else { return }
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: path.path)
        } catch let error as CocoaError
            where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile
        {
            return  // A removed input remains watched and can be recreated.
        }
        if attributes[.type] as? FileAttributeType == .typeDirectory {
            for child in try FileManager.default.contentsOfDirectory(
                at: path, includingPropertiesForKeys: nil)
            {
                try collect(child, into: &result)
            }
        } else {
            result[path.path] = Stamp(
                modified: attributes[.modificationDate] as? Date,
                size: attributes[.size] as? UInt64,
                inode: attributes[.systemFileNumber] as? UInt64
            )
        }
    }

    func run(changes: AsyncStream<Void>.Continuation) async throws {
        defer { changes.finish() }
        var previous = try scan()
        var changedAt: ContinuousClock.Instant?
        var reportedError = false
        changes.yield(())

        // ponytail: stat polling suits small sites; use FSEvents if large trees cost measurable CPU.
        while true {
            try await Task.sleep(for: .milliseconds(250))
            do {
                let current = try scan()
                if current != previous {
                    previous = current
                    changedAt = .now
                } else if let instant = changedAt, instant.duration(to: .now) >= .milliseconds(300)
                {
                    changes.yield(())
                    changedAt = nil
                }
                reportedError = false
            } catch {
                if !reportedError {
                    log("Cannot read watched inputs: \(error.localizedDescription). Retrying.")
                }
                reportedError = true
            }
        }
    }
}
