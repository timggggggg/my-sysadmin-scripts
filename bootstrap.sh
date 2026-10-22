#!/usr/bin/env bash
# Ubuntu 22.04/24.04 lab: install, build, provision storage and start HTTPS.
set -Eeuo pipefail
trap 'printf "bootstrap failed at line %s\n" "$LINENO" >&2' ERR
[[ $EUID -eq 0 ]] || { echo 'Run: sudo bash bootstrap.sh' >&2; exit 1; }
cd -- "$(dirname -- "$(readlink -f -- "$0")")"
[[ -d /run/systemd/system ]] || { echo 'A VM with systemd is required.' >&2; exit 1; }
exec 8>/run/lock/my-app-bootstrap.lock
flock -n 8 || { echo 'Another bootstrap is running.' >&2; exit 1; }
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y docker.io docker-compose-v2 nginx openssl curl mdadm lvm2
systemctl enable --now docker

# Only containers belonging to this Compose project may be replaced.
if docker inspect my-app >/dev/null 2>&1; then
    owner=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' my-app)
    [[ $owner == my-sysadmin-scripts ]] || { echo 'Container my-app is not ours.' >&2; exit 1; }
fi
install -D -m 0755 scripts/storage.sh /usr/local/lib/my-app/storage.sh
install -m 0644 deploy/capstone-storage.service /etc/systemd/system/capstone-storage.service
install -m 0644 deploy/my-app.service /etc/systemd/system/my-app.service
systemctl daemon-reload
systemctl enable --now capstone-storage
mountpoint -q /mnt/raid
mountpoint -q /mnt/logs
install -d -m 0755 /mnt/logs/my-app

docker build -t my-script:latest .
docker compose -p my-sysadmin-scripts config --quiet
systemctl stop my-app
# Demonstrate the required Compose launch, then hand lifecycle to systemd.
docker compose -p my-sysadmin-scripts up -d
docker compose -p my-sysadmin-scripts stop
systemctl enable --now my-app

if [[ ! -f /etc/ssl/private/my-app.key && ! -f /etc/ssl/certs/my-app.crt ]]; then
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout /etc/ssl/private/my-app.key -out /etc/ssl/certs/my-app.crt \
        -subj '/CN=my-app.local' \
        -addext 'subjectAltName=DNS:my-app.local,DNS:localhost,IP:127.0.0.1'
fi
[[ -s /etc/ssl/private/my-app.key && -s /etc/ssl/certs/my-app.crt ]]
chmod 0600 /etc/ssl/private/my-app.key
chmod 0644 /etc/ssl/certs/my-app.crt
install -m 0644 deploy/nginx-my-app.conf /etc/nginx/sites-available/my-app
# Preserve the packaged site, disabling only its standard symlink.
if [[ -L /etc/nginx/sites-enabled/default && $(readlink -f /etc/nginx/sites-enabled/default) == /etc/nginx/sites-available/default ]]; then
    unlink /etc/nginx/sites-enabled/default
fi
ln -sfn /etc/nginx/sites-available/my-app /etc/nginx/sites-enabled/my-app
nginx -t
systemctl enable --now nginx
systemctl reload nginx

# Wait until the HTTP server serves a nonempty monitoring log.
ready=false
for _ in {1..30}; do
    if curl -kfsS --max-time 2 https://127.0.0.1/monitor.log -o /dev/null &&
        [[ -s /mnt/logs/my-app/monitor.log ]]; then
        ready=true
        break
    fi
    sleep 1
done
[[ $ready == true ]] || { echo 'Application failed readiness check.' >&2; exit 1; }
printf '\nREADY: https://<VM-IP>/monitor.log (self-signed TLS)\n'
