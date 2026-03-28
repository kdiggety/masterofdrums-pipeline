import Foundation
import PipelineRuntime

@main
struct MasterOfDrumsPipelineMain {
    static func main() async {
        let command = PipelineCLIParser.parse(arguments: CommandLine.arguments)
        let runtime = PipelineRuntime()

        do {
            try await runtime.run(command: command)
        } catch {
            fputs("[pipeline] error: \(error.localizedDescription)\n", stderr)
            Foundation.exit(1)
        }
    }
}
