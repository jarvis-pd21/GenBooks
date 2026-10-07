#!/usr/bin/env bash
# Serializes test processes that share the selected simulator.
#
# Concurrent test runs can replace or terminate each other's app. The lock is
# keyed by simulator UUID so independent simulators can run separately.
#
# Uses an atomic `mkdir` lock with
# stale-PID recovery. Source it, then call sim_lock_acquire "<udid>".
#
#   LIVINGREADER_SKIP_SIM_LOCK=1   bypass entirely
#   SIM_LOCK_TIMEOUT=<seconds>     how long to wait (default 1800)

SIM_LOCK_DIR=""

sim_lock_release() {
  if [[ -n "$SIM_LOCK_DIR" && -d "$SIM_LOCK_DIR" ]]; then
    if [[ "$(cat "$SIM_LOCK_DIR/pid" 2>/dev/null || echo '')" == "$$" ]]; then
      rm -rf "$SIM_LOCK_DIR"
    fi
  fi
}

sim_lock_acquire() {
  local udid="$1"
  if [[ "${LIVINGREADER_SKIP_SIM_LOCK:-0}" == "1" ]]; then
    echo "sim-lock: bypassed (LIVINGREADER_SKIP_SIM_LOCK=1)"
    return 0
  fi

  local timeout="${SIM_LOCK_TIMEOUT:-1800}"
  local dir="${TMPDIR:-/tmp}/livingreader-sim-${udid}.lock"
  local waited=0

  while true; do
    if mkdir "$dir" 2>/dev/null; then
      SIM_LOCK_DIR="$dir"
      echo "$$" > "$dir/pid"
      echo "${LIVINGREADER_LANE:-$(basename "$(pwd)")}" > "$dir/lane"
      trap sim_lock_release EXIT INT TERM
      [[ "$waited" -gt 0 ]] && echo "sim-lock: acquired after ${waited}s"
      return 0
    fi

    local holder
    holder="$(cat "$dir/pid" 2>/dev/null || echo '')"
    if [[ -z "$holder" ]] || ! kill -0 "$holder" 2>/dev/null; then
      echo "sim-lock: clearing stale lock from pid ${holder:-unknown}"
      rm -rf "$dir"
      continue
    fi

    if [[ "$waited" -ge "$timeout" ]]; then
      echo "FAIL: simulator $udid busy for ${timeout}s (held by pid $holder, lane $(cat "$dir/lane" 2>/dev/null || echo '?'))"
      echo "      Wait for that run, or clear it with: rm -rf '$dir'"
      return 1
    fi

    if (( waited % 30 == 0 )); then
      echo "sim-lock: waiting for $(cat "$dir/lane" 2>/dev/null || echo 'another lane') (pid $holder)…"
    fi
    sleep 5
    waited=$((waited + 5))
  done
}
