import Foundation
import PipelineRuntime

let command = PipelineCLIParser.parse(arguments: CommandLine.arguments)
let runtime = PipelineRuntime()
let semaphore = DispatchSemaphore(value: 0)
var exitCode: Int32 = 0

Task {
    do {
        try await runtime.run(command: command)
    } catch {
        fputs("[pipeline] error: \(error.localizedDescription)\n", stderr)
        exitCode = 1
    }
    semaphore.signal()
}

semaphore.wait()
Foundation.exit(exitCode)
