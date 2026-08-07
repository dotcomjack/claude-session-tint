#!/bin/bash
# Regression tests for strip_mark, the tab-bar marker parser.
#
# This one function has now been wrong twice, both times in a way that only
# shows up on someone else's machine:
#
#   1. An unanchored `${1##*"$WJ" }` truncated any title containing a WJ-space.
#   2. The `${#pre} -le 8` guard that replaced it counted CHARACTERS under a
#      UTF-8 locale but BYTES under C/POSIX. Hooks routinely inherit an unset
#      locale, so any TABTINT_MARK over 8 bytes stopped stripping, and the
#      watcher's re-assert then grew the tab title without bound.
#
# So run the matrix, not just the happy path: every case under three locales
# and two marks. Usage: ./test/strip-mark.sh

set -uo pipefail

SRC="$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)/tabtint.sh"
[ -r "$SRC" ] || { echo "cannot find tabtint.sh next to test/" >&2; exit 1; }

WORK=$(mktemp -d) || exit 1
trap 'rm -rf "$WORK"' EXIT

# Everything above the mode dispatch, so sourcing defines the functions and
# runs nothing.
sed -n '1,/^# ---------------* modes ---$/p' "$SRC" >"$WORK/funcs.sh"
grep -q '^strip_mark()' "$WORK/funcs.sh" || {
  echo "could not extract strip_mark from tabtint.sh (did the modes banner change?)" >&2
  exit 1
}

cat >"$WORK/matrix.sh" <<'MATRIX'
set -uo pipefail
# shellcheck source=/dev/null
source "$WORK/funcs.sh" 2>/dev/null

pass=0; fail=0
chk() {
  local got; got=$(strip_mark "$3")
  if [ "$got" = "$2" ]; then pass=$((pass+1))
  else fail=$((fail+1)); printf '    FAIL %-32s got [%s] want [%s]\n' "$1" "$got" "$2"; fi
}

ZWJ=$(printf '\xf0\x9f\x91\xa8\xe2\x80\x8d\xf0\x9f\x91\xa9\xe2\x80\x8d\xf0\x9f\x91\xa7\xe2\x80\x8d\xf0\x9f\x91\xa6') # 25 bytes
FLAG=$(printf '\xf0\x9f\x87\xba\xf0\x9f\x87\xb8')                                                                    # 8 bytes

chk "our marker is stripped"      "api"        "$MARK$WJ api"
chk "unmarked title untouched"    "api"        "api"
chk "title keeps its spaces"      "my api tab" "$MARK$WJ my api tab"
chk "empty stays empty"           ""           ""
chk "lone marker leaves nothing"  ""           "$MARK$WJ "

# A WORD JOINER the user put there is not ours and must survive. This is what
# the unanchored match shipped broken.
chk "user WJ title not truncated" "my⁠ title"  "my⁠ title"

# Marks over 8 bytes. These are what broke under a C locale.
chk "25-byte ZWJ mark stripped"   "api"        "$ZWJ$WJ api"
chk "8-byte flag mark stripped"   "api"        "$FLAG$WJ api"
chk "9-byte triple mark stripped" "api"        "●●●$WJ api"

# The actual failure mode: mark_set strips then prepends on every watcher poll,
# so a strip that silently does nothing grows the title forever.
t="$ZWJ$WJ api"
before=$(printf '%s' "$t" | wc -c | tr -d ' ')
for i in 1 2 3 4 5 6 7 8; do t="$ZWJ$WJ $(strip_mark "$t")"; done
after=$(printf '%s' "$t" | wc -c | tr -d ' ')
if [ "$before" = "$after" ]; then pass=$((pass+1))
else fail=$((fail+1)); printf '    FAIL %-32s title grew %s -> %s bytes\n' "re-assert is idempotent" "$before" "$after"; fi

printf '  %-30s %2d passed, %d failed\n' "$LABEL" "$pass" "$fail"
[ "$fail" -eq 0 ]
MATRIX

rc=0
export WORK
for loc in en_US.UTF-8 C; do
  for m in "●" "🔴"; do
    LANG=$loc LC_ALL=$loc TABTINT_MARK=$m LABEL="locale=$loc mark=$m" \
      bash "$WORK/matrix.sh" || rc=1
  done
done
# The case that actually bit: no locale at all, which is what a hook inherits.
env -u LANG -u LC_ALL -u LC_CTYPE WORK="$WORK" LABEL="locale=unset mark=default" \
  bash "$WORK/matrix.sh" || rc=1

if [ "$rc" -eq 0 ]; then echo "all green"; else echo "FAILURES"; fi
exit "$rc"
