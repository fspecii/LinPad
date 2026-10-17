import SwiftUI
import UIKit
import XCTest
@testable import DesktopKit

/// `onChangeCompat` must call the action of the render that saw the change, as iOS 17's
/// `onChange(of:initial:_:)` does. iOS 16's own `onChange(of:perform:)` calls the closure of
/// the render before, so an action reading the view's environment or properties got stale ones.
@MainActor
final class ChangeCompatTests: XCTestCase {
    private final class Log { var labels: [String] = [] }
    private final class Model: ObservableObject { @Published var value = 0 }

    private struct Probe: View {
        let value: Int
        let label: String
        let log: Log

        var body: some View {
            Color.clear.frame(width: 10, height: 10)
                .onChangeCompat(of: value) { _, _ in log.labels.append(label) }
        }
    }

    private struct Host: View {
        @ObservedObject var model: Model
        let log: Log

        var body: some View { Probe(value: model.value, label: "render \(model.value)", log: log) }
    }

    func testActionSeesTheRenderAfterTheChange() {
        let log = Log()
        let model = Model()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        window.rootViewController = UIHostingController(rootView: Host(model: model, log: log))
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        for value in 1...2 {
            model.value = value
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        XCTAssertEqual(log.labels, ["render 1", "render 2"])
    }
}
