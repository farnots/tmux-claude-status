#!/bin/sh
# claude-status-jump.sh — jumps to the next window where Claude is waiting.
# Deterministic cycling over the stable order of list-windows; main-thread
# need_input first, then pending subagent permissions, then error. No fallback
# to working (nothing actionable there).

[ -n "$TMUX" ] || exit 0
cur=$(tmux display -p '#{window_id}')

# pick_next MATCH → cycle to the next window whose "field" (column 2) equals
# MATCH; MATCH="+" means any non-empty field (used for the subagent count).
pick_next() {  # $1 = field option name, $2 = value to match ("+" = non-empty)
  first=""; next=""; seen=0
  for w in $(tmux list-windows -a -F "#{window_id}|#{$1}" \
             | awk -F'|' -v m="$2" '(m=="+" && $2!="") || $2==m {print $1}'); do
    [ -z "$first" ] && first=$w
    [ "$seen" = 1 ] && { next=$w; break; }
    [ "$w" = "$cur" ] && seen=1
  done
  [ -n "$next" ] || next=$first  # wrap, or current window not in the list
  [ -n "$next" ] && { tmux switch-client -t "$next"; exit 0; }
}

pick_next @claude_win_status need_input
pick_next @claude_win_subq +
pick_next @claude_win_status error
tmux display-message "claude: no window waiting for input"
