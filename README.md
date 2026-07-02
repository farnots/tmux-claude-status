# tmux-hook · claude-status

Affiche le statut des sessions [Claude Code](https://claude.com/claude-code)
dans tmux : sur chaque fenêtre (barre de statut, sélecteur `choose-tree`),
un badge indique si Claude travaille, attend une décision, attend un prompt
ou s'est arrêté sur une erreur — plus un résumé global et un raccourci pour
sauter vers la session qui attend.

| Statut | Badge (défaut) | Signification |
|---|---|---|
| working | `✻` animé, orange | Claude traite un prompt / exécute des tools |
| need input | `? 3m` orange gras | Claude attend une permission — avec la durée d'attente |
| waiting | `●` orange | Tour terminé, Claude attend un prompt |
| error | `✗` rouge | Claude s'est arrêté sur une erreur (StopFailure) |

Fenêtre sans session Claude → aucun badge.

## Fonctionnement

**Hooks Claude Code** (`settings.json`) → `scripts/claude-status-hook.sh` à
chaque événement. Le script pose des user options tmux :

- `@claude_pane_status` (pane) — statut du pane
- `@claude_pane_status_since` (pane) — epoch du dernier changement
- `@claude_pane_pid` (pane) — PID du process claude (pour la liveness)
- `@claude_win_status` (window) — agrégat, priorité
  `need_input` > `error` > `working` > `waiting`

**Démon compagnon** (`scripts/claude-status-daemon.sh`) — démarré à la
demande par le hook, **fils du serveur tmux** (spawné via `run-shell -b`,
meurt avec lui), single-instance (mkdir-lock), s'éteint quand plus aucune
session Claude. Il gère tout ce qui demande du temps ou du calcul :

- **animation** : `@claude_spinner_frame` avance à ~2,5 fps quand ≥1 fenêtre
  working ET ≥1 client attaché
- **liveness** : un `ps` batché par sweep (~5 s) vérifie que chaque
  `@claude_pane_pid` est vivant **et** sur le tty de son pane (imparable
  contre les kill -9 et la réutilisation de PID) ; sinon efface le statut
- **durées** : `@claude_win_wait` (« 3m ») pour les fenêtres need_input
- **résumé global** : `@claude_status_summary` (« ?1 ✗1 ✱3 ●2 »),
  compte par fenêtre, zéros omis

**Badges** composés par `claude-status.tmux`, à référencer via `#{E:...}` :
`@claude_badge_win`, `@claude_badge_pane`, `@claude_badge_summary`.

## Installation

### 1. Charger le plugin dans `~/.tmux.conf`

```tmux
# idéalement APRÈS catppuccin (hérite de @thm_red pour la couleur d'erreur)
run-shell ~/Developer/perso/tmux-hook/claude-status.tmux
```

### 2. Brancher les hooks Claude Code

Fusionner les blocs de [`examples/claude-settings-hooks.json`](examples/claude-settings-hooks.json)
dans la section `hooks` de `~/.claude/settings.json` (à la fin de chaque
tableau d'événement, sans toucher aux hooks existants — les hooks d'un même
événement tournent en parallèle).

⚠️ Les sessions Claude déjà ouvertes ne prennent les hooks en compte
qu'après relance.

### 3. Afficher les badges où vous voulez

```tmux
# Barre de fenêtres (exemple avec catppuccin) :
set -g @catppuccin_window_text "#{E:@claude_badge_win}<votre format existant>"
set -g @catppuccin_window_current_text "#{E:@claude_badge_win}<votre format existant>"

# window-status-format vanilla :
set -g window-status-format " #I: #{E:@claude_badge_win}#W "

# Résumé global en tête de status-right :
set -g status-right "#{E:@claude_badge_summary}<votre status-right existant>"

# choose-tree (prefix+w) — branche window et branche pane :
bind w choose-tree -Zw -F "#{?pane_format,#{E:@claude_badge_pane}...,#{?window_format,#{E:@claude_badge_win}...,...}}"
```

## Personnalisation

À définir **avant** le `run-shell` du plugin :

```tmux
set -g @claude_status_color "#D97757"        # orange Claude par défaut
set -g @claude_status_error_color "red"      # défaut : @thm_red catppuccin, sinon red ANSI
set -g @claude_status_icon_working "✱"       # fallback statique quand pas d'animation
set -g @claude_status_icon_need_input "?"
set -g @claude_status_icon_waiting "●"
set -g @claude_status_icon_error "✗"
set -g @claude_spinner_frames "✻ ✳ ✶ ✱"     # frames de l'animation, séparées par espaces
set -g @claude_status_jump_key "C"           # prefix+C → prochaine fenêtre need_input
                                             # (puis error) en cycling ; vide = pas de binding
```

## Limitations connues

- Un `choose-tree` déjà ouvert ne se rafraîchit pas (ni animation ni
  changements de statut) ; il est à jour à chaque ouverture.
- L'animation est coupée quand aucun client n'est attaché (rien à animer).
- Après un `kill -9` de claude, le badge disparaît au prochain sweep du
  démon (≤ ~5 s), pas instantanément.
- La durée `? 3m` est rafraîchie au rythme du sweep (~5 s).

## Prérequis

- tmux ≥ 3.4 (user options pane-scope, hooks `pane-exited`/`after-kill-pane`)
- Claude Code avec support des hooks
- Aucune dépendance (POSIX sh, sed, awk, ps)
