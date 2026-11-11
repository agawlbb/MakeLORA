# MakeLORA

An offline iPhone and iPad app for preparing paired-image datasets for image-editing models. Requires iOS or iPadOS 17 or later. iPhones use portrait orientation; iPads support portrait and landscape. Portrait uses a full-width library and a separate pair editor, with stacked image cards on narrow displays. Landscape iPads use a two-pane workspace with side-by-side image comparisons.

Create a project and import photos from Photos or Files, including HEIC, JPEG and PNG. Choose a control (starting image) and a target (desired result), then describe the transformation. Photos can be reused in any number of pairs.

Crop each side independently or apply the same relative crop to both. Drag a crop rectangle or use percentage sliders; reset restores the full image. Crop settings belong to each pair and never modify the originals. Replace either photo, swap the two sides with their crops, or delete a pair without deleting library images. Swapping keeps the caption so you can rewrite it for the reversed transformation.

Changes save automatically on the device. Generated files update after editing pauses. Export waits for generation to finish and opens the system share sheet: choose **Save to Files**, AirDrop, or another sharing destination.

Every dataset ZIP contains only:

```
control/1.jpg
target/1.jpg
target/1.txt
control/2.jpg
target/2.jpg
target/2.txt
```

All generated images are JPG, regardless of input format. Captions are UTF-8. Pair numbers remain stable; deleted numbers are not reused. Output retains the cropped pixel resolution, applies source orientation, flattens transparency onto white, and omits source EXIF/GPS metadata. JPEG quality is 95%. Linked crops use the same percentages, so differently shaped originals may produce differently sized outputs.

Projects and originals are stored in the app's Application Support directory and are eligible for normal device backup. Deleting the app or a project removes its local files. Dataset ZIPs are training exports, not editable project backups. Exported datasets contain the image content and captions you selected; review those before sharing.

Imports are processed one at a time. Images above 100 megapixels or 30,000 pixels on either side are rejected to bound memory usage. ZIP exports are limited to less than 4 GB and 65,535 files; split larger datasets into projects.

## Development

On a Mac with Xcode and XcodeGen:

```sh
swift test
xcodegen generate
open MakeLORA.xcodeproj
```

The Xcode project is generated from `project.yml`. The app has no third-party runtime dependencies. The Swift package contains project models, validation and streaming ZIP creation. UIKit/ImageIO handle HEIC decoding, orientation, previews and JPG generation.

GitHub Actions validates the Swift package and runs application tests on an iPad simulator. Before release, check an iPhone in portrait and an iPad in portrait and landscape: import photos, create/select a pair, replace and crop each image, edit a caption with the keyboard open, and export. Rotate the iPad while editing and verify the selected pair and edits survive. Check the smallest supported screen and larger accessibility text sizes.

Signing and TestFlight use a separate manual workflow. See [release setup](RELEASE.md).

Licensed under the repository's GPL license. Release scripts and workflow structure are adapted from the same owner's GPL-licensed FanControlWatch project.

## Optional server pairing

Projects → **Server** can scan or paste a pairing invitation from a configured
HTTPS pairing service. Confirm the matching code on its management page, then
check status in the app. Connections are saved in device-only Keychain storage.
Pairing is currently a prototype and grants no file or model-run access. The
VM management page also lists privately stored model files and inspection
metadata, with downloads disabled; dataset preparation remains offline. See [pairing service](server/README.md).
