#!/bin/bash
# tabtint.sh  (drive it with the `tabtint` command)
#
# Purely cosmetic Terminal.app window coloring:
#   1. You tag a window with a project once    ->  tabtint api
#   2. It wears that color quietly at rest     ->  22% wash
#   3. It lights up when a response lands      ->  48% wash
#   4. It drops back the moment you focus it
#
# Terminal.app cannot color a TAB. Verified by enumerating every property on the
# tab class: the only color properties (background, normal text, bold text,
# cursor, selected text) all paint the content area, never the tab chrome. Real
# per-tab color is an iTerm2 / kitty / Ghostty capability.
#
# So this paints the window BODY, which is what shows in Mission Control and
# cmd-tab. That works when a window holds ONE tab.
#
# In a MULTI-TAB window Terminal draws only the selected tab's body, so painting
# a background tab is invisible exactly when you need it, and selecting the tab
# clears it before you see it. There the signal moves to the one thing that does
# reach the tab bar: a dot in front of the tab TITLE, stripped again the moment
# you look. See the marker section below.
#
# Colors live in ~/.claude/tabtint-palette.conf. Nothing here inspects your work,
# your files, or your transcripts. A window is whatever you said it was.
#
# Hook modes (wired in ~/.claude/settings.json):
#   set    light up this window        (Stop)
#   clear  drop back to rest           (UserPromptSubmit)
#   rest   apply resting state         (SessionStart)
#   watch  internal shared watcher
#
# Tuning:
#   TABTINT_ATTN_PCT  brightness when unread  (default 48)
#   TABTINT_IDLE_PCT  brightness at rest      (default 22)
#   TABTINT_MARK      tab-bar marker glyph    (default ●)

set -uo pipefail

STATE_DIR="$HOME/.claude/state/tabtint"

# Your palette lives in ~/.claude so it survives plugin updates, which replace
# the plugin directory wholesale. Fall back to the palette bundled next to this
# script so a fresh plugin install works with no setup step.
BRANDS_FILE="$HOME/.claude/tabtint-palette.conf"
if [ ! -r "$BRANDS_FILE" ]; then
  BRANDS_FILE="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/palette.conf"
fi
LOCK_DIR="$STATE_DIR/.watcher.lock"
IDLE_FLAG="$STATE_DIR/.idle-enabled"

ATTN_PCT="${TABTINT_ATTN_PCT:-48}"
IDLE_PCT="${TABTINT_IDLE_PCT:-22}"

# These two reach $(( )), and bash recursively evaluates a variable's CONTENT as
# an arithmetic expression, which will run a command substitution hidden in an
# array subscript. They come from the environment, so validate them as plain
# integers and fall back to the defaults rather than trusting them.
case $ATTN_PCT in ''|*[!0-9]*) ATTN_PCT=48 ;; esac
case $IDLE_PCT in ''|*[!0-9]*) IDLE_PCT=22 ;; esac
DEFAULT_HEX="#6E6E6E" # untagged windows still light up, just colorless and dimmer
                      # than any tagged brand (must not equal a palette entry)

POLL_SECONDS=1
MAX_WATCH_SECONDS=21600 # 6h, so a watcher can never outlive the day

mkdir -p "$STATE_DIR"

# ---------------------------------------------------------------- helpers ---

# Hard wall clock cap, so a hung Apple Event (a TCC dialog waiting on a click,
# say) can never wedge a hook.
osa() { perl -e 'alarm 15; exec @ARGV' osascript "$@" 2>/dev/null; }

# "#A3D8E1" plus a percentage to the 16-bit triple AppleScript wants. Pure bash
# arithmetic, no subprocess, because this runs on every Stop.
scale16() {
  local h="${1#\#}" pct="$2" r g b
  r=$((16#${h:0:2})); g=$((16#${h:2:2})); b=$((16#${h:4:2}))
  printf '%s %s %s' "$((r * 257 * pct / 100))" "$((g * 257 * pct / 100))" "$((b * 257 * pct / 100))"
}

# Claude Code pipes stdin to hooks, so `tty` reports "not a tty". Walk up the
# process tree to the login shell to find the real terminal device.
session_tty() {
  local pid=$$ t ppid
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    t=$(ps -o tty= -p "$pid" 2>/dev/null | tr -d ' ')
    case "$t" in ttys*) printf '%s' "$t"; return 0 ;; esac
    ppid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -z "$ppid" ] && break
    [ "$ppid" -le 1 ] 2>/dev/null && break
    pid=$ppid
  done
  return 1
}

# The window's login process. Terminal reuses tty numbers when you close and
# open windows, so this pins a tag to one physical window, not to "ttys004".
tty_owner() { ps -t "$1" -o pid=,comm= 2>/dev/null | awk '$NF=="login"{print $1; exit}'; }
tty_alive() { [ -n "$(ps -t "$1" -o pid= 2>/dev/null)" ]; }

# Look up a brand by key or label. Accepts a case insensitive prefix.
lookup_brand() {
  awk -F'\t' -v q="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" '
    $1 !~ /^#[0-9A-Fa-f]{6}$/ { next }
    {
      k = tolower($2); l = tolower($3)
      if (k == q || l == q) { print $1 "\t" $2 "\t" $3 "\t" $4; exit }
      if (!hit && (index(k, q) == 1 || index(l, q) == 1)) hit = $1 "\t" $2 "\t" $3 "\t" $4
    }
    END { if (hit) print hit }
  ' "$BRANDS_FILE"
}

# This window's tag, or empty. Ignores a tag left behind by a closed window
# that happened to hold the same tty number.
assignment() {
  local t="$1" owner
  [ -f "$STATE_DIR/$t.brand" ] || return 1
  owner=$(tty_owner "$t")
  if [ -n "$owner" ] && [ -f "$STATE_DIR/$t.owner" ] && [ "$owner" != "$(cat "$STATE_DIR/$t.owner")" ]; then
    # Only the tag is stale. Deleting .orig here would make the NEXT
    # remember_original capture an already-painted wash as the "original",
    # which is unrecoverable without hand-editing state.
    rm -f "$STATE_DIR/$t.brand" "$STATE_DIR/$t.owner"
    return 1
  fi
  cat "$STATE_DIR/$t.brand"
}

# tty of the tab you are actually looking at, empty if Terminal is not front.
focused_tty() {
  osa <<'EOS'
tell application "Terminal"
	if not frontmost then return ""
	if (count of windows) is 0 then return ""
	try
		return tty of (selected tab of window 1)
	on error
		return ""
	end try
end tell
EOS
}

read_bg() {
  osa - "$1" <<'EOS'
on run argv
	tell application "Terminal"
		repeat with w in windows
			repeat with t in tabs of w
				if tty of t is (item 1 of argv) then
					set c to background color of t
					return ((item 1 of c) as string) & " " & ((item 2 of c) as string) & " " & ((item 3 of c) as string)
				end if
			end repeat
		end repeat
	end tell
	return ""
end run
EOS
}

write_bg() {
  osa - "$1" "$2" "$3" "$4" <<'EOS'
on run argv
	tell application "Terminal"
		repeat with w in windows
			repeat with t in tabs of w
				if tty of t is (item 1 of argv) then
					set background color of t to {(item 2 of argv) as integer, (item 3 of argv) as integer, (item 4 of argv) as integer}
					return "ok"
				end if
			end repeat
		end repeat
	end tell
	return ""
end run
EOS
}

# ------------------------------------------ tab-bar marker (shared windows) ---
# Terminal draws only the SELECTED tab's body, so painting a background tab is
# invisible exactly when it matters, and the watcher clears it the instant you
# select it. For tabs that share a window the signal moves to the one thing that
# reaches the tab bar: a dot in front of the title.
#
# U+2060 WORD JOINER is a zero-width sentinel. It renders as nothing and nothing
# else in a terminal title emits it, so we can find our own marker without ever
# storing the title. We STRIP, never restore: Claude Code owns the title and
# rewrites it, so a saved copy would be stale on arrival and would clobber a
# user's own /rename.
WJ=$(printf '\xe2\x81\xa0')
MARK="${TABTINT_MARK:-●}"

# One Apple Event answering everything the Stop hook needs:
#   ntabs <TAB> selected <TAB> focused <TAB> title
#
# `tab` inside a "tell application \"Terminal\"" block resolves to Terminal's tab
# CLASS, not the tab character, and stringifies to the literal text "tab". Bind
# the real character outside the tell block. Verified with od -c.
tab_ctx() {
  osa - "$1" <<'EOS'
on run argv
	set TB to tab
	tell application "Terminal"
		set fm to frontmost
		repeat with i from 1 to (count of windows)
			set w to item i of windows
			set n to (count of tabs of w)
			repeat with t in tabs of w
				if tty of t is (item 1 of argv) then
					set ttl to ""
					try
						set ttl to custom title of t
					end try
					return (n as string) & TB & ((selected of t) as string) & TB & ((fm and i is 1 and (selected of t)) as string) & TB & ttl
				end if
			end repeat
		end repeat
	end tell
	return ""
end run
EOS
}

write_title() {
  osa - "$1" "$2" <<'EOS'
on run argv
	tell application "Terminal"
		repeat with w in windows
			repeat with t in tabs of w
				if tty of t is (item 1 of argv) then
					set custom title of t to (item 2 of argv)
					return "ok"
				end if
			end repeat
		end repeat
	end tell
	return ""
end run
EOS
}

# Everything through the last sentinel goes. A no-op when the sentinel is absent,
# so this can never eat a title we did not write, and it collapses a doubled
# marker instead of nesting it.
strip_mark() { printf '%s' "${1##*"$WJ" }"; }

# Mark a background tab in a shared window. Takes the already-parsed context so
# the single-tab path costs no extra Apple Event. Returns 0 only when it marked,
# which is how the caller knows to skip the (invisible) paint.
mark_set() {
  local t="$1" n="$2" sel="$3" ttl="$4" stripped
  case $n in ''|*[!0-9]*) return 1 ;; esac
  [ "$n" -le 1 ] && return 1
  [ "$sel" = "true" ] && return 1
  # Flag BEFORE the title. A flag with no marker costs one wasted read; a marker
  # with no flag is invisible to every cleanup path and strands the dot.
  : >"$STATE_DIR/$t.mark" || return 1
  stripped=$(strip_mark "$ttl")
  write_title "/dev/$t" "$MARK$WJ $stripped" >/dev/null
}

# Strip only, never restore. Returns non-zero without dropping the flag when
# Terminal did not answer, so the next hook retries instead of leaving the dot
# stranded with nothing left that knows to remove it.
mark_clear() {
  local t="$1" ctx n sel foc ttl stripped
  [ -f "$STATE_DIR/$t.mark" ] || [ "${2:-}" = "force" ] || return 0
  ctx=$(tab_ctx "/dev/$t")
  [ -z "$ctx" ] && return 1
  IFS=$'\t' read -r n sel foc ttl <<<"$ctx"
  case $ttl in
    *"$WJ"*)
      stripped=$(strip_mark "$ttl")
      # Never blank a tab's name. If the title was nothing but our marker, leave
      # it rather than writing an empty custom title.
      [ -n "$stripped" ] && write_title "/dev/$t" "$stripped" >/dev/null
      ;;
  esac
  rm -f "$STATE_DIR/$t.mark"
}

# Record the window's true background once, so we can always get back to it.
remember_original() {
  local t="$1" orig
  [ -f "$STATE_DIR/$t.orig" ] && return 0
  orig=$(read_bg "/dev/$t")
  [ -z "$orig" ] && return 1
  printf '%s\n' "$orig" >"$STATE_DIR/$t.orig"
}

idle_enabled() { [ -f "$IDLE_FLAG" ]; }

# Drop a window back to rest: its idle brand wash if it is tagged and idle tint
# is on, otherwise the background it had before we ever touched it.
rest_window() {
  local t="$1" row hex color
  row=$(assignment "$t") || row=""
  if [ -n "$row" ] && idle_enabled; then
    hex=$(printf '%s' "$row" | cut -f1)
    color=$(scale16 "$hex" "$IDLE_PCT")
  else
    color=$(cat "$STATE_DIR/$t.orig" 2>/dev/null)
  fi
  [ -n "$color" ] && write_bg "/dev/$t" $color >/dev/null
  mark_clear "$t"
  rm -f "$STATE_DIR/$t.unread"
}

purge_dead() {
  shopt -s nullglob
  local f b
  for f in "$STATE_DIR"/ttys*.orig; do
    b=$(basename "$f" .orig)
    tty_alive "$b" || rm -f "$STATE_DIR/$b".*
  done
}

start_watcher() {
  if [ ! -d "$LOCK_DIR" ] || ! kill -0 "$(cat "$LOCK_DIR/pid" 2>/dev/null)" 2>/dev/null; then
    nohup "$0" watch >/dev/null 2>&1 &
    disown 2>/dev/null || true
  fi
}

all_ttys() {
  osa <<'EOS'
tell application "Terminal"
	set out to ""
	repeat with w in windows
		repeat with t in tabs of w
			set out to out & (tty of t) & linefeed
		end repeat
	end repeat
	return out
end tell
EOS
}

# ------------------------------------------------------------------ modes ---

case "${1:-set}" in

  set) # Stop hook
    t=$(session_tty) || exit 0
    remember_original "$t" || exit 0 # not a Terminal.app tab

    # One Apple Event answers both questions the Stop hook has: is the user
    # looking at this tab, and does it share a window. Replaces the separate
    # focused_tty call so the single-tab path costs no more than it did before.
    ctx=$(tab_ctx "/dev/$t")
    IFS=$'\t' read -r ntabs seltab foctab ttl <<<"$ctx"

    # Already looking at it, so nothing was missed. Do not light it up.
    if [ "$foctab" = "true" ]; then rest_window "$t"; exit 0; fi

    row=$(assignment "$t") || row=""
    hex=$(printf '%s' "$row" | cut -f1)
    [ -z "$hex" ] && hex="$DEFAULT_HEX"

    touch "$STATE_DIR/$t.unread"
    # In a shared window the wash is invisible while it matters and would flash
    # at you a beat after you click the tab, so mark the tab bar instead of it.
    mark_set "$t" "$ntabs" "$seltab" "$ttl" \
      || write_bg "/dev/$t" $(scale16 "$hex" "$ATTN_PCT") >/dev/null
    start_watcher
    ;;

  clear | rest) # UserPromptSubmit / SessionStart hooks
    t=$(session_tty) || exit 0
    remember_original "$t" || exit 0
    rest_window "$t"
    ;;

  watch)
    # Single instance. mkdir is atomic, so two Stop hooks racing cannot both win.
    # The loser re-reads the pid once before treating an empty pid file as a dead
    # lock, because there is a real gap between the winner's mkdir and its write.
    if ! mkdir "$LOCK_DIR" 2>/dev/null; then
      p=$(cat "$LOCK_DIR/pid" 2>/dev/null)
      [ -z "$p" ] && { sleep 1; p=$(cat "$LOCK_DIR/pid" 2>/dev/null); }
      [ -n "$p" ] && kill -0 "$p" 2>/dev/null && exit 0
      rm -rf "$LOCK_DIR"; mkdir "$LOCK_DIR" 2>/dev/null || exit 0
    fi
    printf '%s\n' "$$" >"$LOCK_DIR/pid"
    # Release only a lock we still own, so a watcher that lost the race and is
    # exiting cannot delete the lock its replacement already took.
    trap '[ "$(cat "$LOCK_DIR/pid" 2>/dev/null)" = "$$" ] && rm -rf "$LOCK_DIR"' EXIT INT TERM

    deadline=$(($(date +%s) + MAX_WATCH_SECONDS))
    iter=0; nlast=0
    shopt -s nullglob
    while :; do
      unread=("$STATE_DIR"/ttys*.unread)
      [ ${#unread[@]} -eq 0 ] && break

      # Poll at 1Hz for the first ~12s after anything lights up, which is the
      # window that matters for "drops back the moment you focus it", then back
      # off to 3s. Reaping dead ttys is not urgent, so it rides the slow path.
      [ ${#unread[@]} -gt "$nlast" ] && iter=0
      nlast=${#unread[@]}
      if [ $((iter % 10)) -eq 0 ]; then
        for f in "${unread[@]}"; do
          b=${f##*/}; b=${b%.unread}
          tty_alive "$b" || rm -f "$STATE_DIR/$b".*
        done
      fi

      # Claude Code may rewrite the title just after Stop and wipe the marker.
      # Re-assert; strip-then-prepend makes it idempotent. Flag-gated, so an
      # unmarked (single-tab) unread costs nothing here.
      for f in "${unread[@]}"; do
        b=${f##*/}; b=${b%.unread}
        if [ -f "$STATE_DIR/$b.mark" ]; then
          mctx=$(tab_ctx "/dev/$b")
          if [ -n "$mctx" ]; then
            IFS=$'\t' read -r mn ms mf mt <<<"$mctx"
            mark_set "$b" "$mn" "$ms" "$mt"
          fi
        fi
      done

      ft=$(focused_tty)
      [ -n "$ft" ] && [ -f "$STATE_DIR/${ft#/dev/}.unread" ] && rest_window "${ft#/dev/}"

      if [ "$(date +%s)" -ge "$deadline" ]; then
        for f in "$STATE_DIR"/ttys*.unread; do b=${f##*/}; rest_window "${b%.unread}"; done
        break
      fi
      iter=$((iter + 1))
      if [ "$iter" -lt 12 ]; then sleep "$POLL_SECONDS"; else sleep 3; fi
    done
    ;;

  # --------------------------------------------------------- tabcolor CLI ---
  tab)
    sub="${2:-}"
    t=$(session_tty) || { echo "not running inside a Terminal.app window"; exit 1; }

    case "$sub" in
      "" | show)
        row=$(assignment "$t") || row=""
        if [ -n "$row" ]; then
          echo "$t is tagged: $(printf '%s' "$row" | cut -f3)  ($(printf '%s' "$row" | cut -f1))"
        else
          echo "$t is untagged"
        fi
        idle_enabled && echo "resting tint: ON (${IDLE_PCT}%)" || echo "resting tint: OFF"
        echo
        echo "tag it with:  tabcolor <name>"
        "$0" tab list
        ;;

      list)
        echo "available:"
        awk -F'\t' '$1 ~ /^#[0-9A-Fa-f]{6}$/ { printf "  %-2s %-14s %-22s %s\n", $4, $2, $3, $1 }' "$BRANDS_FILE"
        ;;

      off | none | clear)
        remember_original "$t" || true
        rm -f "$STATE_DIR/$t.brand" "$STATE_DIR/$t.owner"
        rest_window "$t"
        echo "$t untagged, back to its original background"
        ;;

      sync)
        purge_dead
        printf '%s\n' "$(all_ttys)" | while read -r dev; do
          [ -z "$dev" ] && continue
          b="${dev#/dev/}"
          remember_original "$b" || continue
          mark_clear "$b" force
          rest_window "$b"
          r=$(assignment "$b") || r=""
          printf '  %-9s %s\n' "$b" "${r:+$(printf '%s' "$r" | cut -f3)}"
        done
        ;;

      idle)
        case "${3:-}" in
          on)  touch "$IDLE_FLAG"; echo "resting brand tint ON";  "$0" tab sync ;;
          off) rm -f "$IDLE_FLAG"; echo "resting brand tint OFF"; "$0" tab sync ;;
          *)   idle_enabled && echo "resting brand tint is ON" || echo "resting brand tint is OFF" ;;
        esac
        ;;

      status)
        echo "brands file : $BRANDS_FILE"
        echo "this tty    : $t"
        echo "focused     : $(focused_tty)"
        idle_enabled && echo "resting tint: ON" || echo "resting tint: OFF"
        if [ -d "$LOCK_DIR" ]; then echo "watcher     : pid $(cat "$LOCK_DIR/pid" 2>/dev/null)"; else echo "watcher     : not running"; fi
        echo "tagged windows:"
        shopt -s nullglob
        for f in "$STATE_DIR"/ttys*.brand; do
          b=$(basename "$f" .brand)
          u=""; [ -f "$STATE_DIR/$b.unread" ] && u="  <- UNREAD"
          [ -f "$STATE_DIR/$b.mark" ] && u="$u (tab-bar $MARK)"
          printf '  %-9s %-22s orig=%s%s\n' "$b" "$(cut -f3 <"$f")" "$(cat "$STATE_DIR/$b.orig" 2>/dev/null)" "$u"
        done
        ;;

      *)
        row=$(lookup_brand "$sub")
        if [ -z "$row" ]; then
          echo "no color named '$sub'"; echo; "$0" tab list; exit 1
        fi
        remember_original "$t" || { echo "not a Terminal.app tab"; exit 1; }
        printf '%s\n' "$row" >"$STATE_DIR/$t.brand"
        tty_owner "$t" >"$STATE_DIR/$t.owner"
        rest_window "$t"
        idle_enabled || echo "note: resting tint is OFF, so this window stays black until a response lands"
        echo "$t tagged $(printf '%s' "$row" | cut -f3)  ($(printf '%s' "$row" | cut -f1))"
        # Terminal.app cannot color the tab chrome, so the only way to get a
        # colored marker into the tab bar is an emoji in the title. Claude Code
        # owns the title, so hand back a ready /rename line instead of fighting
        # it, and put it on the clipboard so it is one paste, not an emoji hunt.
        emo=$(printf '%s' "$row" | cut -f4)
        if [ -n "$emo" ]; then
          rn="/rename $emo $(printf '%s' "$row" | cut -f3)"
          if printf '%s' "$rn" | pbcopy 2>/dev/null; then
            echo "clipboard (paste into the input box):  $rn"
          else
            echo "for the tab bar, paste:  $rn"
          fi
        fi
        ;;
    esac
    ;;

  *)
    echo "usage: $0 {set|clear|rest|watch|tab [...]}" >&2
    exit 2
    ;;
esac
