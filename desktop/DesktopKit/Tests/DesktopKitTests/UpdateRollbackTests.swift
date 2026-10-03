import XCTest
@testable import DesktopKit

final class UpdateLinkTests: XCTestCase {
    func testUpdateLinkParsesAndRoundTrips() {
        XCTAssertEqual(LinPadLink.parse(URL(string: "linpad://update")!), .checkUpdates)
        XCTAssertEqual(LinPadLink.parse(URL(string: "linpad://update/check")!), .checkUpdates)
        XCTAssertEqual(LinPadLink.parse(LinPadLink.checkUpdates.url), .checkUpdates)
        XCTAssertNil(LinPadLink.parse(URL(string: "linpad://update/install")!), "only checking is offered")
    }
}

@MainActor
final class UpdateRollbackTests: XCTestCase {
    func testServiceExposesTheHostsRollback() {
        XCTAssertNil(UpdateService(host: MockLinuxHost(latency: .zero), defaults: UserDefaults(suiteName: UUID().uuidString)!).rollback)
    }

    func testMenuOffersUpdateItems() {
        let controller = DesktopController(host: MockLinuxHost(latency: .zero), apps: BuiltinApps.all())
        controller.toggleCommandMenu(.section(.update))
        let ids = controller.commandMenuResults().map(\.id)
        XCTAssertTrue(ids.contains("update:check"))
        XCTAssertTrue(ids.contains("update:linpad"))
    }
}
