#!/bin/bash
# █ dcj · dotcomjack.com · MIT
# Regression test: tabtint must never LAUNCH Terminal.
#
# `tell application "Terminal"` starts the app when it is not running, and an
# app started by an Apple Event inherits the sender's environment. A hook that
# fires while Terminal is closed (a background or headless Claude session, a
# login item, a restart) would start it carrying that hook's whole environment,
# and every tab opened afterwards would hand Claude Code another session's
# identity: one shared session name across all tabs, and no saved transcripts.
#
# Every Apple Event in tabtint.sh goes through osa(), so the guard lives there.
# This test proves both directions with a stub osascript, and never touches the
# real Terminal:
#   1. target app not running  -> osascript is NOT executed, osa returns non-zero
#   2. target app running      -> osascript IS executed
#   3. the same holds for the public helpers built on osa (all_ttys, tab_ctx)
#   4. no Apple Event in tabtint.sh bypasses osa()
#   5. in an unattended session (CLAUDE_CODE_SESSION_ATTENDED=0) the hook modes
#      send nothing even when the app IS running; attended and unset behave as before
#
# Usage: ./test/never-launch.sh

set -uo pipefail

SRC="$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)/tabtint.sh"
[ -r "$SRC" ] || { echo "cannot find tabtint.sh next to test/" >&2; exit 1; }

WORK=$(mktemp -d) || exit 1
trap 'kill "$STANDIN" 2>/dev/null; rm -rf "$WORK"' EXIT

# Everything above the mode dispatch, so sourcing defines the functions and
# runs nothing.
sed -n '1,/^# ---------------* modes ---$/p' "$SRC" >"$WORK/funcs.sh"
grep -q '^osa()' "$WORK/funcs.sh" || {
  echo "could not extract osa from tabtint.sh (did the modes banner change?)" >&2
  exit 1
}

# A stub osascript that only records that it ran.
mkdir -p "$WORK/bin"
cat >"$WORK/bin/osascript" <<STUB
#!/bin/bash
echo ran >>"$WORK/calls"
echo stub-output
STUB
chmod +x "$WORK/bin/osascript"

# A live process with a name of our own stands in for "the app is running".
# It is a symlink to sleep, so pgrep -x sees the stand-in name.
ln -s "$(command -v sleep)" "$WORK/bin/tabtint-standin"
"$WORK/bin/tabtint-standin" 60 &
STANDIN=$!

pass=0; fail=0
ok() { pass=$((pass + 1)); echo "ok    $1"; }
no() { fail=$((fail + 1)); echo "FAIL  $1"; }
calls() { [ -f "$WORK/calls" ] && wc -l <"$WORK/calls" | tr -d ' ' || echo 0; }

run() { # run <process name to treat as Terminal> <function> [args]
  local proc="$1"; shift
  (
    export PATH="$WORK/bin:$PATH" HOME="$WORK" TABTINT_TERMINAL_PROC="$proc"
    # shellcheck source=/dev/null
    source "$WORK/funcs.sh" 2>/dev/null
    "$@" </dev/null
  )
}

# 1. not running: nothing is sent
: >"$WORK/calls"
out=$(run tabtint-no-such-app osa -e 'return 1'); rc=$?
[ "$(calls)" = 0 ] && ok "app not running: osascript not executed" || no "app not running: osascript WAS executed ($(calls) times)"
[ "$rc" -ne 0 ] && ok "app not running: osa returns non-zero" || no "app not running: osa returned 0"
[ -z "$out" ] && ok "app not running: no output" || no "app not running: got output '$out'"

# 2. running: the event goes through
: >"$WORK/calls"
out=$(run tabtint-standin osa -e 'return 1')
[ "$(calls)" = 1 ] && ok "app running: osascript executed once" || no "app running: osascript ran $(calls) times, want 1"
[ "$out" = stub-output ] && ok "app running: output passed through" || no "app running: got '$out'"

# 3. the helpers built on osa obey the same rule
for fn in all_ttys focused_tty "tab_ctx /dev/ttys999" "write_title /dev/ttys999 x"; do
  : >"$WORK/calls"
  # shellcheck disable=SC2086
  run tabtint-no-such-app $fn >/dev/null
  [ "$(calls)" = 0 ] && ok "app not running: ${fn%% *} sends nothing" || no "app not running: ${fn%% *} sent an Apple Event"
done

# 5. an unattended (background or headless) session's hooks do nothing at all
for v in 0; do
  (export CLAUDE_CODE_SESSION_ATTENDED=$v; source "$WORK/funcs.sh" 2>/dev/null; unattended) && ok "ATTENDED=0 reads as unattended" || no "ATTENDED=0 did not read as unattended"
done
(export CLAUDE_CODE_SESSION_ATTENDED=1; source "$WORK/funcs.sh" 2>/dev/null; unattended) && no "ATTENDED=1 read as unattended" || ok "ATTENDED=1 is attended"
(unset CLAUDE_CODE_SESSION_ATTENDED; source "$WORK/funcs.sh" 2>/dev/null; unattended) && no "an unset marker read as unattended" || ok "an unset marker is attended (hand runs, older Claude Code)"
for mode in set clear rest; do
  : >"$WORK/calls"
  PATH="$WORK/bin:$PATH" HOME="$WORK" TABTINT_TERMINAL_PROC=tabtint-standin CLAUDE_CODE_SESSION_ATTENDED=0 bash "$SRC" "$mode" </dev/null >/dev/null 2>&1; rc=$?
  [ "$(calls)" = 0 ] && [ "$rc" = 0 ] && ok "unattended: the $mode hook sends nothing and exits 0" || no "unattended: the $mode hook sent $(calls) Apple Event(s), exit $rc"
done
hooked=$(sed -n '/^# ---------------* modes ---$/,$p' "$SRC" | grep -A1 -E '^  (set|clear \| rest)\) ' | grep -c 'unattended && exit 0')
[ "$hooked" = 2 ] && ok "both hook entry points check for an unattended session first" || no "$hooked of 2 hook entry points check for an unattended session first"

# 4. nothing reaches osascript except through osa()
direct=$(grep -n 'osascript' "$SRC" | grep -v '^[0-9]*:[[:space:]]*#' | grep -vc "exec @ARGV' osascript")
[ "$direct" = 0 ] && ok "no Apple Event bypasses osa()" || no "$direct osascript call(s) bypass osa()"

echo "passed $pass, failed $fail"
[ "$fail" = 0 ]
