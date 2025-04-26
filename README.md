# Showcase Demo Tool

This tool simplifies the creation of engaging and repeatable software demonstrations by simulating real-time typing from a script.

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

## Configuration

You can customize the demo's behavior using environment variables:

* `SC_PROMPT`: Sets the prompt string displayed before commands (e.g., `$ `, `>` ) (default `[showcase user]`).
* `SC_SPEED`: Controls the typing speed (default = 10).

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
