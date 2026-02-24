# Examples for Wayland Scanner for Odin

This directory contains example programs demonstrating usage of the generated Wayland bindings.

## Examples

- `simple-window`: Creates a basic Wayland window using `xdg-shell`.
- `clipboard-monitor`: Monitors for clipboard changes using `data-control`.

## Building and Running

From the project root:

```bash
# 1) Generate bindings
./generate.sh

# 2) Build all examples into examples/bin/
./build-examples.sh

# 3) Run examples
./examples/bin/simple-window
./examples/bin/clipboard-monitor
```

Or run directly without keeping binaries:

```bash
odin run examples/simple-window -collection:wayland=.
odin run examples/clipboard-monitor -collection:wayland=.
```
