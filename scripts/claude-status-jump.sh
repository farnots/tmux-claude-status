#!/bin/sh
# claude-status-jump.sh — jumps to the next window where Claude is waiting.
# Deterministic cycling over the stable order of list-windows; need_input
# first, then error. No fallback to working (nothing actionable there).

[ -n "$TMUX" ] || exit 0
cur=$(tmux display -p '#{window_id}')

pick_next() {  # $1 = status to look for; switch + exit when found
  first=""; next=""; seen=0
  for w in $(tmux list-windows -a -F '#{window_id}|#{@claude_win_status}' \
             | awk -F'|' -v st="$1" '$2==st{print $1}'); do
    [ -z "$first" ] && first=$w
    [ "$seen" = 1 ] && { next=$w; break; }
    [ "$w" = "$cur" ] && seen=1
  done
  [ -n "$next" ] || next=$first  # wrap, or current window not in the list
  [ -n "$next" ] && { tmux switch-client -t "$next"; exit 0; }
}

pick_next need_input
pick_next error
tmux display-message "claude: no window waiting for input"
