#!/bin/bash
# Author: https://github.com/jscblack
# Description: This script records performance data using perf and generates a flamegraph.
# Usage: ./perf.sh -P <pid> [-D <duration>] | -E <exec_file_path> [-I]
# Modified: 2024.12.27

# Constants
OUTPUT_DIR="./perf_log"
FLAMEGRAPH_DIR="/path/to/FlameGraph"
CAPTURE_FREQ=499


# Create output directory if it doesn't exist
if [ ! -d "$OUTPUT_DIR" ]; then
    mkdir -p "$OUTPUT_DIR" || { echo "[capture.sh] Error: Failed to create output directory $OUTPUT_DIR."; exit 1; }
fi

# Ensure perf is installed
if ! command -v perf &> /dev/null; then
    echo "[capture.sh] Error: perf is not installed. Please install perf to use this script."
    exit 1
fi

# Ensure FlameGraph tools are available
if [ ! -d "$FLAMEGRAPH_DIR" ]; then
    echo "[capture.sh] Error: FlameGraph directory does not exist at $FLAMEGRAPH_DIR"
    echo "[capture.sh] Hint: Run \"git clone https://github.com/brendangregg/FlameGraph.git $FLAMEGRAPH_DIR\" to download it."
    exit 1
fi

# Function to generate the flamegraph
generate_perf_data() {
    local mode="$1"
    local timestamp=$(date +"%Y%m%d%H%M%S")
    local out_perf="$OUTPUT_DIR/out_${timestamp}.perf"
    local out_folded="$OUTPUT_DIR/out_${timestamp}.folded"
    local output_svg="$OUTPUT_DIR/${mode}_${timestamp}.svg"

    echo "[capture.sh] Converting performance data to readable format..."
    perf script > "$out_perf" || { echo "[capture.sh] Error: Failed to convert performance data."; exit 1; }

    echo "[capture.sh] Collapsing performance data..."
    "$FLAMEGRAPH_DIR/stackcollapse-perf.pl" "$out_perf" > "$out_folded" || { echo "[capture.sh] Error: Failed to collapse performance data."; exit 1; }

    echo "[capture.sh] Generating flamegraph..."
    "$FLAMEGRAPH_DIR/flamegraph.pl" "$out_folded" > "$output_svg" || { echo "[capture.sh] Error: Failed to generate flamegraph."; exit 1; }

    echo "[capture.sh] Flamegraph saved as $output_svg"
    # rm -f perf.data || echo "[capture.sh] Warning: Failed to remove perf.data file."
}

# Signal handlers
handle_sigusr1() {
    echo "[capture.sh] SIGUSR1 received from PID $target_pid: Starting perf record..."
    sleep 1
    perf stat -e cpu-clock,cycles,instructions,branches,branch-misses,LLC-loads,LLC-load-misses,dTLB-loads,dTLB-load-misses -p "$target_pid" &
    PERF_PID=$!
    kill -SIGUSR1 $target_pid
    wait $PERF_PID
    wait $target_pid
}

handle_sigusr2() {
    echo "[capture.sh] SIGUSR2 received from PID $target_pid: Stopping perf record..."
    kill -INT $PERF_PID
    wait $PERF_PID
    wait $target_pid
    exit 0
}

handle_sigkill() {
    echo "[capture.sh] SIGKILL received: Stopping perf record..."
    kill -TERM $PERF_PID
    wait $PERF_PID
    generate_perf_data "pid"
    exit 0
}

# Parse arguments
while getopts ":P:D:E:I" opt; do
    case $opt in
        P) target_pid="$OPTARG"; mode="pid" ;;
        D) duration="$OPTARG" ;;
        E) exec_file_path="$OPTARG"; mode="exec" ;;
        I) interactive=true ;;
        *)
            echo "[capture.sh] Usage: $0 -P <pid> [-D <duration>] | -E <exec_file_path> [-I]"
            exit 1
            ;;
    esac
done

# Validate arguments
if [ "$mode" == "pid" ] && [ -n "$exec_file_path" ]; then
    echo "[capture.sh] Error: -P and -E options are mutually exclusive."
    exit 1
fi
if [ "$mode" == "exec" ] && [ -n "$target_pid" ]; then
    echo "[capture.sh] Error: -E and -P options are mutually exclusive."
    exit 1
fi

if [ "$mode" == "pid" ]; then
    if [ -n "$duration" ]; then
        echo "[capture.sh] Recording performance data for PID $target_pid for $duration seconds..."
        perf record -F "$CAPTURE_FREQ" --call-graph=dwarf -p "$target_pid" -g -- sleep "$duration"
        generate_perf_data "pid"
    else
        echo "[capture.sh] Recording performance data for PID $target_pid. Press Ctrl+C to stop recording..."
        perf record -F "$CAPTURE_FREQ" --call-graph=dwarf -p "$target_pid" -g &
        PERF_PID=$!
        trap handle_sigkill SIGINT
        wait $PERF_PID
        generate_perf_data "pid"
    fi
elif [ "$mode" == "exec" ]; then
    if [ "$interactive" == true ]; then
        echo "[capture.sh] Running in interactive mode, Only support perf stat currently."
        trap handle_sigusr1 SIGUSR1
        trap handle_sigusr2 SIGUSR2
        $exec_file_path &
        target_pid=$!
        wait $target_pid
    else
        echo "[capture.sh] Recording performance data for executable $exec_file_path..."
        perf record -F "$CAPTURE_FREQ" --call-graph=dwarf -g -- $exec_file_path
        generate_perf_data "exec"
    fi
else
    echo "[capture.sh] Error: Invalid mode. Use -P for PID or -E for executable file path."
    exit 1
fi

exit 0
