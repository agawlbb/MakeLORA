import XCTest
import UIKit
import SwiftUI
@testable import MakeLORA

@MainActor final class GalleryViewerTests: XCTestCase {
    private func details(legacy: Bool, modelID: String? = nil, seed: Int? = nil) throws -> GenerationDetails {
        var settings: [String: Any] = ["modelName": "Glasses", "prompt": "Add glasses"]
        if let modelID { settings["modelID"] = modelID }
        if !legacy {
            settings.merge(["aspectRatio": "4:3", "loraScale": 0.75, "outputFormat": "jpg", "disableSafetyChecker": true, "retryOffline": false]) { _, new in new }
        }
        if let seed { settings["seed"] = seed }
        return try JSONDecoder().decode(GenerationDetails.self, from: JSONSerialization.data(withJSONObject: ["legacy": legacy, "settings": settings, "hasInput": !legacy]))
    }
    private func model(_ id: String) -> GenerationModel {
        GenerationModel(id: id, displayName: "Glasses", baseModel: "Qwen/Qwen-Image-Edit-2509", sizeBytes: 1, details: "{}", supported: true)
    }
    func testReplayUsesWeightIdentityAndLegacyRequiresUniqueName() throws {
        let output = GenerationOutput(id: "output", model: "Glasses", prompt: "Add glasses", date: Date())
        let exact = GenerationDraft(output: output, details: try details(legacy: false, modelID: "a"))
        XCTAssertEqual(exact.matchingModel(in: [model("b"), model("a")])?.id, "a")
        XCTAssertNil(exact.matchingModel(in: [model("b")]), "Do not silently substitute a similarly named weight")
        let legacy = GenerationDraft(output: output, details: try details(legacy: true))
        XCTAssertEqual(legacy.matchingModel(in: [model("a")])?.id, "a")
        XCTAssertNil(legacy.matchingModel(in: [model("a"), model("b")]))
    }
    func testSubmittedSeedAndSettingsRemainDistinctFromDefaults() throws {
        let random = try details(legacy: false, modelID: "a")
        XCTAssertNil(random.settings.seed)
        XCTAssertEqual(random.settings.aspectRatio, "4:3")
        XCTAssertEqual(random.settings.loraScale, 0.75)
        XCTAssertEqual(random.settings.retryOffline, false)
        XCTAssertEqual(try details(legacy: false, seed: 42).settings.seed, 42)
        let legacy = try details(legacy: true)
        XCTAssertNil(legacy.settings.aspectRatio)
        XCTAssertFalse(legacy.hasInput)
    }
    func testViewerFitsLargeIPadViewportAndBoundsZoomAcrossRotation() async throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 600, height: 900)).image { context in
            UIColor.blue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 600, height: 900))
        }
        let bytes = try XCTUnwrap(image.jpegData(compressionQuality: 0.8))
        let fitted = expectation(description: "Server image displayed")
        var fulfilled = false
        var zoomed = false
        let controller = GalleryImageController(output: GenerationOutput(id: "output", model: "Fixture", prompt: "Edit", date: Date()), load: { _ in bytes }) { value in
            zoomed = value
            if !fulfilled { fulfilled = true; fitted.fulfill() }
        }
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 1024, height: 1100)
        controller.view.layoutIfNeeded()
        controller.viewDidAppear(false)
        await fulfillment(of: [fitted], timeout: 5)
        let scroll = controller.scrollView
        XCTAssertEqual(scroll.bounds.width, 1024)
        XCTAssertEqual(scroll.maximumZoomScale, scroll.minimumZoomScale * 6, accuracy: 0.001)
        scroll.setZoomScale(scroll.minimumZoomScale * 2, animated: false)
        XCTAssertTrue(zoomed)
        controller.view.frame = CGRect(x: 0, y: 0, width: 1366, height: 650)
        controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
        XCTAssertEqual(scroll.zoomScale, scroll.minimumZoomScale, accuracy: 0.001)
        XCTAssertFalse(zoomed)
        controller.viewDidDisappear(false)
    }
    func testPagingFollowsGalleryOrderAndStopsAtEnds() {
        let outputs = (0..<3).map { GenerationOutput(id: "output-\($0)", model: "Fixture", prompt: "Edit", date: Date()) }
        var selected = outputs[1].id
        var zoomed = false
        let pages = GalleryPages(outputs: outputs, selectedID: Binding(get: { selected }, set: { selected = $0 }), zoomed: Binding(get: { zoomed }, set: { zoomed = $0 }), load: { _ in Data() })
        let coordinator = pages.makeCoordinator()
        let pager = UIPageViewController(transitionStyle: .scroll, navigationOrientation: .horizontal)
        coordinator.pager = pager
        coordinator.selectCurrent()
        let middle = pager.viewControllers!.first!
        let previous = coordinator.pageViewController(pager, viewControllerBefore: middle) as? GalleryImageController
        let next = coordinator.pageViewController(pager, viewControllerAfter: middle) as? GalleryImageController
        XCTAssertEqual(previous?.output.id, outputs[0].id)
        XCTAssertEqual(next?.output.id, outputs[2].id)
        XCTAssertNil(coordinator.pageViewController(pager, viewControllerBefore: previous!))
        XCTAssertNil(coordinator.pageViewController(pager, viewControllerAfter: next!))
        coordinator.setPagingEnabled(false)
        XCTAssertTrue(pager.view.subviews.compactMap { $0 as? UIScrollView }.allSatisfy { !$0.isScrollEnabled })
        coordinator.setPagingEnabled(true)
        pager.setViewControllers([next!], direction: .forward, animated: false)
        coordinator.pageViewController(pager, didFinishAnimating: true, previousViewControllers: [middle], transitionCompleted: true)
        XCTAssertEqual(selected, outputs[2].id)
        XCTAssertFalse(zoomed)
    }

}
