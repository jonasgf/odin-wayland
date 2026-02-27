# Examples

- `simple-shm`: Creates a basic Wayland window using `xdg-shell`.
- `clipboard-monitor`: Monitors for clipboard changes using `data-control`.

## Building and Running

From the project root:

```bash
# 1) Generate bindings
./generate.sh

# 2) Build examples
./build-examples.sh

# 3) Run examples
./examples/bin/simple-shm
./examples/bin/clipboard-monitor
```

Or run directly without keeping binaries:

```bash
odin run examples/simple-shm -collection:wayland=.
odin run examples/clipboard-monitor -collection:wayland=.
```
