#!/usr/bin/env bash
set -uo pipefail

monitor_pid=''
http_pid=''

stop_children() {
    if [[ -n "$monitor_pid" ]]; then
        kill -TERM "$monitor_pid" 2>/dev/null || true
    fi
    if [[ -n "$http_pid" ]]; then
        kill -TERM "$http_pid" 2>/dev/null || true
    fi
    if [[ -n "$monitor_pid" ]]; then
        wait "$monitor_pid" 2>/dev/null || true
    fi
    if [[ -n "$http_pid" ]]; then
        wait "$http_pid" 2>/dev/null || true
    fi
}

shutdown() {
    trap '' TERM INT
    printf 'Stopping monitoring and HTTP server.\n'
    stop_children
    exit 0
}

trap shutdown TERM INT

/usr/local/bin/script.sh &
monitor_pid=$!
python3 -m http.server 8080 --bind 0.0.0.0 --directory /var/www &
http_pid=$!
printf 'Monitoring PID=%s; HTTP server PID=%s, port=8080.\n' "$monitor_pid" "$http_pid"

# Both processes are long-lived. Any unexpected exit must stop the container,
# so systemd can restart the whole service instead of leaving half of it alive.
wait -n "$monitor_pid" "$http_pid"
status=$?
trap '' TERM INT
printf 'A child process exited unexpectedly (status=%s); stopping container.\n' "$status" >&2
stop_children
if (( status == 0 )); then
    status=1
fi
exit "$status"
