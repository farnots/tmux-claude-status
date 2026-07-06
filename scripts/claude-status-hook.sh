#!/bin/sh
# claude-status-hook.sh — updates the Claude Code status of a tmux pane/window.
#
# Usage: claude-status-hook.sh <mode> [window_id]
#   Claude Code hook modes: working | working_soft | waiting | need_input |
#                           error | notification | session_end
#     (called from settings.json hooks; the status is passed as argv, only
#      notification and session_end read the JSON on stdin)
#   tmux mode: recompute <window_id>
#     (called by the tmux pane-exited / after-kill-pane hooks to recompute
#      the aggregate of a window whose pane just died)
#
# tmux options set:
#   @claude_pane_status       (pane)   : working | need_input | waiting | error
#   @claude_pane_status_since (pane)   : epoch of the last status change
#   @claude_pane_pid          (pane)   : PID of the claude process (liveness)
#   @claude_pane_flavor       (pane)   : config dir name ("claude", ...)
#   @claude_win_status        (window) : pane aggregate, priority
#                                        need_input > error > working > waiting
#
# Never block or fail Claude: every path exits 0.

[ -n "$TMUX" ] || exit 0
mode="$1"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

json_field() {
  # Minimal extraction of a string field from the JSON on stdin. Sufficient
  # here: expected values are fixed identifiers without escaping.
  sed -n 's/.*"'"$1"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1
}

# Walk the ppid chain from this script up to the direct child of the pane's
# root shell (= the foreground claude process). Also handles claude launched
# with `exec` (claude IS pane_pid).
find_claude_pid() {  # $1 = pane_pid
  pane_root=$1; pid=$$; i=0
  while [ "$i" -lt 8 ]; do
    ppid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -n "$ppid" ] && [ "$ppid" -gt 1 ] 2>/dev/null || return 1
    if [ "$ppid" = "$pane_root" ]; then echo "$pid"; return 0; fi
    if [ "$pid" = "$pane_root" ]; then echo "$pane_root"; return 0; fi
    pid=$ppid; i=$((i+1))
  done
  return 1
}

soft=0
case "$mode" in
  working|waiting|need_input|error) status="$mode" ;;
  working_soft)
    # PreToolUse/PostToolUse/PreCompact: these events can arrive LATE, after
    # the end-of-turn Stop (hooks run in parallel, background agents run
    # tools too). A "soft" working never overrides a waiting — only
    # UserPromptSubmit (a genuine turn start) does waiting → working.
    status=working; soft=1 ;;
  notification)
    # need_input comes from Notification(permission_prompt) ONLY: it fires
    # when the question actually reaches the user. PermissionRequest is not
    # used — it fires for every request, including ones auto-approved by
    # another hook, which would leave a phantom "?" for the whole duration
    # of a long tool (no event until its PostToolUse).
    case "$(json_field notification_type)" in
      permission_prompt) status=need_input ;;
      idle_prompt)       status=waiting ;;
      *)                 exit 0 ;;
    esac ;;
  session_end)
    # /clear emits SessionEnd(reason=clear) then SessionStart, in parallel:
    # unsetting here could lose the race against SessionStart's `waiting`.
    # Setting `waiting` is idempotent whatever the execution order.
    if [ "$(json_field reason)" = "clear" ]; then status=waiting; else status=""; fi ;;
  recompute)
    win="$2"; [ -n "$win" ] || exit 0 ;;
  *) exit 0 ;;
esac

if [ "$mode" != "recompute" ]; then
  [ -n "$TMUX_PANE" ] || exit 0
  cur=$(tmux show -pqv -t "$TMUX_PANE" @claude_pane_status 2>/dev/null) || exit 0
  [ "$cur" = "$status" ] && exit 0
  [ "$soft" = 1 ] && [ "$cur" = "waiting" ] && exit 0
  if [ -n "$status" ]; then
    tmux set -p -t "$TMUX_PANE" @claude_pane_status "$status" 2>/dev/null || exit 0
    tmux set -p -t "$TMUX_PANE" @claude_pane_status_since "$(date +%s)" 2>/dev/null
    # A real event reasserts authority over any daemon activity-promotion:
    # drop the promotion origin AND the "hot" freshness flag, so a leftover
    # flag can't re-promote this fresh status on the daemon's next sweep.
    tmux set -pu -t "$TMUX_PANE" @claude_pane_promoted 2>/dev/null
    tmux set -pu -t "$TMUX_PANE" @claude_pane_hot 2>/dev/null
    # Claude PID for the daemon's liveness check — only when absent (the
    # sweep unsets it when the process dies).
    if [ -z "$(tmux show -pqv -t "$TMUX_PANE" @claude_pane_pid 2>/dev/null)" ]; then
      pane_pid=$(tmux display -p -t "$TMUX_PANE" '#{pane_pid}' 2>/dev/null)
      cpid=$(find_claude_pid "$pane_pid") || cpid=$PPID
      [ "$cpid" -gt 1 ] 2>/dev/null && \
        tmux set -p -t "$TMUX_PANE" @claude_pane_pid "$cpid" 2>/dev/null
      # Session flavor (config dir name, dot stripped): "claude",
      # "claude-poly", ... Useful to display instead of the process name
      # (the Claude Code binary is named after its version number).
      flavor=$(basename "${CLAUDE_CONFIG_DIR:-$HOME/.claude}")
      tmux set -p -t "$TMUX_PANE" @claude_pane_flavor "${flavor#.}" 2>/dev/null
    fi
  else
    tmux set -pu -t "$TMUX_PANE" @claude_pane_status 2>/dev/null || exit 0
    tmux set -pu -t "$TMUX_PANE" @claude_pane_status_since 2>/dev/null
    tmux set -pu -t "$TMUX_PANE" @claude_pane_pid 2>/dev/null
    tmux set -pu -t "$TMUX_PANE" @claude_pane_flavor 2>/dev/null
    tmux set -pu -t "$TMUX_PANE" @claude_pane_promoted 2>/dev/null
    tmux set -pu -t "$TMUX_PANE" @claude_pane_hot 2>/dev/null
    tmux set -pu -t "$TMUX_PANE" @claude_pane_scrhash 2>/dev/null
  fi
  win="$TMUX_PANE"  # a pane id is a valid target-window for list-panes
fi

# Window aggregate: need_input > error > working > waiting; empty if no pane
agg=""
for s in $(tmux list-panes -t "$win" -F '#{@claude_pane_status}' 2>/dev/null); do
  case "$s" in
    need_input) agg=need_input; break ;;
    error)      agg=error ;;
    working)    [ "$agg" != "error" ] && agg=working ;;
    waiting)    [ -z "$agg" ] && agg=waiting ;;
  esac
done

old=$(tmux show -wqv -t "$win" @claude_win_status 2>/dev/null)
if [ "$old" != "$agg" ]; then
  if [ -n "$agg" ]; then
    tmux set -w -t "$win" @claude_win_status "$agg" 2>/dev/null
  else
    tmux set -wu -t "$win" @claude_win_status 2>/dev/null
  fi
  tmux refresh-client -S 2>/dev/null
fi

# Wake the daemon (animation, liveness, durations, summary). Fast heuristic,
# tolerant to false positives: the daemon has its own atomic mkdir lock.
if [ "$mode" != "recompute" ] && [ -n "$status" ]; then
  dpid=$(tmux show -gqv @claude_daemon_pid 2>/dev/null)
  if [ -z "$dpid" ] || ! kill -0 "$dpid" 2>/dev/null; then
    tmux run-shell -b "exec $SCRIPT_DIR/claude-status-daemon.sh '#{socket_path}' >/dev/null 2>&1 </dev/null" 2>/dev/null
  fi
fi
exit 0
