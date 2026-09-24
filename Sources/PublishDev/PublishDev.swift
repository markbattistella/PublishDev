//
// Project: PublishDev
// Author: Mark Battistella
// Website: https://markbattistella.com
//

import Darwin
import Foundation

func log(_ message: String) {
    // A terminal can close while cleanup is reporting progress. Losing output must not abort it.
    let data = Data((message + "\n").utf8)
    data.withUnsafeBytes { bytes in
        var offset = 0
        while offset < bytes.count {
            let count = write(
                STDOUT_FILENO, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
            if count < 0 {
                if errno == EINTR { continue }
                return
            }
            guard count > 0 else { return }
            offset += count
        }
    }
}

@main
struct PublishDev {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments == ["--version"] {
            log("PublishDev \(ReleaseVersion.current)")
            return
        }
        if arguments.contains("--help") || arguments.contains("-h") {
            log(arguments.first == "update" ? UpdateCommand.help : Options.help)
            return
        }
        do {
            try await SignalMonitor.run {
                if arguments.first == "update" {
                    try await UpdateCommand.run(arguments: Array(arguments.dropFirst()))
                } else {
                    let options = try Options(arguments: arguments)
                    if let installation = try await UpdateCommand.offerIfNeeded(
                        disabled: options.noUpdateCheck)
                    {
                        try UpdateCommand.restart(installation, arguments: arguments)
                    }
                    try await DevelopmentSession(options: options).run()
                }
            }
        } catch is CancellationError {
            return
        } catch {
            FileHandle.standardError.write(Data("PublishDev: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
}
