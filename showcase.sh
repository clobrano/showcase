#!/usr/bin/env bash
# -*- coding: UTF-8 -*-
: "${SC_PROMPT:="[showcase user] $ "}"
# SC_SPEED is the base typing speed (chars/second fed to `pv`); a higher number
# types faster. It stays the "slow" pace: the 'f' key temporarily bumps the
# speed to the SC_SPEED_FAST preset, and the 's' key drops back to SC_SPEED.
# Both can be overridden from the environment. SC_SPEED can also be changed
# mid-demo with a silent '! export SC_SPEED=...' command, and such a script-set
# change takes priority over an 'f'/'s' key override (see reconcile_speed).
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
# slow pace, restored by the 's' key); a non-empty value overrides it.
sc_speed_override=""

# The last SC_SPEED value the tool observed. Used to notice when the *script*
# itself changes SC_SPEED (e.g. a '! export SC_SPEED=...' command). A script-set
# change takes priority over an 'f'/'s' key override: it clears the override so
# the script's speed wins. A key pressed afterwards overrides again, until the
# script changes SC_SPEED once more.
sc_speed_seen="$SC_SPEED"

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

# Prompt state. The prompt is drawn *lazily* — right before a line's content
# (see ensure_prompt) rather than left dangling after the previous line — so a
# silent command's output always starts on a clean line instead of colliding
# with a leftover prompt.
#   prompt_active: whether the demo has entered "prompt mode". It stays 0 until
#     a typed line appears or SC_SPEED is set, so lines before then (e.g. a blank
#     line during early setup) don't print a stray default prompt.
#   prompt_shown:  whether a prompt is currently drawn on the current line and
#     not yet followed by a newline.
prompt_active=0
prompt_shown=0

# The base-8 shell colors, mapped to their SGR foreground codes. Used by the
# "/title" command to optionally paint a section header. Only these eight
# names (any casing) are recognised, since they are the colors every terminal
# supports.
declare -A SC_COLORS=(
    [black]=30 [red]=31 [green]=32 [yellow]=33
    [blue]=34 [magenta]=35 [cyan]=36 [white]=37
)

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

Script directives (scripted equivalents of the keys, on their own line):
  /pause  stop until the presenter presses 'p' (skipped on a non-interactive
          run so it never hangs)
  /slow   use the base typing speed SC_SPEED (like the 's' key)
  /fast   use the SC_SPEED_FAST preset (like the 'f' key)
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

# Enter "prompt mode" so subsequent lines show a prompt. Triggered when the
# demo sets SC_SPEED (a common first-setup step), so a blank line right after
# setup still gets a prompt. Idempotent — safe to call more than once.
enter_prompt_mode() {
    prompt_active=1
}

# Draw the prompt for the current line if one isn't already on it. The prompt is
# only ever drawn here (lazily, before content), so it never dangles after a line
# for a silent command's output to collide with.
ensure_prompt() {
    if [[ "$prompt_active" -eq 1 && "$prompt_shown" -eq 0 ]]; then
        echo -n "$SC_PROMPT"
        prompt_shown=1
    fi
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
    local pause_at_the_end=${2:-1}
    # A typed line means we're in prompt mode; draw its prompt before the text.
    enter_prompt_mode
    ensure_prompt
    if [ ${#text} == 0 ]; then
        echo
    else
        echo "$text" | type_effect
    fi
    # The line ended with a newline, so no prompt is dangling any more.
    prompt_shown=0
    if [ "$pause_at_the_end" -eq 1 ]; then
        sleep 1
    fi
}

# Render a "/title" line as a decorated section header: the title text framed
# above and below by a rule of '=' the same length as the text, each line
# prefixed like a shell comment ("# "), e.g.
#
#   [demo] $ # ==========
#   [demo] $ # My Section
#   [demo] $ # ==========
#
# Unlike typed text, a header is printed instantly (no typing animation) and
# every line is preceded by its own prompt, exactly as if the user had typed
# and entered each line. An optional leading "[color]" token (one of the base-8
# shell colors, see SC_COLORS) paints the header lines in that color (the
# prompt keeps its usual color). An unknown color name is left untouched and
# kept as part of the title, so a typo never silently swallows text.
title() {
    local text="$1"
    local color_start="" color_end=""

    if [[ "$text" =~ ^\[([a-zA-Z]+)\][[:space:]]*(.*)$ ]]; then
        local name="${BASH_REMATCH[1],,}"
        if [[ -n "${SC_COLORS[$name]:-}" ]]; then
            color_start=$'\033['"${SC_COLORS[$name]}"'m'
            color_end=$'\033[0m'
            text="${BASH_REMATCH[2]}"
        fi
    fi

    # Build a rule of '=' exactly as long as the title text (a run of spaces
    # of that length, with each space turned into an '='). An empty title
    # yields an empty rule.
    local rule
    printf -v rule '%*s' "${#text}" ''
    rule="${rule// /=}"

    local lines=("# $rule" "# $text" "# $rule")

    # A header behaves like typed content, so make sure we're in prompt mode:
    # each line then gets its own prompt (drawn lazily by ensure_prompt).
    enter_prompt_mode

    # Print each line instantly (no typing effect). Drawing the prompt before
    # each line and ending the line with a newline (so nothing dangles) makes
    # the prompt visible on every line, as if the user typed and entered each.
    local idx
    for idx in "${!lines[@]}"; do
        ensure_prompt
        printf '%s%s%s\n' "$color_start" "${lines[idx]}" "$color_end"
        prompt_shown=0
    done
    sleep 1
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
    # No trailing prompt is drawn here: the next line draws its own (lazily), so
    # nothing dangles for a following silent command's output to collide with.
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

# Give a script-set SC_SPEED change priority over a key override. If SC_SPEED
# differs from the last value we saw, the script changed it (e.g. via a silent
# '! export SC_SPEED=...' command), so drop any 'f'/'s' key override and let the
# script's speed take effect. Runs in the main shell (never a subshell) so its
# state updates persist.
reconcile_speed() {
    if [[ "$SC_SPEED" != "$sc_speed_seen" ]]; then
        sc_speed_seen="$SC_SPEED"
        sc_speed_override=""
    fi
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

# Whether keys can actually be read right now: key handling is enabled AND stdin
# is an interactive terminal. Reading from a non-terminal stdin (a pipe or file)
# would steal the input meant for the demo's own commands (and for the test
# suite), and blocking for a key that can never come would hang the demo.
keys_active() {
    [[ "$SC_KEYS" != 0 && -t 0 ]]
}

# Draw / erase a subtle dimmed "-- paused --" cue at the cursor so the presenter
# can see the demo is waiting. The cursor position is saved before the cue is
# drawn and restored (clearing the cue and any trailing remnant on the line)
# when the demo resumes, so the demo's own output is left exactly as it was.
# Nothing prints while paused, so the saved position stays valid.
show_paused_cue() {
    printf '\033[s\033[2m-- paused --\033[0m'
}
clear_paused_cue() {
    printf '\033[u\033[0K'
}

# Block until the demo is resumed (paused back to 0). Speed keys ('s'/'f') are
# still processed while paused. Guarded so it never blocks when a key can't
# arrive — otherwise a pause (manual or scripted) would hang a non-interactive
# run forever. While blocked, a subtle "-- paused --" cue is shown.
wait_while_paused() {
    keys_active || return 0
    [[ "$paused" -eq 1 ]] || return 0
    local key
    show_paused_cue
    while [[ "$paused" -eq 1 ]]; do
        if IFS= read -rsn1 key; then
            process_key "$key"
        fi
    done
    clear_paused_cue
}

# A flow-control checkpoint between demo steps: read any keys the presenter has
# pressed and act on them, then block here for as long as the demo is paused.
# It is a no-op unless keys can be read (see keys_active).
checkpoint() {
    keys_active || return 0
    local key
    # Consume every key queued since the previous checkpoint. The read returns
    # as soon as a key is available; the short timeout only bounds the final,
    # empty read, so this stays snappy when nothing was typed.
    while IFS= read -rsn1 -t 0.01 key; do
        process_key "$key"
    done
    wait_while_paused
}

# Handle a script directive line (e.g. '/pause', '/fast', '/slow'): the scripted
# equivalents of the playback keys, so a demo can bake pause points and speed
# changes into the script itself. Returns 0 if the line was a directive (and was
# handled), 1 otherwise so the caller can fall through to other line types.
run_directive() {
    case "$1" in
        "/pause"|"/pause "*)
            # Scripted pause: stop here until the presenter presses 'p'. Only
            # when a key can actually arrive, so a non-interactive run (CI,
            # piped stdin, dry-run without a TTY) never hangs — it just skips.
            if keys_active; then
                paused=1
                wait_while_paused
            fi
            ;;
        "/fast"|"/fast "*) process_key f ;;  # same as pressing 'f'
        "/slow"|"/slow "*) process_key s ;;  # same as pressing 's'
        *) return 1 ;;
    esac
    return 0
}

run() {
    local filepath=$1
    prompt_shown=0
    sc_speed_seen="$SC_SPEED"  # baseline for detecting script-set speed changes
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
        # A script-set SC_SPEED change (from the previous step) wins over a key
        # override; apply that before handling any new keypresses this step.
        reconcile_speed
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
                    # Silent command: command is not printed, but stdout and
                    # stderr are not suppressed. If a prompt somehow still dangles
                    # on the current line, end it first so the command's output
                    # starts on a clean line (never overwriting the prompt, e.g.
                    # a progress line that uses '\r').
                    if [[ "$prompt_shown" -eq 1 ]]; then
                        echo
                        prompt_shown=0
                    fi
                    # In dry-run its execution is skipped.
                    if ! dry_run_skip_silent; then
                        term_restore
                        eval "${cmd#"! "}"
                        term_reapply
                    fi
                    # Setting SC_SPEED is the usual cue that setup is done, so
                    # enter prompt mode (the prompt itself is drawn lazily later).
                    if [[ "$cmd" =~ "SC_SPEED" ]]; then
                        enter_prompt_mode
                    fi
                else
                    slowtype_and_run "${cmd#"$ "}"
                fi
                ;;
            "")
                # Reproduce pressing Enter at the prompt: draw the prompt for
                # this line (lazily, if we're in prompt mode) then end the line.
                ensure_prompt
                echo
                prompt_shown=0
                ;;
            /title\ *)
                # A "/title" line renders a decorated section header. It may
                # start with an optional "[color]" token. (Checked before the
                # '//' comment case below, which needs two leading slashes and
                # so never matches "/title".)
                title "${line#/title }"
                ;;
            //*)
                # lines starting with // are comments and are ignored
                ;;
            \#\ *)
                # lines starting with # sign are text to type only
                slowtype "$line"
                ;;
            *)
                # A script directive (e.g. /pause, /fast, /slow) is handled here;
                # any other unrecognized line is ignored.
                run_directive "$line" || true
                ;;
        esac
        (( i++ ))
    done
    # End at a shell prompt (drawn lazily), like a real terminal after the demo.
    ensure_prompt
    echo
    prompt_shown=0
}

# MAIN
# Only run automatically when executed directly. When the script is sourced
# (e.g. by the test suite) this guard keeps `main` from running so individual
# functions can be exercised in isolation.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
