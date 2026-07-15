#!/usr/bin/env bash
# tests/fm-watch-parked-absorb.test.sh - regression tests for the parked-run
# absorb classification. A crew whose no-mistakes run is parked at a gate
# (awaiting_approval or fix_review) is legitimately idle while firstmate drives
# the validation, so the watcher must absorb its stale pane instead of
# immediately surfacing or escalating a "possible wedge". The parked absorb
# uses the extended PARKED_ESCALATE_SECS timer so a genuinely forgotten parked
# run still surfaces.
#
# Each test exercises a specific predicate or watcher behavior. Tests run in
# subshells so failures in one do not stop the runner.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$ROOT/bin/fm-classify-lib.sh"

WATCH="$ROOT/bin/fm-watch.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"

TMP_ROOT=$(fm_test_tmproot fm-watch-parked-absorb-tests)

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

reap() { kill "$1" 2>/dev/null || true; wait "$1" 2>/dev/null || true; }

seen_sig() {
  if [ "$(uname)" = Darwin ]; then stat -f '%z:%Fm' "$1" 2>/dev/null; else stat -c '%s:%Y' "$1" 2>/dev/null; fi
}

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
# Test 1: crew_absorb_class returns parked for a parked run-step.
# ---------------------------------------------------------------------------

test_absorb_class_returns_parked_for_parked_run_step() {
  local dir fakebin
  dir=$(make_case absorb-parked1); fakebin="$dir/fakebin"
  export FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh"
  export FM_FAKE_CREW_STATE
  FM_FAKE_CREW_STATE='state: parked · source: run-step · parked at awaiting_approval: 2 finding(s)'
  [ "$(crew_absorb_class a)" = parked ] || fail "parked run-step not classed as parked"
  crew_is_parked a || fail "crew_is_parked returned false for a parked run-step"
  ! crew_is_provably_working a || fail "parked run-step treated as provably working"
  ! crew_is_paused a || fail "parked run-step treated as paused"
  unset FM_FAKE_CREW_STATE
  pass "crew_absorb_class returns parked for a run-step parked at awaiting_approval"
}

# ---------------------------------------------------------------------------
# Test 2: crew_absorb_class returns parked for a parked run with ask-user.
# ---------------------------------------------------------------------------

test_absorb_class_returns_parked_for_ask_user_gate() {
  local dir fakebin
  dir=$(make_case absorb-parked2); fakebin="$dir/fakebin"
  export FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh"
  export FM_FAKE_CREW_STATE
  FM_FAKE_CREW_STATE='state: parked · source: run-step · parked at fix_review: 1 finding(s) (ask-user: captain decision)'
  [ "$(crew_absorb_class a)" = parked ] || fail "parked fix_review with ask-user not classed as parked"
  crew_is_parked a || fail "crew_is_parked returned false for fix_review gate"
  unset FM_FAKE_CREW_STATE
  pass "crew_absorb_class returns parked for a run-step parked at fix_review with ask-user"
}

# ---------------------------------------------------------------------------
# Test 3: Parked crew does NOT trip stale on new hash (absorbed).
# ---------------------------------------------------------------------------

test_parked_crew_absorbed_on_new_hash() {
  local dir state fakebin out capture_file window key pane_hash sig pid
  dir=$(make_case parked-absorb-newhash); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"
  window="test:fm-parked"
  printf 'idle while firstmate drives validation' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/parked.meta"
  printf 'working: initial implementation\n' > "$state/parked.status"
  sig=$(seen_sig "$state/parked.status"); printf '%s' "$sig" > "$state/.seen-parked_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle while firstmate drives validation")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  export FM_FAKE_CREW_STATE='state: parked · source: run-step · parked at awaiting_approval: 1 finding(s) (ask-user: captain decision)'

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_live "$pid" 30; then
    reap "$pid"; fail "watcher exited for a fresh parked stale (should absorb): $(cat "$out")"
  fi
  [ ! -s "$out" ] || fail "fresh parked stale printed a wake reason during absorb"
  [ ! -s "$state/.wake-queue" ] || fail "fresh parked stale enqueued a wake during absorb"
  [ "$(cat "$state/.stale-$key" 2>/dev/null || true)" = "$pane_hash" ] || fail "stale suppressor not advanced on parked absorb"
  [ -s "$state/.stale-since-$key" ] || fail "parked stale-since timer was not recorded on absorb"
  [ -e "$state/.parkflag-$key" ] || fail "park flag not recorded on absorb"
  [ "$(cat "$state/.parkflag-$key" 2>/dev/null || true)" = "$pane_hash" ] || fail "park flag does not match the stale hash"
  reap "$pid"
  unset FM_FAKE_CREW_STATE
  pass "a parked crew is absorbed on first stale sighting (no wake, parked flag set, timer started)"
}

# ---------------------------------------------------------------------------
# Test 4: Parked crew's wedge timer escalates past PARKED_ESCALATE_SECS.
# ---------------------------------------------------------------------------

test_parked_crew_wedge_escalates_past_parked_threshold() {
  local dir state fakebin out capture_file window key pane_hash sig pid
  dir=$(make_case parked-escalate); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"
  window="test:fm-parked-wedge"
  printf 'idle parked, firstmate may have forgotten' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/parked-wedge.meta"
  printf 'working: initial implementation\n' > "$state/parked-wedge.status"
  sig=$(seen_sig "$state/parked-wedge.status"); printf '%s' "$sig" > "$state/.seen-parked-wedge_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle parked, firstmate may have forgotten")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '%s' "$pane_hash" > "$state/.stale-$key"
  printf '%s' "$pane_hash" > "$state/.parkflag-$key"
  printf '1\n' > "$state/.count-$key"
  # Backdate the timer past PARKED_ESCALATE_SECS (default 2x 240s = 480s).
  echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_STALE_ESCALATE_SECS=240 FM_PARKED_ESCALATE_SECS=400 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 40 || fail "watcher did not escalate a parked stale past PARKED_ESCALATE_SECS"
  grep -F "stale: $window" "$out" >/dev/null || fail "escalation did not print a stale wake for parked crew"
  grep -F "possible wedge" "$out" >/dev/null || fail "escalation did not flag a possible wedge"
  pass "a parked crew's wedge timer escalates after PARKED_ESCALATE_SECS"
}

# ---------------------------------------------------------------------------
# Test 5: Parked override of stale terminal status.
#   Status log has needs-decision (captain-relevant), run-step is parked.
#   On a NEW stale hash, the watcher must absorb (parked overrides the stale
#   captain-relevant line) and start the parked wedge timer.
# ---------------------------------------------------------------------------

test_parked_overrides_stale_terminal_status() {
  local dir state fakebin out capture_file window key pane_hash sig pid
  dir=$(make_case parked-override); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"
  window="test:fm-parked-override"
  printf 'waiting on firstmate decision' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/parked-override.meta"
  # Status log has needs-decision (captain-relevant) -- this would normally
  # trip stale_is_terminal and surface immediately as stale.
  printf 'needs-decision: approve the ask-user findings\n' > "$state/parked-override.status"
  sig=$(seen_sig "$state/parked-override.status"); printf '%s' "$sig" > "$state/.seen-parked-override_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "waiting on firstmate decision")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  # The run-step is parked - firstmate is driving the validation, so the
  # stale pane is expected, not a bug.
  export FM_FAKE_CREW_STATE='state: parked · source: run-step · parked at awaiting_approval: 1 finding(s) (ask-user: captain decision)'

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_live "$pid" 30; then
    reap "$pid"; fail "watcher exited for a parked stale terminal status (should absorb): $(cat "$out")"
  fi
  [ ! -s "$out" ] || fail "parked stale terminal status printed a wake reason during absorb"
  [ ! -s "$state/.wake-queue" ] || fail "parked stale terminal status enqueued a wake during absorb"
  [ "$(cat "$state/.stale-$key" 2>/dev/null || true)" = "$pane_hash" ] || fail "stale suppressor not advanced on parked terminal absorb"
  [ -s "$state/.stale-since-$key" ] || fail "parked stale-since timer was not recorded on terminal absorb"
  [ -e "$state/.parkflag-$key" ] || fail "park flag not recorded on terminal absorb"
  [ ! -e "$state/.hb-surfaced-parked-override" ] || fail "an absorbed parked wake must not mark the status line as surfaced"
  reap "$pid"
  unset FM_FAKE_CREW_STATE
  pass "parked run overrides a stale captain-relevant status log line (absorbed, not surfaced)"
}

# ---------------------------------------------------------------------------
# Test 6: Non-parked crew with stale terminal status still surfaces.
#   When crew_absorb_class returns none (run is genuinely done/failed/unknown),
#   the stale terminal status must still surface immediately.
# ---------------------------------------------------------------------------

test_nonparked_crew_with_terminal_status_surfaces() {
  local dir state fakebin out drain_out capture_file window key pane_hash sig pid
  dir=$(make_case nonparked-surfaces); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; capture_file="$dir/pane.txt"
  window="test:fm-nonparked-done"
  printf 'finished, awaiting PR review' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/nonparked-done.meta"
  printf 'done: PR https://example.test/pr/42 checks green\n' > "$state/nonparked-done.status"
  sig=$(seen_sig "$state/nonparked-done.status"); printf '%s' "$sig" > "$state/.seen-nonparked-done_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "finished, awaiting PR review")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  # The run is genuinely done (not parked), so stale_is_terminal is true and
  # crew_absorb_class returns none - the stale must surface.
  export FM_FAKE_CREW_STATE='state: done · source: run-step · checks green: PR ready for review'

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 40 || fail "watcher did not exit for a terminal stale whose crew is not parked"
  grep -F "stale: $window" "$out" >/dev/null || fail "watcher did not print the terminal stale wake"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the terminal stale failed"
  grep "$(printf '\tstale\t')" "$drain_out" | grep -F "$window" >/dev/null || fail "terminal stale was not queued"
  unset FM_FAKE_CREW_STATE
  pass "a non-parked crew with a stale terminal status still surfaces immediately"
}

# ---------------------------------------------------------------------------

echo ""
echo "=== Running parked-absorb regression tests ==="
echo ""

tests=(
  test_absorb_class_returns_parked_for_parked_run_step
  test_absorb_class_returns_parked_for_ask_user_gate
  test_parked_crew_absorbed_on_new_hash
  test_parked_crew_wedge_escalates_past_parked_threshold
  test_parked_overrides_stale_terminal_status
  test_nonparked_crew_with_terminal_status_surfaces
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
