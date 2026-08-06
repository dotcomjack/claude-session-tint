---
description: Tint this terminal window with a project color. No argument shows the palette.
argument-hint: "<project> | off | list | idle on|off | status   (or just type ,project)"
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/tabtint.sh:*)
disable-model-invocation: true
model: haiku
effort: low
---

The window color command has already run during expansion. Its output:

!`${CLAUDE_PLUGIN_ROOT}/tabtint.sh tab $ARGUMENTS`

Print that output back verbatim, then on a final line print exactly:
`tip: ,<project> in the input box does the same thing with no turn.`

No other commentary, no summary, no preamble, no tool calls. There is nothing left to do.
