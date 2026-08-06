#!/bin/bash
# tabtint installer.  ./install.sh   |   ./install.sh --uninstall
#
# Merges into ~/.claude/settings.json rather than replacing it, and backs the
# file up first. Existing hooks are preserved. Re-running is safe: any previous
# tabtint entries are removed before the new ones are added.

set -uo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
HOOKS="$HOME/.claude/hooks"
CMDS="$HOME/.claude/commands"
BIN="$HOME/.local/bin"
SETTINGS="$HOME/.claude/settings.json"
PALETTE="$HOME/.claude/tabtint-palette.conf"
STATE="$HOME/.claude/state/tabtint"

die() { printf 'error: %s\n' "$1" >&2; exit 1; }

command -v jq >/dev/null 2>&1 || die "jq is required (brew install jq)"
[ -d "$HOME/.claude" ] || die "~/.claude not found, is Claude Code installed?"

# ------------------------------------------------------------- uninstall ---
if [ "${1:-}" = "--uninstall" ]; then
  if [ -f "$SETTINGS" ]; then
    cp "$SETTINGS" "$SETTINGS.bak-tabtint-uninstall"
    tmp=$(mktemp)
    jq '
      def ours: [.hooks[]?.command // ""] | map(test("tabtint\\.sh|prompt-hook\\.sh")) | any;
      .hooks.Stop             = ((.hooks.Stop             // []) | map(select(ours | not)))
      | .hooks.UserPromptSubmit = ((.hooks.UserPromptSubmit // []) | map(select(ours | not)))
      | .hooks.SessionStart     = ((.hooks.SessionStart     // []) | map(select(ours | not)))
    ' "$SETTINGS" >"$tmp" && mv "$tmp" "$SETTINGS" && echo "removed hooks from settings.json"
  fi
  # Restore every window we ever touched before deleting the state that says how.
  [ -x "$HOOKS/tabtint.sh" ] && TABTINT_IDLE_PCT=0 "$HOOKS/tabtint.sh" tab idle off >/dev/null 2>&1
  rm -f "$HOOKS/tabtint.sh" "$HOOKS/prompt-hook.sh" "$CMDS/tabtint.md" "$BIN/tabtint"
  rm -rf "$STATE"
  echo "uninstalled. your palette at $PALETTE was left in place."
  exit 0
fi

# --------------------------------------------------------------- install ---
case "$(uname -s)" in
  Darwin) ;;
  *) die "macOS only: tabtint drives Terminal.app through AppleScript" ;;
esac

if [ "${TERM_PROGRAM:-}" != "Apple_Terminal" ]; then
  printf 'warning: TERM_PROGRAM is "%s", not Apple_Terminal.\n' "${TERM_PROGRAM:-unset}"
  printf '         The window coloring is Terminal.app only and will no-op elsewhere.\n'
  printf '         The zero-turn ,project command still works in any terminal.\n\n'
fi

mkdir -p "$HOOKS" "$CMDS" "$BIN" "$STATE"

install -m 0755 "$SRC/tabtint.sh"     "$HOOKS/tabtint.sh"
install -m 0755 "$SRC/prompt-hook.sh" "$HOOKS/prompt-hook.sh"
install -m 0755 "$SRC/tabtint"        "$BIN/tabtint"

if [ -f "$PALETTE" ]; then
  echo "keeping your existing palette at $PALETTE"
else
  install -m 0644 "$SRC/palette.conf" "$PALETTE"
  echo "installed starter palette at $PALETTE"
fi

sed "s#__HOME__#$HOME#g" "$SRC/commands/tabtint.md" >"$CMDS/tabtint.md"
chmod 0644 "$CMDS/tabtint.md"

[ -f "$SETTINGS" ] || echo '{}' >"$SETTINGS"
cp "$SETTINGS" "$SETTINGS.bak-tabtint"

tmp=$(mktemp)
jq --arg tint "$HOOKS/tabtint.sh" --arg gate "$HOOKS/prompt-hook.sh" '
  def ours: [.hooks[]?.command // ""] | map(test("tabtint\\.sh|prompt-hook\\.sh")) | any;
  def clean(k): ((.hooks[k] // []) | map(select(ours | not)));

  .hooks.Stop = clean("Stop") + [{
    matcher: "", hooks: [{type:"command", command:($tint+" set"), timeout:25, async:true}]
  }]
  # The gate must run FIRST and must be synchronous: an async hook returns too
  # late to stop the prompt reaching the model.
  | .hooks.UserPromptSubmit = [{
      matcher: "", hooks: [{type:"command", command:$gate, timeout:10}]
    }] + clean("UserPromptSubmit") + [{
      matcher: "", hooks: [{type:"command", command:($tint+" clear"), timeout:25, async:true}]
    }]
  | .hooks.SessionStart = clean("SessionStart") + [{
      matcher: "", hooks: [{type:"command", command:($tint+" rest"), timeout:25, async:true}]
    }]
' "$SETTINGS" >"$tmp" || die "failed to update settings.json (original untouched)"

jq -e . "$tmp" >/dev/null 2>&1 || die "produced invalid JSON, aborting (original untouched)"
mv "$tmp" "$SETTINGS"

echo
echo "installed."
echo "  hooks    $HOOKS/tabtint.sh, $HOOKS/prompt-hook.sh"
echo "  command  $BIN/tabtint"
echo "  palette  $PALETTE"
echo "  backup   $SETTINGS.bak-tabtint"
echo
case ":$PATH:" in
  *":$BIN:"*) ;;
  *) echo "note: $BIN is not on your PATH, add it to use the tabtint command directly"; echo ;;
esac
echo "next:  open a Claude Code session and type   ,list"
