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

# Timeout-diagnostic sampling bounds (test-only overrides; the workflow never
# sets them). At most SAMPLE_MAX_TARGETS owned processes are sampled 1s each,
# preferring test-host-like descendants; each sampler is SIGKILLed after
# SAMPLE_WATCHDOG_SECS so diagnostics can never block cleanup; SAMPLE_LINES
# keeps full call graphs instead of a 40-line header.
select_sample_targets() {
  root="$1"
  max_targets="${SAMPLE_MAX_TARGETS:-3}"
  case "$max_targets" in
    ''|*[!0-9]*) max_targets=3 ;;
  esac
  owned="$(owned_pids "$root" 2>/dev/null || true)"
  if [ -z "$(printf '%s' "$owned" | tr -d ' \n\t')" ]; then
    return 0
  fi
  owned_csv="$(printf '%s\n' "$owned" | tr '\n' ',' | sed 's/,$//')"
  proclist="$(ps -o pid=,command= -p "$owned_csv" 2>/dev/null || true)"
  preferred=""
  if [ -n "$(printf '%s' "$proclist" | tr -d ' \n\t')" ]; then
    preferred="$(printf '%s\n' "$proclist" | grep -E 'swiftpm-testing-helper|swift-testing|swift-test' 2>/dev/null | awk '{ print $1 }' || true)"
  fi
  out=""
  count=0
  for p in $preferred; do
    case " $out " in
      *" $p "*) ;;
      *) out="$out$p "; count=$((count + 1)) ;;
    esac
    if [ "$count" -ge "$max_targets" ]; then break; fi
  done
  if [ "$count" -lt "$max_targets" ]; then
    for p in $owned; do
      case " $out " in
        *" $p "*) ;;
        *) out="$out$p "; count=$((count + 1)) ;;
      esac
      if [ "$count" -ge "$max_targets" ]; then break; fi
    done
  fi
  for p in $out; do
    printf '%s\n' "$p"
  done
}

# Sample one pid for 1s, emitting up to SAMPLE_LINES of call graph to stderr.
# Bounded so diagnostics can never block cleanup: the sampler runs in the
# background while the parent polls for exit, and a runaway is SIGKILLed after
# SAMPLE_WATCHDOG_SECS. Always returns 0 so a broken sampler degrades to a
# warning, never to a blocked cleanup or a changed exit status.
sample_one_bounded() {
  _pid="$1"
  _watchdog="${SAMPLE_WATCHDOG_SECS:-15}"
  _lines="${SAMPLE_LINES:-400}"
  echo "--- sample owned pid $_pid (1s) ---" >&2
  _tmp="$(mktemp /tmp/runner-control-sample.XXXXXX 2>/dev/null || true)"
  if [ -z "${_tmp:-}" ] || [ ! -f "$_tmp" ]; then
    echo "WARNING: sample scratch unavailable for pid $_pid" >&2
    return 0
  fi
  sample "$_pid" 1 >"$_tmp" 2>&1 &
  _sp=$!
  _el=0
  while [ "$_el" -lt "$_watchdog" ]; do
    _st="$(ps -o stat= -p "$_sp" 2>/dev/null || true)"
    _st="$(printf '%s' "$_st" | tr -d ' \t\n')"
    case "$_st" in
      ""|Z*) break ;;
    esac
    sleep 1
    _el=$((_el + 1))
  done
  _st="$(ps -o stat= -p "$_sp" 2>/dev/null || true)"
  _st="$(printf '%s' "$_st" | tr -d ' \t\n')"
  case "$_st" in
    ""|Z*) ;;
    *) kill -9 "$_sp" 2>/dev/null || true
       echo "WARNING: sample of pid $_pid exceeded ${_watchdog}s; killed" >&2 ;;
  esac
  wait "$_sp" 2>/dev/null || true
  head -n "$_lines" "$_tmp" >&2 2>&1 || echo "WARNING: sample output unreadable for pid $_pid" >&2
  rm -f "$_tmp" 2>/dev/null || true
  return 0
}

echo "TIMEOUT: swift test exceeded ${timeout_secs}s; capturing owned-process diagnostics" >&2
pids_csv="$(owned_pids "$child" 2>/dev/null | tr '\n' ',' | sed 's/,$//' || true)"
echo "--- owned-process ps (${pids_csv:-unknown}) ---" >&2
if [ -n "$pids_csv" ]; then
  ps -o pid,ppid,etime,command -p "$pids_csv" >&2 2>&1 || echo "WARNING: ps probe failed" >&2
else
  echo "WARNING: no owned pids enumerated" >&2
fi
if command -v sample >/dev/null 2>&1; then
  targets="$(select_sample_targets "$child" 2>/dev/null || true)"
  if [ -z "$(printf '%s' "$targets" | tr -d ' \n\t')" ]; then
    echo "WARNING: no owned pids to sample" >&2
  else
    for t in $targets; do
      sample_one_bounded "$t"
    done
  fi
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
