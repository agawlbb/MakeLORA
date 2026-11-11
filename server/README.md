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
provider jobs or downloads are currently implemented.

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
metadata. There is no upload/download HTTP endpoint and device tokens cannot
read files. Model binaries are never committed to Git.

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
