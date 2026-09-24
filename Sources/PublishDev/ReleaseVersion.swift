//
// Project: PublishDev
// Author: Mark Battistella
// Website: https://markbattistella.com
//

import Foundation

/// Stable release versions only. Drafts, prereleases, and non-version tags are not updates.
struct ReleaseVersion: Comparable, Sendable, CustomStringConvertible {
    // Bump this before tagging and publishing the matching GitHub release (v0.1.0).
    static let current = ReleaseVersion(major: 0, minor: 1, patch: 0)

    let major: Int
    let minor: Int
    let patch: Int

    init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    init?(tag: String) {
        let value = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        let numbers = parts.compactMap { part -> Int? in
            guard !part.isEmpty, part.utf8.allSatisfy({ (48...57).contains($0) }),
                part.count == 1 || part.first != "0"
            else { return nil }
            return Int(part)
        }
        guard numbers.count == 3 else { return nil }
        self.init(major: numbers[0], minor: numbers[1], patch: numbers[2])
    }

    var description: String { "\(major).\(minor).\(patch)" }

    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}
