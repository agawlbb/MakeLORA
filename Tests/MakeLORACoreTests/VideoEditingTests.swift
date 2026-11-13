import XCTest
@testable import MakeLORACore

final class VideoEditingTests: XCTestCase {
    private func clip(_ id: String = "first", start: Double = 10, end: Double = 20) -> VideoEditingClip { VideoEditingClip(id: id, start: start, end: end, caption: "Original caption") }

    func testTrimEndpointsNeverMoveEachOtherAndCannotCross() {
        var session = VideoEditingSession(duration: 100, clips: [clip()], selectedID: "first")
        session.setStart(15)
        XCTAssertEqual(session.selected?.start, 15); XCTAssertEqual(session.selected?.end, 20)
        session.setEnd(40)
        XCTAssertEqual(session.selected?.start, 15); XCTAssertEqual(session.selected?.end, 40)
        session.setStart(90)
        XCTAssertEqual(session.selected!.start, 39.9, accuracy: 0.000001); XCTAssertEqual(session.selected?.end, 40)
        session.setEnd(-10)
        XCTAssertEqual(session.selected!.start, 39.9, accuracy: 0.000001); XCTAssertEqual(session.selected!.end, 40, accuracy: 0.000001)
        let before = session.clips
        session.setStart(.nan); session.setEnd(.infinity)
        XCTAssertEqual(session.clips, before)
    }
    func testSequentialShortClipsRetainIndependentDraftsWhenSwitching() {
        var session = VideoEditingSession(duration: 100, clips: [clip()], selectedID: "first")
        session.edit { $0.caption = "First changed"; $0.crop = Crop(x: 0.1, y: 0, width: 0.5, height: 1) }
        XCTAssertTrue(session.add(at: 20, fallbackToBeginning: false))
        let second = session.selectedID!
        XCTAssertEqual(session.selected?.start, 20); XCTAssertEqual(session.selected?.end, 25)
        XCTAssertEqual(session.selected?.crop, .full); XCTAssertEqual(session.selected?.caption, "")
        session.edit { $0.caption = "Second caption" }
        session.selectedID = "first"
        XCTAssertEqual(session.selected?.caption, "First changed"); XCTAssertEqual(session.selected?.crop.width, 0.5)
        session.selectedID = second
        XCTAssertEqual(session.selected?.caption, "Second caption")
        XCTAssertEqual(session.baseline, [clip()]); XCTAssertTrue(session.hasChanges)
    }
    func testEndOfSourceDoesNotCreateZeroLengthClipOrUnexpectedlyWrapSequentialFlow() {
        var session = VideoEditingSession(duration: 22, clips: [], selectedID: nil)
        XCTAssertTrue(session.add(at: 20, fallbackToBeginning: false))
        XCTAssertEqual(session.selected?.end, 22)
        let before = session.clips
        XCTAssertFalse(session.add(at: 22, fallbackToBeginning: false)); XCTAssertEqual(session.clips, before)
        XCTAssertTrue(session.add(at: 22)); XCTAssertEqual(session.selected?.start, 0)
    }
    func testDuplicateCanOverlapAndChangingItLeavesOriginalUntouched() {
        var session = VideoEditingSession(duration: 100, clips: [clip()], selectedID: "first")
        session.duplicate()
        XCTAssertNotEqual(session.selectedID, "first"); XCTAssertEqual(session.selected?.caption, "Original caption")
        session.setStart(12); session.edit { $0.caption = "Duplicate caption" }
        XCTAssertEqual(session.clips.first, clip()); XCTAssertEqual(session.selected?.end, 20)
        session.removeSelected(); XCTAssertEqual(session.selectedID, "first"); XCTAssertFalse(session.hasChanges)
        session.removeSelected(); XCTAssertTrue(session.clips.isEmpty); XCTAssertNil(session.selected)
        session.add(at: 30); XCTAssertEqual(session.selected?.start, 30)
    }
    func testAcceptSaveRemapsTemporaryLocalSelectionAndResetsDirtyState() {
        var session = VideoEditingSession(duration: 100, clips: [], selectedID: nil)
        session.add(at: 12)
        let temporaryID = session.selectedID!
        var saved = session.selected!; saved.id = "42"
        session.accept(VideoEditSaveResult(clips: [saved], idMapping: [temporaryID: "42"]))
        XCTAssertEqual(session.selectedID, "42"); XCTAssertFalse(session.hasChanges)
    }
    func testMergePreservesConcurrentUneditedClipsAndNewClips() throws {
        let first = clip(), second = clip("second", start: 30, end: 40), external = clip("external", start: 70, end: 80)
        var changed = first; changed.caption = "My change"
        var changedElsewhere = second; changedElsewhere.caption = "Other device"
        let result = try VideoClipChanges.merge(baseline: [first, second], edited: [changed, second], current: [first, changedElsewhere, external])
        XCTAssertEqual(result, [changed, changedElsewhere, external])
    }
    func testMergeRejectsConflictingEditsDeletionsAndReusedNewIDs() {
        let first = clip()
        var mine = first; mine.start = 12
        var other = first; other.caption = "Changed elsewhere"
        XCTAssertThrowsError(try VideoClipChanges.merge(baseline: [first], edited: [mine], current: [other]))
        XCTAssertThrowsError(try VideoClipChanges.merge(baseline: [first], edited: [], current: [other]))
        XCTAssertThrowsError(try VideoClipChanges.merge(baseline: [], edited: [mine], current: [first]))
        XCTAssertThrowsError(try VideoClipChanges.merge(baseline: [first], edited: [mine], current: []))
    }
    func testMultipleClipSavePreservesLocalSourceAndStableExportNames() throws {
        let video = LibraryVideo(filename: "source.mp4", name: "Source", duration: 100, width: 1920, height: 1080)
        var project = Project(name: "Video edits", model: .wan21I2V14B); project.videos = [video]
        let id = project.addSample(video: video)
        let baseline = project.samples.map(VideoEditingClip.init)
        var first = baseline[0]; first.start = 10; first.end = 15; first.caption = "First"
        let second = VideoEditingClip(id: "temporary", start: 15, end: 20, caption: "Second", crop: Crop(x: 0.25, y: 0, width: 0.5, height: 1))
        let result = try project.saveVideoEdits(video: video.id, baseline: baseline, edited: [first, second])
        XCTAssertEqual(result.idMapping["temporary"], "2"); XCTAssertEqual(project.samples.map(\.id), [id, 2])
        XCTAssertEqual(project.samples.map(\.caption), ["First", "Second"])
        XCTAssertEqual(project.datasetFilenames, ["1.mp4", "1.txt", "2.mp4", "2.txt"])
        _ = try project.saveVideoEdits(video: video.id, baseline: result.clips, edited: [])
        XCTAssertEqual(project.videos, [video]); XCTAssertTrue(project.samples.isEmpty)
        let added = try project.saveVideoEdits(video: video.id, baseline: [], edited: [second])
        XCTAssertEqual(added.idMapping["temporary"], "3")
    }
    func testEditingOneSourceRetainsInterleavedProjectClipOrder() throws {
        let first = LibraryVideo(filename: "a.mp4", name: "A", duration: 100, width: 1920, height: 1080)
        let second = LibraryVideo(filename: "b.mp4", name: "B", duration: 100, width: 1920, height: 1080)
        var project = Project(name: "Sources", model: .wan21I2V14B); project.videos = [first, second]
        project.addSample(video: first); project.addSample(video: second); project.addSample(video: first)
        let baseline = project.samples.filter { $0.video == first.id }.map(VideoEditingClip.init)
        var edited = baseline; edited[0].caption = "Changed"
        _ = try project.saveVideoEdits(video: first.id, baseline: baseline, edited: edited)
        XCTAssertEqual(project.samples.map(\.id), [1, 2, 3])
        XCTAssertEqual(project.samples[1].video, second.id)
    }
    func testFailedLocalSaveDoesNotPartiallyMutateProjectOrConsumeIDs() {
        let video = LibraryVideo(filename: "source.mp4", name: "Source", duration: 100, width: 1920, height: 1080)
        var project = Project(name: "Video edits", model: .wan21I2V14B); project.videos = [video]
        let before = project
        XCTAssertThrowsError(try project.saveVideoEdits(video: video.id, baseline: [], edited: [clip("temp", start: 0, end: 101)]))
        XCTAssertEqual(project, before)
    }
    func testCropShapesMatchPhysicalAspectForLandscapeAndPortraitSources() {
        for source in [16.0/9, 9.0/16] {
            for shape in VideoCropShape.allCases where shape != .free {
                let crop = VideoCropGeometry.preset(shape, sourceAspect: source, around: .full)
                XCTAssertEqual(crop.width/crop.height*source, shape.aspect(source: source)!, accuracy: 0.000001)
                XCTAssertEqual(crop, crop.clamped)
            }
        }
    }
    func testCropMoveClampsWithoutChangingItsSize() {
        let crop = Crop(x: 0.2, y: 0.3, width: 0.4, height: 0.5)
        let moved = VideoCropGeometry.move(crop, dx: 20, dy: -20)
        XCTAssertEqual(moved, Crop(x: 0.6, y: 0, width: 0.4, height: 0.5))
    }
    func testCropCornersStayAnchoredWithinFrameAndPreserveLockedAspect() {
        let crop = Crop(x: 0.2, y: 0.2, width: 0.4, height: 0.4)
        for corner in VideoCropCorner.allCases {
            for delta in [-10.0, -0.1, 0.1, 10] {
                let next = VideoCropGeometry.resize(crop, corner: corner, dx: delta, dy: delta, normalizedAspect: 1)
                XCTAssertEqual(next, next.clamped)
                XCTAssertEqual(next.width/next.height, 1, accuracy: 0.000001)
                let left = corner == .topLeft || corner == .bottomLeft
                let top = corner == .topLeft || corner == .topRight
                XCTAssertEqual(left ? next.x+next.width : next.x, left ? crop.x+crop.width : crop.x, accuracy: 0.000001)
                XCTAssertEqual(top ? next.y+next.height : next.y, top ? crop.y+crop.height : crop.y, accuracy: 0.000001)
            }
        }
    }
    func testLetterboxedVideoGeometryUsesDisplayedImageDimensions() {
        let landscape = VideoCropGeometry.fitted(aspect: 16.0/9, width: 1000, height: 500)
        XCTAssertEqual(landscape.width, 500*16.0/9, accuracy: 0.000001); XCTAssertEqual(landscape.height, 500)
        let portrait = VideoCropGeometry.fitted(aspect: 9.0/16, width: 1000, height: 500)
        XCTAssertEqual(portrait.width, 500*9.0/16, accuracy: 0.000001); XCTAssertEqual(portrait.height, 500)
    }
}
