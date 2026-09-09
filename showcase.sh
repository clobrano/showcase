#!/usr/bin/env bash
# -*- coding: UTF-8 -*-
: "${SC_PROMPT:="[showcase user] $ "}"
: "${SC_SPEED:=10}"

main() {
    local sc_script=$1
    clear
    run "$sc_script"
}

init() {
    echo -n "$SC_PROMPT"
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

run() {
    local filepath=$1
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
                # physical lines, each continued with a trailing backslash
                # (just like a shell), so gather those lines into one command.
                cmd="$line"
                while [[ "$cmd" == *\\ ]] && (( i + 1 < n )); do
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
                # An empty line in the script prints an empty line during
                # replay, as if the user had pressed Enter at the prompt.
                echo
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
