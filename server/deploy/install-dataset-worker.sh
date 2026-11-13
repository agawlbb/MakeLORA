#!/usr/bin/env bash
set -euo pipefail
# Explicit production activation only; never run by a web request or tests.
dev ssh vps-admin 'sudo -n bash -s' <<'REMOTE'
set -euo pipefail
app=/opt/services/shared-frontend/private/makelora/app
docker exec --user 33:33 -e MAKELORA_CONFIG=/run/site-private/makelora/settings.php shared-frontend-web-1 php /run/site-private/makelora/app/bin/process-datasets.php --check
install -m 0644 "$app/deploy/makelora-datasets.service" /etc/systemd/system/makelora-datasets.service
install -m 0644 "$app/deploy/makelora-datasets.timer" /etc/systemd/system/makelora-datasets.timer
systemctl daemon-reload
systemctl enable --now makelora-datasets.timer
systemctl is-active makelora-datasets.timer
REMOTE
