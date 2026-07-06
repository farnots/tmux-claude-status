# claude-status-lib.sh — shared helpers for the hook and the daemon.
# Sourced, never executed. POSIX sh only.
#
# Subagent permission tracking. A "set" is a space-separated list of
# "agent_id:epoch" tokens: the subagents currently blocked on a permission
# prompt. epoch is when the prompt was last (re)raised, used for staleness.

# subq_add SET AGENT NOW → echo the set with AGENT present (deduped, epoch
# refreshed). A subagent asking twice stays a single entry.
subq_add() {
  _set=$1; _agent=$2; _now=$3; _out=""
  for _t in $_set; do
    [ "${_t%%:*}" = "$_agent" ] && continue
    _out="$_out $_t"
  done
  printf '%s' "${_out# } ${_agent}:${_now}" | sed 's/^ *//'
}

# subq_del SET AGENT → echo the set without AGENT.
subq_del() {
  _set=$1; _agent=$2; _out=""
  for _t in $_set; do
    [ "${_t%%:*}" = "$_agent" ] && continue
    _out="$_out $_t"
  done
  printf '%s' "${_out# }"
}

# subq_expire SET NOW TTL → echo the set without tokens older than TTL seconds
# (backstop for a decrement event that never arrived).
subq_expire() {
  _set=$1; _now=$2; _ttl=$3; _out=""
  for _t in $_set; do
    _e=${_t##*:}
    [ -n "$_e" ] && [ $((_now - _e)) -ge "$_ttl" ] 2>/dev/null && continue
    _out="$_out $_t"
  done
  printf '%s' "${_out# }"
}

# subq_count SET → echo the number of tokens.
subq_count() {
  # shellcheck disable=SC2086
  set -- $1; echo $#
}

# subq_disp COUNT → echo the badge suffix:
#   0 → "" | 1 → "?" | 2..9 → "?" + superscript digit | ≥10 → "?" + digits
subq_disp() {
  _n=$1
  [ "$_n" -gt 0 ] 2>/dev/null || { printf ''; return; }
  [ "$_n" = 1 ] && { printf '?'; return; }
  _sup=""
  for _d in $(printf '%s' "$_n" | fold -w1); do
    case "$_d" in
      0) _sup="${_sup}⁰" ;; 1) _sup="${_sup}¹" ;; 2) _sup="${_sup}²" ;;
      3) _sup="${_sup}³" ;; 4) _sup="${_sup}⁴" ;; 5) _sup="${_sup}⁵" ;;
      6) _sup="${_sup}⁶" ;; 7) _sup="${_sup}⁷" ;; 8) _sup="${_sup}⁸" ;;
      9) _sup="${_sup}⁹" ;; *) _sup="${_sup}${_d}" ;;
    esac
  done
  printf '?%s' "$_sup"
}
