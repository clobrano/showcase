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

slowtype() {
    local text="$1"
    local prompt_at_the_end=${2:-1}
    if [ ${#text} == 0 ]; then
        echo
    else
        # Add the hashtag at the beginning of the line
        echo "$text" | pv -qL "$SC_SPEED"
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
    # do not loop over the file rows in the loop, otherwise, for
    # unknown reasons, the first ssh command will break the loop
    mapfile -t lines < "$filepath"  # Read all lines into the array 'lines'

    for line in "${lines[@]}"; do
        line=$(envsubst <<< "$line")
        if [[ "$line" == \!\ * ]]; then
            # consider lines starting with exclamation mark as command to execute silently
            eval "${line#"! "}"
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
        if [[ "$line" == \\//?* ]]; then
            # consider lines starting with slash as comments to ignore
            continue
        fi
        if [[ "$line" == \#\ * ]]; then
            # lines starting with # sign are text to type only
            slowtype "$line"
            continue
        fi
        # all the rest is ignored
    done < "$filepath"
    slowtype "" 0
}

# MAIN
main "$1"
