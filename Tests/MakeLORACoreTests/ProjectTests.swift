import XCTest
@testable import MakeLORACore

final class ProjectTests: XCTestCase {
    func testStableIDsPhotoReuseAndRoundTrip() throws {
        let a = LibraryPhoto(filename: "a.heic", name: "Original HEIC")
        let b = LibraryPhoto(filename: "b.png", name: "Target")
        var project = Project(name: "Test")
        project.photos = [a, b]
        XCTAssertEqual(project.addPair(control: a.id, target: b.id), 1)
        XCTAssertEqual(project.addPair(control: a.id, target: a.id), 2)
        project.pairs.removeFirst()
        XCTAssertEqual(project.addPair(control: b.id, target: a.id), 3)
        try project.validate()
        XCTAssertEqual(try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(project)), project)
    }
    func testSwapKeepsCropsWithTheirPhotos() {
        let a = UUID(), b = UUID()
        let crop = Crop(x: 0.1, y: 0.2, width: 0.7, height: 0.6)
        var pair = ImagePair(id: 1, control: a, target: b, caption: "Change light", controlCrop: crop)
        pair.swap()
        XCTAssertEqual(pair.control, b); XCTAssertEqual(pair.target, a)
        XCTAssertEqual(pair.targetCrop, crop); XCTAssertEqual(pair.controlCrop, .full)
        XCTAssertEqual(pair.caption, "Change light")
    }
    func testCropBoundsAndInvalidReferences() {
        XCTAssertEqual(Crop(x: -2, y: 5, width: 3, height: 0.5).clamped, Crop(x: 0, y: 0.5, width: 1, height: 0.5))
        XCTAssertEqual(Crop(x: .nan, width: .infinity).clamped, .full)
        var project = Project(name: "Broken")
        project.addPair(control: UUID(), target: UUID())
        XCTAssertThrowsError(try project.validate())
        project.pairs = []
        project.photos = [LibraryPhoto(filename: "../private", name: "Invalid")]
        XCTAssertThrowsError(try project.validate())
    }
    func testStreamingZIPWithUnicodeAndEmptyCaption() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = directory.appendingPathComponent("image")
        let text = directory.appendingPathComponent("text")
        let data = Data((0..<1_200_000).map { UInt8(truncatingIfNeeded: $0) })
        try data.write(to: image); try Data().write(to: text)
        let zip = directory.appendingPathComponent("dataset.zip")
        try DatasetZIP.write(files: [("control/1.jpg", image), ("target/1.jpg", image), ("target/1.txt", text), ("target/café.txt", text)], to: zip)
        #if os(macOS)
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-q", zip.path, "-d", directory.appendingPathComponent("out").path]
        try unzip.run(); unzip.waitUntilExit()
        XCTAssertEqual(unzip.terminationStatus, 0)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("out/control/1.jpg")), data)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("out/target/1.txt")), Data())
        #endif
    }
}
