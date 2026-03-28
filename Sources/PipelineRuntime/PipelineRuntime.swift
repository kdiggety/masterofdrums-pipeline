import Foundation
import PipelineInfrastructure
import PipelineHTTP

public struct PipelineRuntime {
    public let store: InMemoryJobStore
    public let api: HTTPAPIConfiguration

    public init(
        store: InMemoryJobStore = InMemoryJobStore(),
        api: HTTPAPIConfiguration = HTTPAPIConfiguration(bindHost: "127.0.0.1", bindPort: 8080)
    ) {
        self.store = store
        self.api = api
    }

    public func start() async {
        print("[pipeline] runtime started")
        print("[pipeline] bind: \(api.bindHost):\(api.bindPort)")
    }
}
