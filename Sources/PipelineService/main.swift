import Foundation
import PipelineRuntime

@main
struct MasterOfDrumsPipelineMain {
    static func main() async {
        let runtime = PipelineRuntime()
        await runtime.start()
    }
}
