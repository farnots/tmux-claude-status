#!/bin/sh
# claude-status-hook.sh — met à jour le statut Claude Code d'un pane/window tmux.
#
# Usage: claude-status-hook.sh <mode> [window_id]
#   modes hook Claude Code : working | waiting | need_input | notification | session_end
#     (appelés depuis les hooks de settings.json ; le statut est passé en argv,
#      seuls notification et session_end lisent le JSON stdin)
#   mode tmux : recompute <window_id>
#     (appelé par le hook tmux pane-exited pour recalculer l'agrégat d'une
#      window dont un pane vient de mourir)
#
# Options tmux posées :
#   @claude_pane_status (pane-scope)  : working | need_input | waiting
#   @claude_win_status  (window-scope): agrégat des panes, priorité
#                                       need_input > working > waiting
#
# Ne jamais bloquer ni faire échouer Claude : tout chemin sort en `exit 0`.

[ -n "$TMUX" ] || exit 0
mode="$1"

json_field() {
  # Extraction minimale d'un champ string du JSON stdin. Suffisant ici :
  # les valeurs attendues sont des identifiants fixes sans échappement.
  sed -n 's/.*"'"$1"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1
}

case "$mode" in
  working|waiting|need_input) status="$mode" ;;
  notification)
    case "$(json_field notification_type)" in
      permission_prompt) status=need_input ;;
      idle_prompt)       status=waiting ;;
      *)                 exit 0 ;;
    esac ;;
  session_end)
    # /clear émet SessionEnd(reason=clear) puis SessionStart, en parallèle :
    # effacer ici perdrait la course contre le `waiting` du SessionStart.
    # Poser `waiting` est idempotent quel que soit l'ordre d'exécution.
    if [ "$(json_field reason)" = "clear" ]; then status=waiting; else status=""; fi ;;
  recompute)
    win="$2"; [ -n "$win" ] || exit 0 ;;
  *) exit 0 ;;
esac

if [ "$mode" != "recompute" ]; then
  [ -n "$TMUX_PANE" ] || exit 0
  cur=$(tmux show -pqv -t "$TMUX_PANE" @claude_pane_status 2>/dev/null) || exit 0
  [ "$cur" = "$status" ] && exit 0
  if [ -n "$status" ]; then
    tmux set -p -t "$TMUX_PANE" @claude_pane_status "$status" 2>/dev/null || exit 0
  else
    tmux set -pu -t "$TMUX_PANE" @claude_pane_status 2>/dev/null || exit 0
  fi
  win="$TMUX_PANE"  # un pane id est un target-window valide pour list-panes
fi

agg=""
for s in $(tmux list-panes -t "$win" -F '#{@claude_pane_status}' 2>/dev/null); do
  case "$s" in
    need_input) agg=need_input; break ;;
    working)    agg=working ;;
    waiting)    [ -z "$agg" ] && agg=waiting ;;
  esac
done

old=$(tmux show -wqv -t "$win" @claude_win_status 2>/dev/null)
[ "$old" = "$agg" ] && exit 0
if [ -n "$agg" ]; then
  tmux set -w -t "$win" @claude_win_status "$agg" 2>/dev/null
else
  tmux set -wu -t "$win" @claude_win_status 2>/dev/null
fi
tmux refresh-client -S 2>/dev/null
exit 0
