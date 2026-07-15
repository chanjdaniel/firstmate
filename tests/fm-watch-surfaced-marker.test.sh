#!/usr/bin/env bash
# tests/fm-watch-surfaced-marker.test.sh - the TWO-STATE .hb-surfaced-<task>
# marker (fm-classify-lib.sh's surfaced-marker helpers) that closes the
# surfaced-forever arm-gap hole. The watcher writes enqueued:<line> at
# wake-ENQUEUE time; bin/fm-wake-drain.sh upgrades it to consumed:<line> after
# a provable drain, but ONLY while the stored line still matches the status
# file's current last line. Suppression treats both phases as already-surfaced
# and anything else (absent, a different line, a legacy bare marker) as
# never-surfaced, so a wake lost without a drain keeps both its enqueued marker
# and its queued record and the status still reaches firstmate.
#
# Watcher-side enqueue triage lives in fm-watch-triage.test.sh; the turn-end
# cross-reference and heartbeat payload in fm-watch-surface-scout.test.sh.
# Tests run in subshells so failures in one do not stop the runner.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$ROOT/bin/fm-classify-lib.sh"

WATCH="$ROOT/bin/fm-watch.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"

TMP_ROOT=$(fm_test_tmproot fm-watch-surfaced-marker-tests)

watch_bg() {
  local state=$1 fakebin=$2 out=$3
  shift 3
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$@" "$WATCH" > "$out" &
}

wait_live() {
  local pid=$1 limit=${2:-30} i=0
  while [ "$i" -lt "$limit" ]; do
    kill -0 "$pid" 2>/dev/null || return 1
    sleep 0.1
    i=$((i + 1))
  done
  return 0
}

reap() { kill "$1" 2>/dev/null || true; wait "$1" 2>/dev/null || true; }

seen_sig() {
  if [ "$(uname)" = Darwin ]; then stat -f '%z:%Fm' "$1" 2>/dev/null; else stat -c '%s:%Y' "$1" 2>/dev/null; fi
}

run_test() {
  ( set -e; "$1" )
}

# ---------------------------------------------------------------------------
# 1. enqueued-at-enqueue: a surfacing wake writes the marker in the enqueued
# phase, prefixed with the exact status line it queued.
# ---------------------------------------------------------------------------

test_marker_written_as_enqueued_at_enqueue() {
  local dir state fakebin out status_file line pid
  dir=$(make_case enq-at-enqueue); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"
  status_file="$state/task.status"
  line='needs-decision: pick A or B'
  printf '%s\n' "$line" > "$status_file"
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 40 || fail "watcher did not surface a captain-relevant signal"
  [ "$(cat "$state/.hb-surfaced-task" 2>/dev/null || true)" = "enqueued:$line" ] \
    || fail "marker is not enqueued:<line> after enqueue (got: '$(cat "$state/.hb-surfaced-task" 2>/dev/null || true)')"
  [ -s "$state/.wake-queue" ] || fail "surfacing wake left no durable queue record"
  pass "a surfacing wake writes the marker as enqueued:<line> at enqueue time"
}

# ---------------------------------------------------------------------------
# 2. drain-upgrades: draining the queued record upgrades the marker to
# consumed:<line> when the status file is unchanged.
# ---------------------------------------------------------------------------

test_drain_upgrades_enqueued_to_consumed() {
  local dir state fakebin out drain_out status_file line pid
  dir=$(make_case drain-upgrades); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"
  status_file="$state/task.status"
  line='done: PR https://example.test/pr/11 checks green'
  printf '%s\n' "$line" > "$status_file"
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 40 || fail "watcher did not surface the captain-relevant signal"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain failed"
  grep "$(printf '\tsignal\t')" "$drain_out" | grep -F "task.status" >/dev/null \
    || fail "drain did not deliver the signal record"
  [ "$(cat "$state/.hb-surfaced-task" 2>/dev/null || true)" = "consumed:$line" ] \
    || fail "drain did not upgrade the marker to consumed:<line> (got: '$(cat "$state/.hb-surfaced-task" 2>/dev/null || true)')"
  pass "a drain upgrades an unchanged task's marker from enqueued to consumed"
}

# ---------------------------------------------------------------------------
# 3. stale-enqueued-untouched: if the status changed between enqueue and drain,
# the stale enqueued marker is left alone for the fresh surfacing to replace.
# ---------------------------------------------------------------------------

test_drain_leaves_stale_enqueued_marker_untouched() {
  local dir state fakebin out drain_out status_file old_line pid
  dir=$(make_case stale-untouched); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"
  status_file="$state/task.status"
  old_line='blocked: need repo access'
  printf '%s\n' "$old_line" > "$status_file"
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 40 || fail "watcher did not surface the captain-relevant signal"
  # The status moves on BEFORE the drain: the queued record and its enqueued
  # marker now describe a superseded line.
  printf 'done: PR https://example.test/pr/12 checks green\n' >> "$status_file"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain failed"
  [ "$(cat "$state/.hb-surfaced-task" 2>/dev/null || true)" = "enqueued:$old_line" ] \
    || fail "drain touched a stale enqueued marker (got: '$(cat "$state/.hb-surfaced-task" 2>/dev/null || true)')"
  pass "a drain leaves an enqueued marker untouched when the status changed since enqueue"
}

# ---------------------------------------------------------------------------
# 4. consumed==absent for re-surface: a consumed marker for a superseded line
# suppresses nothing - a NEW captain-relevant status re-surfaces through the
# heartbeat backstop exactly as if no marker existed.
# ---------------------------------------------------------------------------

test_consumed_marker_for_old_line_resurfaces_like_absent() {
  local dir state fakebin out sig pid
  dir=$(make_case consumed-resurface); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"
  # An earlier milestone was surfaced, drained, and consumed; the crew has since
  # written a NEW captain-relevant line. .seen-* already matches (the per-poll
  # signal scan stays quiet), so only the heartbeat backstop can catch it.
  printf 'consumed:done: implementation complete' > "$state/.hb-surfaced-task"
  printf 'done: implementation complete\ndone: PR https://example.test/pr/13 checks green\n' > "$state/task.status"
  sig=$(seen_sig "$state/task.status"); printf '%s' "$sig" > "$state/.seen-task_status"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=1 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 40 || fail "heartbeat backstop did not re-surface a new line past a consumed marker"
  grep -F "heartbeat (tasks:" "$out" >/dev/null || fail "backstop wake did not carry the task identity"
  grep -F "task" "$out" >/dev/null || fail "backstop wake does not name the task"
  pass "a consumed marker for a superseded line behaves like absent: the new status re-surfaces"
}

# ---------------------------------------------------------------------------
# 5. enqueued suppresses duplicate: an enqueued marker for the CURRENT line is
# already-surfaced (the record is in the queue or drained), so the heartbeat
# backstop absorbs instead of re-firing a duplicate wake.
# ---------------------------------------------------------------------------

test_enqueued_marker_suppresses_duplicate_surfacing() {
  local dir state fakebin out line sig pid
  dir=$(make_case enq-suppresses); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"
  line='done: PR https://example.test/pr/14 checks green'
  printf 'enqueued:%s' "$line" > "$state/.hb-surfaced-task"
  printf '%s\n' "$line" > "$state/task.status"
  sig=$(seen_sig "$state/task.status"); printf '%s' "$sig" > "$state/.seen-task_status"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=1 "$WATCH" > "$out" &
  pid=$!
  if ! wait_live "$pid" 30; then
    reap "$pid"
    fail "heartbeat re-fired for a line whose enqueued marker is current (should absorb): $(cat "$out")"
  fi
  [ ! -s "$out" ] || { reap "$pid"; fail "suppressed heartbeat printed a wake reason: $(cat "$out")"; }
  [ ! -s "$state/.wake-queue" ] || { reap "$pid"; fail "suppressed heartbeat enqueued a duplicate record"; }
  reap "$pid"
  pass "an enqueued marker for the current line suppresses duplicate surfacing"
}

# ---------------------------------------------------------------------------

echo ""
echo "=== Running two-state surfaced-marker tests ==="
echo ""

tests=(
  test_marker_written_as_enqueued_at_enqueue
  test_drain_upgrades_enqueued_to_consumed
  test_drain_leaves_stale_enqueued_marker_untouched
  test_consumed_marker_for_old_line_resurfaces_like_absent
  test_enqueued_marker_suppresses_duplicate_surfacing
)

passed=0 failed=0
for t in "${tests[@]}"; do
  if run_test "$t"; then
    passed=$((passed + 1))
  else
    failed=$((failed + 1))
  fi
done

echo ""
echo "Results: $passed passed, $failed failed"
echo ""

if [ "$failed" -gt 0 ]; then
  exit 1
fi

exit 0
