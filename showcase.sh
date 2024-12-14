#!/usr/bin/env bash
# -*- coding: UTF-8 -*-
: ${SC_PROMPT:=""}
: ${SC_SPEED:=15}

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
    local command=$@
    slowtype "${command}" 0
    sleep 0.5
    eval ${command}
    sleep 1
    echo -n "$SC_PROMPT"
}

slowtype_tmux() {
    # The command to "type"
    local COMMAND=$1
    # The target pane (use `tmux list-panes` to find the target pane index)
    local TARGET_PANE=$2
    # Delay between each character (in seconds)
    local DELAY=0.2

    if [ ! -z $TARGET_PANE ]; then
        target_pane_field="-t $TARGET_PANE"
    fi

    # Send each character of the command
    for ((i=0; i<${#COMMAND}; i++)); do
        tmux send-keys "$target_pane_field" "${COMMAND:$i:1}"
        sleep $DELAY
    done

    # Send Enter to execute the command
    tmux send-keys "$target_pane_field" Enter
    sleep 1
}

run() {
    local filepath=$1
    # do not loop over the file rows, otherwise, for
    # unknown reasons, the first ssh command will break the loop
    mapfile -t lines < $filepath  # Read all lines into the array 'lines'

    for line in "${lines[@]}"; do
        line=$(envsubst <<< $line)
        if [[ "$line" == "@@ start @@" ]]; then
            clear
            init
            continue
        fi
        if [[ "$line" == \$\ * ]]; then
            # lines starting with $ sign are commands to type and execute
            slowtype_and_run ${line#"$ "}
            continue
        fi
        if [[ "$line" == \!\ * ]]; then
            eval ${line#"! "}
            continue
        fi
        if [[ "$line" == \!t* ]]; then
            pane=$(echo $line | awk -F'[: ]' '{print $2}')
            command=${line#* }
            echo "(tmux send-keys -t $pane \"$command\" Enter)"
            tmux send-keys -t $pane "$command" Enter
            continue
        fi
        if [[ "$line" == \?* ]]; then
            # consider lines starting with slash as comments to ignore
            continue
        fi
        # all the rest is text to type only
        if [[ "$line" == \t* ]]; then
            pane=$(echo $line | awk -F'[: ]' '{print $2}')
            command=${line#* }
            slowtype_tmux "$command" $pane
            continue
        fi
        slowtype "$line"
    done < $filepath
    slowtype "" 0
}

# MAIN
init
run $1
