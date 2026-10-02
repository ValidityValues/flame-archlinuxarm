#!/usr/bin/env bash
set -euo pipefail
command -v adb >/dev/null || { echo "adb is required" >&2; exit 1; }
command -v fastboot >/dev/null || { echo "fastboot is required" >&2; exit 1; }
OUT="${1:-pixel4-layout-$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$OUT"
adb devices -l > "$OUT/adb-devices.txt" 2>&1 || true
if adb get-state >/dev/null 2>&1; then
  adb shell getprop > "$OUT/getprop.txt" 2>&1 || true
  adb shell 'getprop ro.boot.slot_suffix; getprop ro.build.fingerprint' > "$OUT/slot.txt" 2>&1 || true
  adb shell 'ls -l /dev/block/by-name; echo ===MAPPER===; ls -l /dev/block/mapper; echo ===PARTITIONS===; cat /proc/partitions' > "$OUT/block-layout.txt" 2>&1 || true
  adb shell 'su -c "lpdump 2>/dev/null"' > "$OUT/lpdump.txt" 2>&1 || true
fi
fastboot devices > "$OUT/fastboot-devices.txt" 2>&1 || true
fastboot getvar all > "$OUT/fastboot-getvar-all.txt" 2>&1 || true
printf 'Saved read-only device layout to %s\n' "$OUT"
printf 'Redact serial numbers and identifiers before sharing.\n'
