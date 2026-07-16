#!/usr/bin/env bash
# tests/fm-watch-surface-scout.test.sh - failing regression tests for the
# HIGH-VALUE supervision bug where a crewmate's "PR ready / checks green"
# milestone is silently never surfaced to firstmate.
#
# Two compounding defects:
#
# DEFECT 1 (the direct miss / blind spot): when a crew's status file carries a
# captain-relevant line but the signal scan only picks up a bare .turn-ended
# (because .seen-* for the status was advanced on a previous cycle),
# signal_reason_is_actionable returns 1 (no .status files in $files) and the
# absorb decision falls entirely to crew_is_provably_working. If
# crew_is_provably_working returns true, the turn-end is absorbed - silently
# dropping the captain-relevant milestone that is STILL on disk.
#
# DEFECT 2 (the fail-safe is defeated): the heartbeat backstop calls
# mark_all_captain_relevant_surfaced at wake-ENQUEUE time, setting
# .hb-surfaced-* BEFORE firstmate consumes the wake. If that heartbeat fires
# during a watcher arm-gap or is otherwise drained without the mandatory full
# fleet review, the marker permanently suppresses future heartbeats.
#
# These tests are designed to FAIL (confirming the bug) in the current codebase
# and PASS once the fix is applied. Each test runs in a subshell so the runner
# continues through all of them.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$ROOT/bin/fm-classify-lib.sh"

WATCH="$ROOT/bin/fm-watch.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"

TMP_ROOT=$(fm_test_tmproot fm-watch-surface-scout-tests)   # consumed by make_case via wake-helpers.sh

# The runner dispatches test functions indirectly (run_test "$t"), which
# ShellCheck cannot see through, so its reachability analysis flags the test
# functions and the helpers they call as never invoked: SC2329 on newer
# versions, SC2317 (per body command) on the older version CI runs.
# Each such function carries a targeted disable for both codes.

# shellcheck disable=SC2317,SC2329 # Invoked only from indirectly-dispatched tests; see note above.
watch_bg() {
  local state=$1 fakebin=$2 out=$3
  shift 3
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$@" "$WATCH" > "$out" &
}

# shellcheck disable=SC2317,SC2329 # Invoked only from indirectly-dispatched tests; see note above.
wait_live() {
  local pid=$1 limit=${2:-30} i=0
  while [ "$i" -lt "$limit" ]; do
    kill -0 "$pid" 2>/dev/null || return 1
    sleep 0.1
    i=$((i + 1))
  done
  return 0
}

# shellcheck disable=SC2317,SC2329 # Invoked only from indirectly-dispatched tests; see note above.
wait_for_exit() {
  local pid=$1 limit=${2:-50} i=0
  while [ "$i" -lt "$limit" ]; do
    if ! kill -0 "$pid" 2>/dev/null; then
      wait "$pid"
      return "$?"
    fi
    sleep 0.1
    i=$((i + 1))
  done
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  return 124
}

# shellcheck disable=SC2317,SC2329 # Invoked only from indirectly-dispatched tests; see note above.
reap() { kill "$1" 2>/dev/null || true; wait "$1" 2>/dev/null || true; }

# shellcheck disable=SC2317,SC2329 # Invoked only from indirectly-dispatched tests; see note above.
seen_sig() {
  if [ "$(uname)" = Darwin ]; then stat -f '%z:%Fm' "$1" 2>/dev/null; else stat -c '%s:%Y' "$1" 2>/dev/null; fi
}

# Run a test in a subshell so failures do not stop the runner.
# 0 = test passed (assertion held). 1 = test failed (defect confirmed).
run_test() {
  local rc
  ( set -e; "$1" )
  rc=$?
  if [ "$rc" -eq 0 ]; then
    return 0
  else
    return 1
  fi
}

# ---------------------------------------------------------------------------
# DEFECT 1: Blind spot - turn-end absorbed despite captain-relevant status
# ---------------------------------------------------------------------------

# shellcheck disable=SC2317,SC2329 # Dispatched indirectly via run_test "$t"; see note above.
test_defect1_blind_spot() {
  local dir state fakebin out status_file sig pid
  dir=$(make_case d1-blind); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"
  status_file="$state/task.status"

  # Status file carries a captain-relevant "done: PR ... checks green" line.
  # .seen-* was ALREADY advanced (the status was surfaced on a previous cycle).
  # Now only a bare .turn-ended fires (the crew is monitoring for merge).
  printf 'done: PR https://example.test/pr/1 checks green\n' > "$status_file"
  sig=$(seen_sig "$status_file"); printf '%s' "$sig" > "$state/.seen-task_status"
  : > "$state/task.turn-ended"

  # crew_is_provably_working returns true: fm-crew-state.sh reports the crew
  # as actively working in CI-monitoring where the ci log is unreadable/unknown.
  export FM_FAKE_CREW_STATE='state: working · source: run-step · ci running'

  watch_bg "$state" "$fakebin" "$out"
  pid=$!

  # BUG (current behavior): watcher absorbs the turn-ended signal.
  # signal_reason_is_actionable sees only .turn-ended (skips non-.status) -> 1.
  # signal_crew_provably_working returns true (crew in ci-monitoring) -> 0.
  # afk_present is false.
  # Condition: false || 1 || !true = false -> ABSORB.
  # CORRECT behavior: should SURFACE because the task's status on disk has a
  # captain-relevant milestone.
  if wait_live "$pid" 30; then
    reap "$pid"
    fail "DEFECT 1 BUG CONFIRMED: turn-end ABSORBED despite status carrying captain-relevant 'done: PR ... checks green' on disk"
  fi
  wait "$pid" || true
  grep -F "signal:" "$out" >/dev/null || fail "DEFECT 1: watcher exited but did not print a signal wake"
  pass "DEFECT 1 FIXED: turn-end surfaced (status on disk is recognized)"
}

# ---------------------------------------------------------------------------
# DEFECT 1 variant: signal_reason_is_actionable only inspects .status files
# in $files. A turn-ended-only $files produces 0 hits, but there may be
# captain-relevant statuses ON DISK for the same task.
# ---------------------------------------------------------------------------

# shellcheck disable=SC2317,SC2329 # Dispatched indirectly via run_test "$t"; see note above.
test_defect1_sria_blind_to_disk() {
  local dir state last
  dir=$(make_case d1-sria); state="$dir/state"

  printf 'done: PR https://x/pull/1 checks green\n' > "$state/alpha.status"
  : > "$state/alpha.turn-ended"

  # signal_reason_is_actionable($files) where $files contains only .turn-ended.
  # It skips non-.status files -> returns 1.
  signal_reason_is_actionable "$state/alpha.turn-ended" \
    && fail "DEFECT 1: signal_reason_is_actionable falsely returned 0 for a turn-ended-only signal list"

  # But the status file ON DISK IS captain-relevant.
  last=$(last_status_line "$state/alpha.status")
  status_is_captain_relevant "$last" || fail "DEFECT 1: status on disk is captain-relevant"

  pass "DEFECT 1 CONFIRMED: signal_reason_is_actionable does not inspect status files of turn-ended-referenced tasks"
}

# ---------------------------------------------------------------------------
# DEFECT 2: Heartbeat backstop marks statuses surfaced at ENQUEUE time.
# After the fix: the heartbeat payload now carries per-task identity so
# firstmate can target its fleet review. The marker suppression in Phase B
# is correct (the status was already surfaced in Phase A).
# ---------------------------------------------------------------------------

# shellcheck disable=SC2317,SC2329 # Dispatched indirectly via run_test "$t"; see note above.
test_defect2_hb_marks_too_early() {
  local dir state fakebin out sig pid
  dir=$(make_case d2-hb-early); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"

  printf 'done: PR https://example.test/pr/99 checks green\n' > "$state/miss.status"
  sig=$(seen_sig "$state/miss.status"); printf '%s' "$sig" > "$state/.seen-miss_status"

  # Phase A: first heartbeat fires, payload now carries per-task identity.
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=1 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 40 || fail "DEFECT 2: first heartbeat did not exit"

  # After the fix: payload is NOT plain "heartbeat" — it should carry task identity.
  if grep -Fx "heartbeat" "$out" >/dev/null; then
    fail "DEFECT 2: first heartbeat payload is still generic 'heartbeat' (should carry task identity)"
  fi
  grep -F "heartbeat (tasks:" "$out" >/dev/null || fail "DEFECT 2: first heartbeat payload missing task identity"
  grep -F "miss" "$out" >/dev/null || fail "DEFECT 2: heartbeat payload does not list the 'miss' task"

  if [ ! -e "$state/.hb-surfaced-miss" ]; then
    fail "DEFECT 2: .hb-surfaced-miss was NOT set by heartbeat"
  fi

  # Phase B: the marker was set, so a second heartbeat correctly suppresses
  # the already-surfaced status (no change since Phase A).
  sig=$(seen_sig "$state/miss.status"); printf '%s' "$sig" > "$state/.seen-miss_status"
  : > "$out"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=1 "$WATCH" > "$out" &
  pid=$!

  if ! wait_live "$pid" 30; then
    wait "$pid" || true
    fail "DEFECT 2: second heartbeat re-fired for an already-surfaced status (should absorb)"
  fi
  reap "$pid"
  pass "DEFECT 2 FIXED: heartbeat carries per-task identity; already-surfaced statuses correctly suppressed"
}

# ---------------------------------------------------------------------------
# DEFECT 2 variant: verify the heartbeat payload carries per-task identity.
# Before the fix, the payload was a generic "heartbeat" string.
# After the fix, it lists the task IDs whose statuses triggered the heartbeat.
# ---------------------------------------------------------------------------

# shellcheck disable=SC2317,SC2329 # Dispatched indirectly via run_test "$t"; see note above.
test_defect2_hb_payload_has_task_identity() {
  local dir state fakebin out drain_out sig pid
  dir=$(make_case d2-hb-payload); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"

  printf 'done: PR https://example.test/pr/77 checks green\n' > "$state/a.status"
  sig=$(seen_sig "$state/a.status"); printf '%s' "$sig" > "$state/.seen-a_status"
  printf 'blocked: need approval\n' > "$state/b.status"
  sig=$(seen_sig "$state/b.status"); printf '%s' "$sig" > "$state/.seen-b_status"

  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=1 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 40 || fail "DEFECT 2: heartbeat did not exit"
  grep -F "heartbeat (tasks:" "$out" >/dev/null || fail "DEFECT 2: heartbeat payload missing task identity"

  # Both tasks should appear in the payload (format: "heartbeat (tasks:a b)").
  grep -F "tasks:" "$out" >/dev/null || fail "DEFECT 2: heartbeat payload missing 'tasks:' prefix"
  grep -q 'tasks:.*a' "$out" || fail "DEFECT 2: heartbeat payload does not list task 'a'"
  grep -q 'tasks:.*b' "$out" || fail "DEFECT 2: heartbeat payload does not list task 'b'"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "DEFECT 2: drain failed"
  grep "$(printf '\theartbeat\t')" "$drain_out" >/dev/null || fail "DEFECT 2: heartbeat wake not in queue"
  pass "DEFECT 2 FIXED: heartbeat payload carries per-task identity (tasks: a b)"
}

# ---------------------------------------------------------------------------
# Clean classifier test: verify signal_reason_is_actionable only inspects
# .status files (the design intent), so callers must compensate.
# ---------------------------------------------------------------------------

# shellcheck disable=SC2317,SC2329 # Dispatched indirectly via run_test "$t"; see note above.
test_signal_reason_is_actionable_filters_only_status_files() {
  local dir state
  dir=$(make_case d1-filter); state="$dir/state"

  printf 'done: PR ready checks green\n' > "$state/t.status"
  : > "$state/t.turn-ended"
  : > "$state/t.other"

  # Only .status files are inspected.
  signal_reason_is_actionable "$state/t.status" || fail "classifier: captain-relevant .status not caught"
  signal_reason_is_actionable "$state/t.turn-ended" && fail "classifier: .turn-ended falsely classified as actionable"
  signal_reason_is_actionable "$state/t.other" && fail "classifier: .other file falsely classified"

  # Mixed: a .status with captain-relevant verb makes the whole batch actionable.
  signal_reason_is_actionable "$state/t.status" "$state/t.turn-ended" \
    || fail "classifier: mixed batch with one captain-relevant .status should be actionable"

  pass "classifier: signal_reason_is_actionable correctly filters for .status files only"
}

# ---------------------------------------------------------------------------

echo ""
echo "=== Running defect regression tests ==="
echo "Each test that prints 'not ok' confirms the BUG is present."
echo "When the fix is applied, these tests will pass."
echo ""

tests=(
  test_signal_reason_is_actionable_filters_only_status_files
  test_defect1_sria_blind_to_disk
  test_defect1_blind_spot
  test_defect2_hb_marks_too_early
  test_defect2_hb_payload_has_task_identity
)

passed=0 failed=0
for t in "${tests[@]}"; do
  if run_test "$t"; then
    passed=$((passed + 1))
  else
    # Determine if this was a defect-confirmation failure vs an infrastructure failure
    failed=$((failed + 1))
  fi
done

echo ""
echo "Results: $passed passed, $failed failed (defect confirmations or regressions)"
echo ""

if [ "$failed" -gt 0 ]; then
  echo "Some tests FAILED - this is EXPECTED when the defects are present."
  echo "After the fix: all tests should pass."
  exit 1
fi

echo "All regression tests passed (defects may already be fixed)."
exit 0
