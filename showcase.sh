#!/usr/bin/env bash
# -*- coding: UTF-8 -*-
: "${SC_PROMPT:="[showcase user] $ "}"
: "${SC_SPEED:=10}"

# Tracks whether a prompt is currently drawn on screen. It stays 0 until the
# first prompt is emitted (by init or a typed line), so empty lines that come
# before the prompt is configured don't print a stray default prompt.
prompt_shown=0

main() {
    local sc_script=$1
    clear
    run "$sc_script"
}

init() {
    echo -n "$SC_PROMPT"
    prompt_shown=1
}

# Render stdin with a typing effect. Uses `pv` to animate output at
# SC_SPEED when it is available, and falls back to plain output otherwise
# so the tool still works (just without the animation) on minimal systems.
type_effect() {
    if command -v pv >/dev/null 2>&1; then
        pv -qL "$SC_SPEED"
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
    eval "${command}"
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
                    # Silent command: stdout is suppressed to keep the demo
                    # clean (stderr is kept so real failures still surface).
                    eval "${cmd#"! "}" >/dev/null
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
    main "$1"
fi
