#!/usr/bin/env bash

set -euo pipefail

N="${INTERVAL_SECONDS:-5}"
LOG_FILE="${LOG_FILE:-monitor.log}"
ONCE=false
case "${1:-}" in
    --once) ONCE=true ;;
    '') ;;
    *) printf 'Usage: %s [--once]\n' "$0" >&2; exit 2 ;;
esac
if [[ ! "$N" =~ ^[1-9][0-9]*$ ]]; then
    printf 'INTERVAL_SECONDS must be a positive integer.\n' >&2
    exit 2
fi

trap 'printf "\nМониторинг остановлен.\n"; exit 0' INT TERM

printf 'Запись в %s каждые %s секунд. Остановка: Ctrl+C.\n' "$LOG_FILE" "$N"

while true; do
    if {
        printf -- '--- %s ---\n' "$(date '+%Y-%m-%d %H:%M:%S')" &&
        free -h &&
        df -h &&
        uptime &&
        printf '\n'
    } >> "$LOG_FILE"; then
        if "$ONCE"; then
            printf 'One monitoring sample saved to %s.\n' "$LOG_FILE"
            exit 0
        fi
        sleep "$N" &
        wait $!
    else
        printf 'Ошибка: не удалось собрать или записать данные в %s.\n' "$LOG_FILE" >&2
        exit 1
    fi
done
