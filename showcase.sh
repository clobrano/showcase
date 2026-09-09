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

run() {
    local filepath=$1
    mapfile -t lines < "$filepath"  # Read all lines into the array 'lines'

    # Iterate over the pre-read array (not the file via the loop's stdin), so
    # commands that consume stdin (e.g. ssh) can't swallow the rest of the
    # script. This is why the lines are read up-front with mapfile above.
    for line in "${lines[@]}"; do
        # Expand environment variables in the line when envsubst is
        # available; otherwise leave the line untouched.
        if command -v envsubst >/dev/null 2>&1; then
            line=$(envsubst <<< "$line")
        fi
        if [[ "$line" == \!\ * ]]; then
            # Lines starting with an exclamation mark are commands run for
            # their side effects only: stdout is suppressed to keep the demo
            # clean (stderr is kept so real failures still surface).
            eval "${line#"! "}" >/dev/null
            if [[ "$line" =~ "SC_SPEED" ]]; then
                init
            fi
            continue
        fi
        if [[ "$line" == \$\ * ]]; then
            # lines starting with $ sign are commands to type and execute
            slowtype_and_run "${line#"$ "}"
            continue
        fi
        if [[ "$line" == //* ]]; then
            # lines starting with // are comments and are ignored
            continue
        fi
        if [[ "$line" == \#\ * ]]; then
            # lines starting with # sign are text to type only
            slowtype "$line"
            continue
        fi
        # all the rest is ignored
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
