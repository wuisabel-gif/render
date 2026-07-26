#!/bin/sh
# Validate shaders/splat_raster.slang without requiring a package manager.
#
# Compiler validation:
#   scripts/validate_slang.sh [--output-dir DIR]
#
# Optional CPU-vs-GPU validation uses commands supplied by the caller. Each
# command must write an identical-sized raw RGB8 file to the path in $OUTPUT.
# The comparison is per byte and accepts an integer absolute tolerance:
#   scripts/validate_slang.sh --cpu-command '...' --gpu-command '...' \
#       --cpu-output cpu.rgb --gpu-output gpu.rgb --tolerance 0
# Commands are deliberately not guessed: this repository has no GPU runtime.

set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SHADER=${SHADER:-"$ROOT/shaders/splat_raster.slang"}
OUT_DIR=${OUT_DIR:-"$ROOT/.shader-validation"}
CPU_COMMAND=
GPU_COMMAND=
CPU_OUTPUT=
GPU_OUTPUT=
TOLERANCE=0

usage() {
    echo "usage: $0 [--output-dir DIR] [--shader FILE]"
    echo "       [--cpu-command CMD --gpu-command CMD --cpu-output FILE --gpu-output FILE]"
    echo "       [--tolerance INTEGER]"
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --output-dir) OUT_DIR=$2; shift 2 ;;
        --shader) SHADER=$2; shift 2 ;;
        --cpu-command) CPU_COMMAND=$2; shift 2 ;;
        --gpu-command) GPU_COMMAND=$2; shift 2 ;;
        --cpu-output) CPU_OUTPUT=$2; shift 2 ;;
        --gpu-output) GPU_OUTPUT=$2; shift 2 ;;
        --tolerance) TOLERANCE=$2; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "error: unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done

if [ ! -f "$SHADER" ]; then
    echo "error: shader not found: $SHADER" >&2
    exit 2
fi
case "$TOLERANCE" in
    ''|*[!0-9]*) echo "error: tolerance must be a non-negative integer" >&2; exit 2 ;;
esac

mkdir -p "$OUT_DIR"
compiled=0
if command -v slangc >/dev/null 2>&1; then
    echo "compiler: $(command -v slangc)"
    slangc --version 2>&1 | sed -n '1p'
    for entry in binTiles rasterizeTiles; do
        output="$OUT_DIR/splat_raster.$entry.spv"
        echo "compile: $entry -> $output"
        if ! slangc -target spirv -entry "$entry" "$SHADER" -o "$output"; then
            echo "FAIL: Slang compiler rejected $SHADER ($entry)" >&2
            exit 1
        fi
        compiled=1
    done
else
    echo "PENDING: slangc is unavailable; SPIR-V compilation was not attempted."
fi

# This is an opt-in path because no runtime, image loader, or tolerance policy
# is part of the current repository. Commands may be wrappers around Vulkan,
# WebGPU, or a future host integration.
if [ -n "$CPU_COMMAND" ] || [ -n "$GPU_COMMAND" ] || [ -n "$CPU_OUTPUT" ] || [ -n "$GPU_OUTPUT" ]; then
    if [ -z "$CPU_COMMAND" ] || [ -z "$GPU_COMMAND" ] || [ -z "$CPU_OUTPUT" ] || [ -z "$GPU_OUTPUT" ]; then
        echo "error: CPU/GPU validation requires both commands and both output paths" >&2
        exit 2
    fi
    echo "running CPU reference command"
    OUTPUT="$CPU_OUTPUT" sh -c "$CPU_COMMAND"
    echo "running GPU command"
    OUTPUT="$GPU_OUTPUT" sh -c "$GPU_COMMAND"
    if [ ! -f "$CPU_OUTPUT" ] || [ ! -f "$GPU_OUTPUT" ]; then
        echo "error: validation commands did not create both raw RGB outputs" >&2
        exit 1
    fi
    cpu_bytes=$(wc -c < "$CPU_OUTPUT")
    gpu_bytes=$(wc -c < "$GPU_OUTPUT")
    if [ "$cpu_bytes" -ne "$gpu_bytes" ]; then
        echo "FAIL: CPU/GPU output sizes differ ($cpu_bytes vs $gpu_bytes bytes)" >&2
        exit 1
    fi
    # od and awk are POSIX utilities. Avoid Python/ImageMagick dependencies.
    cpu_values="$OUT_DIR/cpu.values"
    gpu_values="$OUT_DIR/gpu.values"
    od -An -v -tu1 "$CPU_OUTPUT" > "$cpu_values"
    od -An -v -tu1 "$GPU_OUTPUT" > "$gpu_values"
    mismatch=$(paste "$cpu_values" "$gpu_values" | awk -v tol="$TOLERANCE" '
        {
            half = NF / 2
            for (i = 1; i <= half; ++i) {
                d = $i - $(i + half)
                if (d < 0) d = -d
                if (d > tol) bad++
            }
        }
        END { print bad+0 }
    ')
    if [ "$mismatch" != "0" ]; then
        echo "FAIL: $mismatch raw RGB byte(s) exceed tolerance $TOLERANCE" >&2
        exit 1
    fi
    echo "PASS: CPU/GPU raw RGB comparison (tolerance $TOLERANCE)"
else
    echo "PENDING: no CPU/GPU runtime commands supplied; tolerance validation was not run."
fi

if [ "$compiled" -eq 0 ]; then
    # Pending is intentionally successful for environments without toolchains;
    # it is not a claim that the shader compiled.
    exit 0
fi
echo "PASS: requested Slang entry points compiled to SPIR-V"
exit 0
