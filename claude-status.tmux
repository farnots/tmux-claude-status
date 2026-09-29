#!/usr/bin/env bash
# claude-status.tmux — plugin entry point. Composes the Claude Code status
# badges, installs the cleanup hooks and the opt-in jump binding.
# Load from tmux.conf (ideally AFTER catppuccin, to inherit @thm_red as the
# error color):
#   run-shell /path/to/tmux-claude-status/claude-status.tmux
#
# Exposed badges (reference them via #{E:...} in any tmux format):
#   @claude_badge_win     : aggregated window status (@claude_win_status)
#   @claude_badge_pane    : pane status (@claude_pane_status)
#   @claude_badge_summary : all-windows summary, for status-right
#
# Customization options (set them BEFORE loading the plugin):
#   @claude_status_color            (default: #D97757, Claude orange)
#   @claude_status_error_color      (default: catppuccin @thm_red, else red)
#   @claude_status_icon_working     (default: ✱ — fallback without spinner)
#   @claude_status_icon_need_input  (default: ?)
#   @claude_status_icon_waiting     (default: ●)
#   @claude_status_icon_background  (default: ✻ — summary, and badge fallback
#                                    without spinner)
#   @claude_status_icon_error       (default: ✗)
#   @claude_status_summary_icon     (default: nerd-font robot)
#   @claude_spinner_frames          (default: "✻ ✳ ✶ ✱", space-separated)
#   @claude_status_jump_key         (default: empty — no binding; e.g. "C"
#                                    for prefix+C → jump to need_input)

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
# Turn over but subagents still running: spinner + their count ("✻2").
icon_background=$(get_tmux_option "@claude_status_icon_background" "✻")
# Waiting badge "shrinks" with age (daemon sets @claude_win_age: 1 then 2)
# to surface sessions left unattended — a terminal cannot change font size,
# so smaller glyphs simulate it.
icon_waiting_old=$(get_tmux_option "@claude_status_icon_waiting_old" "•")
icon_waiting_stale=$(get_tmux_option "@claude_status_icon_waiting_stale" "·")
icon_error=$(get_tmux_option "@claude_status_icon_error" "✗")

# Adaptive red: user override > catppuccin @thm_red (follows the light/dark
# flavor) > ANSI red (terminal palette, theme-agnostic).
thm_red=$(tmux show-option -gqv "@thm_red")
err_color=$(get_tmux_option "@claude_status_error_color" "${thm_red:-red}")
# Published for the daemon (✗ segment of the summary).
tmux set -g @claude_status_error_color_resolved "$err_color"

# tmux format WARNING: never put a comma inside a #[...] — tmux counts the
# commas of #{?,,} ternaries without following square brackets.
#
# 5-state badge: need_input > error > working > background > waiting.
#   - color: red for error, orange otherwise
#   - working: spinner frame while the daemon runs, static icon otherwise
#   - background: same spinner, followed by the running subagents count
#   - need_input (window badge): waiting duration when set by the daemon
badge() {
  local opt="$1" wait_part="$2" count_opt="$3"
  printf '#{?#{%s},#{?#{==:#{%s},error},#[fg=%s],#[fg=%s]}#[bold]#{?#{==:#{%s},need_input},%s %s,#{?#{==:#{%s},error},%s ,#{?#{==:#{%s},working},#{?#{@claude_spinner_frame},#{E:@claude_spinner_frame},%s} ,#{?#{==:#{%s},background},#{?#{@claude_spinner_frame},#{E:@claude_spinner_frame},%s}#{%s} ,#{?#{==:#{@claude_win_age},2},#[dim]%s #[nodim],#{?#{==:#{@claude_win_age},1},%s ,%s }}}}}}#[nobold]#[fg=default],}' \
    "$opt" \
    "$opt" "$err_color" "$color" \
    "$opt" "$icon_need_input" "$wait_part" \
    "$opt" "$icon_error" \
    "$opt" "$icon_working" \
    "$opt" "$icon_background" "$count_opt" \
    "$icon_waiting_stale" "$icon_waiting_old" "$icon_waiting"
}

# Waiting duration (window option set by the daemon), conditional space.
win_wait='#{?#{@claude_win_wait},#{@claude_win_wait} ,}'

tmux set -g @claude_badge_win "$(badge '@claude_win_status' "$win_wait" '@claude_win_agents')"
tmux set -g @claude_badge_pane "$(badge '@claude_pane_status' '' '@claude_pane_agents_n')"

# Global summary (text set by the daemon). If catppuccin is loaded
# (@thm_surface_0 present), rendered as a "pill" like its status modules:
#   ◖icon on orange◗ counters on surface background
# Otherwise, plain orange text. Both cases: empty → nothing (no space).
# Default icon: nerd-font robot (U+F06A9), built from UTF-8 bytes (same
# reason as the separators below).
default_sum_icon=$(printf '\363\260\232\251')
sum_icon=$(get_tmux_option "@claude_status_summary_icon" "$default_sum_icon")
# Powerline half-circles (U+E0B6 / U+E0B4) built from UTF-8 bytes: literals
# in this file risk being dropped by editors/tools that do not preserve the
# Unicode private use area.
sep_left=$(printf '\356\202\266')
sep_right=$(printf '\356\202\264')
thm_surface=$(tmux show-option -gqv "@thm_surface_0")
if [ -n "$thm_surface" ]; then
  tmux set -g @claude_status_summary_text_fg "#{@thm_fg}"
  tmux set -g @claude_badge_summary \
    "#{?#{@claude_status_summary},#[fg=${color}]#[bg=default]${sep_left}#[fg=#{@thm_crust}]#[bg=${color}]${sum_icon} #[fg=#{@thm_fg}]#[bg=#{@thm_surface_0}] #{E:@claude_status_summary}#[fg=#{@thm_surface_0}]${sep_right} ,}"
else
  tmux set -g @claude_status_summary_text_fg "$color"
  tmux set -g @claude_badge_summary \
    "#{?#{@claude_status_summary},#[fg=${color}]#[bold]#{E:@claude_status_summary}#[nobold]#[fg=default] ,}"
fi

# Cleanup: when a pane dies, recompute its window aggregate (otherwise a
# stale @claude_win_status could outlive the Claude pane).
# pane-exited covers the program's natural exit; it does NOT fire on the
# kill-pane command (prefix+x) — after-kill-pane fills that gap.
tmux set-hook -g pane-exited "run-shell \"$CURRENT_DIR/scripts/claude-status-hook.sh recompute #{window_id}\""
tmux set-hook -g after-kill-pane "run-shell \"$CURRENT_DIR/scripts/claude-status-hook.sh recompute #{window_id}\""

# Jump (opt-in): prefix+<key> → next need_input window (then error).
jump_key=$(get_tmux_option "@claude_status_jump_key" "")
[ -n "$jump_key" ] && tmux bind "$jump_key" run-shell "$CURRENT_DIR/scripts/claude-status-jump.sh"

exit 0
