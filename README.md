# Wayland Scanner for Odin

This project provides a scanner to generate Wayland client bindings for the Odin programming language.

## Prerequisites

- **Odin Compiler**: [odin-lang.org](https://odin-lang.org)
- **Wayland Protocols**: XML files (e.g `/usr/share/wayland/wayland.xml`, `/usr/share/wayland-protocols/*.xml`).
- **pkg-config** (optional): Used by the generate script to detect the Wayland and Wayland protocols directories.

## Example Usage

### Run the generate script:

```bash
./generate.sh
```

This will:

- Build the scanner (default: `./wayland-scanner`).
- Generate the core Wayland protocol in `./wayland/wayland.odin`.
- Generate all installed protocols found in
  `wayland-protocols/(stable|staging|unstable)` into matching paths under `./wayland/`.

To use a different output directory:

```bash
./generate.sh /path/to/output
```

### Include as a collection in your project:

```bash
odin build -collection:wayland=/path/to/odin-wayland
```

### Build all bundled examples:

```bash
./build-examples.sh
```

Binaries are put in `./examples/bin/`. The script runs `./generate.sh` first.

Direct scanner invocation:

```bash
odin run scanner -- /path/to/protocol.xml /path/to/output.odin -package=my_pkg
```

### Path Configuration

Uses `pkg-config` to locate:

- Core protocol: `wayland.xml` (via `wayland-scanner`).
- Protocols directory (via `wayland-protocols`).

Defaults:

- Core protocol: `/usr/share/wayland/wayland.xml`
- Protocols: `/usr/share/wayland-protocols`

Override:

```bash
export WAYLAND_XML=/custom/path/wayland.xml
export WAYLAND_PROTOCOLS_DIR=/custom/path/wayland-protocols
./generate.sh
```
