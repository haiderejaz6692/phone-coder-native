import XCTest
@testable import PhoneCoder

final class PhoneCoderAppIdentityTests: XCTestCase {
    func testBuildManifestPinsApprovedUpstreamCommit() {
        let manifest = PhoneCoderBuildManifest.current

        XCTAssertEqual(manifest.upstreamRepository.absoluteString, "https://github.com/Mesutcydev/ios-local-llm.git")
        XCTAssertEqual(manifest.upstreamCommit, "cc4e2d3f25dfe77e9ef9e629ee6ddc7e3134ac88")
        XCTAssertEqual(manifest.apiProfile, "phone-coder-api/1")
    }

    func testProductIdentityHasNoOnDeviceBundleIdentifier() {
        let manifest = PhoneCoderBuildManifest.current

        XCTAssertEqual(manifest.productName, "Phone Coder")
        XCTAssertEqual(manifest.bundleIdentifier, "com.haider.phonecoder")
        XCTAssertEqual(Bundle.main.bundleIdentifier, manifest.bundleIdentifier)
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String, "Phone Coder")
    }

    func testSideloadFlavorDeclaresNoContentClassifier() {
        // This tests the declared build flavor. Classifier runtime auditing
        // belongs to the later image-policy increment.
        XCTAssertEqual(PhoneCoderBuildManifest.current.policyFlavor, "sideload-owner-controlled")
    }

    func testCredentialStoresUsePhoneCoderNamespaces() {
        XCTAssertEqual(LocalAPIKeyStore.keychainService, "com.haider.phonecoder.localapi")
        XCTAssertEqual(KeychainStore.service, "com.haider.phonecoder.webtool")
        XCTAssertEqual(HFTokenKeychainIdentity.service, "com.haider.phonecoder.huggingface")
    }
}
