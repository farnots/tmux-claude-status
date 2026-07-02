#!/usr/bin/env bash
# claude-status.tmux — entry point du plugin. Compose les badges de statut
# Claude Code et installe le hook de nettoyage. À charger depuis tmux.conf :
#   run-shell /path/to/tmux-hook/claude-status.tmux
#
# Badges exposés (à référencer via #{E:...} dans n'importe quel format tmux —
# window-status, status-right, choose-tree, ...) :
#   @claude_badge_win  : badge basé sur l'agrégat window @claude_win_status
#   @claude_badge_pane : badge basé sur @claude_pane_status du pane
#
# Options de personnalisation (à définir AVANT de charger le plugin) :
#   @claude_status_color            (défaut : #D97757, orange Claude)
#   @claude_status_icon_working     (défaut : ✳)
#   @claude_status_icon_need_input  (défaut : ?)
#   @claude_status_icon_waiting     (défaut : ○)

CURRENT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

get_tmux_option() {
  local value
  value=$(tmux show-option -gqv "$1")
  echo "${value:-$2}"
}

color=$(get_tmux_option "@claude_status_color" "#D97757")
icon_working=$(get_tmux_option "@claude_status_icon_working" "✱")
icon_need_input=$(get_tmux_option "@claude_status_icon_need_input" "?")
icon_waiting=$(get_tmux_option "@claude_status_icon_waiting" "●")

# ATTENTION format tmux : jamais de virgule à l'intérieur d'un #[...] — tmux
# compte les virgules des ternaires #{?,,} sans suivre les crochets.
badge() {
  local opt="$1"
  printf '#{?#{%s},#[fg=%s]#[bold]#{?#{==:#{%s},need_input},%s,#{?#{==:#{%s},working},%s,%s}} #[nobold]#[fg=default],}' \
    "$opt" "$color" \
    "$opt" "$icon_need_input" \
    "$opt" "$icon_working" \
    "$icon_waiting"
}

tmux set -g @claude_badge_win "$(badge '@claude_win_status')"
tmux set -g @claude_badge_pane "$(badge '@claude_pane_status')"

# Nettoyage : quand un pane meurt, recalcule l'agrégat de sa window
# (sinon un @claude_win_status périmé peut survivre au pane Claude).
# pane-exited couvre l'exit naturel du programme ; il ne se déclenche PAS
# sur la commande kill-pane (prefix+x) — after-kill-pane comble ce trou.
tmux set-hook -g pane-exited "run-shell \"$CURRENT_DIR/scripts/claude-status-hook.sh recompute #{window_id}\""
tmux set-hook -g after-kill-pane "run-shell \"$CURRENT_DIR/scripts/claude-status-hook.sh recompute #{window_id}\""
