#!/usr/bin/env bash
# Dependency-light benchmark harness for the CPU and GPU renderers.
#
# A command is a shell template. These tokens are expanded before execution:
#   {count} {width} {height} {resolution} {repeat}
# The same values are also exported as BENCH_GAUSSIANS, BENCH_WIDTH,
# BENCH_HEIGHT, BENCH_RESOLUTION, and BENCH_REPETITION.
#
# A successful invocation is the only source of timing values. Missing commands,
# dry runs, and non-zero exits are recorded as pending/TODO, never as zeroes.

set -u

SCRIPT_NAME=${0##*/}
CPU_COMMAND=''
GPU_COMMAND=''
COUNTS=''
RESOLUTIONS=''
REPETITIONS=1
OUTPUT='benchmarks/results.csv'
DRY_RUN=0

usage() {
    cat <<EOF
Usage: $SCRIPT_NAME [options]

Run caller-supplied commands across gaussian-count and resolution sweeps.
Commands are shell templates and may use {count}, {width}, {height},
{resolution}, and {repeat}. The values are also available in BENCH_* variables.
One command invocation is treated as one frame; wall_seconds and frame_seconds
are measured for that invocation.

Required:
  --cpu-command CMD       CPU command template (optional when GPU is supplied)
  --gpu-command CMD       GPU command template (optional when CPU is supplied)
  --counts LIST           Comma-separated gaussian counts, e.g. 1000,10000
  --resolutions LIST      Comma-separated WxH values, e.g. 640x480,1280x720

Optional:
  --repetitions N         Invocations per case (default: 1)
  --output FILE           CSV destination (default: benchmarks/results.csv)
  --dry-run               Do not execute commands; emit pending rows
  -h, --help              Show this help

Examples:
  $SCRIPT_NAME \\
    --cpu-command './cpu_viewer --gaussians {count} --size {resolution}' \\
    --counts 1000,10000 --resolutions 640x480,1280x720 --repetitions 3

  $SCRIPT_NAME --gpu-command './gpu_viewer --count {count} --width {width} --height {height}' \\
    --counts 1000 --resolutions 1280x720 --dry-run

The CSV contains environment metadata and one row per backend/count/resolution/
repetition. Timing columns contain TODO: run on hardware unless the command
exited successfully and was actually measured on this host. This script makes
no FPS, speedup, or hardware-availability claims.
EOF
}

fail() { printf 'error: %s\n' "$*" >&2; exit 2; }

while [ "$#" -gt 0 ]; do
    case "$1" in
        --cpu-command) [ "$#" -ge 2 ] || fail "--cpu-command needs a value"; CPU_COMMAND=$2; shift 2 ;;
        --gpu-command) [ "$#" -ge 2 ] || fail "--gpu-command needs a value"; GPU_COMMAND=$2; shift 2 ;;
        --counts) [ "$#" -ge 2 ] || fail "--counts needs a value"; COUNTS=$2; shift 2 ;;
        --resolutions) [ "$#" -ge 2 ] || fail "--resolutions needs a value"; RESOLUTIONS=$2; shift 2 ;;
        --repetitions) [ "$#" -ge 2 ] || fail "--repetitions needs a value"; REPETITIONS=$2; shift 2 ;;
        --output) [ "$#" -ge 2 ] || fail "--output needs a value"; OUTPUT=$2; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) fail "unknown option: $1 (use --help)" ;;
    esac
done

[ -n "$COUNTS" ] || fail "--counts is required"
[ -n "$RESOLUTIONS" ] || fail "--resolutions is required"
case "$REPETITIONS" in ''|*[!0-9]*) fail "--repetitions must be a positive integer" ;; esac
[ "$REPETITIONS" -gt 0 ] || fail "--repetitions must be a positive integer"
[ -n "$CPU_COMMAND" ] || [ -n "$GPU_COMMAND" ] || fail "supply --cpu-command and/or --gpu-command"

# date is available on the target platforms. The fallback keeps the harness
# usable where date lacks nanosecond formatting, without pretending to have
# sub-second precision.
now_ns() {
    value=$(date +%s%N 2>/dev/null || date +%s)
    case "$value" in
        *N) printf '%s000000000\n' "$(date +%s)" ;;
        *) printf '%s\n' "$value" ;;
    esac
}

seconds_from_ns() {
    awk -v ns="$1" 'BEGIN { printf "%.9f", ns / 1000000000 }'
}

csv() {
    # RFC 4180-style quoting; empty and TODO values remain ordinary fields.
    local value=$1
    value=$(printf '%s' "$value" | sed 's/"/""/g')
    printf '"%s"' "$value"
}

host=$(hostname 2>/dev/null || printf 'TODO: unavailable')
os_name=$(uname -s 2>/dev/null || printf 'TODO: unavailable')
kernel=$(uname -r 2>/dev/null || printf 'TODO: unavailable')
arch=$(uname -m 2>/dev/null || printf 'TODO: unavailable')
zig_version=$(zig version 2>/dev/null || printf 'TODO: zig unavailable')
cpu_model='TODO: unavailable'
if [ -r /proc/cpuinfo ]; then
    cpu_model=$(awk -F': ' '/model name|Processor/ { print $2; exit }' /proc/cpuinfo)
    [ -n "$cpu_model" ] || cpu_model='TODO: unavailable'
fi
gpu_model='TODO: unavailable'
if [ -r /proc/device-tree/model ]; then
    gpu_model=$(tr -d '\000' < /proc/device-tree/model)
fi
power_mode='TODO: nvpmodel unavailable (not detected or not a Jetson)'
if command -v nvpmodel >/dev/null 2>&1; then
    power_mode=$(nvpmodel -q 2>&1 | tr '\n' ' ')
    [ -n "$power_mode" ] || power_mode='TODO: nvpmodel returned no mode'
fi

dir=${OUTPUT%/*}
[ "$dir" = "$OUTPUT" ] || mkdir -p "$dir"
{
    printf 'timestamp_utc,host,os,kernel,arch,zig_version,cpu_model,gpu_model,power_mode,backend,gaussian_count,width,height,repetition,wall_seconds,frame_seconds,status,command\n'
} > "$OUTPUT" || fail "cannot write $OUTPUT"

timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf 'TODO: unavailable')

run_backend() {
    local backend=$1
    local template=$2
    local count=$3
    local resolution=$4
    local repeat=$5
    local width=${resolution%x*}
    local height=${resolution#*x}
    local command=${template//\{count\}/$count}
    command=${command//\{width\}/$width}
    command=${command//\{height\}/$height}
    command=${command//\{resolution\}/$resolution}
    command=${command//\{repeat\}/$repeat}
    local status='pending'
    local wall='TODO: run on hardware'
    local frame='TODO: run on hardware'

    export BENCH_GAUSSIANS=$count BENCH_WIDTH=$width BENCH_HEIGHT=$height
    export BENCH_RESOLUTION=$resolution BENCH_REPETITION=$repeat
    if [ "$DRY_RUN" -eq 1 ]; then
        status='pending: dry-run'
    else
        local start end elapsed_ns
        start=$(now_ns)
        bash -c "$command" >&2
        local exit_code=$?
        end=$(now_ns)
        elapsed_ns=$((end - start))
        if [ "$exit_code" -eq 0 ]; then
            wall=$(seconds_from_ns "$elapsed_ns")
            frame=$wall
            status='measured'
        else
            status="pending: command exited $exit_code"
        fi
    fi

    csv "$timestamp"; printf ','; csv "$host"; printf ','; csv "$os_name"; printf ','
    csv "$kernel"; printf ','; csv "$arch"; printf ','; csv "$zig_version"; printf ','
    csv "$cpu_model"; printf ','; csv "$gpu_model"; printf ','; csv "$power_mode"; printf ','
    csv "$backend"; printf ','; csv "$count"; printf ','; csv "$width"; printf ','; csv "$height"; printf ','
    csv "$repeat"; printf ','; csv "$wall"; printf ','; csv "$frame"; printf ','; csv "$status"; printf ','
    csv "$command"; printf '\n'
}

# Append rows through a grouped redirection, so stdout remains the progress log.
for backend in cpu gpu; do
    case "$backend" in
        cpu) template=$CPU_COMMAND ;;
        gpu) template=$GPU_COMMAND ;;
    esac
    [ -n "$template" ] || continue
    IFS=',' read -r -a count_values <<< "$COUNTS"
    IFS=',' read -r -a resolution_values <<< "$RESOLUTIONS"
    for count in "${count_values[@]}"; do
        [ -n "$count" ] || fail "empty gaussian count"
        case "$count" in *[!0-9]*) fail "invalid gaussian count: $count" ;; esac
        for resolution in "${resolution_values[@]}"; do
            case "$resolution" in
                *x*) width=${resolution%x*}; height=${resolution#*x} ;;
                *) fail "invalid resolution (expected WxH): $resolution" ;;
            esac
            case "$width:$height" in *[!0-9:]*|:*) fail "invalid resolution: $resolution" ;; esac
            for ((repeat=1; repeat<=REPETITIONS; repeat++)); do
                printf '%s %s %sx%s repetition %s\n' "$backend" "$count" "$width" "$height" "$repeat" >&2
                run_backend "$backend" "$template" "$count" "$resolution" "$repeat" >> "$OUTPUT"
            done
        done
    done
done

printf 'Wrote %s\n' "$OUTPUT"
if [ "$DRY_RUN" -eq 1 ]; then
    printf 'Pending dry-run only: no benchmark commands were executed.\n' >&2
fi
exit 0
