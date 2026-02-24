#!/bin/sh

set -eu

EXAMPLES_DIR="${1:-examples}"
OUTPUT_DIR="${2:-examples/bin}"
COLLECTION_ROOT="${COLLECTION_ROOT:-.}"

if [ ! -d "$EXAMPLES_DIR" ]; then
	echo "Examples directory not found: $EXAMPLES_DIR" >&2
	exit 1
fi

echo "Generating bindings required by examples..."
sh ./generate.sh

rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"

built=0

for example_dir in "$EXAMPLES_DIR"/*; do
	[ -d "$example_dir" ] || continue

	if ! find "$example_dir" -maxdepth 1 -type f -name "*.odin" | grep -q .; then
		continue
	fi

	example_name="$(basename "$example_dir")"
	output_path="$OUTPUT_DIR/$example_name"

	echo "$example_dir -> $output_path"
	odin build "$example_dir" -collection:wayland="$COLLECTION_ROOT" -out:"$output_path"
	built=$((built + 1))
done

if [ "$built" -eq 0 ]; then
	echo "No buildable examples found in $EXAMPLES_DIR" >&2
	exit 1
fi

echo "Built $built example(s) into $OUTPUT_DIR"
