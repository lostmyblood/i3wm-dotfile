#!/usr/bin/env bash
# Restart polybar without waiting forever on a stuck instance.
pkill -x polybar 2>/dev/null
for _ in {1..20}; do
    pgrep -x polybar >/dev/null || break
    sleep 0.05
done
pgrep -x polybar >/dev/null && pkill -9 -x polybar 2>/dev/null
exec polybar -q main
