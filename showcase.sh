#!/usr/bin/env bash
# -*- coding: UTF-8 -*-
: "${SC_PROMPT:="$ "}"
: "${SC_SPEED:=10}"

init() {
    echo -n "$SC_PROMPT"
    sleep 1
}

slowtype() {
    local text="$1"
    local prompt_at_the_end=${2:-1}
    echo "$text" | pv -qL "$SC_SPEED"
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
    # do not loop over the file rows in the loop, otherwise, for
    # unknown reasons, the first ssh command will break the loop
    mapfile -t lines < "$filepath"  # Read all lines into the array 'lines'

    for line in "${lines[@]}"; do
        line=$(envsubst <<< "$line")
        if [[ "$line" == \$\ * ]]; then
            # lines starting with $ sign are commands to type and execute
            slowtype_and_run "${line#"$ "}"
            continue
        fi
        if [[ "$line" == \!\ * ]]; then
            # consider lines starting with exclamation mark as command to execute silently
            eval ${line#"! "}
            continue
        fi
        if [[ "$line" == \?* ]]; then
            # consider lines starting with slash as comments to ignore
            continue
        fi
        # all the rest is text to type only
        slowtype "$line"
    done < "$filepath"
    slowtype "" 0
}

# MAIN
clear
init
run $1
