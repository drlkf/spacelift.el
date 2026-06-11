# Agents

You are building an Emacs integration package with the Spacelift service. This
service provides a [CLI tool](https://github.com/spacelift-io/spacectl/) called
`spacectl` which can interact with their API; you shall use this tool as backend
to interact with the real world and interpret its results. Request the output to
be formatted with `json` to ease results parsing.

Build the appropriate Lisp structs to contain the objects at runtime. Separate
API functions from display and interactive functions.

You shall display the interactive functions in read-only buffers and define
major modes with dedicated keys to interact. Make sure to have a Spacemacs+evil
friendly set of keys. Make the interactive buffers link to one another e.g the
stack list buffer should lead to the stack buffer when selecting a stack. If
you're unsure about the available data schemas, use the GraphQL API to explore.

DO NOT perform write operations with the CLI, only explore. On write operations,
take your assumptions for granted and let the user report issues.
