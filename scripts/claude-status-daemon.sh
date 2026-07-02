#!/bin/sh
# claude-status-daemon.sh <socket_path>
#
# Démon compagnon du plugin claude-status. Spawné par le serveur tmux
# (run-shell -b depuis claude-status-hook.sh) : il est fils du serveur et
# meurt avec lui. Vivant tant qu'au moins un pane a un @claude_pane_status.
#
# Responsabilités (propriété exclusive de ces options) :
#   @claude_spinner_frame   (global) : frame d'animation quand ≥1 working
#   @claude_status_summary  (global) : résumé toutes fenêtres « ?1 ✗1 ✱3 ●2 »
#   @claude_win_wait        (window) : durée d'attente des fenêtres need_input
# Et : liveness — efface le statut des panes dont le process claude est mort.
# Le hook reste l'autorité sur les statuts en régime événementiel ; le démon
# ne recalcule un agrégat window QUE pour les panes qu'il vient d'effacer.

sock=$1
[ -S "$sock" ] || exit 0
t() { tmux -S "$sock" "$@"; }

# ---- single-instance : mkdir-lock atomique, nommé par pid du serveur ----
server_pid=$(t display -p '#{pid}' 2>/dev/null) || exit 0
lock="${TMPDIR:-/tmp}/claude-status-daemon-${server_pid}.lock"
acquire() {
  if mkdir "$lock" 2>/dev/null; then echo $$ > "$lock/pid"; return 0; fi
  old=$(cat "$lock/pid" 2>/dev/null)
  if [ -n "$old" ]; then
    kill -0 "$old" 2>/dev/null && return 1  # démon vivant → on est un doublon
  else
    # pid pas encore écrit : le gagnant vient probablement de créer le lock
    # (fenêtre mkdir→echo). Ne voler que si le lock est manifestement stale.
    mtime=$(stat -f %m "$lock" 2>/dev/null || stat -c %Y "$lock" 2>/dev/null || echo 0)
    [ $(( $(date +%s) - mtime )) -lt 30 ] && return 1
  fi
  rm -rf "$lock"
  if mkdir "$lock" 2>/dev/null; then echo $$ > "$lock/pid"; return 0; fi
  return 1  # course de nettoyage perdue : un concurrent a gagné, tant mieux
}
acquire || exit 0

cleanup() {
  t set -gu @claude_spinner_frame \; set -gu @claude_status_summary \; \
    set -gu @claude_daemon_pid \; refresh-client -S 2>/dev/null
  rm -rf "$lock"
}
trap 'cleanup; exit 0' TERM INT
t set -g @claude_daemon_pid $$ 2>/dev/null || { rm -rf "$lock"; exit 0; }

# ---- config (lue une fois au démarrage) ----
opt() { v=$(t show -gqv "$1" 2>/dev/null); [ -n "$v" ] && echo "$v" || echo "$2"; }
frames=$(opt @claude_spinner_frames "✻ ✳ ✶ ✱")
icon_need=$(opt @claude_status_icon_need_input "?")
icon_err=$(opt @claude_status_icon_error "✗")
icon_work=$(opt @claude_status_icon_working "✱")
icon_wait=$(opt @claude_status_icon_waiting "●")
color=$(opt @claude_status_color "#D97757")
err_color=$(opt @claude_status_error_color_resolved "red")
set -- $frames; nframes=$#; fi=0

fmt_dur() {  # 30s / 3m / 1h05
  s=$1; [ "$s" -ge 0 ] 2>/dev/null || s=0
  if   [ "$s" -lt 60 ];   then printf '%ss' "$s"
  elif [ "$s" -lt 3600 ]; then printf '%sm' $((s / 60))
  else printf '%dh%02d' $((s / 3600)) $(( (s % 3600) / 60 )); fi
}

# ---- sweep : liveness, durées, summary. Pose $mode pour la boucle. ----
sweep() {
  now=$(date +%s); changed=0; mode=none

  panes=$(t list-panes -a -F \
    '#{pane_id}|#{window_id}|#{pane_tty}|#{@claude_pane_status}|#{@claude_pane_pid}|#{@claude_pane_status_since}' \
    2>/dev/null) || { cleanup; exit 0; }

  # 1) liveness : un seul ps batché ; mort = pid absent OU tty différent
  #    (le process claude garde le tty du pane ; contre la réutilisation de PID)
  pids=""
  while IFS='|' read -r pane win tty st pid since; do
    [ -n "$st" ] && [ -n "$pid" ] && pids="$pids,$pid"
  done <<EOF
$panes
EOF
  pids=${pids#,}
  alive=""
  [ -n "$pids" ] && alive=$(ps -o pid=,tt= -p "$pids" 2>/dev/null)

  dead_windows=""
  live_panes=""
  while IFS='|' read -r pane win tty st pid since; do
    [ -n "$st" ] || continue
    if [ -n "$pid" ]; then
      ptty=$(printf '%s\n' "$alive" | awk -v p="$pid" '$1==p{print $2}')
      if [ -z "$ptty" ] || [ "${tty#/dev/tty}" != "$ptty" ]; then
        t set -pu -t "$pane" @claude_pane_status \; \
          set -pu -t "$pane" @claude_pane_pid \; \
          set -pu -t "$pane" @claude_pane_status_since 2>/dev/null
        dead_windows="$dead_windows $win"; changed=1
        continue
      fi
    fi
    live_panes="$live_panes
$pane|$win|$st|$since"
  done <<EOF
$panes
EOF

  # 2) agrégats : uniquement les fenêtres dont on vient de tuer un pane
  for win in $(printf '%s\n' $dead_windows | sort -u); do
    agg=""
    for s in $(t list-panes -t "$win" -F '#{@claude_pane_status}' 2>/dev/null); do
      case "$s" in
        need_input) agg=need_input; break ;;
        error)      agg=error ;;
        working)    [ "$agg" != "error" ] && agg=working ;;
        waiting)    [ -z "$agg" ] && agg=waiting ;;
      esac
    done
    if [ -n "$agg" ]; then
      t set -w -t "$win" @claude_win_status "$agg" 2>/dev/null
    else
      t set -wu -t "$win" @claude_win_status 2>/dev/null
    fi
  done

  # 3) par fenêtre : compteurs (granularité fenêtre) + durées need_input
  wins=$(t list-windows -a -F '#{window_id}|#{@claude_win_status}|#{@claude_win_wait}' 2>/dev/null)
  n_need=0; n_err=0; n_work=0; n_wait=0
  while IFS='|' read -r win agg wait; do
    case "$agg" in
      need_input)
        n_need=$((n_need+1))
        min_since=""
        while IFS='|' read -r p w st since; do
          [ "$w" = "$win" ] && [ "$st" = "need_input" ] && [ -n "$since" ] || continue
          if [ -z "$min_since" ] || [ "$since" -lt "$min_since" ]; then min_since=$since; fi
        done <<EOF2
$live_panes
EOF2
        if [ -n "$min_since" ]; then
          txt=$(fmt_dur $((now - min_since)))
          [ "$txt" != "$wait" ] && { t set -w -t "$win" @claude_win_wait "$txt" 2>/dev/null; changed=1; }
        fi ;;
      error)   n_err=$((n_err+1)) ;;
      working) n_work=$((n_work+1)) ;;
      waiting) n_wait=$((n_wait+1)) ;;
    esac
    if [ "$agg" != "need_input" ] && [ -n "$wait" ]; then
      t set -wu -t "$win" @claude_win_wait 2>/dev/null; changed=1
    fi
  done <<EOF
$wins
EOF

  # 4) summary global (zéros omis, ordre d'actionnabilité)
  summary=""
  [ "$n_need" -gt 0 ] && summary="${summary}${icon_need}${n_need} "
  [ "$n_err"  -gt 0 ] && summary="${summary}#[fg=${err_color}]${icon_err}${n_err}#[fg=${color}] "
  [ "$n_work" -gt 0 ] && summary="${summary}${icon_work}${n_work} "
  [ "$n_wait" -gt 0 ] && summary="${summary}${icon_wait}${n_wait} "
  summary=${summary% }
  [ "$summary" != "$(t show -gqv @claude_status_summary 2>/dev/null)" ] && {
    if [ -n "$summary" ]; then
      t set -g @claude_status_summary "$summary" 2>/dev/null
    else
      t set -gu @claude_status_summary 2>/dev/null
    fi
    changed=1
  }

  # 5) mode pour la boucle principale
  total=$((n_need + n_err + n_work + n_wait))
  clients=$(t list-clients 2>/dev/null | grep -c .)
  if [ "$total" -eq 0 ]; then
    mode=none
  elif [ "$n_work" -gt 0 ] && [ "$clients" -gt 0 ]; then
    mode=working
  else
    mode=idle
  fi
  [ "$changed" = 1 ] && [ "$clients" -gt 0 ] && t refresh-client -S 2>/dev/null
}

# ---- boucle principale ----
while :; do
  sweep
  case $mode in
    none)
      cleanup; exit 0 ;;
    working)
      # ~5 s de ticks rapides (animation) puis re-sweep
      n=0
      while [ "$n" -lt 12 ]; do
        fi=$(( (fi % nframes) + 1 ))
        set -- $frames; shift $((fi - 1)); frame=$1
        t set -g @claude_spinner_frame "$frame" \; refresh-client -S 2>/dev/null || { cleanup; exit 0; }
        sleep 0.4; n=$((n+1))
      done ;;
    idle)
      if [ -n "$(t show -gqv @claude_spinner_frame 2>/dev/null)" ]; then
        t set -gu @claude_spinner_frame \; refresh-client -S 2>/dev/null
      fi
      sleep 5 ;;
  esac
done
