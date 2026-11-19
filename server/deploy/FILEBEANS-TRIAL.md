# FileBeans dataset trial

Keep `feature/filebeans-datasets` (MakeLORA) and `feature/makelora-datasets`
(fileBeans) unmerged until the owner decides to retain this feature. Both use
explicit feature worktrees; the canonical main checkouts remain unchanged.

Runtime artifacts are under MakeLORA's ignored `build/` directory:

- API: `filebeans-api:dc6ecd6-datasets`, source `dc6ecd6`.
- Normalizer: `filebeans-normalizer:793eeb8-datasets`, source `793eeb8`.
- Broker: `filebeans-vault-broker-793eeb8`, source `793eeb8`.
- MakeLORA server and published TestFlight 13 source: `f62babc`.
- Adjacent `.tar.json` files contain archive checksums and image digests.

Verification passed: server tests and PHP lint; release-script tests; Apple source
validation; real FFmpeg preparation/rendering, upload retries and SQL recovery;
hidden protected-reference errors; encrypted local/Samba preparation and idle
expiry; full Go race tests with runtime rclone 1.76.0; vet; isolated image smoke
checks. Set `FILEBEANS_TEST_RCLONE` to the prepared runtime's rclone for Go tests;
the older development binary causes an existing critical-log test failure on main.

## Completed cutover — November 19, 2026 UTC

The archive-move maintenance finished before deployment: its marker was absent
and the broker active. The owner explicitly requested server cutover and app
publication. Both feature branches remain unmerged.

Deployed the VM-prepared API, broker and normalizer using
`/opt/services/filebeans/makelora-datasets.compose.yaml` with `--no-build
--no-deps --pull never`. The API and normalizer are running with zero restarts.
The prior images were `filebeans-api:d988424-fast-moves` and
`filebeans-normalizer:3644c21-recovery`.

MakeLORA's application directory was exchanged atomically with the prepared
server artifact. Its existing frontend container was preserved. The mode-0600
private FileBeans connection uses the existing server token and `VPS`/`Samba`
sources. The retired dataset timer is disabled; the generation timer remains
active and generation implementation files were verified unchanged.

Live checks verified `datasetMediaV1`, authenticated source discovery, the
MakeLORA-to-FileBeans connection, HTTP 401 for unauthenticated device APIs, and
HTTP 302 to sign-in for management. Protected folders are locked after broker
restart and can be unlocked using the FileBeans mobile app. Physical-device
capture, upload, editing and rendering acceptance remains a user check.

Rollback files, original application archive, service identities, verified input
artifacts and the deployment report are retained root-only under
`/opt/services/filebeans/deploy/makelora-datasets-dc6ecd6/`. Its `before.json`
and `after.json` describe the cutover. The previous MakeLORA application also
remains at `private/makelora/app-next-datasets-f62babc` after the directory exchange.

[TestFlight publication 44597039231](https://github.com/agawlbb/MakeLORA/actions/runs/44597039231)
passed simulator tests, signing, upload and internal audience verification.
MakeLORA **0.1.0 (13)** is **VALID / IN_BETA_TESTING** for the existing sole
intended internal tester. Apple build ID: `32dff6d2-23a1-439d-bd08-1703af037feb`.

Rollback restores saved images, broker binary, Compose configuration and MakeLORA
code/gateway. FileBeans originals and published outputs remain intact.

## Original-source correction — November 19, 2026

Deployed FileBeans API `b5c4c7f` (`filebeans-api:b5c4c7f-originals`) and MakeLORA
server `3fdbcf6`. The FileBeans API includes the earlier Drive fixes. Existing
normalizer, broker, credentials, and generation services remain in place.

Existing-source registration records the original path/revision only. Metadata
inspection is read-only; content responses stream original bytes with range and
HEAD support. No preparation jobs, preview videos, thumbnail files, or automatic
clips are created. Old preparation jobs cannot execute. Rendering writes directly
to the chosen output destination and occurs only on explicit dataset export.

Verification passed: 23 MakeLORA server tests; FileBeans Go race suite and vet;
original byte/range/revision checks; real FFmpeg export and recovery; protected
local/Samba original access, locked errors, and inactivity renewal; Apple app
validation. Live checks verified the image digest, deployed source hashes,
authenticated original-streaming capability/source discovery, unauthenticated
HTTP 401, disabled dataset timer, and active generation timer. Both API and
frontend run with zero restarts. Production test media/jobs were not created.

The corrected iOS release **0.1.0 (14)** uses `3fdbcf6`. Apple processing and
sole internal tester verification passed (**VALID / IN_BETA_TESTING**); see
`RELEASE.md` and workflow 44613430749. Feature branches remain unmerged.
Temporary deployment/recovery material remains at
`/opt/services/filebeans/deploy/originals-b5c4c7f/` and
`private/makelora/app-originals-3fdbcf6`; automatic approval review rejected their
removal to preserve recovery evidence. Earlier retained trial recovery is intact.
