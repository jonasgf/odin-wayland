#!/bin/sh

set -eu

EXAMPLES_DIR="examples"
OUTPUT_DIR="examples/bin"
COLLECTION_ROOT="."
EXAMPLES="simple-shm clipboard-monitor"

if [ ! -d "$EXAMPLES_DIR" ]; then
	echo "Examples directory not found: $EXAMPLES_DIR" >&2
	exit 1
fi

rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"

for example_name in $EXAMPLES; do
	example_dir="$EXAMPLES_DIR/$example_name"
	output_path="$OUTPUT_DIR/$example_name"

	echo "$example_dir"
	odin build "$example_dir" -collection:wayland="$COLLECTION_ROOT" -out:"$output_path"
done
