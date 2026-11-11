#!/usr/bin/env bash
set -euo pipefail
# Run on the VM: source preparation and Composer dependencies belong in dev.
# The VPS is production only; never start its retained development container.
root=$(cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"
test -f server/vendor/autoload.php
test -z "$(git status --porcelain --untracked-files=no)"
git rev-parse HEAD
tar -C server -cf - src public vendor bin schema.sql migrations deploy | \
  dev ssh vps-admin 'sudo -n bash -c '\''set -euo pipefail
    site=/opt/services/shared-frontend
    test -f "$site/private/makelora/settings.php"
    install -d -o root -g www-data -m 0750 "$site/private/makelora/app"
    tar -xf - -C "$site/private/makelora/app"
    chown -R root:www-data "$site/private/makelora/app"
    find "$site/private/makelora/app" -type d -exec chmod 0750 {} +
    find "$site/private/makelora/app" -type f -exec chmod 0640 {} +
    install -d -m 0755 "$site/public/MakeLORA"
    install -m 0644 "$site/private/makelora/app/deploy/.htaccess" "$site/public/MakeLORA/.htaccess"
    install -m 0644 "$site/private/makelora/app/deploy/gateway.php" "$site/public/MakeLORA/gateway.php"
  '\'''
