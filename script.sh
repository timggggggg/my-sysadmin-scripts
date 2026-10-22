#!/usr/bin/env bash

N=5
LOG_FILE="monitor.log"

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
        sleep "$N" || exit 1
    else
        printf 'Ошибка: не удалось собрать или записать данные в %s.\n' "$LOG_FILE" >&2
        exit 1
    fi
done
