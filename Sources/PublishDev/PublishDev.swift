// PublishDev — Created by Mark Battistella

import Darwin
import Foundation

func log(_ message: String) {
    FileHandle.standardOutput.write(Data((message + "\n").utf8))
}

@main
struct PublishDev {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.contains("--help") || arguments.contains("-h") {
            log(Options.help)
            return
        }
        do {
            try await DevelopmentSession(options: Options(arguments: arguments)).run()
        } catch is CancellationError {
            return
        } catch {
            FileHandle.standardError.write(Data("PublishDev: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
}
