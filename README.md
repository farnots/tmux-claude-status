# tmux-hook · claude-status

Affiche le statut des sessions [Claude Code](https://claude.com/claude-code)
dans tmux : sur chaque fenêtre (barre de statut, sélecteur `choose-tree`),
un badge indique si Claude travaille, attend une décision ou attend un prompt.

| Statut | Badge (défaut) | Signification |
|---|---|---|
| working | `✱` orange gras | Claude traite un prompt / exécute des tools |
| need input | `?` orange gras | Claude attend une permission ou une réponse |
| waiting | `●` orange gras | Tour terminé, Claude attend un prompt |

Fenêtre sans session Claude → aucun badge.

## Fonctionnement

Les hooks Claude Code (`settings.json`) appellent `scripts/claude-status-hook.sh`
à chaque événement (prompt soumis, tool use, permission, fin de tour…). Le
script pose deux user options tmux :

- `@claude_pane_status` (pane-scope) — statut du pane
- `@claude_win_status` (window-scope) — agrégat des panes de la fenêtre,
  priorité `need_input` > `working` > `waiting`

Le plugin (`claude-status.tmux`) compose deux badges prêts à l'emploi,
`@claude_badge_win` et `@claude_badge_pane`, à référencer via `#{E:...}`
dans n'importe quel format tmux. Un hook tmux `pane-exited` recalcule
l'agrégat quand un pane meurt.

## Installation

### 1. Charger le plugin dans `~/.tmux.conf`

```tmux
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

# choose-tree (prefix+w) — branche window et branche pane :
bind w choose-tree -Zw -F "#{?pane_format,#{E:@claude_badge_pane}...,#{?window_format,#{E:@claude_badge_win}...,...}}"
```

## Personnalisation

À définir **avant** le `run-shell` du plugin :

```tmux
set -g @claude_status_color "#D97757"       # orange Claude par défaut
set -g @claude_status_icon_working "✱"
set -g @claude_status_icon_need_input "?"
set -g @claude_status_icon_waiting "●"
```

## Limitations connues

- `kill -9` du process claude (shell du pane survivant) : le badge reste
  périmé jusqu'au prochain lancement de Claude dans ce pane (le
  `SessionStart` le corrige).
- Un `choose-tree` déjà ouvert ne se rafraîchit pas quand un statut change ;
  il est à jour à chaque ouverture.
- La barre de statut est rafraîchie immédiatement (`refresh-client -S`)
  quand l'agrégat d'une fenêtre change.

## Prérequis

- tmux ≥ 3.4 (user options pane-scope, hook `pane-exited`)
- Claude Code avec support des hooks
- Aucune dépendance (POSIX sh, sed)
