# spacelift.el

This package interacts with [Spacelift](https://spacelift.io/) using `spacectl`
as backend.

To get started, make sure `spacectl` is available and configured, for instance with:

```
spacectl profile login my-app
```

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

## Customization

- `spacelift-spacectl-executable`: path to the `spacectl` binary.
- `spacelift-profile`: profile passed as `--profile` (default profile when nil).
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
