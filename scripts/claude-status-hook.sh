#!/bin/sh
# claude-status-hook.sh — updates the Claude Code status of a tmux pane/window.
#
# Usage: claude-status-hook.sh <mode> [window_id]
#   Claude Code hook modes: working | working_soft | waiting | need_input |
#                           error | notification | session_end |
#                           subagent_start | subagent_end
#     (called from settings.json hooks; the status is passed as argv, the
#      JSON on stdin is read by waiting, notification, session_end and the
#      subagent modes)
#   tmux mode: recompute <window_id>
#     (called by the tmux pane-exited / after-kill-pane hooks to recompute
#      the aggregate of a window whose pane just died)
#
# tmux options set:
#   @claude_pane_status       (pane)   : working | need_input | background |
#                                        waiting | error
#   @claude_pane_status_since (pane)   : epoch of the last status change
#   @claude_pane_pid          (pane)   : PID of the claude process (liveness)
#   @claude_pane_flavor       (pane)   : config dir name ("claude", ...)
#   @claude_pane_agents       (pane)   : ids of the running subagents
#   @claude_pane_agents_n     (pane)   : their count (for the badge)
#   @claude_pane_agents_done  (pane)   : recently ended ids (race guard)
#   @claude_win_status        (window) : pane aggregate, priority need_input >
#                                        error > working > background > waiting
#   @claude_win_agents        (window) : running subagents of background panes
#
# Never block or fail Claude: every path exits 0.

[ -n "$TMUX" ] || exit 0
mode="$1"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

json_field() {
  # Minimal extraction of a string field from $payload. Sufficient here:
  # expected values are fixed identifiers without escaping.
  printf '%s' "$payload" |
    sed -n 's/.*"'"$1"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1
}

# Ids of the running subagents and workflows listed in the payload's
# background_tasks (Stop and SubagentStop carry it). A workflow is listed
# alone, not its agents: it counts as one. Its entries are flat objects;
# escaped quotes inside message texts never match the unescaped
# "key":"value" patterns. Background shells and teammates are ignored on
# purpose: a dev server or an idle teammate would keep a session busy
# forever.
bg_agent_ids() {
  printf '%s' "$payload" | sed 's/.*"background_tasks"//' | tr '{}' '\n\n' |
    grep -E '"type"[[:space:]]*:[[:space:]]*"(subagent|workflow)"' |
    grep '"status"[[:space:]]*:[[:space:]]*"running"' |
    sed -n 's/.*"id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p'
}

has_word() { case " $1 " in *" $2 "*) return 0 ;; esac; return 1; }

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

case "$mode" in
  waiting|notification|session_end|subagent_start|subagent_end)
    payload=$(cat) ;;
esac

soft=0
agents_op=""  # how this event changes the running-subagents set
case "$mode" in
  working|need_input|error) status="$mode" ;;
  waiting)
    # Stop: the turn is over, but background subagents may still run — the
    # payload lists them. SessionStart (startup/resume/clear): none survive.
    status=waiting
    if [ "$(json_field hook_event_name)" = "Stop" ]; then agents_op=sync; else agents_op=reset; fi ;;
  working_soft)
    # PreToolUse/PostToolUse/PreCompact: these events can arrive LATE, after
    # the end-of-turn Stop (hooks run in parallel, background agents run
    # tools too). A "soft" working never overrides a waiting/background —
    # only UserPromptSubmit (a genuine turn start) does.
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
    agents_op=reset
    if [ "$(json_field reason)" = "clear" ]; then status=waiting; else status=""; fi ;;
  subagent_start|subagent_end)
    # Status follows the set: waiting ↔ background, anything else is kept.
    agent_id=$(json_field agent_id)
    [ -n "$agent_id" ] || exit 0
    agents_op=${mode#subagent_}; status=""
    # A workflow's agents come and go between its phases: the workflow
    # itself (from background_tasks) is what we track, not them.
    if [ "$(json_field agent_type)" = "workflow-subagent" ]; then
      [ "$mode" = subagent_start ] && exit 0
      agents_op=sync
    fi ;;
  recompute)
    win="$2"; [ -n "$win" ] || exit 0 ;;
  *) exit 0 ;;
esac

if [ "$mode" != "recompute" ]; then
  [ -n "$TMUX_PANE" ] || exit 0
  cur=$(tmux show -pqv -t "$TMUX_PANE" @claude_pane_status 2>/dev/null) || exit 0

  # ---- running subagents ----
  agents=$(tmux show -pqv -t "$TMUX_PANE" @claude_pane_agents 2>/dev/null)
  done_ids=$(tmux show -pqv -t "$TMUX_PANE" @claude_pane_agents_done 2>/dev/null)
  old_agents=$agents
  case "$agents_op" in
    reset) agents=""; done_ids="" ;;
    sync)
      # Stop runs in parallel with a SubagentStop: skip ids already ended.
      agents=""
      for id in $(bg_agent_ids); do
        has_word "$done_ids" "$id" || agents="$agents $id"
      done ;;
    start)
      has_word "$agents" "$agent_id" || has_word "$done_ids" "$agent_id" ||
        agents="$agents $agent_id" ;;
    end)
      # keep the last 20 ended ids
      done_ids=$(printf '%s\n' $done_ids "$agent_id" | tail -20 | tr '\n' ' ')
      case "$payload" in
        *'"background_tasks"'*)
          # the payload still lists this agent as running: done_ids skips it
          agents=""
          for id in $(bg_agent_ids); do
            has_word "$done_ids" "$id" || agents="$agents $id"
          done ;;
        *)
          rest=""
          for id in $agents; do [ "$id" = "$agent_id" ] || rest="$rest $id"; done
          agents=$rest ;;
      esac ;;
  esac
  agents=$(echo $agents); done_ids=$(echo $done_ids)  # normalize spaces
  n_agents=$(echo $agents | wc -w | tr -d ' ')
  if [ -n "$agents_op" ]; then
    if [ -n "$agents" ]; then
      tmux set -p -t "$TMUX_PANE" @claude_pane_agents "$agents" \; \
        set -p -t "$TMUX_PANE" @claude_pane_agents_n "$n_agents" 2>/dev/null
    else
      tmux set -pu -t "$TMUX_PANE" @claude_pane_agents \; \
        set -pu -t "$TMUX_PANE" @claude_pane_agents_n 2>/dev/null
    fi
    if [ -n "$done_ids" ]; then
      tmux set -p -t "$TMUX_PANE" @claude_pane_agents_done "$done_ids" 2>/dev/null
    else
      tmux set -pu -t "$TMUX_PANE" @claude_pane_agents_done 2>/dev/null
    fi
  fi

  # waiting with subagents still running = background (and back)
  case "$mode" in
    subagent_start|subagent_end)
      case "$cur" in
        waiting|background) status=waiting ;;
        *) status=$cur ;;
      esac ;;
  esac
  [ "$status" = "waiting" ] && [ -n "$agents" ] && status=background

  if [ "$cur" = "$status" ]; then
    # Same status: only the subagent count may have changed.
    [ "$agents" != "$old_agents" ] || exit 0
  elif [ "$soft" = 1 ] && { [ "$cur" = "waiting" ] || [ "$cur" = "background" ]; }; then
    exit 0
  elif [ -n "$status" ]; then
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
  else
    tmux set -pu -t "$TMUX_PANE" @claude_pane_status 2>/dev/null || exit 0
    tmux set -pu -t "$TMUX_PANE" @claude_pane_status_since 2>/dev/null
    tmux set -pu -t "$TMUX_PANE" @claude_pane_pid 2>/dev/null
    tmux set -pu -t "$TMUX_PANE" @claude_pane_flavor 2>/dev/null
    tmux set -pu -t "$TMUX_PANE" @claude_pane_promoted 2>/dev/null
  fi
  win="$TMUX_PANE"  # a pane id is a valid target-window for list-panes
fi

# Window aggregate: need_input > error > working > background > waiting;
# empty if no pane. Subagent count summed over the background panes.
agg=""; win_agents=0
while IFS='|' read -r s n; do
  case "$s" in
    need_input) agg=need_input ;;
    error)      [ "$agg" != need_input ] && agg=error ;;
    working)    case "$agg" in need_input|error) ;; *) agg=working ;; esac ;;
    background) case "$agg" in ""|waiting) agg=background ;; esac
                win_agents=$((win_agents + ${n:-0})) ;;
    waiting)    [ -z "$agg" ] && agg=waiting ;;
  esac
done <<EOF
$(tmux list-panes -t "$win" -F '#{@claude_pane_status}|#{@claude_pane_agents_n}' 2>/dev/null)
EOF

old=$(tmux show -wqv -t "$win" @claude_win_status 2>/dev/null)
old_n=$(tmux show -wqv -t "$win" @claude_win_agents 2>/dev/null)
[ "$win_agents" -gt 0 ] || win_agents=""
if [ "$old" != "$agg" ] || [ "$old_n" != "$win_agents" ]; then
  if [ -n "$agg" ]; then
    tmux set -w -t "$win" @claude_win_status "$agg" 2>/dev/null
  else
    tmux set -wu -t "$win" @claude_win_status 2>/dev/null
  fi
  if [ -n "$win_agents" ]; then
    tmux set -w -t "$win" @claude_win_agents "$win_agents" 2>/dev/null
  else
    tmux set -wu -t "$win" @claude_win_agents 2>/dev/null
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
