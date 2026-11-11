import XCTest
@testable import PhoneCoder

final class PhoneCoderRootNavigationTests: XCTestCase {
    func testTabIDsKeepTheFiveDestinationsInProductOrder() {
        XCTAssertEqual(
            PhoneCoderTab.allCases.map(\.id),
            ["chat", "models", "server", "images", "settings"]
        )
    }

    func testDockRetainsApprovedLabelsAndSymbols() {
        XCTAssertEqual(PhoneCoderTab.allCases.map(\.accessibilityLabel), ["Chat", "Models", "Server", "Images", "Settings"])
        XCTAssertEqual(PhoneCoderTab.allCases.map(\.systemImage),
                       ["bubble.left.and.bubble.right", "shippingbox", "server.rack", "photo", "gearshape"])
    }

    func testServerOccupiesTheCenterTab() {
        XCTAssertEqual(PhoneCoderTab.allCases.firstIndex(of: .server), 2)
    }

    func testEveryTabHasAnAccessibilityLabelAndSystemImage() {
        for tab in PhoneCoderTab.allCases {
            XCTAssertFalse(tab.accessibilityLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Missing accessibility label for \(tab.id)")
            XCTAssertFalse(tab.systemImage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Missing SF Symbol for \(tab.id)")
        }
    }
}
