#!/bin/bash
# Author: https://github.com/jscblack
# Description: This script records performance data using perf and generates a flamegraph.
# Usage: ./perf.sh <pid|exec_file_path> [duration]
# Modified: 2024.06.05

# 定义输出目录
# 默认就在运行的位置
OUTPUT_DIR="./perf_log"
FLAMEGRAPH_DIR="/path/to/FlameGraph"
CAPTURE_FREQ=200

# 检查输出目录是否存在，如果不存在则创建它
if [ ! -d "$OUTPUT_DIR" ]; then
    mkdir -p "$OUTPUT_DIR"
    if [ $? -ne 0 ]; then
        echo "Error: Failed to create output directory $OUTPUT_DIR."
        exit 1
    fi
fi

# 检查perf命令是否安装
if ! command -v perf &> /dev/null; then
    echo "Error: perf is not installed. Please install perf to use this script."
    exit 1
fi

# 检查FlameGraph工具是否存在
if [ ! -d "$FLAMEGRAPH_DIR" ]; then
    echo "Error: FlameGraph directory does not exist at $FLAMEGRAPH_DIR"
    echo "Hint: Run \"git clone https://github.com/brendangregg/FlameGraph.git "$FLAMEGRAPH_DIR"\" to download it."
    exit 1
fi

# 检查参数个数
if [ $# -lt 1 ] || [ $# -gt 2 ]; then
    echo "Usage: $0 <pid|exec_file_path> [duration]"
    exit 1
fi

first_arg="$1"
duration="$2"
timestamp=$(date +"%Y%m%d%H%M%S")  # 获取当前时间戳

# 判断第一个参数是PID还是可执行文件路径
if [[ $first_arg =~ ^[0-9]+$ ]]; then
    pid=$first_arg
    mode="pid"
elif [ -f "$first_arg" ]; then
    exec_file_path=$first_arg
    mode="exec"
else
    echo "Error: The first argument must be a PID or a valid file path to an executable."
    exit 1
fi

handle_sigint() {
    echo "Interrupt signal received. Stopping perf record..."
    # Send SIGINT to the perf process
    kill -INT $PERF_PID
    wait $PERF_PID
    perf_exit_code=$?
    # 如果perf因为SIGINT退出，则允许脚本继续执行
    if [ $perf_exit_code -eq 130 ]; then
        generate_perf_data
    fi
    exit 0
}

generate_perf_data() {
    # 在输出目录下定义输出文件的名称
    out_perf="$OUTPUT_DIR/out_${timestamp}.perf"
    out_folded="$OUTPUT_DIR/out_${timestamp}.folded"
    output_svg="$OUTPUT_DIR/${mode}_${timestamp}.svg"

    # 将性能数据转换为可读格式
    echo "Converting performance data to readable format..."
    perf script > "$out_perf"
    if [ $? -ne 0 ]; then
        echo "Error: Failed to convert performance data."
        exit 1
    fi

    # 折叠性能数据
    echo "Collapsing performance data..."
    "$FLAMEGRAPH_DIR/stackcollapse-perf.pl" "$out_perf" > "$out_folded"
    if [ $? -ne 0 ]; then
        echo "Error: Failed to collapse performance data."
        exit 1
    fi

    # 生成火焰图
    echo "Generating flamegraph..."
    "$FLAMEGRAPH_DIR/flamegraph.pl" "$out_folded" > "$output_svg"
    if [ $? -ne 0 ]; then
        echo "Error: Failed to generate flamegraph."
        exit 1
    fi

    echo "Flamegraph saved as $output_svg"

    # 删除 perf.data 文件
    echo "Cleaning up perf.data file..."
    rm perf.data
    if [ $? -ne 0 ]; then
        echo "Error: Failed to remove perf.data file."
        exit 1
    fi
}

# 设置一个信号陷阱，当接收到SIGINT信号时会调用一个函数来处理它
trap handle_sigint INT

# 根据mode执行perf record
if [ "$mode" == "pid" ]; then
    # 根据是否有持续时间来执行perf record
    if [ -n "$duration" ]; then
        echo "Recording performance data for PID $pid for $duration seconds..."
        perf record -F "$CAPTURE_FREQ" -p "$pid" -g -- sleep "$duration"
    else
        echo "Recording performance data for PID $pid. Press Ctrl+C to stop recording..."
        perf record -F "$CAPTURE_FREQ" -p "$pid" -g &
        PERF_PID=$!
        # 等待perf进程结束
        wait $PERF_PID
    fi
elif [ "$mode" == "exec" ]; then
    echo "Recording performance data for executable at path $exec_file_path..."
    # 在后台执行perf并运行可执行文件
    if [ -n "$duration" ]; then
        perf record -F "$CAPTURE_FREQ" -g -- "$exec_file_path" &
        PERF_PID=$!
        sleep "$duration"
        kill -INT $PERF_PID
        wait $PERF_PID
    else
        perf record -F "$CAPTURE_FREQ" -g -- "$exec_file_path"
    fi
fi

# 从这里开始，我们假设perf record已经正常退出，所以可以生成性能数据
generate_perf_data
exit 0
