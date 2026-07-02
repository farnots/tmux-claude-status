#!/bin/sh
# claude-status-jump.sh — saute vers la prochaine fenêtre où Claude attend.
# Cycling déterministe sur l'ordre stable de list-windows ; need_input
# d'abord, puis error. Pas de fallback working (rien d'actionnable).

[ -n "$TMUX" ] || exit 0
cur=$(tmux display -p '#{window_id}')

pick_next() {  # $1 = statut cherché ; switch + exit si trouvé
  first=""; next=""; seen=0
  for w in $(tmux list-windows -a -F '#{window_id}|#{@claude_win_status}' \
             | awk -F'|' -v st="$1" '$2==st{print $1}'); do
    [ -z "$first" ] && first=$w
    [ "$seen" = 1 ] && { next=$w; break; }
    [ "$w" = "$cur" ] && seen=1
  done
  [ -n "$next" ] || next=$first  # wrap, ou fenêtre courante hors liste
  [ -n "$next" ] && { tmux switch-client -t "$next"; exit 0; }
}

pick_next need_input
pick_next error
tmux display-message "claude: aucune fenêtre en attente"
