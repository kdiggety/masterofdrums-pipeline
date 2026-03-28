import Foundation

public struct HTTPAPIConfiguration: Sendable {
    public let bindHost: String
    public let bindPort: Int

    public init(bindHost: String, bindPort: Int) {
        self.bindHost = bindHost
        self.bindPort = bindPort
    }
}
