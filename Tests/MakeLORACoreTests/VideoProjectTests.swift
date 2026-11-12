import XCTest
@testable import MakeLORACore

final class VideoProjectTests: XCTestCase {
    func testLegacyImageProjectDefaultsToQwen() throws {
        let project = Project(name: "Existing")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(project)) as? [String: Any])
        for key in ["model", "videos", "samples", "nextSampleID"] { json.removeValue(forKey: key) }
        let loaded = try JSONDecoder().decode(Project.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(loaded.model, .qwenImageEdit2509)
        XCTAssertTrue(loaded.videos.isEmpty)
        try loaded.validate()
    }
    func testVideoRoundTripAndStableFlatExportNames() throws {
        var project = Project(name: "Motion", model: .wan21I2V14B)
        let video = LibraryVideo(filename: "original.mov", name: "Original", duration: 10, width: 1920, height: 1080)
        project.videos = [video]
        XCTAssertEqual(project.addSample(video: video, caption: "A person waves"), 1)
        project.samples.removeAll()
        XCTAssertEqual(project.addSample(video: video), 2)
        XCTAssertEqual(project.addSample(video: video), 3)
        XCTAssertEqual(project.datasetFilenames, ["2.mp4", "2.txt", "3.mp4", "3.txt"])
        XCTAssertEqual(project.formatVersion, 2, "Older app versions must refuse to overwrite video projects")
        try project.validate()
        XCTAssertEqual(try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(project)), project)
    }
    func testTrimValidationAndModelSeparation() throws {
        var project = Project(name: "Motion", model: .wan21I2V14B)
        let video = LibraryVideo(filename: "original.mov", name: "Original", duration: 5, width: 1080, height: 1920)
        project.videos = [video]; project.addSample(video: video)
        for (start, end) in [(-1.0, 2.0), (3, 3), (0, 6), (Double.infinity, 4), (0, Double.nan)] {
            project.samples[0].start = start; project.samples[0].end = end
            XCTAssertThrowsError(try project.validate())
        }
        project.samples[0].start = 1; project.samples[0].end = 4
        try project.validate()
        project.samples[0].video = UUID()
        XCTAssertThrowsError(try project.validate())
        project.samples[0].video = video.id
        project.photos = [LibraryPhoto(filename: "extra.jpg", name: "Wrong model")]
        XCTAssertThrowsError(try project.validate())
    }
    func testOutputSizePreservesShapeAndUsesEvenPixels() {
        var sample = VideoSample(id: 1, video: UUID(), end: 1)
        let landscape = sample.outputSize(width: 1920, height: 1080)
        XCTAssertEqual(landscape.width, 854); XCTAssertEqual(landscape.height, 480)
        let portrait = sample.outputSize(width: 1080, height: 1920)
        XCTAssertEqual(portrait.width, 480); XCTAssertEqual(portrait.height, 854)
        sample.crop = Crop(width: 0.5, height: 1)
        let cropped = sample.outputSize(width: 1920, height: 1080)
        XCTAssertEqual(cropped.width, 480); XCTAssertEqual(cropped.height, 540)
    }
}
