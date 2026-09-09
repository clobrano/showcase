#!/usr/bin/env bash
# -*- coding: UTF-8 -*-
#
# Test suite for showcase.sh.
#
# Pure bash, no external test framework required. It sources showcase.sh
# (which is safe thanks to the source-guard at the bottom of that file) and
# drives its functions directly, capturing their output for assertions.
#
# Usage:
#   ./tests/run.sh
#
# Exit status is 0 when every test passes, 1 otherwise.

# SC_PROMPT and SC_SPEED are read by the sourced showcase.sh, which shellcheck
# cannot follow across the `source`, so it would flag them as unused.
# shellcheck disable=SC2034
set -u

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$TESTS_DIR/.." && pwd)"
SHOWCASE="$ROOT_DIR/showcase.sh"

# --- Make the tool fast and side-effect free during tests -------------------
# Override the pacing/screen commands the tool would otherwise call. Because
# these are shell functions, calls from within the sourced script resolve to
# them instead of the real commands.
sleep() { :; }
clear() { :; }

# Keep the animation instant regardless of whether `pv` is installed.
export SC_SPEED=1000000

# Source the tool. The source-guard in showcase.sh prevents `main` from
# running, so only the function definitions are loaded.
# shellcheck source=/dev/null
source "$SHOWCASE"

# --- Tiny assertion helpers -------------------------------------------------
pass=0
fail=0

_pass() { printf '  \033[32mok\033[0m   %s\n' "$1"; pass=$((pass + 1)); }
_fail() {
    printf '  \033[31mFAIL\033[0m %s\n' "$1"
    printf '       %s\n' "$2"
    fail=$((fail + 1))
}

assert_contains() { # label haystack needle
    if [[ "$2" == *"$3"* ]]; then
        _pass "$1"
    else
        _fail "$1" "expected output to contain: [$3]"
    fi
}

assert_not_contains() { # label haystack needle
    if [[ "$2" != *"$3"* ]]; then
        _pass "$1"
    else
        _fail "$1" "expected output NOT to contain: [$3]"
    fi
}

assert_file_exists() { # label path
    if [[ -f "$2" ]]; then
        _pass "$1"
    else
        _fail "$1" "expected file to exist: [$2]"
    fi
}

# Write the here-doc on stdin to a temp script, run it through run(), and
# echo the captured output (stdout + stderr).
run_script() {
    local f out
    f="$(mktemp)"
    cat >"$f"
    out="$(run "$f" 2>&1)"
    rm -f "$f"
    printf '%s' "$out"
}

# --- Tests ------------------------------------------------------------------

test_typed_text_is_shown() {
    local out
    out="$(run_script <<'EOF'
# TYPED_TEXT_TOKEN
EOF
)"
    assert_contains "typed '#' text is rendered" "$out" "TYPED_TEXT_TOKEN"
}

test_dollar_command_is_displayed_and_executed() {
    local out
    out="$(run_script <<'EOF'
$ printf 'EXEC_OUTPUT\n'
EOF
)"
    # The command line itself is "typed" out...
    assert_contains "'\$' command line is displayed" "$out" "printf 'EXEC_OUTPUT"
    # ...and the command is actually executed, showing its real output.
    assert_contains "'\$' command is executed" "$out" "EXEC_OUTPUT"
}

test_silent_command_suppresses_stdout() {
    local out
    out="$(run_script <<'EOF'
! echo SILENT_NOISE_TOKEN
EOF
)"
    assert_not_contains "'!' command stdout is suppressed" "$out" "SILENT_NOISE_TOKEN"
}

test_silent_command_side_effect_runs() {
    local marker out
    marker="$(mktemp -u)"
    out="$(run_script <<EOF
! printf 'data' > "$marker"
EOF
)"
    assert_file_exists "'!' command still runs (side effect)" "$marker"
    rm -f "$marker"
}

test_slash_comment_is_ignored() {
    local out
    out="$(run_script <<'EOF'
// SLASH_COMMENT_TOKEN
EOF
)"
    assert_not_contains "'//' comment line is ignored" "$out" "SLASH_COMMENT_TOKEN"
}

test_unprefixed_line_is_ignored() {
    local out
    out="$(run_script <<'EOF'
UNPREFIXED_TOKEN with no leading marker
EOF
)"
    assert_not_contains "unprefixed line is ignored" "$out" "UNPREFIXED_TOKEN"
}

test_custom_prompt_is_used() {
    local out
    SC_PROMPT="CUSTOM_PROMPT_TOKEN> "
    out="$(run_script <<'EOF'
# hello
EOF
)"
    SC_PROMPT="[showcase user] $ "  # restore default for later tests
    assert_contains "SC_PROMPT customises the prompt" "$out" "CUSTOM_PROMPT_TOKEN>"
}

test_envsubst_expands_variables() {
    if ! command -v envsubst >/dev/null 2>&1; then
        printf '  \033[33mskip\033[0m envsubst variable expansion (envsubst not installed)\n'
        return
    fi
    local out
    export SUBST_VAR="SUBSTITUTED_VALUE"
    out="$(run_script <<'EOF'
# the value is $SUBST_VAR
EOF
)"
    unset SUBST_VAR
    assert_contains "envsubst expands \$VAR in a line" "$out" "the value is SUBSTITUTED_VALUE"
}

# --- Run everything ---------------------------------------------------------
echo "Running showcase.sh test suite..."
echo

test_typed_text_is_shown
test_dollar_command_is_displayed_and_executed
test_silent_command_suppresses_stdout
test_silent_command_side_effect_runs
test_slash_comment_is_ignored
test_unprefixed_line_is_ignored
test_custom_prompt_is_used
test_envsubst_expands_variables

echo
echo "-------------------------------------------"
printf 'Total: %d passed, %d failed\n' "$pass" "$fail"

[[ "$fail" -eq 0 ]]
