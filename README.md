# spacelift.el

This package interacts with [Spacelift](https://spacelift.io/) using `spacectl`
as backend.

To get started, make sure `spacectl` is available and configured, for instance with:

```
spacectl profile login my-app
```

You can also log in from Emacs: if `spacectl` is not authenticated when you open
a Spacelift buffer, the package offers to run `spacectl profile login` for you in
a terminal buffer. Complete the interactive flow there, then retry the command.
`M-x spacelift-profile-login` runs the login flow on demand.

## Usage

Load the package and call one of the entry points:

- `M-x spacelift-stack-list-stacks` opens a buffer listing your stacks. With a
prefix argument (`C-u`), you are prompted for a full-text search string.
- `M-x spacelift-stack-show-buffer` prompts for a stack id and opens its detail
buffer directly.
- `M-x spacelift-run-list-buffer` prompts for a stack id and opens a buffer
listing that stack's runs.

In the stack list buffer, press `RET` on a stack to open its detail buffer, or
`R` to open its run list. In a run list buffer, press `RET` on a run to open its
detail buffer.

Stack list and stack detail buffers:

| Key   | Action               |
|-------|----------------------|
| `r`   | Reload the buffer    |
| `q`   | Quit the window      |
| `?`   | Show a magit-style popup of the available keys |
| `RET` | Visit the stack (list buffer only) |
| `R`   | Open the stack's run list |
| `w`   | Browse the stack in the Spacelift console |
| `j`/`k`, `n`/`p` | Move down/up (list buffer) |

Run list and run detail buffers:

| Key   | Action               |
|-------|----------------------|
| `r`   | Reload the buffer    |
| `q`   | Quit the window      |
| `?`   | Show a magit-style popup of the available keys |
| `RET` | Visit the run (list buffer only) |
| `w`   | Browse the run URL in the Spacelift console |
| `j`/`k`, `n`/`p` | Move down/up (list buffer) |

These bindings work both with vanilla Emacs and with `evil-mode`. When `evil`
is loaded, the keys are bound in the `motion` and `normal` states so they are
not shadowed by evil; navigation uses evil's own `j`/`k`. The `g` key is
deliberately left to evil (e.g. `gg`), so use `r` to reload.

## Customization

- `spacelift-spacectl-executable`: path to the `spacectl` binary.
- `spacelift-profile`: profile alias selected via `spacectl profile select`
before each command (uses the current profile when nil).
- `spacelift-login-offer`: when non-nil (the default), offer to log in when
`spacectl` is not authenticated.
- `spacelift-stack-line-format`: format string for a stack line.
- `spacelift-run-line-format`: format string for a run line.
- `spacelift-run-list-max-results`: default maximum number of runs fetched.

Stack line specifiers:

| Spec | Meaning            |
|------|--------------------|
| `%n` | stack name         |
| `%i` | stack id (slug)    |
| `%s` | current state      |
| `%b` | tracked branch     |
| `%p` | worker pool name   |
| `%r` | repository         |
| `%S` | space name         |
| `%d` | description        |
| `%l` | comma-separated labels |

Run line specifiers:

| Spec | Meaning            |
|------|--------------------|
| `%i` | run id             |
| `%s` | current state      |
| `%t` | run title          |
| `%b` | branch             |
| `%c` | short commit hash  |
| `%a` | commit author      |
| `%d` | creation date      |
| `%T` | trigger source     |
| `%D` | resource delta (added/changed/deleted) |

Width and alignment flags are supported, e.g. `%-30n`.

## Files

- `spacelift-core.el`: low-level `spacectl` invocation, JSON parsing, and
console URL helpers.
- `spacelift-stack.el`: stack structs and API functions.
- `spacelift-run.el`: run structs and API functions.
- `spacelift-ui.el`: interactive buffers and major modes.
- `spacelift.el`: top-level entry point.
