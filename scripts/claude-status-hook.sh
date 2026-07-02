#!/bin/sh
# claude-status-hook.sh — met à jour le statut Claude Code d'un pane/window tmux.
#
# Usage: claude-status-hook.sh <mode> [window_id]
#   modes hook Claude Code : working | waiting | need_input | error |
#                            notification | session_end
#     (appelés depuis les hooks de settings.json ; le statut est passé en argv,
#      seuls notification et session_end lisent le JSON stdin)
#   mode tmux : recompute <window_id>
#     (appelé par le hook tmux pane-exited pour recalculer l'agrégat d'une
#      window dont un pane vient de mourir)
#
# Options tmux posées :
#   @claude_pane_status       (pane)   : working | need_input | waiting | error
#   @claude_pane_status_since (pane)   : epoch du dernier changement de statut
#   @claude_pane_pid          (pane)   : PID du process claude (liveness démon)
#   @claude_win_status        (window) : agrégat des panes, priorité
#                                        need_input > error > working > waiting
#
# Ne jamais bloquer ni faire échouer Claude : tout chemin sort en `exit 0`.

[ -n "$TMUX" ] || exit 0
mode="$1"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

json_field() {
  # Extraction minimale d'un champ string du JSON stdin. Suffisant ici :
  # les valeurs attendues sont des identifiants fixes sans échappement.
  sed -n 's/.*"'"$1"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1
}

# Remonte la chaîne des ppid depuis ce script jusqu'au fils direct du shell
# racine du pane (= le process claude au premier plan). Gère aussi le cas où
# claude a été lancé en `exec` (claude EST pane_pid).
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
  working|waiting|need_input|error) status="$mode" ;;
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
    tmux set -p -t "$TMUX_PANE" @claude_pane_status_since "$(date +%s)" 2>/dev/null
    # PID claude pour la liveness du démon — seulement si absent (le sweep
    # l'efface quand le process meurt).
    if [ -z "$(tmux show -pqv -t "$TMUX_PANE" @claude_pane_pid 2>/dev/null)" ]; then
      pane_pid=$(tmux display -p -t "$TMUX_PANE" '#{pane_pid}' 2>/dev/null)
      cpid=$(find_claude_pid "$pane_pid") || cpid=$PPID
      [ "$cpid" -gt 1 ] 2>/dev/null && \
        tmux set -p -t "$TMUX_PANE" @claude_pane_pid "$cpid" 2>/dev/null
    fi
  else
    tmux set -pu -t "$TMUX_PANE" @claude_pane_status 2>/dev/null || exit 0
    tmux set -pu -t "$TMUX_PANE" @claude_pane_status_since 2>/dev/null
    tmux set -pu -t "$TMUX_PANE" @claude_pane_pid 2>/dev/null
  fi
  win="$TMUX_PANE"  # un pane id est un target-window valide pour list-panes
fi

# Agrégat window : need_input > error > working > waiting ; vide si aucun pane
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

# Réveil du démon (animation, liveness, durées, summary). Heuristique rapide
# tolérante aux faux positifs : le démon a son propre mkdir-lock atomique.
if [ "$mode" != "recompute" ] && [ -n "$status" ]; then
  dpid=$(tmux show -gqv @claude_daemon_pid 2>/dev/null)
  if [ -z "$dpid" ] || ! kill -0 "$dpid" 2>/dev/null; then
    tmux run-shell -b "exec $SCRIPT_DIR/claude-status-daemon.sh '#{socket_path}' >/dev/null 2>&1 </dev/null" 2>/dev/null
  fi
fi
exit 0
