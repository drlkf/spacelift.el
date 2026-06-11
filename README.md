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

In the stack list buffer, press `RET` on a stack to open its detail buffer.

In every buffer:

| Key   | Action               |
|-------|----------------------|
| `r`   | Reload the buffer    |
| `q`   | Quit the window      |
| `RET` | Visit the stack (list buffer only) |
| `j`/`k`, `n`/`p` | Move down/up (list buffer) |

These bindings work both with vanilla Emacs and with `evil-mode`. When `evil`
is loaded, `r`, `q` and `RET` are bound in the `motion` and `normal` states so
they are not shadowed by evil; navigation uses evil's own `j`/`k`. The `g` key
is deliberately left to evil (e.g. `gg`), so use `r` to reload.

## Customization

- `spacelift-spacectl-executable`: path to the `spacectl` binary.
- `spacelift-profile`: profile alias selected via `spacectl profile select`
before each command (uses the current profile when nil).
- `spacelift-login-offer`: when non-nil (the default), offer to log in when
`spacectl` is not authenticated.
- `spacelift-stack-line-format`: format string for a stack line.

Supported specifiers:

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

Width and alignment flags are supported, e.g. `%-30n`.

## Files

- `spacelift-core.el`: low-level `spacectl` invocation and JSON parsing.
- `spacelift-stack.el`: stack structs and API functions.
- `spacelift-ui.el`: interactive buffers and major modes.
- `spacelift.el`: top-level entry point.
