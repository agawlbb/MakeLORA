# Pairing prototype

PHP 8.2+ and MariaDB. The management page is intentionally open on the VM. Device
credentials grant only status/disconnect access; there are no file/provider APIs.
The open management page lists the private VM file catalog described below.
Do not enable this open management mode for a service with real privileges.

Install dependencies inside development:

```sh
dev bash -lc 'cd /home/dev/projects/MakeLORA/server && composer install --no-dev --prefer-dist'
```

Set the web document root/alias to **server/public only**, import `schema.sql`, and
set `MAKELORA_CONFIG` to an absolute private PHP settings file based on
`settings.example.php`. Configure a fixed HTTPS `base_url`; request Host headers
are never used to generate invitations. Settings and database credentials stay
outside Git. The runtime deliberately refuses non-prototype configurations until
shared authentication is integrated.

The VM route is `/makelora/`. Its private configuration uses the existing
VM-only LensSwap test database credential, with isolated `makelora_` table names;
no LensSwap tables are accessed. A dedicated MakeLORA database/user can replace
this configuration later. Schema creation is explicit and idempotent, not run by
web requests. The VM Apache mount/alias is tracked separately in vm-laptop.

Invitations contain version 1, the server base URL, and a 256-bit random secret.
They expire after five minutes and are redeemed once under a row lock. Secrets
are stored hashed. The website shows a pending device's six-digit confirmation
code. Approve only after matching it on the iPad. Pending requests expire after
five minutes. Device credentials are random 256-bit bearer tokens, stored hashed
server-side and in device-only, when-unlocked Keychain storage on the iPad after
approval. Prototype credentials last until revocation; future privileged access
requires a review of expiry/rotation and authorization. Revocation takes effect
on the next request. Revoked devices remain visible for management history.

The app supports one server connection. Return to Projects → Server to pair,
check status, or disconnect. Camera-unavailable devices can paste the displayed
invitation. Pending credentials remain in memory, so closing the app during
pairing requires a new invitation. The website and app use manual refresh/check
buttons. Disconnect removes local credentials even if offline; if the server
cannot be reached, revoke the device on the website. No credentials follow HTTP
redirects. No server address or credential is embedded in the app.

## API

### Replicate token storage

The frontend accepts a Replicate API token through a password field and shows
only saved/absent status afterwards. Save and remove require the management
session's CSRF token. Tokens are never returned in HTML or device API responses,
and this feature makes no Replicate requests or jobs.

Before enabling it, create a directory outside every Git checkout and web
document root, owned by the PHP runtime user with mode **0700**, and set
`private_session_directory` in the private settings file to its absolute path.
For example use `/var/lib/makelora/private-sessions`, never `server/public` or
any web alias. The application refuses missing, permissive, or in-repository
directories. PHP's file session handler writes mode **0600** files there.
Do not add this directory to public hosting, source control, or request-body logs.
Treat any separately arranged backups as containing credentials.

This open prototype has no user accounts: tokens belong to individual browser
sessions, not the shared management page or paired devices. Removing a token
rewrites that session without it; revoke it at Replicate too if revocation is
needed. Losing the session cookie loses access to its saved token. Configure
normal PHP session garbage collection for this private directory to remove
expired sessions; session lifetime follows the server's PHP settings. Changing
the directory also starts fresh management sessions. Shared sign-in is still
required before production deployment.

Verify storage permissions, session isolation and removal inside development:

```sh
dev php /home/dev/projects/MakeLORA/server/tests/private_session.php
```

All responses are JSON with no-store caching. Errors contain `error`.

- `POST api.php?action=redeem`: JSON `invitation`, `name` (1–100 characters).
  Returns 201 with `deviceID`, `token`, `confirmation`, `status: pending`.
- `GET api.php?action=status`: Bearer token; returns `deviceID`, `name`,
  `confirmation`, `status` (`pending` or `active`). Updates last contact.
- `POST api.php?action=disconnect`: Bearer token; revokes that device.
- Invalid/unknown/revoked credentials return 401, expired invitations/pending
  requests 410, invalid input 400, unsupported operations 405, failures 503.

No API can list/manage other devices or create invitations. Website mutations
require a session CSRF token and secure same-site cookies. Tokens must not be
logged. Keep HTTPS and default logs without request bodies/authorization headers.

## Verification and deployment

Run the following only against the VM prototype:

```sh
dev bash -lc 'cd /home/dev/projects/MakeLORA && python3 server/tests/integration.py https://vm.coffeybean.com/makelora'
```

The test creates temporary devices, removes those device rows, and leaves
short-lived invitation rows. Swift invitation tests run with the existing package
CI. QR camera/Keychain checks need a physical iPad and a separately requested iOS
build; no build or release is part of this change.

VPS deployment is deferred. Integrate management requests with the existing
shared sign-in and `vps_access` claim, keeping device endpoints outside browser
redirect authentication. Add a directory link, configure the production database,
and enforce authentication before enabling production mode. Do not copy VM
credentials or paired-device records to production. No Firebase setup is needed
for this VM prototype.

## Private file catalog (VM only)

The management page also lists imported safetensors files and their detected
attributes. There is no download/upload HTTP endpoint and device tokens cannot
access files. Binary files live in ignored `server/storage/files/`, outside
`server/public`; never alias or mount that storage into a public document root.
Storage is on the VM disk, not in Git. Include it and the catalog table in any
separately arranged data backup; committing source does not back up model files.

Apply `schema.sql` to the existing VM test database before updating the page.
Then import a local file from inside development:

```sh
dev bash -lc 'cd /home/dev/projects/MakeLORA && php server/bin/import-file.php /path/to/model.safetensors "Display name"'
```

The CLI defaults to the VM `.test-config/makelora.php`; `MAKELORA_CONFIG` can
select another private **prototype** configuration. It snapshots the source,
validates bounded header structure, tensor byte lengths and offsets, calculates
a full-file SHA-256, and stores a private content-addressed copy with mode 0600.
Reimporting identical bytes updates the inspection without creating another row
or replacing the display name, target model, original filename or upload date.
Different files with the same source filename receive distinct hash-based storage
names automatically, so uploads cannot overwrite each other. Display names
default to the source filename stem when the optional label is omitted. The source is left intact;
remove staging copies only after checking the stored copy and database record.
If database registration fails after storage is finalized, retry the import;
the already verified stored copy is reused. No source file is executed and no
model/GPU runtime is required. PHP CLI and Python 3 are required for import;
Python is not needed by the web process.

The database retains display names, original filenames, byte sizes, SHA-256,
timestamps, scanner versions, embedded metadata and complete tensor descriptors.
The catalog shows one collapsed row per file: display name, upload time (UTC)
and target model. Tapping the row reveals the original filename and technical
attributes. Device management is also collapsed. There is no architecture
signature catalog or external model lookup yet. The scanner
currently rejects unsupported dtypes (including packed/quantized types) rather
than guessing. Inspections validate the container, not model quality or behavior.

```sh
dev bash -lc 'cd /home/dev/projects/MakeLORA && python3 -m unittest discover -s server/tests -p "test_*.py"'
# After importing the initial addminus.safetensors file:
dev bash -lc 'cd /home/dev/projects/MakeLORA && python3 server/tests/catalog_integration.py'
```

This remains a VM prototype. Production hosting and authenticated file serving
require separate work and authorization.

User-specified target models are stored in `makelora_files.target_model`,
shown separately from embedded metadata, and preserved on reimport. Existing
catalog databases must apply `migrations/002_file_target_model.sql` before
updating the page; new databases include the column in `schema.sql`.

Display names are stored in `makelora_files.display_name`. Existing databases
must also apply `migrations/003_file_display_name.sql` before updating the page.
The initial file is named “add minus glasses”. Verify filename collisions with:

```sh
dev bash -lc 'cd /home/dev/projects/MakeLORA && python3 server/tests/import_integration.py'
```
