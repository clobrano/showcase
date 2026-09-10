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

test_silent_clear_reaches_the_terminal() {
    # Regression: silent commands redirect stdout to /dev/null, but `clear`
    # works by writing escape sequences to stdout — so `! clear` must be
    # exempt from that redirect or it silently does nothing. Here `clear` is
    # overridden to emit a marker on stdout; finding it proves the redirect
    # was skipped for `! clear`.
    local out
    clear() { printf 'CLEAR_TOKEN'; }
    out="$(run_script <<'EOF'
! clear
EOF
)"
    clear() { :; }  # restore the no-op override for later tests
    assert_contains "'! clear' stdout reaches the terminal" "$out" "CLEAR_TOKEN"
}

test_silent_command_suppresses_non_clear_stdout() {
    # The clear exemption must be narrow: a silent command that merely
    # contains the word "clear" (but isn't the bare `clear` command) still has
    # its stdout suppressed like any other silent command.
    local out
    out="$(run_script <<'EOF'
! echo clear NOISE_TOKEN
EOF
)"
    assert_not_contains "'!' non-clear command stdout is still suppressed" \
        "$out" "NOISE_TOKEN"
}

test_slash_comment_is_ignored() {
    local out
    out="$(run_script <<'EOF'
// SLASH_COMMENT_TOKEN
EOF
)"
    assert_not_contains "'//' comment line is ignored" "$out" "SLASH_COMMENT_TOKEN"
}

test_commands_read_callers_stdin_not_the_script() {
    # Regression test: run() must not feed the script file to commands as
    # stdin (an earlier `done < "$filepath"` bug did exactly that, so a
    # command like `read`/`ssh` would swallow the script instead of the
    # caller's input). A command that reads stdin should see what the caller
    # piped into run(), not the first line of the script.
    # `cat` echoes whatever stdin it is given. With the caller piping a known
    # token into run(), a working tool echoes that token; the buggy redirect
    # would instead make `cat` echo the script file's own contents.
    local f out
    f="$(mktemp)"
    cat >"$f" <<'EOF'
$ cat
EOF
    out="$(printf 'CALLER_STDIN_9F3A\n' | run "$f" 2>&1)"
    rm -f "$f"
    assert_contains "commands read the caller's stdin, not the script file" \
        "$out" "CALLER_STDIN_9F3A"
}

test_unprefixed_line_is_ignored() {
    local out
    out="$(run_script <<'EOF'
UNPREFIXED_TOKEN with no leading marker
EOF
)"
    assert_not_contains "unprefixed line is ignored" "$out" "UNPREFIXED_TOKEN"
}

test_dollar_multiline_command_is_joined_and_executed() {
    # A '$' command whose line ends with a backslash continues onto the
    # following lines (just like a shell), and the whole thing runs as one
    # command. Here the two printf calls are joined with && across three
    # physical lines.
    local out
    out="$(run_script <<'EOF'
$ printf 'FIRST_HALF_' && \
  printf 'SECOND_HALF' && \
  printf '\n'
EOF
)"
    # The joined command runs as a single pipeline: both halves appear.
    assert_contains "'\$' multiline command executes joined" "$out" "FIRST_HALF_SECOND_HALF"
    # The command is also typed out, continuation lines and all.
    assert_contains "'\$' multiline command is displayed" "$out" "printf 'SECOND_HALF'"
}

test_silent_multiline_command_side_effect_runs() {
    # A silent '!' command may also span multiple lines via trailing
    # backslashes; the joined command still runs (with stdout suppressed).
    local marker out
    marker="$(mktemp -u)"
    out="$(run_script <<EOF
! printf 'multi' > "$marker" && \\
  printf 'line' >> "$marker"
EOF
)"
    assert_file_exists "'!' multiline command still runs (side effect)" "$marker"
    if [[ -f "$marker" ]]; then
        assert_contains "'!' multiline command joins all parts" \
            "$(cat "$marker")" "multiline"
    fi
    rm -f "$marker"
}

test_multiline_command_does_not_consume_following_lines() {
    # A command without a trailing backslash must NOT swallow the next line;
    # the '#' text after it should still be typed.
    local out
    out="$(run_script <<'EOF'
$ printf 'NO_CONT\n'
# AFTER_TOKEN
EOF
)"
    assert_contains "single-line '\$' command executes" "$out" "NO_CONT"
    assert_contains "line after a non-continued command is still processed" \
        "$out" "AFTER_TOKEN"
}

test_empty_line_prints_blank_line() {
    # An empty line in the script should render as an empty line during
    # replay (as if the user pressed Enter), rather than being ignored.
    local out
    SC_PROMPT="PROMPT> "
    out="$(run_script <<'EOF'
# BEFORE_BLANK

# AFTER_BLANK
EOF
)"
    SC_PROMPT="[showcase user] $ "  # restore default for later tests
    # Pressing Enter finishes the current prompt line and redraws a fresh
    # prompt, so the next line's content is preceded by its own prompt.
    assert_contains "empty script line redraws the prompt (press Enter)" \
        "$out" $'PROMPT> \nPROMPT> # AFTER_BLANK'
}

test_empty_line_before_prompt_setup_emits_no_stray_prompt() {
    # A blank line that appears before the prompt is configured must not
    # print a stray default prompt (regression: it used to emit the default
    # "[showcase user] $" right before the custom prompt was set up).
    local out
    out="$(run_script <<'EOF'

! export SC_PROMPT="CUSTOM_ONLY> "
! export SC_SPEED=1000000
# HELLO_TOKEN
EOF
)"
    assert_not_contains "blank line before setup prints no default prompt" \
        "$out" "[showcase user]"
    assert_contains "custom prompt appears once configured" \
        "$out" "CUSTOM_ONLY>"
}

test_backslash_continuation_tolerates_trailing_whitespace() {
    # A stray space after a continuation backslash ("cmd \ ") must not break
    # the join. Regression: the old check only matched a backslash at the very
    # end of the line, so trailing whitespace dropped the continuation and the
    # shell read "\ " as an escaped space (mangling or hanging the command).
    # The output token (QQQ) never appears in the typed command, so finding it
    # proves the joined command actually ran.
    local f out
    f="$(mktemp)"
    # NOTE: the first line intentionally ends with a backslash + a space.
    printf '%s\n%s\n' "\$ printf 'zzz' | \\ " "  tr 'z' 'Q'" >"$f"
    out="$(run "$f" </dev/null 2>&1)"
    rm -f "$f"
    assert_contains "trailing whitespace after '\\' still continues the command" \
        "$out" "QQQ"
}

test_trailing_pipe_continues_command() {
    # A line ending in a pipe continues onto the next line, exactly like an
    # interactive shell, even without a trailing backslash.
    local out
    out="$(run_script <<'EOF'
$ printf 'zzz' |
  tr 'z' 'Q'
EOF
)"
    assert_contains "a line ending in '|' continues onto the next line" \
        "$out" "QQQ"
}

test_trailing_logical_operator_continues_command() {
    # A line ending in '&&' (or '||') also continues onto the next line.
    local out
    out="$(run_script <<'EOF'
$ printf 'aa' &&
  printf 'bb'
EOF
)"
    assert_contains "a line ending in '&&' continues onto the next line" \
        "$out" "aabb"
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
test_silent_clear_reaches_the_terminal
test_silent_command_suppresses_non_clear_stdout
test_slash_comment_is_ignored
test_commands_read_callers_stdin_not_the_script
test_unprefixed_line_is_ignored
test_dollar_multiline_command_is_joined_and_executed
test_silent_multiline_command_side_effect_runs
test_multiline_command_does_not_consume_following_lines
test_empty_line_prints_blank_line
test_empty_line_before_prompt_setup_emits_no_stray_prompt
test_backslash_continuation_tolerates_trailing_whitespace
test_trailing_pipe_continues_command
test_trailing_logical_operator_continues_command
test_custom_prompt_is_used
test_envsubst_expands_variables

echo
echo "-------------------------------------------"
printf 'Total: %d passed, %d failed\n' "$pass" "$fail"

[[ "$fail" -eq 0 ]]
