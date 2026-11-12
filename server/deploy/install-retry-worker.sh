#!/usr/bin/env bash
set -euo pipefail
# Explicit deployment step: never invoked by a web request or test.
dev ssh vps-admin 'sudo -n bash -s' <<'REMOTE'
set -euo pipefail
app=/opt/services/shared-frontend/private/makelora/app
docker exec --user 33:33 -e MAKELORA_CONFIG=/run/site-private/makelora/settings.php shared-frontend-web-1 php /run/site-private/makelora/app/bin/retry-generations.php --check
install -m 0644 "$app/deploy/makelora-generation-retries.service" /etc/systemd/system/makelora-generation-retries.service
install -m 0644 "$app/deploy/makelora-generation-retries.timer" /etc/systemd/system/makelora-generation-retries.timer
systemctl daemon-reload
systemctl enable --now makelora-generation-retries.timer
systemctl is-active makelora-generation-retries.timer
REMOTE
