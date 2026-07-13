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
#   @claude_win_subq(_disp) (window) : pending subagent permission count/suffix
# Plus: expires stale @claude_pane_subagents tokens and refreshes the pane/
# window subagent suffixes. Plus: liveness — clears the status of panes whose
# claude process is dead.
# The hook remains the authority on statuses in event-driven mode; the daemon
# only recomputes a window aggregate for panes it just cleared.

sock=$1
[ -S "$sock" ] || exit 0
t() { tmux -S "$sock" "$@"; }
. "$(cd "$(dirname "$0")" && pwd)/claude-status-lib.sh"

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
# Pending subagent permission tokens expire after this — a last-resort leak
# backstop for a session stuck mid-turn (the end-of-turn Stop already clears
# the set in the normal case). Kept long so a genuinely long-pending permission
# (user away from keyboard) is not dropped while it is still on screen.
subq_stale=$(opt @claude_status_subq_stale_secs 14400)
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
    '#{pane_id}|#{window_id}|#{pane_tty}|#{@claude_pane_status}|#{@claude_pane_pid}|#{@claude_pane_status_since}|#{@claude_pane_promoted}|#{@claude_pane_subagents}' \
    2>/dev/null) || { cleanup; exit 0; }

  # 1) liveness: a single batched ps; dead = pid gone OR different tty
  #    (the claude process keeps the pane's tty; guards against PID reuse)
  pids=""
  while IFS='|' read -r pane win tty st pid since prom subs; do
    { [ -n "$st" ] || [ -n "$subs" ]; } && [ -n "$pid" ] && pids="$pids,$pid"
  done <<EOF
$panes
EOF
  pids=${pids#,}
  alive=""
  [ -n "$pids" ] && alive=$(ps -o pid=,tt= -p "$pids" 2>/dev/null)

  dead_windows=""
  live_panes=""
  while IFS='|' read -r pane win tty st pid since prom subs; do
    [ -n "$st" ] || [ -n "$subs" ] || continue
    if [ -n "$pid" ]; then
      ptty=$(printf '%s\n' "$alive" | awk -v p="$pid" '$1==p{print $2}')
      if [ -z "$ptty" ] || [ "${tty#/dev/tty}" != "$ptty" ]; then
        t set -pu -t "$pane" @claude_pane_status \; \
          set -pu -t "$pane" @claude_pane_pid \; \
          set -pu -t "$pane" @claude_pane_status_since \; \
          set -pu -t "$pane" @claude_pane_flavor \; \
          set -pu -t "$pane" @claude_pane_promoted \; \
          set -pu -t "$pane" @claude_pane_subagents \; \
          set -pu -t "$pane" @claude_pane_subq_disp 2>/dev/null
        dead_windows="$dead_windows $win"; changed=1
        continue
      fi
    fi
    live_panes="$live_panes
$pane|$win|$st|$since|$prom|$subs"
  done <<EOF
$panes
EOF

  # 2) aggregates: only for windows we just cleared a pane from
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

  # 2b) subagent permission counters (orthogonal to the main-loop status).
  #     Expire stale tokens (missed decrement backstop), refresh each pane's
  #     rendered suffix, then sum per window. subq_total feeds the summary.
  subq_total=0
  subq_pw=""   # "window count" per live pane, for the per-window sums
  while IFS='|' read -r pane win st since prom subs; do
    [ -n "$pane" ] || continue
    new=$(subq_expire "$subs" "$now" "$subq_stale")
    if [ "$new" != "$subs" ]; then
      if [ -n "$new" ]; then
        t set -p -t "$pane" @claude_pane_subagents "$new" 2>/dev/null
      else
        t set -pu -t "$pane" @claude_pane_subagents 2>/dev/null
      fi
      changed=1
    fi
    c=$(subq_count "$new")
    d=$(subq_disp "$c")
    cur_d=$(t show -pqv -t "$pane" @claude_pane_subq_disp 2>/dev/null)
    if [ "$d" != "$cur_d" ]; then
      if [ -n "$d" ]; then
        t set -p -t "$pane" @claude_pane_subq_disp "$d" 2>/dev/null
      else
        t set -pu -t "$pane" @claude_pane_subq_disp 2>/dev/null
      fi
      changed=1
    fi
    subq_pw="$subq_pw
$win $c"
  done <<EOF
$live_panes
EOF
  # Per-window sums; set/unset @claude_win_subq(_disp) over ALL windows so a
  # window that dropped to zero is cleared.
  sums=$(printf '%s\n' "$subq_pw" | awk 'NF==2{a[$1]+=$2} END{for(w in a) print w, a[w]}')
  for wl in $(t list-windows -a -F '#{window_id}|#{@claude_win_subq}' 2>/dev/null); do
    win=${wl%%|*}; had=${wl#*|}
    wsum=$(printf '%s\n' "$sums" | awk -v w="$win" '$1==w{print $2}')
    [ -n "$wsum" ] || wsum=0
    subq_total=$((subq_total + wsum))
    if [ "$wsum" -gt 0 ]; then
      [ "$had" != "$wsum" ] && { t set -w -t "$win" @claude_win_subq "$wsum" \; \
        set -w -t "$win" @claude_win_subq_disp "$(subq_disp "$wsum")" 2>/dev/null; changed=1; }
    elif [ -n "$had" ]; then
      t set -wu -t "$win" @claude_win_subq \; \
        set -wu -t "$win" @claude_win_subq_disp 2>/dev/null; changed=1
    fi
  done

  # 3) per window: counters (window granularity), need_input durations, and
  #    activity-based correction. Hooks can't see everything: answering a
  #    question or a background agent running after end-of-turn emit no
  #    event. But a working Claude redraws its spinner continuously, which
  #    tmux tracks as window activity. So:
  #    - need_input/waiting + fresh output on 2 consecutive sweeps → promote
  #      to working (origin saved in @claude_pane_promoted)
  #    - daemon-promoted working + output gone stale → roll back to origin
  #    Real hook events always clear @claude_pane_promoted (authority).
  wins=$(t list-windows -a -F '#{window_id}|#{@claude_win_status}|#{@claude_win_wait}|#{window_activity}|#{@claude_win_hot}|#{@claude_win_age}' 2>/dev/null)
  n_need=0; n_err=0; n_work=0; n_wait=0
  while IFS='|' read -r win agg wait activity hot age; do
    fresh=0
    [ -n "$activity" ] && [ $((now - activity)) -le 2 ] && fresh=1

    if [ "$agg" = "need_input" ] || [ "$agg" = "waiting" ]; then
      if [ "$fresh" = 1 ] && [ "$hot" = 1 ]; then
        # Sustained redraw: Claude is actually working. Promote.
        while IFS='|' read -r p w st since prom subs; do
          [ "$w" = "$win" ] || continue
          case "$st" in
            need_input|waiting)
              t set -p -t "$p" @claude_pane_promoted "$st" \; \
                set -p -t "$p" @claude_pane_status working \; \
                set -p -t "$p" @claude_pane_status_since "$now" 2>/dev/null ;;
          esac
        done <<EOF2
$live_panes
EOF2
        t set -w -t "$win" @claude_win_status working \; \
          set -wu -t "$win" @claude_win_hot 2>/dev/null
        [ -n "$wait" ] && t set -wu -t "$win" @claude_win_wait 2>/dev/null
        agg=working; changed=1
      elif [ "$fresh" = 1 ]; then
        t set -w -t "$win" @claude_win_hot 1 2>/dev/null
      elif [ "$hot" = 1 ]; then
        t set -wu -t "$win" @claude_win_hot 2>/dev/null
      fi
    elif [ "$agg" = "working" ] && [ "$fresh" = 0 ] && \
         [ -n "$activity" ] && [ $((now - activity)) -gt 8 ]; then
      # Output went quiet: roll back panes WE promoted (never hook-set ones).
      rolled=""
      while IFS='|' read -r p w st since prom subs; do
        [ "$w" = "$win" ] && [ "$st" = "working" ] && [ -n "$prom" ] || continue
        t set -p -t "$p" @claude_pane_status "$prom" \; \
          set -p -t "$p" @claude_pane_status_since "$now" \; \
          set -pu -t "$p" @claude_pane_promoted 2>/dev/null
        case "$prom" in
          need_input) rolled=need_input ;;
          waiting)    [ "$rolled" != "need_input" ] && rolled=waiting ;;
        esac
      done <<EOF2
$live_panes
EOF2
      if [ -n "$rolled" ]; then
        t set -w -t "$win" @claude_win_status "$rolled" 2>/dev/null
        agg=$rolled; changed=1
      fi
    fi
    # Stale hot marker (window switched to working/error via hooks meanwhile)
    if [ "$hot" = 1 ] && { [ "$agg" = "working" ] || [ "$agg" = "error" ]; }; then
      t set -wu -t "$win" @claude_win_hot 2>/dev/null
    fi

    case "$agg" in
      need_input)
        n_need=$((n_need+1))
        min_since=""
        while IFS='|' read -r p w st since prom subs; do
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
      waiting)
        n_wait=$((n_wait+1))
        # Aging bucket: how long has this window been waiting unattended?
        min_since=""
        while IFS='|' read -r p w st since prom subs; do
          [ "$w" = "$win" ] && [ "$st" = "waiting" ] && [ -n "$since" ] || continue
          if [ -z "$min_since" ] || [ "$since" -lt "$min_since" ]; then min_since=$since; fi
        done <<EOF2
$live_panes
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

  # 4) global summary (zeros omitted, actionability order). The "?" count
  #    folds main-thread need_input windows and pending subagent permissions.
  n_need=$((n_need + subq_total))
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

  # 5) mode for the main loop (n_need already includes subq_total)
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
