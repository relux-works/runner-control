#!/bin/bash
# Bounded Swift test runner for hosted CI.
# Production entry point invoked by .github/workflows/ci.yml
# ("Core unit tests (no UI tests or production runners)").
# Runs the fixed full-suite command with live output, enforces a wall-clock
# bound, captures owned-process diagnostics on timeout, terminates owned
# processes, and propagates the test exit status. Takes no test-selection
# passthrough: every invocation runs the whole suite. Prints toolchain
# versions before the run. Reads no credentials and performs no runner
# operations.
#
# Ownership model: the test child runs in its own process group (monitor
# mode below; macOS ships no setsid), so TERM/KILL addressed at the group
# reaches descendants even after they are reparented. Tree enumeration is
# kept for diagnostics and as a second sweep for group escapees. Every
# signal is addressed at the owned group/tree only, never at siblings.
set -uo pipefail
set -m

usage() {
  cat <<'EOF'
Usage: run-bounded-swift-tests.sh --timeout-secs N --package-path P --scratch-path S
Runs the full Swift suite with live output bounded by N seconds.
Exit: test status on completion, 124 on timeout, 2 on usage error.
EOF
}

timeout_secs=""
package_path=""
scratch_path=""
need_value() {
  if [ $# -lt 2 ]; then
    echo "error: $1 requires a value" >&2
    usage >&2
    exit 2
  fi
}

while [ $# -gt 0 ]; do
  case "$1" in
    --timeout-secs)
      need_value "$@"
      timeout_secs="${2:-}"; shift 2 ;;
    --timeout-secs=*)
      timeout_secs="${1#*=}"; shift ;;
    --package-path)
      need_value "$@"
      package_path="${2:-}"; shift 2 ;;
    --package-path=*)
      package_path="${1#*=}"; shift ;;
    --scratch-path)
      need_value "$@"
      scratch_path="${2:-}"; shift 2 ;;
    --scratch-path=*)
      scratch_path="${1#*=}"; shift ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      echo "error: unknown argument '$1'" >&2
      usage >&2
      exit 2 ;;
  esac
done

if [ -z "$timeout_secs" ] || [ -z "$package_path" ] || [ -z "$scratch_path" ]; then
  echo "error: missing required argument" >&2
  usage >&2
  exit 2
fi
case "$timeout_secs" in
  ''|*[!0-9]*)
    echo "error: --timeout-secs must be a positive integer" >&2
    exit 2 ;;
esac
if [ "$timeout_secs" -le 0 ]; then
  echo "error: --timeout-secs must be greater than zero" >&2
  exit 2
fi
if [ ! -d "$package_path" ]; then
  echo "error: package path not found: $package_path" >&2
  exit 2
fi

echo "--- toolchain versions ---"
echo "--- swift --version ---"
swift --version 2>&1 || echo "WARNING: swift version probe failed" >&2
echo "--- xcode-select -p ---"
xcode-select -p 2>&1 || echo "WARNING: xcode-select probe failed" >&2
echo "--- xcodebuild -version ---"
xcodebuild -version 2>&1 || echo "WARNING: xcodebuild probe failed" >&2
echo "--- running full Swift suite (live output, bound ${timeout_secs}s) ---"

owned_pids() {
  root="$1"
  printf '%s\n' "$root"
  if command -v pgrep >/dev/null 2>&1; then
    seen=" $root "
    queue=" $root "
    while [ -n "$(printf '%s' "$queue" | tr -d ' ')" ]; do
      next=" "
      for p in $queue; do
        children="$(pgrep -P "$p" 2>/dev/null || true)"
        for c in $children; do
          case "$seen" in
            *" $c "*) ;;
            *)
              printf '%s\n' "$c"
              seen="$seen$c "
              next="$next$c " ;;
          esac
        done
      done
      queue="$next"
    done
  else
    kids="$(ps -o pid=,ppid= 2>/dev/null | awk -v want="$root" '$2 == want { print $1 }' || true)"
    for c in $kids; do
      printf '%s\n' "$c"
    done
  fi
}

child=""

# Signal every member of the owned process group, then sweep the enumerated
# tree for processes that escaped the group. Only owned pids are signaled.
signal_owned() {
  sig="$1"
  root="$2"
  kill "-$sig" -- "-$root" 2>/dev/null || true
  for p in $(owned_pids "$root" 2>/dev/null || true); do
    kill "-$sig" "$p" 2>/dev/null || true
  done
}

group_alive() {
  kill -0 -- "-$1" 2>/dev/null
}

# Best-effort reap of owned group strays after the leader exited early.
# Never changes the exit status; never signals outside the owned group.
sweep_lingering_owned_group() {
  grp="$1"
  if group_alive "$grp"; then
    echo "note: reaping lingering owned test processes" >&2
    signal_owned TERM "$grp"
    sleep 2
    signal_owned KILL "$grp"
  fi
}

cleanup_on_signal() {
  if [ -n "$child" ]; then
    signal_owned KILL "$child"
  fi
  exit 130
}
trap cleanup_on_signal INT TERM

swift test --package-path "$package_path" --scratch-path "$scratch_path" &
child=$!

elapsed=0
while [ "$elapsed" -lt "$timeout_secs" ]; do
  if ! kill -0 "$child" 2>/dev/null; then
    wait "$child"
    status=$?
    trap - INT TERM
    sweep_lingering_owned_group "$child"
    exit "$status"
  fi
  sleep 1
  elapsed=$((elapsed + 1))
done

if ! kill -0 "$child" 2>/dev/null; then
  wait "$child"
  status=$?
  trap - INT TERM
  sweep_lingering_owned_group "$child"
  exit "$status"
fi

echo "TIMEOUT: swift test exceeded ${timeout_secs}s; capturing owned-process diagnostics" >&2
pids_csv="$(owned_pids "$child" 2>/dev/null | tr '\n' ',' | sed 's/,$//' || true)"
echo "--- owned-process ps (${pids_csv:-unknown}) ---" >&2
if [ -n "$pids_csv" ]; then
  ps -o pid,ppid,etime,command -p "$pids_csv" >&2 2>&1 || echo "WARNING: ps probe failed" >&2
else
  echo "WARNING: no owned pids enumerated" >&2
fi
if command -v sample >/dev/null 2>&1; then
  echo "--- sample owned test host $child (1s) ---" >&2
  sample "$child" 1 2>&1 | head -n 40 >&2 || echo "WARNING: sample probe failed" >&2
else
  echo "--- sample tool unavailable; ps output above is the timeout diagnostic ---" >&2
fi

signal_owned TERM "$child"
grace=0
while [ "$grace" -lt 5 ]; do
  if ! kill -0 "$child" 2>/dev/null && ! group_alive "$child"; then
    break
  fi
  sleep 1
  grace=$((grace + 1))
done
signal_owned KILL "$child"
wait "$child" 2>/dev/null || true
settle=0
while [ "$settle" -lt 2 ]; do
  if ! group_alive "$child"; then
    break
  fi
  sleep 1
  settle=$((settle + 1))
done
if group_alive "$child"; then
  echo "WARNING: owned processes survived KILL in group $child" >&2
  ps -o pid,ppid,etime,command -g "$child" >&2 2>&1 || true
else
  echo "TIMEOUT: owned test processes terminated; failing with 124" >&2
fi
trap - INT TERM
exit 124
