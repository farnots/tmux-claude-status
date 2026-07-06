#!/bin/sh
# claude-status-daemon.sh <socket_path>
#
# Companion daemon of the claude-status plugin. Spawned by the tmux server
# itself (run-shell -b from claude-status-hook.sh): it is a child of the
# server and dies with it. Alive as long as at least one pane has a
# @claude_pane_status.
#
# Responsibilities (exclusive ownership of these options):
#   @claude_spinner_frame   (global) : animation frame while ≥1 window works
#   @claude_status_summary  (global) : all-windows summary "?1 ✗1 ✱3 ●2"
#   @claude_win_wait        (window) : waiting duration of need_input windows
#   @claude_pane_scrhash    (pane)   : last cksum of the pane's visible content
#   @claude_pane_hot        (pane)   : content changed on the previous sweep
#                                      (the 2-sweep debounce, per pane)
# Plus: liveness — clears the status of panes whose claude process is dead.
# The hook remains the authority on statuses in event-driven mode; the daemon
# recomputes the window aggregates from the (corrected) pane statuses.

sock=$1
[ -S "$sock" ] || exit 0
t() { tmux -S "$sock" "$@"; }

# ---- single instance: atomic mkdir lock, named after the server pid ----
server_pid=$(t display -p '#{pid}' 2>/dev/null) || exit 0
lock="${TMPDIR:-/tmp}/claude-status-daemon-${server_pid}.lock"
acquire() {
  if mkdir "$lock" 2>/dev/null; then echo $$ > "$lock/pid"; return 0; fi
  old=$(cat "$lock/pid" 2>/dev/null)
  if [ -n "$old" ]; then
    kill -0 "$old" 2>/dev/null && return 1  # live daemon → we are a duplicate
  else
    # pid not written yet: the winner probably just created the lock
    # (mkdir→echo window). Only steal if the lock is clearly stale.
    mtime=$(stat -f %m "$lock" 2>/dev/null || stat -c %Y "$lock" 2>/dev/null || echo 0)
    [ $(( $(date +%s) - mtime )) -lt 30 ] && return 1
  fi
  rm -rf "$lock"
  if mkdir "$lock" 2>/dev/null; then echo $$ > "$lock/pid"; return 0; fi
  return 1  # lost the cleanup race: a concurrent daemon won, which is fine
}
acquire || exit 0

cleanup() {
  t set -gu @claude_spinner_frame \; set -gu @claude_status_summary \; \
    set -gu @claude_daemon_pid \; refresh-client -S 2>/dev/null
  rm -rf "$lock"
}
trap 'cleanup; exit 0' TERM INT
t set -g @claude_daemon_pid $$ 2>/dev/null || { rm -rf "$lock"; exit 0; }

# ---- config (read once at startup) ----
opt() { v=$(t show -gqv "$1" 2>/dev/null); [ -n "$v" ] && echo "$v" || echo "$2"; }
frames=$(opt @claude_spinner_frames "✻ ✳ ✶ ✱")
icon_need=$(opt @claude_status_icon_need_input "?")
icon_err=$(opt @claude_status_icon_error "✗")
icon_work=$(opt @claude_status_icon_working "✱")
icon_wait=$(opt @claude_status_icon_waiting "●")
color=$(opt @claude_status_color "#D97757")
err_color=$(opt @claude_status_error_color_resolved "red")
# Waiting badge aging thresholds (seconds): ● → • after old, → · after stale
old_secs=$(opt @claude_status_waiting_old_secs 300)
stale_secs=$(opt @claude_status_waiting_stale_secs 1800)
# Color to return to after the ✗ segment: set by the entry point according
# to the summary rendering context (theme fg in pill mode, orange otherwise).
text_fg=$(opt @claude_status_summary_text_fg "$color")
set -- $frames; nframes=$#; fi=0

fmt_dur() {  # 30s / 3m / 1h05
  s=$1; [ "$s" -ge 0 ] 2>/dev/null || s=0
  if   [ "$s" -lt 60 ];   then printf '%ss' "$s"
  elif [ "$s" -lt 3600 ]; then printf '%sm' $((s / 60))
  else printf '%dh%02d' $((s / 3600)) $(( (s % 3600) / 60 )); fi
}

# ---- sweep: liveness, durations, summary. Sets $mode for the main loop. ----
sweep() {
  now=$(date +%s); changed=0; mode=none

  panes=$(t list-panes -a -F \
    '#{pane_id}|#{window_id}|#{pane_tty}|#{@claude_pane_status}|#{@claude_pane_pid}|#{@claude_pane_status_since}|#{@claude_pane_promoted}' \
    2>/dev/null) || { cleanup; exit 0; }

  # 1) liveness: a single batched ps; dead = pid gone OR different tty
  #    (the claude process keeps the pane's tty; guards against PID reuse)
  pids=""
  while IFS='|' read -r pane win tty st pid since prom; do
    [ -n "$st" ] && [ -n "$pid" ] && pids="$pids,$pid"
  done <<EOF
$panes
EOF
  pids=${pids#,}
  alive=""
  [ -n "$pids" ] && alive=$(ps -o pid=,tt= -p "$pids" 2>/dev/null)

  live_panes=""
  while IFS='|' read -r pane win tty st pid since prom; do
    [ -n "$st" ] || continue
    if [ -n "$pid" ]; then
      ptty=$(printf '%s\n' "$alive" | awk -v p="$pid" '$1==p{print $2}')
      if [ -z "$ptty" ] || [ "${tty#/dev/tty}" != "$ptty" ]; then
        t set -pu -t "$pane" @claude_pane_status \; \
          set -pu -t "$pane" @claude_pane_pid \; \
          set -pu -t "$pane" @claude_pane_status_since \; \
          set -pu -t "$pane" @claude_pane_flavor \; \
          set -pu -t "$pane" @claude_pane_promoted \; \
          set -pu -t "$pane" @claude_pane_hot \; \
          set -pu -t "$pane" @claude_pane_scrhash 2>/dev/null
        changed=1
        continue
      fi
    fi
    live_panes="$live_panes
$pane|$win|$st|$since|$prom"
  done <<EOF
$panes
EOF

  # 2) activity-based correction, PER PANE. Hooks can't see everything:
  #    answering a question or a background agent running after end-of-turn
  #    emit no event. A working Claude redraws its spinner/elapsed-timer every
  #    sweep, so its visible content keeps changing; an idle one is stable.
  #    tmux has no per-pane activity timestamp — window_activity aggregates
  #    ALL panes of the window, so a noisy sibling (lazygit, a dev server,
  #    tail -f) would keep a truly-idle Claude pane perpetually "fresh". We
  #    therefore hash each candidate pane's OWN content (@claude_pane_scrhash):
  #    - need_input/waiting + content changed on 2 consecutive sweeps → promote
  #      to working (origin saved in @claude_pane_promoted)
  #    - daemon-promoted working + content gone stable → roll back to origin
  #    Only candidate panes are captured (idle Claude panes, or ones we
  #    promoted); hook-set working panes (no @claude_pane_promoted) are never
  #    touched. Real hook events always clear @claude_pane_promoted (authority).
  while IFS='|' read -r p win st since prom; do
    [ -n "$p" ] || continue
    # working is a candidate only when WE promoted it (prom set); a hook-set
    # working must never be rolled back by activity.
    cand=0
    case "$st" in
      need_input|waiting) cand=1 ;;
      working) [ -n "$prom" ] && cand=1 ;;
    esac
    [ "$cand" = 1 ] || continue
    h=$(t capture-pane -p -t "$p" 2>/dev/null | cksum)
    ph=$(t show -pqv -t "$p" @claude_pane_scrhash 2>/dev/null)
    pfresh=0; [ "$h" != "$ph" ] && pfresh=1
    [ "$pfresh" = 1 ] && t set -p -t "$p" @claude_pane_scrhash "$h" 2>/dev/null
    phot=$(t show -pqv -t "$p" @claude_pane_hot 2>/dev/null)
    case "$st" in
      need_input|waiting)
        if [ "$pfresh" = 1 ] && [ "$phot" = 1 ]; then
          t set -p -t "$p" @claude_pane_promoted "$st" \; \
            set -p -t "$p" @claude_pane_status working \; \
            set -p -t "$p" @claude_pane_status_since "$now" \; \
            set -pu -t "$p" @claude_pane_hot 2>/dev/null
          changed=1
        elif [ "$pfresh" = 1 ]; then
          [ "$phot" = 1 ] || t set -p -t "$p" @claude_pane_hot 1 2>/dev/null
        elif [ "$phot" = 1 ]; then
          t set -pu -t "$p" @claude_pane_hot 2>/dev/null
        fi ;;
      working)
        # Promoted pane: roll back to its origin once content goes stable.
        if [ "$pfresh" = 0 ]; then
          t set -p -t "$p" @claude_pane_status "$prom" \; \
            set -p -t "$p" @claude_pane_status_since "$now" \; \
            set -pu -t "$p" @claude_pane_promoted \; \
            set -pu -t "$p" @claude_pane_hot 2>/dev/null
          changed=1
        fi ;;
    esac
  done <<EOF
$live_panes
EOF

  # 3) recompute window aggregates + per-window counters, need_input durations
  #    and waiting-age buckets. Each window's pane statuses are re-read fresh
  #    here (not from the top-of-sweep snapshot) so a hook event that raced
  #    this sweep — or our own promotion/rollback above — is reflected and we
  #    never clobber a freshly hook-set aggregate.
  wins=$(t list-windows -a -F '#{window_id}|#{@claude_win_status}|#{@claude_win_wait}|#{@claude_win_age}' 2>/dev/null)
  n_need=0; n_err=0; n_work=0; n_wait=0
  while IFS='|' read -r win oldagg wait age; do
    [ -n "$win" ] || continue
    ppanes=$(t list-panes -t "$win" -F '#{@claude_pane_status}|#{@claude_pane_status_since}' 2>/dev/null)
    agg=""
    while IFS='|' read -r st since; do
      case "$st" in
        need_input) agg=need_input; break ;;
        error)      agg=error ;;
        working)    [ "$agg" != "error" ] && agg=working ;;
        waiting)    [ -z "$agg" ] && agg=waiting ;;
      esac
    done <<EOF2
$ppanes
EOF2
    if [ "$agg" != "$oldagg" ]; then
      if [ -n "$agg" ]; then
        t set -w -t "$win" @claude_win_status "$agg" 2>/dev/null
      else
        t set -wu -t "$win" @claude_win_status 2>/dev/null
      fi
      changed=1
    fi

    case "$agg" in
      need_input)
        n_need=$((n_need+1))
        min_since=""
        while IFS='|' read -r st since; do
          [ "$st" = "need_input" ] && [ -n "$since" ] || continue
          if [ -z "$min_since" ] || [ "$since" -lt "$min_since" ]; then min_since=$since; fi
        done <<EOF2
$ppanes
EOF2
        if [ -n "$min_since" ]; then
          txt=$(fmt_dur $((now - min_since)))
          [ "$txt" != "$wait" ] && { t set -w -t "$win" @claude_win_wait "$txt" 2>/dev/null; changed=1; }
        fi ;;
      error)   n_err=$((n_err+1)) ;;
      working) n_work=$((n_work+1)) ;;
      waiting)
        n_wait=$((n_wait+1))
        # Aging bucket: how long has this window been waiting unattended?
        min_since=""
        while IFS='|' read -r st since; do
          [ "$st" = "waiting" ] && [ -n "$since" ] || continue
          if [ -z "$min_since" ] || [ "$since" -lt "$min_since" ]; then min_since=$since; fi
        done <<EOF2
$ppanes
EOF2
        bucket=""
        if [ -n "$min_since" ]; then
          w_age=$((now - min_since))
          if [ "$w_age" -ge "$stale_secs" ]; then bucket=2
          elif [ "$w_age" -ge "$old_secs" ]; then bucket=1; fi
        fi
        if [ "$bucket" != "$age" ]; then
          if [ -n "$bucket" ]; then
            t set -w -t "$win" @claude_win_age "$bucket" 2>/dev/null
          else
            t set -wu -t "$win" @claude_win_age 2>/dev/null
          fi
          changed=1
        fi ;;
    esac
    if [ "$agg" != "need_input" ] && [ -n "$wait" ]; then
      t set -wu -t "$win" @claude_win_wait 2>/dev/null; changed=1
    fi
    if [ "$agg" != "waiting" ] && [ -n "$age" ]; then
      t set -wu -t "$win" @claude_win_age 2>/dev/null; changed=1
    fi
  done <<EOF
$wins
EOF

  # 4) global summary (zeros omitted, actionability order)
  summary=""
  [ "$n_need" -gt 0 ] && summary="${summary}${icon_need}${n_need} "
  [ "$n_err"  -gt 0 ] && summary="${summary}#[fg=${err_color}]${icon_err}${n_err}#[fg=${text_fg}] "
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

  # 5) mode for the main loop
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

# ---- main loop ----
while :; do
  sweep
  case $mode in
    none)
      cleanup; exit 0 ;;
    working)
      # ~5 s of fast ticks (animation), then re-sweep
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
