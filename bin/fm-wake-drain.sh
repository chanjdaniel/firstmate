#!/usr/bin/env bash
# Atomically drain durable watcher wake records, upgrade the drained tasks'
# surfaced markers from enqueued to consumed, then assert watcher liveness.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# For the post-drain surfaced-marker upgrade: last_status_line, window_to_task,
# and the two-state .hb-surfaced-* helpers (fm_surfaced_mark_consumed owns the
# match-then-upgrade rule; fm-classify-lib.sh owns the marker format).
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"

DRAIN_TMP=
DRAIN_LOCK_HELD=false

# Defense in depth for the supervision chain: this script runs at the top of
# every wake-handling and recovery turn, so assert watcher liveness here too. A
# lapsed supervision chain then surfaces on a plain drain-and-handle turn, not
# only when a guarded supervision script (fm-peek/fm-send/...) happens to run.
# Reuse fm-guard.sh's existing graced, beacon-based banner (FM_GUARD_GRACE) - do
# not duplicate the beacon math. Because the watcher touches its beacon every
# poll cycle, a normal fire leaves a recent beacon well inside grace and stays
# silent; only a genuine stale-beyond-grace lapse with work in flight warns. Call
# after the queue is emptied so guard never re-prints its own queued-wakes notice
# for the records this run just drained, and never let a guard hiccup change the
# drain's exit status.
assert_watcher_liveness() {
  "$SCRIPT_DIR/fm-guard.sh" || true
}

# shellcheck disable=SC2317,SC2329 # Invoked by trap handlers below.
cleanup() {
  local status=$?
  if [ "$status" -ne 0 ] && [ "$DRAIN_LOCK_HELD" = true ] && [ -n "$DRAIN_TMP" ] && [ -e "$DRAIN_TMP" ]; then
    fm_wake_restore_queue "$DRAIN_TMP" || true
  fi
  if [ "$DRAIN_LOCK_HELD" = true ]; then
    fm_lock_release "$FM_WAKE_QUEUE_LOCK"
  fi
  exit "$status"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Post-drain hook: upgrade the two-state .hb-surfaced-* marker from enqueued to
# consumed for every task named in the records this drain just delivered. A
# drain that printed the records IS the proof firstmate received them, so the
# suppression may now outlive the queue - but only while the marker's stored
# status line still matches the status file's current last line
# (fm_surfaced_mark_consumed owns that match-then-upgrade rule; a changed status
# leaves the stale enqueued marker for the fresh surfacing to replace). Tasks
# are resolved per record kind: a signal's key is the status/turn-end basename,
# a stale's key is a window target mapped through the task metadata, and a
# heartbeat's payload carries its "(tasks:...)" list. Best-effort and
# idempotent: a marker hiccup must never fail or re-queue the drain.
upgrade_surfaced_markers() {  # <drained-queue-file>
  local drained=$1 tasks="" seen="" epoch seq kind key payload task
  [ -s "$drained" ] || return 0
  while IFS=$(printf '\t') read -r epoch seq kind key payload; do
    [ -n "${kind:-}" ] || continue
    task=""
    case "$kind" in
      signal)
        case "$key" in
          *.status) task=${key%.status} ;;
          *.turn-ended) task=${key%.turn-ended} ;;
        esac
        [ -n "$task" ] && tasks="$tasks $task"
        ;;
      stale)
        task=$(window_to_task "$key" "$STATE")
        [ -n "$task" ] && tasks="$tasks $task"
        ;;
      heartbeat)
        case "$payload" in
          *"(tasks:"*)
            payload=${payload#*"(tasks:"}
            payload=${payload%%")"*}
            tasks="$tasks $payload"
            ;;
        esac
        ;;
    esac
  done < "$drained"
  for task in $tasks; do
    case " $seen " in *" $task "*) continue ;; esac
    seen="$seen $task"
    fm_surfaced_mark_consumed "$STATE" "$task" || true
  done
  return 0
}

fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK"
DRAIN_LOCK_HELD=true

if [ ! -s "$FM_WAKE_QUEUE" ]; then
  : > "$FM_WAKE_QUEUE"
  assert_watcher_liveness
  exit 0
fi

DRAIN_TMP="$STATE/.wake-queue.drain.$(fm_current_pid)"
rm -f "$DRAIN_TMP"
mv "$FM_WAKE_QUEUE" "$DRAIN_TMP" || exit 1
: > "$FM_WAKE_QUEUE" || exit 1

fm_wake_print_deduped "$DRAIN_TMP" || exit "$?"
upgrade_surfaced_markers "$DRAIN_TMP"
rm -f "$DRAIN_TMP"
DRAIN_TMP=
assert_watcher_liveness
exit 0
