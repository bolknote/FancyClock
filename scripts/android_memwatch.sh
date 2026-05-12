#!/usr/bin/env bash
# Poll Android PSS for the FancyClock app (native / graphics / camera leaks show here).
# Prereqs: adb on PATH, device authorized, app installed (debug or release).
#
# Usage:
#   scripts/android_memwatch.sh [interval_seconds] [iterations]
#   INTERVAL=5 ITER=120 scripts/android_memwatch.sh   # env overrides
#
# Example (6 min, every 10 s):  scripts/android_memwatch.sh 10 36
# While this runs, exercise the app (leave clock on, toggle camera, etc.).

set -euo pipefail

PKG="${ANDROID_MEMWATCH_PKG:-com.fancyclock.fancy_clock}"
INTERVAL="${INTERVAL:-${1:-10}}"
ITER="${ITER:-${2:-36}}"

if ! command -v adb >/dev/null 2>&1; then
  echo "adb not found; install Android platform-tools." >&2
  exit 1
fi

if ! adb devices | awk 'NR>1 && $2=="device" {found=1} END{exit !found}'; then
  echo "No authorized device (adb devices). Connect a device or start an emulator." >&2
  exit 1
fi

echo "# unix_ts_iso interval_s total_pss_kb native_pss_kb graphics_pss_kb dalvik_pss_kb" >&2
echo "# package=$PKG interval=${INTERVAL}s iterations=${ITER}" >&2

parse_meminfo() {
  local out
  out="$(adb shell dumpsys meminfo "$PKG" 2>/dev/null || true)"
  if [[ -z "$out" ]] || echo "$out" | grep -qi "No process"; then
    echo ""
    return 1
  fi
  local total native graphics dalvik
  total="$(echo "$out" | sed -n 's/.*TOTAL PSS:[[:space:]]*\([0-9][0-9]*\).*/\1/p' | tail -1)"
  # Prefer "App Summary" lines (name with colon); avoid the detailed table row "Native Heap    NNN".
  native="$(echo "$out" | awk '/Native Heap:/{print $3; exit}')"
  graphics="$(echo "$out" | awk '/Graphics:/{print $2; exit}')"
  dalvik="$(echo "$out" | awk '/Java Heap:/{print $3; exit}')"
  if [[ -z "$total" ]]; then
    echo ""
    return 1
  fi
  echo "${total:-} ${native:-} ${graphics:-} ${dalvik:-}"
}

# When stdout is redirected to a file, libc often fully buffers plain echo;
# perl with $| flushes each row so multi-hour runs are visible in tail -f.
_memwatch_print_row() {
  if command -v perl >/dev/null 2>&1; then
    perl -we 'BEGIN { $| = 1; } print shift, "\n"' "$1"
  else
    printf '%s\n' "$1"
  fi
}

for ((i = 1; i <= ITER; i++)); do
  ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  if line="$(parse_meminfo)"; then
    # shellcheck disable=SC2086
    set -- $line
    _memwatch_print_row "$ts $INTERVAL $1 $2 $3 $4"
  else
    echo "$ts $INTERVAL NA NA NA NA # dumpsys failed or process not running" >&2
  fi
  if ((i < ITER)); then
    sleep "$INTERVAL"
  fi
done
