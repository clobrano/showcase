# Showcase Demo Tool

This tool simplifies the creation of engaging and repeatable software demonstrations by simulating real-time typing from a script.

[Watch the demo](https://youtu.be/nu-qY67qPzM)

## Requirements

* **bash** (4.0+ for `mapfile`).
* **pv** — used to animate the "typing" effect. Optional: if `pv` is not
  installed the text is printed instantly instead of being animated.
* **envsubst** (from `gettext`) — used to expand environment variables inside
  script lines. Optional: if it is not installed, lines are used verbatim.

On Debian/Ubuntu: `sudo apt-get install pv gettext-base`.

## Usage

```bash
./showcase.sh demo.txt
```

### Dry run

Use `--dry-run` to rehearse a demo without touching the system: the commands
are still printed on screen, but their execution is skipped. Because a script
has two kinds of commands — visible (`$`) and silent (`!`) — you can choose
which kind to skip:

```bash
./showcase.sh --dry-run demo.txt          # skip every command ("all")
./showcase.sh --dry-run=all demo.txt      # same as above
./showcase.sh --dry-run=visible demo.txt  # skip only the visible '$' commands
./showcase.sh --dry-run=silent demo.txt   # skip only the silent '!' commands
```

The same behavior can be set from the environment with `SC_DRY_RUN` (`all`,
`visible`, or `silent`):

```bash
SC_DRY_RUN=visible ./showcase.sh demo.txt
```

Note that silent commands are often used for setup (e.g. `export SC_PROMPT=...`,
`sleep`); skipping them (`all` or `silent`) also skips that setup. Use
`--dry-run=visible` when you want the setup to run but the visible demo
commands to be shown without executing.

## Key Features

* **Script-Driven Demos:** Create demos by writing a simple script. Lines in the script are "typed" out as if a user were entering them.
* **Live Command Execution:** Embed and execute shell commands **live** during the demo. The command is displayed, followed by its **real-time** output. This ensures the demo reflects the current system state, not a pre-recorded result.
* **Silent Commands:** Execute commands without displaying their output, useful for setup and cleanup tasks within the demo.
* **Repeatable Demos:** Ensure consistent and error-free demonstrations every time. You can test and refine your script before any presentation.
* **Easy Preparation:** Demos are much easier and faster to prepare compared to live typing, reducing the risk of mistakes and saving time.

## Script Syntax

* `#` Lines starting with a hashtag are displayed as if being typed.
* `$` Lines starting with a dollar sign are executed as shell commands **live**. The command and its output are displayed.
* `!` Lines starting with an exclamation mark are executed as shell commands, but the output is suppressed. Useful to setup the demo environment and introduce the necessary pauses (e.g. `sleep 1`).
* `//` Lines starting with a double slash are comments: they are ignored and never displayed. (Any non-empty line that does not start with one of the markers above is also ignored.)
* An **empty line** renders as an empty line during replay, as if the user had pressed Enter at the prompt. Use blank lines in your script to add breathing room to the demo.

### Multiline commands

A command line (`$` or `!`) continues onto the following lines exactly like in
a shell: when it ends with a backslash (`\`), or when it ends with a pipe
(`|`) or a logical operator (`&&`, `||`). Any stray trailing whitespace after
the continuation character is ignored, so an invisible space after a `\` (a
common editing mistake, especially after a pipe) won't break the command. The
lines are joined into a single command that is displayed (for `$`) as written
and then executed as one:

```
$ osac create computeinstance \
    --name default-vm \
    --catalog-item ${CI_ID1} \
    --network-attachment subnet=${SUBNET_ID} && \
  osac get computeinstance default-vm --watch
```

### Playback controls (keys)

During a live demo you can drive the flow from the keyboard. Handling happens
at checkpoints **between** steps, so a command that is already running is never
interrupted — only the visible/silent flow is affected (as you'd expect: you
can't "pause" a command that has already started):

| Key | Action |
| --- | ------ |
| `p` | Pause / resume the demo. Pressing `p` while a command is being typed out stops the demo **just before that command runs**, so it is shown but not executed until you press `p` again. |
| `s` | **Slower**: use the base typing speed `SC_SPEED` (the default pace). |
| `f` | **Faster**: use the `SC_SPEED_FAST` preset. |

The base speed is `SC_SPEED` — the slow, default pace. Pressing `f` temporarily
speeds typing up to `SC_SPEED_FAST`; pressing `s` drops back to `SC_SPEED`.
Speed changes take effect from the next typed line onward, so you can speed
through boilerplate and slow down for the important command. A speed key pressed
while paused is applied when you resume.

**The script wins.** If the script itself changes the speed mid-demo (a silent
`! export SC_SPEED=...` command), that takes priority over the keys: it becomes
the new base pace and clears any `f`/`s` override in effect. You can still press
`f`/`s` again afterwards to adjust from there, until the script changes the
speed once more.

Keys are only read from an interactive terminal, so a piped or redirected
`stdin` (which belongs to the demo's own commands) is never consumed. Terminal
echo is turned off while the tool is in control so your control keys don't
appear on screen, and it is restored around every live command (so interactive
programs still work) and on exit. Set `SC_KEYS=0` to disable key handling
entirely.

## Configuration

You can customize the demo's behavior using environment variables:

* `SC_PROMPT`: Sets the prompt string displayed before commands (e.g., `$ `, `>` ) (default `[showcase user]`).
* `SC_SPEED`: The base typing speed; a higher number types faster (default = 10). This is the "slow" pace the `s` key returns to.
* `SC_SPEED_FAST`: The faster typing speed the `f` key switches to (default = 40).
* `SC_KEYS`: Set to `0` to disable the interactive [playback keys](#playback-controls-keys) (default = enabled). See above.
* `SC_DRY_RUN`: Skips execution of commands while still printing them (`all`,
  `visible`, or `silent`; empty/unset means execute everything). Equivalent to
  the `--dry-run[=MODE]` flag. See [Dry run](#dry-run) above.

These variables can also be set within the demo script itself using silent commands (`!`) at the beginning, allowing for dynamic configuration.

## Benefits

* **Improved Demo Quality:** Deliver polished and professional demos.
* **Reduced Preparation Time:** Create complex demos quickly and efficiently.
* **Increased Confidence:** Eliminate the stress of live typing and potential errors.
* **Enhanced Audience Engagement:** Keep the audience focused with a clear and dynamic presentation.
* **Easy Testing:** Thoroughly test the demo script before presenting to ensure everything works as expected.
* **Demonstrates Live Interaction:** Clearly shows the tool interacting with the system in real-time, proving its functionality.

## Example

(Refer to the `demo.txt` file for a complete example)

## Testing

A self-contained test suite (pure bash, no external framework needed) lives in
`tests/`:

```bash
./tests/run.sh
```

It sources `showcase.sh` and exercises each line type (`#`, `$`, `!`, `//`),
multiline (backslash-continued) commands, prompt configuration, and variable
expansion. The suite runs even without `pv`
or `envsubst` installed (the `envsubst`-specific test is skipped in that case).
Tests also run in CI via GitHub Actions (see `.github/workflows/test.yml`).
