#!/usr/bin/env bash
# claude-status.tmux — entry point du plugin. Compose les badges de statut
# Claude Code, installe les hooks de nettoyage et le binding jump (opt-in).
# À charger depuis tmux.conf (idéalement APRÈS catppuccin, pour hériter de
# @thm_red comme couleur d'erreur) :
#   run-shell /path/to/tmux-hook/claude-status.tmux
#
# Badges exposés (à référencer via #{E:...} dans n'importe quel format tmux) :
#   @claude_badge_win     : statut agrégé de la fenêtre (@claude_win_status)
#   @claude_badge_pane    : statut du pane (@claude_pane_status)
#   @claude_badge_summary : résumé global toutes fenêtres, pour status-right
#
# Options de personnalisation (à définir AVANT de charger le plugin) :
#   @claude_status_color            (défaut : #D97757, orange Claude)
#   @claude_status_error_color     (défaut : @thm_red catppuccin, sinon red)
#   @claude_status_icon_working     (défaut : ✱ — fallback quand pas de spinner)
#   @claude_status_icon_need_input  (défaut : ?)
#   @claude_status_icon_waiting     (défaut : ●)
#   @claude_status_icon_error       (défaut : ✗)
#   @claude_spinner_frames          (défaut : "✻ ✳ ✶ ✱", séparées par espaces)
#   @claude_status_jump_key         (défaut : vide — pas de binding ; ex: "C"
#                                    pour prefix+C → saute vers need_input)

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
icon_error=$(get_tmux_option "@claude_status_icon_error" "✗")

# Rouge adaptatif : override utilisateur > @thm_red catppuccin (suit le
# flavor clair/sombre) > red ANSI (palette du terminal, thème-agnostique).
thm_red=$(tmux show-option -gqv "@thm_red")
err_color=$(get_tmux_option "@claude_status_error_color" "${thm_red:-red}")
# Publiée pour le démon (segment ✗ du summary).
tmux set -g @claude_status_error_color_resolved "$err_color"

# ATTENTION format tmux : jamais de virgule à l'intérieur d'un #[...] — tmux
# compte les virgules des ternaires #{?,,} sans suivre les crochets.
#
# Badge 4 états : need_input > error > working > waiting.
#   - couleur : rouge si error, orange sinon
#   - working : frame du spinner si le démon tourne, icône statique sinon
#   - need_input (badge fenêtre) : durée d'attente si posée par le démon
badge() {
  local opt="$1" wait_part="$2"
  printf '#{?#{%s},#{?#{==:#{%s},error},#[fg=%s],#[fg=%s]}#[bold]#{?#{==:#{%s},need_input},%s %s,#{?#{==:#{%s},error},%s ,#{?#{==:#{%s},working},#{?#{@claude_spinner_frame},#{E:@claude_spinner_frame},%s} ,%s }}}#[nobold]#[fg=default],}' \
    "$opt" \
    "$opt" "$err_color" "$color" \
    "$opt" "$icon_need_input" "$wait_part" \
    "$opt" "$icon_error" \
    "$opt" "$icon_working" \
    "$icon_waiting"
}

# Durée d'attente (option window posée par le démon), espace conditionnel.
win_wait='#{?#{@claude_win_wait},#{@claude_win_wait} ,}'

tmux set -g @claude_badge_win "$(badge '@claude_win_status' "$win_wait")"
tmux set -g @claude_badge_pane "$(badge '@claude_pane_status' '')"

# Résumé global (texte posé par le démon). Si catppuccin est chargé
# (@thm_surface_0 présent), rendu en « pill » comme ses modules status-right :
#   ◖icône sur fond orange◗ compteurs sur fond surface ◗
# Sinon, texte brut orange. Dans les deux cas : vide → rien (pas d'espace).
sum_icon=$(get_tmux_option "@claude_status_summary_icon" "✳")
thm_surface=$(tmux show-option -gqv "@thm_surface_0")
if [ -n "$thm_surface" ]; then
  tmux set -g @claude_status_summary_text_fg "#{@thm_fg}"
  tmux set -g @claude_badge_summary \
    "#{?#{@claude_status_summary},#[fg=${color}]#[bg=default]#[fg=#{@thm_crust}]#[bg=${color}] ${sum_icon} #[fg=#{@thm_fg}]#[bg=#{@thm_surface_0}] #{E:@claude_status_summary}#[fg=#{@thm_surface_0}]#[bg=default] ,}"
else
  tmux set -g @claude_status_summary_text_fg "$color"
  tmux set -g @claude_badge_summary \
    "#{?#{@claude_status_summary},#[fg=${color}]#[bold]#{E:@claude_status_summary}#[nobold]#[fg=default] ,}"
fi

# Nettoyage : quand un pane meurt, recalcule l'agrégat de sa window
# (sinon un @claude_win_status périmé peut survivre au pane Claude).
# pane-exited couvre l'exit naturel du programme ; il ne se déclenche PAS
# sur la commande kill-pane (prefix+x) — after-kill-pane comble ce trou.
tmux set-hook -g pane-exited "run-shell \"$CURRENT_DIR/scripts/claude-status-hook.sh recompute #{window_id}\""
tmux set-hook -g after-kill-pane "run-shell \"$CURRENT_DIR/scripts/claude-status-hook.sh recompute #{window_id}\""

# Jump (opt-in) : prefix+<key> → prochaine fenêtre need_input (puis error).
jump_key=$(get_tmux_option "@claude_status_jump_key" "")
[ -n "$jump_key" ] && tmux bind "$jump_key" run-shell "$CURRENT_DIR/scripts/claude-status-jump.sh"

exit 0
