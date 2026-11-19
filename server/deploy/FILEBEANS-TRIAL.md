# FileBeans dataset trial

Keep `feature/filebeans-datasets` (MakeLORA) and `feature/makelora-datasets`
(fileBeans) unmerged until the owner decides to retain this feature. Both use
explicit feature worktrees; the canonical main checkouts remain unchanged.

Runtime artifacts are under MakeLORA's ignored `build/` directory:

- API: `filebeans-api:dc6ecd6-datasets`, source `dc6ecd6`.
- Normalizer: `filebeans-normalizer:793eeb8-datasets`, source `793eeb8`.
- Broker: `filebeans-vault-broker-793eeb8`, source `793eeb8`.
- MakeLORA: `makelora-server.tar`; TestFlight 13 app source `ad66ac9`.
- Adjacent `.tar.json` files contain archive checksums and image digests.

Verification passed: server tests and PHP lint; release-script tests; Apple source
validation; real FFmpeg preparation/rendering, upload retries and SQL recovery;
hidden protected-reference errors; encrypted local/Samba preparation and idle
expiry; full Go race tests with runtime rclone 1.76.0; vet; isolated image smoke
checks. Set `FILEBEANS_TEST_RCLONE` to the prepared runtime's rclone for Go tests;
the older development binary causes an existing critical-log test failure on main.

## Deployment dependency

Deployments and app releases are authorized, but existing FileBeans archive-move
maintenance must finish first. The broker was deliberately stopped at 15:38 UTC
on November 19, 2026. Its systemd condition references
`/opt/services/filebeans/deploy/vm-pic-archive-move/maintenance.json`.
Do not remove that marker or override the stopped broker for this feature.

After coordination, recheck active tasks and image identities. Previously active
images were `filebeans-api:d988424-fast-moves` and
`filebeans-normalizer:3644c21-recovery`. Preserve Compose configuration, broker
binary, MakeLORA code/gateway and service state as root-only rollback artifacts.
Load verified VM-prepared images; update the broker, API and normalizer with a
feature Compose overlay and `--no-build --no-deps --pull never`. Do not build on
the VPS or change default branches. Preserve private settings and user data.

Configure MakeLORA's mode-0600 private `filebeans.json` using the existing server
token, `https://files.coffeybean.com/companion`, and allowed source names `VPS` and
`Samba`. Never print credentials. Deploy the server archive and updated gateway;
disable the retired dataset timer, preserving the generation timer. No migration
or deletion of old credentials, originals, exports or backups is required.

Verify authenticated capabilities (`datasetMediaV1`), source discovery, broker
readiness, container health, MakeLORA-to-FileBeans access, pairing enforcement and
management sign-in. Do not create production test data. Physical-device capture,
upload, unlock/retry, playback and render acceptance follows cutover.

Rollback restores saved images, broker binary, Compose configuration and MakeLORA
code/gateway. FileBeans originals and published outputs remain intact.
