<!-- █ dcj · dotcomjack.com · MIT -->
# Security

This tool installs **hooks that run shell commands on every Claude Code
session event**, including one on `UserPromptSubmit` that sees the text you
type. It also edits `~/.claude/settings.json`. That is a lot of trust to hand a
terminal decoration, and you should not hand it over on the strength of a README.

This page exists so you can check the two things that actually matter: what it
does with your prompts, and whether it talks to the network.

## The two claims, and how to verify them yourself

**1. It never sends anything anywhere. There is no network code in this repo.**

```sh
grep -rnE 'curl|wget|nc |ncat|/dev/tcp|https?://' bin lib hooks *.sh
```

The only matches are comments and documentation URLs. No request is ever made.

**2. Your prompt text is pattern matched in memory and never stored.**

`prompt-hook.sh` reads the hook payload on stdin and pulls out `.prompt` so it
can recognise a leading command like `,ai`. That variable is then used in
nothing but `case` statements:

```sh
grep -nE '\$prompt' prompt-hook.sh | grep -v '^\s*#'
```

Every use is a `case` match or an emptiness test. It is never written to a file,
never logged, never passed to another process. State on disk is limited to tint
and idle flags under the state directory.

If either check fails on a copy you are holding, that copy is not this one.
Report it.

## Reporting a vulnerability

**Do not open a public issue for a security problem.** Two private channels:

1. [Open a private advisory](https://github.com/dotcomjack/claude-session-tint/security/advisories/new)
   on this repository. Preferred.
2. Email **jack@dotcomjack.com** with `claude-session-tint security` in the
   subject.

**Response:** maintained by one person. Acknowledgement within 3 business days,
first assessment within 7. Anything touching prompt handling or hook execution
gets same day treatment.

## In scope

* **Hook command injection.** A repository path, directory name, git branch, or
  session value containing shell metacharacters that reaches an unquoted
  expansion. This is the most likely real bug in a project like this.
* **Terminal escape injection.** A crafted project or branch name that escapes
  the tinting sequence and emits control codes your terminal acts on. Some
  terminals will do more with an escape sequence than change a colour.
* **Prompt leakage.** Anything at all that writes, logs, or transmits prompt
  text. See above.
* **`settings.json` damage.** A path where the installer corrupts, truncates, or
  drops other people's hooks. The installer writes a `.bak-tabtint` backup
  before touching it, and a failure of that backup is in scope too.
* **A hook that can hang or block a session.** `prompt-hook.sh` is written to
  exit 0 on every failure path so it can never eat a real prompt. A path that
  breaks that guarantee is a bug worth reporting.

## Out of scope

* Claude Code itself and its hook system. Report those to
  [anthropics/claude-code](https://github.com/anthropics/claude-code/issues).
* Your terminal emulator's handling of standard OSC colour sequences.
* Colours you dislike. That is a regular issue, and it is welcome as one.

## Before you install

The install script is short and readable, and it shows you what it will change:

```sh
git clone https://github.com/dotcomjack/claude-session-tint
cd claude-session-tint
cat install.sh          # read it, it is not long
cat hooks/hooks.json    # exactly which events get a hook, and what they run
```

Uninstalling restores the settings backup it made at install time.

## Supported versions

Only the current `main` is supported. Pull before reporting.
