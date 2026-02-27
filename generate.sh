#!/bin/sh

set -eu

OUTPUT_DIR="${1:-wayland}"
SCANNER_SRC="${SCANNER_SRC:-scanner}"
SCANNER_BIN="${SCANNER_BIN:-./wayland-scanner}"

DEFAULT_WAYLAND_XML="/usr/share/wayland/wayland.xml"
DEFAULT_WAYLAND_PROTOCOLS_DIR="/usr/share/wayland-protocols"

if [ -z "${WAYLAND_PROTOCOLS_DIR:-}" ] && command -v pkg-config >/dev/null 2>&1; then
	WAYLAND_PROTOCOLS_DIR=$(pkg-config --variable=pkgdatadir wayland-protocols 2>/dev/null || echo "$DEFAULT_WAYLAND_PROTOCOLS_DIR")
else
	WAYLAND_PROTOCOLS_DIR="${WAYLAND_PROTOCOLS_DIR:-$DEFAULT_WAYLAND_PROTOCOLS_DIR}"
fi

if [ -z "${WAYLAND_XML:-}" ] && command -v pkg-config >/dev/null 2>&1; then
	WAYLAND_XML_DIR=$(pkg-config --variable=pkgdatadir wayland-scanner 2>/dev/null || true)
	if [ -n "$WAYLAND_XML_DIR" ]; then
		WAYLAND_XML="$WAYLAND_XML_DIR/wayland.xml"
	else
		WAYLAND_XML="$DEFAULT_WAYLAND_XML"
	fi
else
	WAYLAND_XML="${WAYLAND_XML:-$DEFAULT_WAYLAND_XML}"
fi

odin build "$SCANNER_SRC" -out:"$SCANNER_BIN"

run_scanner() {
	input_file="$1"
	output_file="$2"
	package_name="${3:-}"
	mkdir -p "$(dirname "$OUTPUT_DIR/$output_file")"
	echo "$input_file"
	if [ -n "$package_name" ]; then
		"$SCANNER_BIN" "$input_file" "$OUTPUT_DIR/$output_file" "-package=$package_name"
	else
		"$SCANNER_BIN" "$input_file" "$OUTPUT_DIR/$output_file"
	fi
}

run_scanner "$WAYLAND_XML" "wayland.odin" "wayland"

for protocol_class in stable staging unstable; do
	class_dir="$WAYLAND_PROTOCOLS_DIR/$protocol_class"
	if [ ! -d "$class_dir" ]; then
		continue
	fi

	find "$class_dir" -type f -name "*.xml" | sort | while read -r xml_file; do
		relative_path="${xml_file#$WAYLAND_PROTOCOLS_DIR/}"
		output_file="${relative_path%.xml}.odin"
		run_scanner "$xml_file" "$output_file"
	done
done
