#!/usr/bin/env bash

{
    printf -- '--- %s ---\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    free -h
    df -h
    uptime
    printf '\n'
} >> monitor.log
