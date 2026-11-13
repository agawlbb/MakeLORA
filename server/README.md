# MakeLORA server

The default deployment target is **https://vps.coffeybean.com/MakeLORA/** in
`/opt/services/shared-frontend`, using the existing frontend container. Deploy to
the VM only when explicitly requested. The VM remains the development workspace.

Management requires the existing Firebase sign-in and current `vps_access` claim.
The shared gateway enforces sign-in even for CSS. Device requests use only the
pairing bearer credential; they do not follow browser sign-in redirects. The edge
allows exactly `/MakeLORA/api.php` through to device authentication. Never expose
other management routes without shared sign-in.

## Deployment

Install PHP dependencies in the VM development container, commit source, then
publish through the existing SSH connection:

```sh
dev bash -lc 'cd /home/dev/projects/MakeLORA/server && composer install --no-dev --prefer-dist'
bash server/deploy-vps.sh
```

The deployment script runs on the VM host, uses `dev ssh vps-admin`, and copies
only server source and dependencies. It does not build or release the iOS app,
change databases, or overwrite private settings/data. VPS routing, authentication,
main-page link and backup policy are tracked in `vps_admin`; keep that runbook
current when changing infrastructure. Deployments use the canonical source and
preserve live private state.

Public hosting contains only the gateway and rewrite rules under
`public/MakeLORA`. Server source/vendor live at
`private/makelora/app`, outside the document root. The existing private read-only
mount exposes settings at `/run/site-private/makelora/settings.php`. Configure
`environment=production`, `open_management=false`, and
`base_url=https://vps.coffeybean.com/MakeLORA`. Shared sign-in is checked before
management database access. Errors and request logs must never contain token
values, Authorization headers or POST bodies.

## Persistent data

The dedicated production MariaDB schema/user are both `makelora`; its runtime
account has only SELECT, INSERT, UPDATE and DELETE privileges for that schema.
Private settings contain the generated production password; VM test credentials
are never deployed. Import `schema.sql` explicitly when provisioning an empty
database. Existing migrations are idempotent schema setup for older catalogs;
web requests never create tables.

- Model files: `/opt/services/shared-frontend/data/makelora/files/`.
- Provider token and private sessions:
  `/opt/services/shared-frontend/data/makelora/private/`.
- Database settings: `/opt/services/shared-frontend/private/makelora/settings.php`.

Private data directories are owned by UID/GID 33, mode 0700. Files use mode 0600;
settings use mode 0400. None are in Git or publicly served. The persistent
`replicate-token` file remains until explicitly removed, independently of PHP
session expiry. The frontend accepts it once through a password field and then
shows only the remove control. Save/remove require a session CSRF token. Paired
device provider operations must read the credential server-side after verifying
an active device credential; never send the provider token to a device. No
provider jobs are started without an authenticated generation request.

The production backup policy captures the dedicated database and grants, private
configuration, model files and persistent token. Transient `sess_*` files are
excluded. Restore data to the same paths with the recorded private permissions.
See `vps_admin`'s existing runbook and restore inventory for the full procedure.

## Pairing and compatibility

Invitations use version 1, a fixed HTTPS server URL and a random 256-bit secret.
They expire after five minutes and redeem once under a database row lock. Match
the six-digit code in the app before approval. Device bearer credentials are
stored hashed in MariaDB and in device-only Keychain storage on the app. Revoked
devices lose access on the next request. Pending requests expire after five
minutes. No API can list/manage other devices or create invitations.

The migration preserves existing device records and token hashes. The old
`https://vm.coffeybean.com/makelora/api.php` URL is served directly by the VPS edge,
rewritten to the new device API without redirects or VM dependency. Existing
paired devices keep working. Old browser management URLs redirect to the new
VPS website; new invitations contain the new URL. Do not remove the compatibility
route while existing paired devices still use it.

All API responses are JSON with no-store caching:

- `POST api.php?action=redeem`: JSON `invitation`, `name` (1–100 characters).
  Returns 201 with `deviceID`, `token`, `confirmation`, `status: pending`.
- `GET api.php?action=status`: bearer token; returns device ID/name, confirmation
  and pending/active status. Updates last contact.
- `POST api.php?action=disconnect`: bearer token; revokes that device.
- Invalid/unknown/revoked credentials return 401, expired invitations/pending
  requests 410, invalid input 400, unsupported operations 405, failures 503.

## Private file catalog

The page lists one collapsed row per safetensors file: display name, upload time
and target model. Expanding shows the original filename, hash and inspection
metadata. Device generation uses scoped, signed provider downloads; model binaries are
never committed to Git.

The CLI importer supports `file_storage_directory` from private settings and
requires Python 3 plus PHP CLI. It snapshots source bytes, validates bounded
headers, tensor lengths and offsets, calculates SHA-256, then stores a private
content-addressed file. Identical imports update inspection only, preserving
display name, target model, original filename and upload date. Different bytes
with the same source filename receive distinct storage names. No model is
executed. The scanner rejects unsupported dtypes rather than guessing; inspection
validates the container, not model quality. Run imports only when requested,
with the correct private configuration and write access to private storage.

## Verification

Run isolated checks inside VM development:

```sh
dev bash -lc 'cd /home/dev/projects/MakeLORA && php server/tests/private_session.php'
dev bash -lc 'cd /home/dev/projects/MakeLORA && python3 -m unittest discover -s server/tests -p "test_*.py"'
```

`production_http.py` tests production routing with fixture sign-in, private test
storage and VM `.test-config/makelora.php` database access. The older integration,
catalog and importer scripts also target a disposable VM prototype, not the VPS.
Provision a disposable schema/settings before running those database tests;
never use production credentials for them. Shared Firebase session/claim/revocation
regressions live in `vps_admin`'s `shared-frontend/test-auth.py`.

Live deployment verification must check anonymous management redirects, invalid
Firebase cookies, sign-in return paths, authorized management, CSRF rejection,
private path denial, model checksum, token preservation, and device pairing/status
through both the current and compatibility API URLs. Remove temporary test rows
and credentials afterwards. No iOS build/release is part of a server deployment.


## Mobile generation and shared output gallery

For an existing installation, apply `migrations/004_generations.sql` if generation
has never been installed, then `migrations/005_server_gallery.sql` and
`migrations/006_generation_recovery.sql` and
`migrations/007_generation_retries.sql` and
`migrations/008_generation_recipes.sql` and
`migrations/009_video_generation.sql` before deploying.
New installations use the updated `schema.sql` instead of replaying migrations.
Migration 005 preserves older prediction IDs. PHP requires cURL and outbound
HTTPS access to `api.replicate.com` and `*.replicate.delivery`. The existing saved
Replicate token is reused; no provider credential is returned to a device.

Active paired devices can:
- GET `api.php?action=models` for the weight catalog.
- POST `action=generate` with `model` (catalog SHA-256), `image` (JPEG data URI),
  `prompt`, `aspect_ratio`, `lora_scale`, optional integer `seed`, and optional
  boolean `retry_offline` (omitted means one-shot). Instead of `image`, send
  `source_output_id` to reuse that output’s retained original; supplying both
  is rejected. All model/settings validation still applies.
- GET `action=prediction&id=...` to poll a server job, including a job started by
  another approved device.
- GET `action=gallery` to list the shared server gallery. Pages contain up to 100
  metadata entries and a `next` cursor; pass it as `before` for the next page.
  The first page also includes up to 100 newest unfinished/failed jobs in `jobs`,
  with a single `latestStatus` message and no log history. Prediction polling
  updates that message; successful archival replaces the job tile with images.
- GET `action=generation_details&id=...` for an output’s immutable submitted
  settings, available original flag, and resolved seed when provided. Legacy
  outputs explicitly report missing data.
- GET `action=generation_input&id=...` for its original input JPG in memory.
- GET `action=output&id=...` to view a private archived JPG.
- POST `action=remove_output&id=...` to remove an image for every device.
- POST `action=cancel_retries&id=...` to stop future submission attempts. An
  already accepted provider run can still finish and archive its outputs.
- POST `action=dismiss_generation&id=...` to hide a failed, unconfirmed or active
  generation tile for every device and stop its automatic retries. This does not cancel a paid run or delete its
  outputs. The job/callback record remains so later completion still archives
  images. Dismissal works even when Replicate is unavailable.

Every operation above requires `Authorization: Bearer <active device token>`.
Missing, malformed, unknown and revoked tokens fail authentication; pending
devices cannot access these operations. There are no public output URLs. Images
are served with `Cache-Control: no-store`. The mobile gallery keeps display data
in memory; only an explicit Share request writes a temporary original for the
iOS share sheet, cleaned up on dismissal or the next launch after termination.

Current supported bases are `Qwen/Qwen-Image-Edit-2509` and
`Qwen-Image-Edit-2509`. Other weights remain visible with generation disabled.
The fixed provider endpoint is `qwen/qwen-image-edit-plus-lora`, with JPG output
and safety checking disabled.

The server supplies a one-hour signed `action=weights` URL to Replicate for the
selected private weight. Both GET and HEAD require the same valid signature;
HEAD returns size/type without model bytes. This authorizes only that file and exposes no
device/provider token. It expires independently of device revocation and becomes
invalid if the provider token changes.

### Submission errors and status recovery

Provider failures retain their HTTP category and return an actionable message
with a random diagnostic reference. The server logs only that reference, HTTP
status and transport error code; raw provider bodies, input data, signed URLs
and credentials are excluded. Billing (402), token/access (401/403), validation
(400/422), missing model/prediction (404), throttling (429), and network/provider
outages are distinguished. Create rejections are stored as failed jobs even
without a provider ID. Timeouts/5xx are `unconfirmed`, because the provider may
have accepted the request before the response was lost. Errors include `jobID`,
`jobStatus` and `retryAfter` when applicable.

The app can always submit another generation once the current submission
request ends; it no longer waits on a single locally persisted pending marker.
Old pending markers are retired on upgrade, and jobs are restored from the
server. Status-check failures are inline tile messages with a retry action,
rather than repeated modal alerts. Polling does not create new predictions.

A database claim caches each job's status check for at least ten seconds across
all paired devices. Throttled/failed checks honor the provider's bounded
`Retry-After` delay (default 30 seconds), avoiding a request loop.
Completion callbacks bypass the short cache so archival happens promptly.
A provider prediction returning 404 becomes a failed, dismissible tile.
Dismissal and callback retries never resurrect the tile or delete archived
originals. Migration 006 adds the dismissal and next-check timestamps.

### Offline submission retries

The updated composer enables **Retry temporary failures** by default. With
`retry_offline: true`, one durable gallery tile tracks the initial submission
and up to 24 retries, spaced 30 minutes apart within a 12-hour window. Network
errors, HTTP 408/429 and provider 5xx qualify; authentication, billing and input
errors stop immediately. Accepted predictions are only polled and archived;
a failed inference is not automatically submitted again. The app can close
without stopping the queue. **Stop retries** or **Remove tile** stops future
attempts. Revoking the submitting device also prevents further submissions.

The server privately retains validated input image/prompt/settings under
`private_session_directory/retry-inputs` (directory 0700, files 0600). It removes
retry-payload copies after confirmed acceptance, cancellation or expiry. The worker
cleans expired crash leftovers; existing backups follow their normal retention.
Each attempt creates fresh signed weight/callback URLs and uses the saved
server token. An uncertain submission is reconciled against provider history
before another POST. Missing or ambiguous history pauses retries rather than
risking a blind duplicate; this is not an exactly-once provider guarantee.
Older failed jobs have no retained image and must be submitted again.

After deploying the code and migrations, explicitly install the worker timer:

```sh
bash server/deploy/install-retry-worker.sh
```

This is a production activation step, separate from normal deployment. It checks
configuration/schema, installs the systemd service/timer and enables a queue
pass every minute. No device connection is needed. Inspect with
`systemctl status makelora-generation-retries.timer` and
`journalctl -u makelora-generation-retries.service`. Disabling the timer pauses
background processing; queued work remains stored. The CLI `--check` validates
setup without processing jobs or contacting Replicate.

### Gallery viewing and rerunning

The app opens gallery photos full screen, fitting the available iPad/iPhone
viewport. Pinch/pan supports up to 6× fitted size; double-tap toggles 2×/fit.
Swipe between gallery images while fitted. Below the photo, **View settings**
shows the immutable submission snapshot and **Run again** opens an editable
composer with its original photo and settings. Blank submitted seeds remain
blank (random); a provider-resolved seed is shown separately.

Migration 008 adds `makelora_generation_recipes`. Every new submission saves
its validated original under `private_session_directory/generation-inputs`
(directory 0700, JPG files 0600), independently from temporary retry payloads.
Settings preserve catalog SHA, display name/base, prompt, aspect ratio, scale,
submitted seed, output format, safety and retry settings. No tokens or signed
URLs are stored in recipes or returned in details.

All approved devices share these originals under the same pairing authentication
and no-store policy as outputs. The app retains preview bytes in memory only;
replay sends a source reference unless the user chooses a replacement image.
Deleting the last output removes the original after active work has finished.
Failed requests without outputs and crash leftovers are cleaned after 12 hours
by the existing retry worker. Include originals and recipes in the existing
private-data/SQL backup inventory; historical backups follow normal retention.
Older outputs cannot recover unsaved photos/settings: the composer restores the
known prompt, matches a model only by unique saved name, and explicitly requires
a photo with defaults for unavailable fields. New recipes always use exact SHA.
Missing/unsupported models require choosing an available supported weight.

Deploy migration 008 and server code before releasing the new app. Existing
clients remain compatible. The worker `--check` verifies the new table/storage;
no worker schedule change is necessary.

### Server archival

Generated originals are stored under `private_session_directory/outputs`,
outside the public document root (directory mode 0700, file mode 0600).
The PHP user needs write access and sufficient storage. Include this directory
and the database in the existing server backup process; no new backup jobs are
installed by this change.

Each new prediction registers an HTTPS completion callback at
`api.php?action=generation_webhook&id=...&secret=...`. The callback's random
secret is scoped to that job and stored only as a hash; it grants no gallery,
weight catalog or device access. Keep callback query strings out of access logs.
The server re-fetches the provider prediction before trusting its result.
Downloads accept only HTTPS Replicate delivery hosts, reject redirects, cap
each original at 50 MB and validate JPG content. Originals are committed with
gallery metadata before success is reported. Duplicate callbacks and concurrent
polling serialize on the job row; deletion tombstones prevent image resurrection.

Completion callbacks archive outputs while the app is closed; polling also
retries archival if a callback fails. A callback can recover a provider ID when
the create response was lost or has not yet been recorded, after verifying that
the provider prediction contains the matching callback. Background submission retries require the separately installed timer above. Keep `base_url` publicly reachable over HTTPS without redirects,
allow the callback through the frontend, and permit image submissions up to
16 MB. Provider output retention and callback retry windows still limit recovery
during an extended server outage. If submission loses its response before a job
ID reaches the device, inspect the shared gallery and Replicate before retrying
to avoid a duplicate paid prediction.

### Tests

Inside development, run:

```sh
php -n server/tests/generation.php
php -n server/tests/weight_download.php
php -n server/tests/retry_queue.php
php server/tests/gallery_schema.php
php server/tests/retry_schema.php
php server/tests/recipes_schema.php
```

The fake-provider suites use no network or paid requests and cover retry timing,
expiry, cancellation, response loss, duplicate prevention and archival recovery.
The first uses a fake provider/database to test pairing-token rejection, shared
access from two devices, callback archival without a client, invalid output
rollback, missing-create-response recovery, pagination, deletion and retry
idempotency. It starts no paid jobs. The SQL check requires the VM's existing
`/home/dev/projects/.test-config/makelora.php` credentials and uses temporary
tables only; it never applies production migrations. Set `MAKELORA_TEST_CONFIG`
to another existing VM `.test-config` PHP file when needed (for example the
shared `lensswap.php` test configuration); the schema checks reject database
names that do not contain `test`.


## Wan 2.1 image-to-video

Deploy migration **009_video_generation.sql** before this server version, and
release the app only after the server is updated. New installations use
`schema.sql`. Migration 009 is idempotent and defaults old jobs/outputs to
Qwen/JPEG. No production deployment is performed by development or tests.

The adapter uses the documented official-model endpoint
`models/wavespeedai/wan-2.1-i2v-480p/predictions`. Replicate hides/aliases the
execution version for this official model, so inference cannot be pinned using
historical community-version URLs. `src/contracts/wan-2.1-i2v-480p.json` records
verified input constraints, URI output shape and observed public schema ID
`e2870aa4965fd9ddfd87c16a3c8ab952c18e745e63f3f3b123c2dc8b538ad2b5`.
Recipes and jobs retain that schema ID as provenance, rather than claiming an
immutable execution build. Retry reconciliation verifies the attempt-scoped
callback secret, including predictions with internal model aliases or hidden
versions; ambiguous history pauses resubmission. This version has
no frame-count, FPS or duration inputs. Its ratios are `16:9`/`9:16` and its
acceleration modes are `Off`/`Balanced`/`Fast`.

The model catalog includes a base Wan entry without uploaded weights. Custom
Wan LoRAs must declare target model `Wan-AI/Wan2.1-I2V-14B-480P` when imported
with the existing importer. 720p, T2V and Wan 2.2 weights are not accepted for
this endpoint. Signed weight delivery and device access requirements are
unchanged. Base generation omits LoRA weights/strength entirely.

**Runtime prerequisite:** install FFmpeg's `ffprobe` executable on the PHP server
(default `/usr/bin/ffprobe`) and permit PHP `proc_open`. A nonstandard executable
can be configured with `ffprobe_binary` in private settings. This is checked
before accepting a paid Wan submission. The request archives at most 250 MB per
video, validates the MP4 container/video stream using a bounded local ffprobe
process, and streams authenticated downloads with single-byte-range and HEAD
support. Qwen retains its 50 MB JPEG limit. Review the HTTP/PHP request timeout
budget to permit video archival (the provider download timeout is 180 seconds).

Gallery responses add `mediaType` and `mimeType`. Catalog responses add `family`,
`mediaType` and `isBase`. These fields are additive; update clients alongside the
server because older galleries cannot display video. Video outputs remain
private in the existing output directory. Original images, saved Wan parameters,
provider identity/version, retry scheduling and callback deletion tombstones
use the same retention rules as Qwen. No training videos are uploaded from
local dataset projects by this feature.

Additional development checks (no paid requests):

```sh
php -n server/tests/wan_generation.php
php -n server/tests/wan_retries.php
python3 -m unittest discover -s server/tests -p 'test_*.py'
```

Set `MAKELORA_TEST_FFPROBE` to a development-only ffprobe path if it is not
installed at `/usr/bin/ffprobe`. `tests/fixtures/wan-output.mp4` is a synthetic
32 × 32 blue clip created solely for archival validation. Existing schema tests
cover the migration and Wan replay using connection-local temporary tables and
VM `.test-config` credentials only. Swift core tests cover old project loading,
video references/trims and flat filenames; iOS tests cover conversion, source
orientation, variable timestamps, cancellation and generation requests. Run iOS
tests on macOS with the existing validation workflow; Linux has no Apple SDK.

## Google Drive and server video datasets

The app's **Datasets → Server datasets · Google Drive** keeps this workflow
separate from existing offline projects. Active paired devices share the server
library. Videos travel **Drive → server**, while the device streams only a 360p
preview and eight timeline thumbnails. Trims, normalized crops and UTF-8 captions
are metadata until an explicit **Render dataset on server** operation. Multiple
clips reuse one retained original. ZIPs contain numbered `1.mp4`/`1.txt` pairs at
the root, with the cropped shorter side resized to 480 even pixels, no audio and
no separate control image. Numbers reflect the current clip order on each export.
Server datasets are editable manifests, independent from local project formats.

### Setup and deployment

This feature requires server deployment and a new app release. No database
migration is needed: atomically replaced JSON manifests live beside private
video files under `private_session_directory/datasets`. Preserve this directory,
`google-drive-client.json`, `google-drive.json` and `dataset-signing-key` with the existing private backup
inventory. They are not web-accessible. Do not create another backup job.

1. Enable the Google Drive API in a dedicated Google Cloud project. Configure
   an OAuth consent screen and a **Web application** OAuth client. Register the
   exact redirect `https://vps.coffeybean.com/MakeLORA/drive.php` (or your configured
   `base_url` plus `/drive.php`). Download the Web client JSON and upload it through
   **Google Drive connection → Upload client JSON** on the authenticated server
   website. The server validates the client type/redirect, stores only client ID
   and secret privately, and never echoes the secret. Existing private settings
   keys `google_drive_client_id`/`google_drive_client_secret` remain a fallback
   when there is no uploaded client file. Do not use
   credentials belonging to another app, or put credentials in Git/the iOS app.
2. Deploy code and the updated gateway allowlist (`drive.php`). Ensure FFmpeg,
   ffprobe, PHP cURL/mbstring/zip and `proc_open` are available. PHP's user needs
   the existing mode-0700 private storage directory. `ffmpeg_binary` and
   `ffprobe_binary` default to `/usr/bin/ffmpeg` and `/usr/bin/ffprobe`.
3. Run `php server/bin/process-datasets.php --check` with the installation's
   private `MAKELORA_CONFIG`. This only checks local prerequisites. Once deployment
   is authorized, run `bash server/deploy/install-dataset-worker.sh` on the VM to
   install/enable the dedicated systemd timer. No worker is activated by tests,
   deployment packaging, or a device request. The existing generation retry
   worker is unchanged. Disable the dataset timer to pause queued work.
4. Open **Google Drive connection** on the authenticated server management page
   (also linked from the app), sign in to Google and grant read-only offline
   access. The OAuth state is single-use, browser-session-bound and expires in
   ten minutes; code exchange uses PKCE. Tokens stay in mode-0600 private files.
   The server refreshes access tokens without an open app. Disconnect removes
   this installation's tokens; optionally revoke the grant in Google Account
   settings too. Existing imported originals remain until their dataset is deleted.

The account grants `drive.readonly` because an in-app folder browser must list
existing videos throughout the account. The management page discloses this
account-wide read access before consent. This is **not** a folder-scoped grant;
use a dedicated Google account containing only intended training data if that
boundary is required. All approved paired devices can browse this connected
account and share imported datasets. This is the existing single-owner server
permission model, not a multi-user service. Google may require OAuth verification
for broader distribution; an external consent app in Testing can have expiring
refresh tokens. Configure the consent audience/publishing status appropriately.
See Google's [web-server OAuth documentation](https://developers.google.com/identity/protocols/oauth2/web-server)
and [Drive scopes](https://developers.google.com/workspace/drive/api/guides/api-specific-auth).

### Operation and limits

Browse **My Drive** or **Shared with me**, open folders, select up to 100 videos
across folders and import. Listings are paginated. The server downloads only
selected videos and an optional identical-stem `.txt` sibling; duplicate matching
captions or non-UTF-8 text fail clearly. Missing captions start blank. Drive
shortcuts and Shared Drives without a browsable shared folder are not listed as
special root entries; this first version does not offer a separate Shared Drives
root chooser. Private files do not need public sharing links. Downloads use the
[authorized Drive media API](https://developers.google.com/workspace/drive/api/guides/manage-downloads),
not Google web-preview pages. Deleted or non-downloadable sources fail the queued
import. A successful server copy remains usable if its Drive source later changes
or disappears; it does not automatically sync subsequent Drive edits.

Default original limit is 2 GiB (`dataset_video_limit_bytes`), total library budget
50 GiB (`dataset_storage_limit_bytes`), up to 500 source entries and 500 clips per
dataset. Inputs are limited to 30 minutes, 8192 pixels per dimension, 40 megapixels,
and a maximum 16:1 display aspect ratio. MOV/MP4, Matroska/WebM and AVI containers
are supported when FFmpeg can decode their video. Rotation and non-square pixels
are normalized before cropping. Extremely small crops can fail encoding; errors
remain visible and a wider crop can be exported again. The server reserves storage
headroom before jobs; estimates are conservative but operators must still monitor
actual disk usage. FFmpeg is limited to two encode threads, each process has a
30-minute timeout, and imports have a 30-minute download timeout. ZIPs use the
server's ZipArchive/ZIP64 support rather than the local app's 4-GiB ZIP limit.

The single worker takes one queued import or export per pass. Its global file
lock prevents duplicate work; a surviving `processing` state is restarted after a
crash, without creating external inference jobs. Status and sanitized errors are
stored in the manifest. Local originals are replaced when restarting an interrupted
import; temporary render files are replaced on export retry. A failed import can
be retried in place in the app. Swipe a source row to remove its retained files
and dependent clips; active processing must finish first. The app warns when the worker has no recent heartbeat and
is not currently running. Delete a dataset after its active processing finishes to
remove originals/previews/exports; queued work is removed with it. Drive originals
are never modified. List/GET operations do not trigger processing.

Playback URLs are HMAC-signed, scoped to one media item and one active device,
expire in one hour, support GET/HEAD and single byte ranges, and are checked
against device revocation on every request. They contain no device bearer token
or Google credential. Treat these URLs as temporary credentials: keep query
strings out of HTTP access logs. Reopen an editor/dataset to refresh an expired
URL. **Share download link** intentionally shares access to that ZIP for one hour;
it does not download the ZIP through the device. Dataset edits invalidate stale
export URLs. Save uses a manifest revision and rejects concurrent overwrites;
the clip editor merges unrelated changes when its own clip is unchanged. Export
captures a revision and rejects its result if the dataset changes while rendering.

Additional APIs (all active-device bearer authentication except signed media):
`drive_status`, `drive_files` (`folder`, `page`), `datasets`, `dataset_create` (POST
name), `dataset` (GET id), `dataset_import` (POST id, files), `dataset_save` (POST id,
name, revision, clips), `dataset_export` (POST id), `dataset_delete` (POST id), and
`dataset_remove_video` (POST id, video query parameter), and
`dataset_media` (scoped signed GET/HEAD). No API returns original server paths or
Google credentials. The `drive.php` browser route requires normal management
sign-in and CSRF-protected connect/disconnect; a paired device cannot replace
server Drive credentials.

Development verification (no Google/Replicate requests):

```sh
dev bash -lc 'cd /home/dev/projects/MakeLORA && python3 -m unittest server.tests.test_datasets -v'
```

Install FFmpeg inside development to run the real trim/crop/ZIP test. The HTTP
suite checks active-device access, queue-only imports, duplicate prevention,
invalid paths/trim/crop, revision conflicts, scoped playback, expiry/revocation,
byte ranges/HEAD, deletion and stale export invalidation. Complete a live OAuth
connection and one private Drive import after configuring the dedicated client;
synthetic tests do not prove Google consent configuration or access to your files.

Manual `validate.yml` dispatches default to server tests and an iOS Swift source
type check without producing an app build. Set `build_app=true` only when an app
build/test has been requested. Automatic push/PR app validation is unchanged.

The protected Drive page accepts Google Web client JSON uploads up to 32 KiB.
A matching server redirect URI and CSRF token are required. Replacing an existing
client requires explicit confirmation, removes the current server Drive tokens
and invalidates pending authorization for the old client; imported datasets remain.
The mode-0600 `google-drive-client.json` in private storage takes precedence over
legacy settings keys. It is read by the API and worker too; no app release or
server restart is needed after uploading. The file is covered by the existing
private-data backup capture. Never upload credentials through chat or commit them.
