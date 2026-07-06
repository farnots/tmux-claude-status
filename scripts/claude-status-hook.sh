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
#   @claude_pane_subagents    (pane)   : "agent_id:epoch" set of subagents
#                                        currently blocked on a permission
#   @claude_pane_subq_disp    (pane)   : rendered suffix ("", "?", "?²", ...)
#   @claude_win_status        (window) : pane aggregate, priority
#                                        need_input > error > working > waiting
#   @claude_win_subq          (window) : sum of pane subagent counts (unset=0)
#   @claude_win_subq_disp     (window) : rendered suffix for the window badge
#
# Never block or fail Claude: every path exits 0.

[ -n "$TMUX" ] || exit 0
mode="$1"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/claude-status-lib.sh"

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

# Recompute the subagent-permission counters of a window from its panes:
# per-pane @claude_pane_subq_disp, and window @claude_win_subq(_disp).
recompute_subq() {  # $1 = target window (a pane id is a valid target-window)
  _w=$1; _sum=0
  _lp=$(tmux list-panes -t "$_w" -F '#{pane_id}|#{@claude_pane_subagents}' 2>/dev/null)
  while IFS='|' read -r _p _set; do
    [ -n "$_p" ] || continue
    _c=$(subq_count "$_set")
    _d=$(subq_disp "$_c")
    if [ -n "$_d" ]; then
      tmux set -p -t "$_p" @claude_pane_subq_disp "$_d" 2>/dev/null
    else
      tmux set -pu -t "$_p" @claude_pane_subq_disp 2>/dev/null
    fi
    _sum=$((_sum + _c))
  done <<EOF
$_lp
EOF
  if [ "$_sum" -gt 0 ]; then
    tmux set -w -t "$_w" @claude_win_subq "$_sum" \; \
      set -w -t "$_w" @claude_win_subq_disp "$(subq_disp "$_sum")" 2>/dev/null
  else
    tmux set -wu -t "$_w" @claude_win_subq \; \
      set -wu -t "$_w" @claude_win_subq_disp 2>/dev/null
  fi
}

# Wake the daemon (animation, liveness, durations, summary, subq expiry).
# Fast heuristic, tolerant to false positives: the daemon has its own lock.
wake_daemon() {
  dpid=$(tmux show -gqv @claude_daemon_pid 2>/dev/null)
  if [ -z "$dpid" ] || ! kill -0 "$dpid" 2>/dev/null; then
    tmux run-shell -b "exec $SCRIPT_DIR/claude-status-daemon.sh '#{socket_path}' >/dev/null 2>&1 </dev/null" 2>/dev/null
  fi
}

soft=0; subq_apply=0; subq_only=0
case "$mode" in
  working|waiting|need_input|error) status="$mode" ;;
  working_soft)
    # PreToolUse/PostToolUse/PreCompact: these events can arrive LATE, after
    # the end-of-turn Stop (hooks run in parallel, background agents run
    # tools too). A "soft" working never overrides a waiting — only
    # UserPromptSubmit (a genuine turn start) does waiting → working.
    status=working; soft=1
    # A subagent tool event carries agent_id: that subagent has moved past
    # its permission prompt → drop it from the pending set.
    if [ -n "$TMUX_PANE" ]; then
      agent=$(json_field agent_id)
      if [ -n "$agent" ]; then
        cur_set=$(tmux show -pqv -t "$TMUX_PANE" @claude_pane_subagents 2>/dev/null)
        new_set=$(subq_del "$cur_set" "$agent")
        [ "$new_set" != "$cur_set" ] && subq_apply=1
      fi
    fi ;;
  notification)
    # Main-thread need_input comes from Notification(permission_prompt)
    # without agent_id. A permission_prompt WITH agent_id is a subagent
    # request: it increments a separate counter (@claude_pane_subagents)
    # instead of overriding the main-loop status. PermissionRequest is not
    # used — it fires for every request, including auto-approved ones.
    payload=$(cat)
    case "$(printf '%s' "$payload" | json_field notification_type)" in
      permission_prompt)
        agent=$(printf '%s' "$payload" | json_field agent_id)
        if [ -n "$agent" ]; then
          [ -n "$TMUX_PANE" ] || exit 0
          cur_set=$(tmux show -pqv -t "$TMUX_PANE" @claude_pane_subagents 2>/dev/null)
          new_set=$(subq_add "$cur_set" "$agent" "$(date +%s)")
          subq_apply=1; subq_only=1
        else
          status=need_input
        fi ;;
      idle_prompt) status=waiting ;;
      *)           exit 0 ;;
    esac ;;
  subagent_end)
    # SubagentStop: the subagent concluded (answered/denied/finished) → drop
    # it from the pending set. Backstop for a missed PostToolUse decrement.
    [ -n "$TMUX_PANE" ] || exit 0
    agent=$(json_field agent_id)
    [ -n "$agent" ] || exit 0
    cur_set=$(tmux show -pqv -t "$TMUX_PANE" @claude_pane_subagents 2>/dev/null)
    new_set=$(subq_del "$cur_set" "$agent")
    [ "$new_set" = "$cur_set" ] && exit 0
    subq_apply=1; subq_only=1 ;;
  session_end)
    # /clear emits SessionEnd(reason=clear) then SessionStart, in parallel:
    # unsetting here could lose the race against SessionStart's `waiting`.
    # Setting `waiting` is idempotent whatever the execution order.
    if [ "$(json_field reason)" = "clear" ]; then status=waiting; else status=""; fi ;;
  recompute)
    win="$2"; [ -n "$win" ] || exit 0 ;;
  *) exit 0 ;;
esac

# Apply a subagent-set change (may accompany a status change in working_soft).
if [ "$subq_apply" = 1 ]; then
  if [ -n "$new_set" ]; then
    tmux set -p -t "$TMUX_PANE" @claude_pane_subagents "$new_set" 2>/dev/null
  else
    tmux set -pu -t "$TMUX_PANE" @claude_pane_subagents 2>/dev/null
  fi
  recompute_subq "$TMUX_PANE"
  tmux refresh-client -S 2>/dev/null
  wake_daemon
fi
# Subagent-only events (permission_prompt with agent_id, SubagentStop) never
# touch the main-loop status.
[ "$subq_only" = 1 ] && exit 0

if [ "$mode" != "recompute" ]; then
  [ -n "$TMUX_PANE" ] || exit 0
  cur=$(tmux show -pqv -t "$TMUX_PANE" @claude_pane_status 2>/dev/null) || exit 0
  [ "$cur" = "$status" ] && exit 0
  [ "$soft" = 1 ] && [ "$cur" = "waiting" ] && exit 0
  if [ -n "$status" ]; then
    tmux set -p -t "$TMUX_PANE" @claude_pane_status "$status" 2>/dev/null || exit 0
    tmux set -p -t "$TMUX_PANE" @claude_pane_status_since "$(date +%s)" 2>/dev/null
    # A real event reasserts authority over any daemon activity-promotion.
    tmux set -pu -t "$TMUX_PANE" @claude_pane_promoted 2>/dev/null
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
    # End of turn / session start: no subagent can still be pending.
    if [ "$status" = waiting ] && \
       [ -n "$(tmux show -pqv -t "$TMUX_PANE" @claude_pane_subagents 2>/dev/null)" ]; then
      tmux set -pu -t "$TMUX_PANE" @claude_pane_subagents 2>/dev/null
      recompute_subq "$TMUX_PANE"
    fi
  else
    tmux set -pu -t "$TMUX_PANE" @claude_pane_status 2>/dev/null || exit 0
    tmux set -pu -t "$TMUX_PANE" @claude_pane_status_since 2>/dev/null
    tmux set -pu -t "$TMUX_PANE" @claude_pane_pid 2>/dev/null
    tmux set -pu -t "$TMUX_PANE" @claude_pane_flavor 2>/dev/null
    tmux set -pu -t "$TMUX_PANE" @claude_pane_promoted 2>/dev/null
    tmux set -pu -t "$TMUX_PANE" @claude_pane_subagents 2>/dev/null
    recompute_subq "$TMUX_PANE"
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

[ "$mode" != "recompute" ] && [ -n "$status" ] && wake_daemon
exit 0
