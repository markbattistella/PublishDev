//
// Project: PublishDev
// Author: Mark Battistella
// Website: https://markbattistella.com
//

import Darwin
import Foundation

/// A directory of static files served by `python3 -m http.server`.
///
/// Each successful build is staged beside the served directory and swapped in atomically, so a
/// failed or partial build keeps the previous website visible.
struct Preview: Sendable {
    /// The directory handed to the server; its contents are replaced, never the directory itself.
    let live: URL
    private let next: URL

    static let reloadPath = "__publish_dev/reload.js"
    static let revisionPath = "__publish_dev/revision.txt"

    init(base: URL) throws {
        live = base.appendingPathComponent("live")
        next = base.appendingPathComponent("next")
        try? FileManager.default.removeItem(at: base)
        try FileManager.default.createDirectory(at: live, withIntermediateDirectories: true)
        let revision = UUID().uuidString
        try write(
            Self.waitingPage, to: live.appendingPathComponent("index.html"), revision: revision)
        try writeEndpoints(in: live, revision: revision)
    }

    /// Copies `output` into a staging directory, injects the reload client, and swaps it in.
    @discardableResult
    func publish(output: URL) throws -> Int {
        let revision = UUID().uuidString
        try? FileManager.default.removeItem(at: next)
        do {
            try FileManager.default.copyItem(at: output.resolvingSymlinksInPath(), to: next)
            guard
                FileManager.default.fileExists(
                    atPath: next.appendingPathComponent("index.html").path)
            else { throw DevError("Generation did not produce Output/index.html.") }
            let staged = try inject(revision: revision)
            try writeEndpoints(in: next, revision: revision)
            try stamp(
                staged + [Self.reloadPath, Self.revisionPath].map(next.appendingPathComponent))
            try exchange()
            return staged.filter { Self.isPage($0) }.count
        } catch {
            try? FileManager.default.removeItem(at: next)
            throw error
        }
    }

    /// Injects the reload client into every staged page and rejects links that escape the preview.
    /// Returns every staged file.
    private func inject(revision: String) throws -> [URL] {
        let keys: [URLResourceKey] = [.isSymbolicLinkKey, .isRegularFileKey]
        guard
            let walk = FileManager.default.enumerator(
                at: next, includingPropertiesForKeys: keys)
        else { throw DevError("Could not read the generated Output directory.") }
        var files: [URL] = []
        for case let url as URL in walk {
            try Task.checkCancellation()
            let values = try url.resourceValues(forKeys: Set(keys))
            guard values.isSymbolicLink != true else {
                throw DevError(
                    "Output contains a symbolic link: \(url.lastPathComponent). Copy the resource into Output instead."
                )
            }
            if values.isRegularFile == true { files.append(url) }
        }
        // Rewrite after the walk; an atomic write replaces the file the enumerator is reading.
        for url in files where Self.isPage(url) {
            guard let page = try? String(contentsOf: url, encoding: .utf8) else { continue }
            try write(page, to: url, revision: revision)
        }
        return files
    }

    private static func isPage(_ url: URL) -> Bool {
        ["html", "htm"].contains(url.pathExtension.lowercased())
    }

    /// Dates the staged files ahead of the ones they replace.
    ///
    /// Python's server answers `If-Modified-Since` from whole-second modification times, so a
    /// rebuild finishing in the same second as the previous one would otherwise reply `304` with
    /// the superseded page. Staying one second ahead of both the clock and the served build keeps
    /// every revalidation honest.
    private func stamp(_ files: [URL]) throws {
        let attributes = try? FileManager.default.attributesOfItem(
            atPath: live.appendingPathComponent(Self.revisionPath).path)
        let served = attributes?[.modificationDate] as? Date ?? .distantPast
        let date = max(Date(), served).addingTimeInterval(1)
        for url in files {
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        }
    }

    private func writeEndpoints(in directory: URL, revision: String) throws {
        let reload = directory.appendingPathComponent(Self.reloadPath)
        try FileManager.default.createDirectory(
            at: reload.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(Self.reloadScript.utf8).write(to: reload, options: .atomic)
        try Data(revision.utf8)
            .write(to: directory.appendingPathComponent(Self.revisionPath), options: .atomic)
    }

    /// Exchanges the staged and served directories in one step, then discards the old contents.
    private func exchange() throws {
        guard renamex_np(next.path, live.path, UInt32(RENAME_SWAP)) == 0 else {
            // A volume without atomic exchange leaves a sub-millisecond gap; the browser only
            // reloads once the new revision file is in place.
            let previous = live.appendingPathExtension("previous")
            try? FileManager.default.removeItem(at: previous)
            try FileManager.default.moveItem(at: live, to: previous)
            do {
                try FileManager.default.moveItem(at: next, to: live)
            } catch {
                // Put the served website back rather than leave the server with no directory.
                try? FileManager.default.moveItem(at: previous, to: live)
                throw error
            }
            try? FileManager.default.removeItem(at: previous)
            return
        }
        try? FileManager.default.removeItem(at: next)
    }

    private func write(_ page: String, to url: URL, revision: String) throws {
        var html = page
        let script = "<script src=\"/\(Self.reloadPath)?revision=\(revision)\" defer></script>"
        if let body = html.range(of: "</body>", options: [.caseInsensitive, .backwards]) {
            html.insert(contentsOf: script, at: body.lowerBound)
        } else {
            html.append(script)
        }
        try Data(html.utf8).write(to: url, options: .atomic)
    }

    static let waitingPage = """
        <!doctype html><html><head><title>PublishDev</title></head><body>
        <h1>Waiting for a successful build</h1>
        <p>Build output appears in your terminal. This page refreshes when the website is ready.</p>
        </body></html>
        """

    static let reloadScript = """
        (() => {
          const revision = new URL(document.currentScript.src).searchParams.get('revision');
          async function check() {
            try {
              const response = await fetch('/\(revisionPath)', {
                cache: 'no-store', signal: AbortSignal.timeout(3000)
              });
              if (response.ok && (await response.text()).trim() !== revision) {
                window.location.reload();
                return;
              }
            } catch (_) {
              // A stopped or restarting development server is expected.
            }
            setTimeout(check, 750);
          }
          setTimeout(check, 750);
        })();
        """
}
