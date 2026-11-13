# MakeLORA

An iPhone and iPad app for preparing image and video training datasets offline, with optional server-backed video datasets and generation. Requires iOS or iPadOS 17 or later. iPhones use portrait orientation; iPads support portrait and landscape. Portrait uses a full-width library and a separate pair editor, with stacked image cards on narrow displays. Landscape iPads use a two-pane workspace with side-by-side image comparisons.

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

## Model-specific datasets

New projects choose **Qwen Image Edit 2509** or **Wan 2.1 Image-to-Video 14B**.
Existing projects remain Qwen projects with the paired-image layout described above.
Project model types are fixed at creation.

Wan projects import videos from Photos or Files. The video Files picker opens
references in place and dismisses before MakeLORA copies them. Provider downloads
and coordinated copies run off the UI thread with visible progress and Cancel;
a provider that does not supply the file within two minutes reports an error.
Video details are read from the local copy, with a separate 30-second limit.
If a provider stalls, download the video to On My iPhone/iPad in Files and retry.
Select matching UTF-8 `.txt`
files alongside videos in Files to import captions by filename stem. Edit captions
in the clip editor. Multiple clips can reuse one original video. Use playback,
timeline trim handles or precise start/end times to trim; **Crop** adjusts the
same relative rectangle across every frame. Originals are preserved.

AVFoundation converts clips on the device to H.264 MP4, with orientation applied,
SDR color, no audio, and source frame timing retained. After cropping, the shorter
side becomes 480 pixels; the other dimension rounds to an even pixel count
(for example, 1920 × 1080 becomes 854 × 480). Very narrow crops that would exceed
8192 pixels on the longer side cannot be encoded; choose a wider crop. There is
no automatic duration limit. Conversion updates after editing pauses; export waits
for current files. Cancel stops conversion or import, preserving saved edits.

Wan ZIPs contain only `1.mp4`, `1.txt`, `2.mp4`, `2.txt`, etc., all at the ZIP root.
IDs remain stable after deletion. No control images are exported. The existing
4 GB ZIP limit applies to video projects too. Video projects use format version 2,
which older app versions refuse to open; Qwen projects retain format version 1.

Generation also offers base **Wan 2.1 Image-to-Video 14B** and compatible server
LoRAs through Replicate's `wavespeedai/wan-2.1-i2v-480p`. Choose an input image,
motion prompt and landscape/portrait ratio. Advanced controls include negative
prompt, acceleration, guidance, inference steps, flow shift and safety checking;
LoRA strength appears for custom weights. Seed and temporary-failure retry
controls work as before. MP4 outputs appear in the shared server gallery with
playback, sharing, removal, saved settings and **Run again**. Playback and sharing
use protected temporary files that are removed afterward; gallery images remain
in memory. See the server README for the required migration and `ffprobe` setup.

## Server video datasets from Google Drive

Open **Datasets → Server datasets · Google Drive** to create a Wan server dataset.
Connect Google Drive through the server's authenticated website, then browse and
select videos in the app. Originals download directly from Drive to the server;
this avoids importing through the iOS Files provider. Matching same-name UTF-8
TXT files in the same folder supply captions automatically.

Once the preview is ready, stream it to trim, crop and caption clips. Multiple
clips can reuse one server original. **Render dataset on server** creates a ZIP
of matching numbered MP4/TXT files at 480p. **Share download link** lets a training
server download that ZIP directly; the link grants access for one hour. Source
videos, editable settings and rendered datasets remain on the server. This
workflow needs a network connection and remains separate from offline projects.

The server needs its own dedicated Google OAuth client and a background dataset
worker. All approved devices share the connected Drive account and datasets.
See [server setup and limits](server/README.md#google-drive-and-server-video-datasets).

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
The management website at https://vps.coffeybean.com/MakeLORA/ uses the existing
VPS sign-in. It lists privately stored model files and inspection metadata and
stores a persistent Replicate token for server-side paired-device operations.
The **Datasets** and **Generation** tabs switch between dataset preparation and
image generation. Generation lists server weights by display name and base model.
Tap a weight for metadata, then **Use model to generate**. Qwen Image Edit 2509
weights are supported through Replicate’s `qwen/qwen-image-edit-plus-lora` endpoint.
Choose a photo or file and enter an editing prompt. Inputs are oriented, flattened
to JPG and resized to at most 2048 pixels on the longest side before upload.
Aspect ratio defaults to `match_input_image`, LoRA scale to 1, seed to random
(blank), output to JPG, and `disable_safety_checker` to true. The server uses its
saved Replicate token; the app never receives that token.

Each submission immediately adds an upcoming-image tile to the gallery. Its
spinner animates while processing, and a single status line updates to the latest
provider message. All paired devices see pending server jobs; completed images
replace their pending tiles. Failed or canceled tiles stop animating and have a
**Remove tile** action. A stalled status check appears on its tile instead of
repeated alerts; **Check status** retries it. Failed, unconfirmed and active jobs
never block another submission. Removing a tile hides it for all paired devices
without canceling a submitted request; completed images still appear.
**Retry temporary failures** keeps a submission queued on the server every
30 minutes for up to 12 hours, even with the app closed. **Stop retries** ends
future attempts. Accepted runs are monitored without resubmitting them. This
requires the server retry worker; inputs are retained privately until acceptance,
cancellation or expiry.
Completed images are
archived privately on the server through a completion callback, even if the app
is closed. All approved paired devices view the same server-wide output gallery.
A valid active device credential is required to list weights, generate, view
images, or remove them. Provider output URLs are never handed to the app.

Gallery photos fill the available iPhone or iPad window, including iPad Split View. Pinch to zoom and pan;
double-tap toggles 2×/fit. Swipe between photos when fitted. **View settings**
shows the submission settings; **Run again** opens an editable composer using
the server’s original photo and settings. Originals remain private on the server
while their generated outputs remain. Older outputs restore known information
and require selecting the original photo again.

The gallery displays images in memory without saving local image files or using
a disk URL cache. Tap an image for a larger view or to remove it from the server
gallery for all devices. **Share** fetches a temporary JPG for the iOS share sheet;
choose Save to Files, Save Image or another destination to keep your own copy.
The temporary share file is removed when sharing ends. Generation tracking is
restored from the server gallery after interruption; gallery images remain on
the server. Dataset preparation remains offline. Future server deployments target the VPS unless explicitly requested
otherwise. See [server operations](server/README.md).
