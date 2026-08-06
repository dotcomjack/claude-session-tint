#!/bin/bash
# tab-tag-prompt.sh  -  UserPromptSubmit hook  (companion to tabtint.sh)
#
# Tag the current Terminal window from inside a running Claude session without
# spending a turn. Type a lone comma line into the Claude input box:
#
#   ,aianyone    tag this window        (prefixes work, so ,ai is enough)
#   ,off         untag it
#   ,            show this window's tag plus the palette
#   ,list        just the palette
#   ,idle on     resting tint on / off
#
# HOW THE ZERO-TURN PART ACTUALLY WORKS (verified against the 2.1.223 binary,
# not inferred from docs). On a UserPromptSubmit hook result that carries a
# blockingError, Claude Code returns { shouldQuery: false, ... }, so the model
# is never invoked: no turn, no tokens, no assistant message.
#
# The important detail, and the reason this script prints JSON instead of just
# exiting 2 with a message on stderr:
#
#     V = H.suppressOriginalPrompt ? q : `${q}\n\nOriginal prompt: ${O}`
#
# A bare `exit 2` cannot set suppressOriginalPrompt, so the blocked prompt gets
# echoed back into the transcript as "Original prompt: ,ai". Emitting
# hookSpecificOutput.suppressOriginalPrompt = true drops that echo. Setting
# decision:"block" also supplies the reason text directly, instead of Claude
# Code synthesising "[<command>]: <stderr>" around it.
#
# We still exit 2 as well as printing the JSON. That is deliberate: with exit 0
# there is an earlier success branch (gated on `de.status===0`) that can yield
# before the blocking decision is applied. Exit 2 skips it, and because
# decision:"block" already populated blockingError, the exit-2 stderr fallback
# (`if (status===2 && !fe.blockingError)`) never fires either.
#
# Everything that is not a comma line exits 0 and is passed through untouched.
# Every failure path also exits 0. This must never eat a real prompt.
#
# Must be wired NON-async in settings.json. An async hook runs in the
# background, so its result arrives too late to gate the prompt.

set -uo pipefail

# Resolve tabtint.sh next to this script rather than at a fixed path. That makes
# the same file work as a plugin (both scripts sit in the plugin root, which
# moves on every update) and as a manual install (both in ~/.claude/hooks/).
TAB="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/tabtint.sh"

payload=$(cat 2>/dev/null) || exit 0
[ -n "$payload" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

# Field name is `prompt`, confirmed in the binary:
#   hook_event_name:"UserPromptSubmit",prompt:e,...
prompt=$(printf '%s' "$payload" | jq -r '.prompt // empty' 2>/dev/null) || exit 0
[ -n "$prompt" ] || exit 0

# ---- the gate -------------------------------------------------------------
# Pure bash 3.2 pattern matching. No grep: `grep -E '^,...$'` matches ANY LINE
# of a multi-line prompt, so a long real message containing a short
# comma-leading line would be silently eaten. Reject newlines outright first.

case $prompt in
  *'
'*) exit 0 ;;                                   # multi-line, always a real prompt
esac

# Trim leading whitespace before matching. Typing a space before the comma is
# easy to do and used to fall straight through as a real prompt.
prompt=${prompt#"${prompt%%[![:space:]]*}"}

case $prompt in
  ,*) ;;                                        # candidate
  *) exit 0 ;;
esac

[ ${#prompt} -le 25 ] || exit 0                 # long comma line, real prompt

# Only characters a brand key / subcommand can contain. This also excludes the
# glob metacharacters, which is what makes the unquoted expansion below safe.
case $prompt in
  *[!A-Za-z0-9\ _,.-]*) exit 0 ;;
esac

[ -x "$TAB" ] || exit 0

# ---- do the work ----------------------------------------------------------

arg=${prompt#,}
arg=${arg#"${arg%%[![:space:]]*}"}              # ltrim
arg=${arg%"${arg##*[![:space:]]}"}              # rtrim

set -f                                          # belt and braces, no globbing
# shellcheck disable=SC2086
out=$("$TAB" tab $arg 2>&1)
set +f

[ -n "$out" ] || out="tabcolor: no output"

jq -n --arg r "$out" '{
  decision: "block",
  reason: $r,
  hookSpecificOutput: {
    hookEventName: "UserPromptSubmit",
    suppressOriginalPrompt: true
  }
}' 2>/dev/null || exit 0

exit 2
