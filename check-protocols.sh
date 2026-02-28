#!/bin/sh

set -eu

GENERATED_DIR="${1:-wayland}"
COLLECTION_ROOT="${COLLECTION_ROOT:-.}"
GENERATE_SCRIPT="${GENERATE_SCRIPT:-./generate.sh}"

if [ ! -f "$GENERATE_SCRIPT" ]; then
	echo "Generate script not found: $GENERATE_SCRIPT" >&2
	exit 1
fi

echo "Generating protocols into $GENERATED_DIR ..."
"$GENERATE_SCRIPT" "$GENERATED_DIR"

if [ ! -d "$GENERATED_DIR" ]; then
	echo "Generated directory not found after generation: $GENERATED_DIR" >&2
	exit 1
fi

TOTAL=0
FAIL=0

for protocol_file in $(find "$GENERATED_DIR" -type f -name "*.odin" | sort); do
	TOTAL=$((TOTAL + 1))
	if ! odin check "$protocol_file" -file -no-entry-point -collection:wayland="$COLLECTION_ROOT" >/dev/null 2>&1; then
		FAIL=$((FAIL + 1))
		echo "FAIL $protocol_file" >&2
	fi
done

echo "Checked $TOTAL protocol files."

if [ "$FAIL" -ne 0 ]; then
	echo "Protocol check failures: $FAIL" >&2
	exit 1
fi

echo "All protocol files type-check."
