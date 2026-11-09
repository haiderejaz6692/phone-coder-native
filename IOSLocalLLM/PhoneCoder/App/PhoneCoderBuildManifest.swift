import Foundation

/// Auditable build identity. The policy flavor is a declaration; runtime
/// policy enforcement is owned by the corresponding feature increment.
struct PhoneCoderBuildManifest: Codable, Equatable, Sendable {
    let productName: String
    let bundleIdentifier: String
    let upstreamRepository: URL
    let upstreamCommit: String
    let apiProfile: String
    let policyFlavor: String

    static let current: Self = Self(
        productName: "Phone Coder",
        bundleIdentifier: "com.haider.phonecoder",
        upstreamRepository: URL(string: "https://github.com/Mesutcydev/ios-local-llm.git")!,
        upstreamCommit: "cc4e2d3f25dfe77e9ef9e629ee6ddc7e3134ac88",
        apiProfile: "phone-coder-api/1",
        policyFlavor: "sideload-owner-controlled"
    )
}
