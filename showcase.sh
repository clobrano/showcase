#!/usr/bin/env bash
# -*- coding: UTF-8 -*-
: "${SC_PROMPT:="[showcase user] $ "}"
# SC_SPEED is the base typing speed (chars/second fed to `pv`); a higher number
# types faster. It stays the "slow" pace: the 'f' key temporarily bumps the
# speed to the SC_SPEED_FAST preset, and the 's' key drops back to SC_SPEED.
# Both can be overridden from the environment, and SC_SPEED can still be changed
# mid-demo with a silent '! export SC_SPEED=...' command.
: "${SC_SPEED:=10}"
: "${SC_SPEED_FAST:=40}"

# Playback keys: while the demo runs, the presenter can press a key to control
# the flow. Handling only happens at checkpoints *between* steps, so a command
# that is already running is never interrupted (only the visible/silent flow is
# affected). The keys are:
#   p  toggle pause / resume (pauses just before the next command runs)
#   s  slower: use the base SC_SPEED (the default pace)
#   f  faster: use the SC_SPEED_FAST preset
# Keys are read only from an interactive terminal, so a piped/redirected stdin
# (which belongs to the demo's own commands) is never consumed. Set SC_KEYS=0
# to disable key handling entirely.
: "${SC_KEYS:=1}"

# Whether the demo is currently paused (toggled by the 'p' key at a checkpoint).
paused=0

# Speed override set by the 'f' key. Empty means "follow SC_SPEED" (the base,
# slow pace, restored by the 's' key); a non-empty value overrides it so the
# base SC_SPEED — including any mid-demo change to it — is never lost.
sc_speed_override=""

# Saved terminal settings (from `stty -g`) while key handling is active, so the
# original mode can be restored around live commands and on exit. Empty when key
# handling is off, stdin isn't a terminal, or stty is unavailable.
term_saved=""

# Dry-run mode: when set, matching commands are shown but NOT executed, so a
# demo can be rehearsed without touching the system. Valid values:
#   ""/none  - execute everything (default)
#   all      - skip executing every command (both '$' and '!')
#   visible  - skip executing only the visible '$' commands
#   silent   - skip executing only the silent '!' commands
# It can be set from the environment or with the --dry-run[=MODE] flag.
: "${SC_DRY_RUN:=}"

# Tracks whether a prompt is currently drawn on screen. It stays 0 until the
# first prompt is emitted (by init or a typed line), so empty lines that come
# before the prompt is configured don't print a stray default prompt.
prompt_shown=0

usage() {
    cat <<'EOF'
Usage: showcase.sh [--dry-run[=MODE]] SCRIPT

Options:
  --dry-run[=MODE]  Show commands without executing them. MODE is one of:
                      all      skip every command (both '$' and '!') [default]
                      visible  skip only the visible '$' commands
                      silent   skip only the silent '!' commands
  -h, --help        Show this help and exit.

Playback keys (interactive terminal only; set SC_KEYS=0 to disable):
  p  pause / resume (pauses just before the next command runs; a command
     that is already running is not stopped)
  s  slower: use the base typing speed SC_SPEED (the default pace)
  f  faster: use the SC_SPEED_FAST preset
EOF
}

main() {
    local sc_script=""
    local arg
    for arg in "$@"; do
        case "$arg" in
            --dry-run)     SC_DRY_RUN="all" ;;
            --dry-run=*)   SC_DRY_RUN="${arg#--dry-run=}" ;;
            -h|--help)     usage; return 0 ;;
            -*)
                printf 'Unknown option: %s\n' "$arg" >&2
                usage >&2
                return 2
                ;;
            *)             sc_script="$arg" ;;
        esac
    done

    # Validate the dry-run mode (whether it came from the flag or the
    # environment) before doing anything, so a typo fails fast.
    case "$SC_DRY_RUN" in
        ""|none|all|visible|silent) ;;
        *)
            printf 'Invalid dry-run mode: %s (expected all, visible, or silent)\n' \
                "$SC_DRY_RUN" >&2
            return 2
            ;;
    esac

    if [[ -z "$sc_script" ]]; then
        printf 'No demo script provided.\n' >&2
        usage >&2
        return 2
    fi

    clear
    term_setup
    run "$sc_script"
    local rc=$?
    term_restore
    return "$rc"
}

# Whether execution of visible ('$') commands should be skipped in dry-run.
dry_run_skip_visible() {
    [[ "$SC_DRY_RUN" == "all" || "$SC_DRY_RUN" == "visible" ]]
}

# Whether execution of silent ('!') commands should be skipped in dry-run.
dry_run_skip_silent() {
    [[ "$SC_DRY_RUN" == "all" || "$SC_DRY_RUN" == "silent" ]]
}

init() {
    # Draw the initial prompt, but only once: a silent command that references
    # SC_SPEED triggers this, and a demo may do so more than once (e.g. change
    # the speed mid-run). Redrawing when a prompt is already on screen would
    # print the prompt twice on the same line, since it is emitted without a
    # trailing newline.
    if [[ "$prompt_shown" -eq 1 ]]; then
        return
    fi
    echo -n "$SC_PROMPT"
    prompt_shown=1
}

# Render stdin with a typing effect. Uses `pv` to animate output at
# SC_SPEED when it is available, and falls back to plain output otherwise
# so the tool still works (just without the animation) on minimal systems.
type_effect() {
    if command -v pv >/dev/null 2>&1; then
        # Use the 'f'-key override when one is set, otherwise the base SC_SPEED.
        pv -qL "${sc_speed_override:-$SC_SPEED}"
    else
        cat
    fi
}

slowtype() {
    local text="$1"
    local prompt_at_the_end=${2:-1}
    if [ ${#text} == 0 ]; then
        echo
    else
        # Add the hashtag at the beginning of the line
        echo "$text" | type_effect
    fi
    if [ "$prompt_at_the_end" -eq 1 ]; then
        echo -n "$SC_PROMPT"
        prompt_shown=1
        sleep 1
    fi
}

slowtype_and_run() {
    local command=$*
    slowtype "${command}" 0
    sleep 0.5
    # Pause point *after* the command has been typed but *before* it runs: a 'p'
    # pressed while the command was being printed stops here, so the command is
    # shown but not yet executed until the presenter resumes.
    checkpoint
    # In dry-run the command is still typed out above (so the demo looks the
    # same), but its execution is skipped here.
    if ! dry_run_skip_visible; then
        # Give the live command a normal terminal (echo on, canonical mode) so
        # interactive programs behave, then resume key handling afterwards.
        term_restore
        eval "${command}"
        term_reapply
    fi
    sleep 1
    echo -n "$SC_PROMPT"
    prompt_shown=1
}

# Expand environment variables in a line when envsubst is available;
# otherwise return the line unchanged.
expand_vars() {
    if command -v envsubst >/dev/null 2>&1; then
        envsubst <<< "$1"
    else
        printf '%s\n' "$1"
    fi
}

# Decide whether a (possibly multi-line) command continues onto the next
# physical line, exactly like an interactive shell would. A command continues
# when its last non-whitespace token is a line-continuation backslash "\" or a
# trailing pipe "|" / logical operator "&&" / "||". Trailing whitespace after
# that token is ignored, so a stray space (a very common, invisible mistake,
# especially after a pipe) doesn't break the continuation.
line_continues() {
    local re='(\\|\||&&)[[:space:]]*$'
    [[ "$1" =~ $re ]]
}

# Turn off terminal echo (and remember the previous settings) so the playback
# keys the presenter presses between steps aren't printed into the demo. No-op
# unless key handling is enabled, stdin is a terminal, and stty is available.
# Also installs traps so the terminal is always restored, even on Ctrl-C.
term_setup() {
    [[ "$SC_KEYS" != 0 && -t 0 ]] || return 0
    command -v stty >/dev/null 2>&1 || return 0
    term_saved="$(stty -g 2>/dev/null)" || { term_saved=""; return 0; }
    stty -echo 2>/dev/null
    trap 'term_restore; exit 130' INT TERM
    trap term_restore EXIT
}

# Restore the terminal to its saved settings. Used before running a live
# command (so it sees a normal terminal) and on exit. Idempotent.
term_restore() {
    [[ -n "$term_saved" ]] || return 0
    stty "$term_saved" 2>/dev/null
}

# Re-disable echo after a live command returns, resuming key handling. No-op
# when the terminal was never put under our control.
term_reapply() {
    [[ -n "$term_saved" ]] || return 0
    stty -echo 2>/dev/null
}

# Act on a single playback key. Kept separate from the reading logic so it can
# be unit-tested directly (the actual key reads need an interactive terminal).
process_key() {
    case "$1" in
        p|P)
            if [[ "$paused" -eq 1 ]]; then
                paused=0
            else
                paused=1
            fi
            ;;
        s|S) sc_speed_override="" ;;               # back to the base SC_SPEED
        f|F) sc_speed_override="$SC_SPEED_FAST" ;;  # bump to the fast preset
    esac
}

# A flow-control checkpoint between demo steps: read any keys the presenter has
# pressed and act on them, then block here for as long as the demo is paused.
# It is a no-op unless key handling is enabled AND stdin is an interactive
# terminal — reading from a non-terminal stdin (a pipe or file) would steal the
# input meant for the demo's own commands (and for the test suite).
checkpoint() {
    [[ "$SC_KEYS" != 0 && -t 0 ]] || return 0
    local key
    # Consume every key queued since the previous checkpoint. The read returns
    # as soon as a key is available; the short timeout only bounds the final,
    # empty read, so this stays snappy when nothing was typed.
    while IFS= read -rsn1 -t 0.01 key; do
        process_key "$key"
    done
    # Honor a pause request by blocking until the demo is resumed. Speed keys
    # ('s'/'f') are still processed while paused (they take effect on resume).
    while [[ "$paused" -eq 1 ]]; do
        if IFS= read -rsn1 key; then
            process_key "$key"
        fi
    done
}

run() {
    local filepath=$1
    prompt_shown=0
    mapfile -t lines < "$filepath"  # Read all lines into the array 'lines'

    # Iterate over the pre-read array (not the file via the loop's stdin), so
    # commands that consume stdin (e.g. ssh) can't swallow the rest of the
    # script. This is why the lines are read up-front with mapfile above. An
    # index is used (rather than a plain `for`) so a command can consume the
    # continuation lines that follow it (see the backslash handling below).
    local n=${#lines[@]}
    local i=0
    local line cmd
    while (( i < n )); do
        # Flow control: pause/resume and speed keys take effect here, between
        # steps, so a running command is never interrupted.
        checkpoint
        # Expand environment variables in the line when envsubst is
        # available; otherwise leave the line untouched.
        line=$(expand_vars "${lines[i]}")
        case "$line" in
            \!\ *|\$\ *)
                # Command lines: '!' runs silently (for setup/teardown), '$'
                # is typed out and executed live. Either may span several
                # physical lines, continued either with a trailing backslash or
                # by ending on a pipe/logical operator (just like a shell), so
                # gather those lines into one command.
                cmd="$line"
                while (( i + 1 < n )) && line_continues "$cmd"; do
                    # Drop any trailing whitespace before joining the next
                    # line. Without this, a stray space after a continuation
                    # backslash ("\ ") would be read by the shell as an escaped
                    # space rather than a line continuation, mangling (or
                    # hanging) the command.
                    cmd="${cmd%"${cmd##*[![:space:]]}"}"
                    (( i++ ))
                    cmd+=$'\n'$(expand_vars "${lines[i]}")
                done
                if [[ "$cmd" == \!\ * ]]; then
                    # Silent command: command is not printed, but stdout and stderr
                    # are not suppressed.
                    # In dry-run its execution is skipped, but the prompt setup
                    # (init, a display-only action) still runs so the demo's
                    # look is preserved.
                    if ! dry_run_skip_silent; then
                        term_restore
                        eval "${cmd#"! "}"
                        term_reapply
                    fi
                    if [[ "$cmd" =~ "SC_SPEED" ]]; then
                        init
                    fi
                else
                    slowtype_and_run "${cmd#"$ "}"
                fi
                ;;
            "")
                if [[ "$prompt_shown" -eq 1 ]]; then
                    # A prompt is on screen: reproduce pressing Enter at the
                    # prompt. Finish the current prompt line, then draw a fresh
                    # prompt for the next line (just like a real terminal).
                    echo
                    echo -n "$SC_PROMPT"
                else
                    # No prompt has been drawn yet (e.g. an empty line before
                    # the prompt is configured), so just emit a blank line and
                    # don't print a stray prompt.
                    echo
                fi
                ;;
            //*)
                # lines starting with // are comments and are ignored
                ;;
            \#\ *)
                # lines starting with # sign are text to type only
                slowtype "$line"
                ;;
            *)
                # all the rest is ignored
                ;;
        esac
        (( i++ ))
    done
    slowtype "" 0
}

# MAIN
# Only run automatically when executed directly. When the script is sourced
# (e.g. by the test suite) this guard keeps `main` from running so individual
# functions can be exercised in isolation.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
