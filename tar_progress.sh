#!/usr/bin/env bash
# ============================================================================
# tar_progress.sh - Monitor tar compress/decompress progress in real-time
# ============================================================================
# Original author: ddcw (https://github.com/ddcw)
# Modified: Added compression progress monitoring, bzip2/zstd support
# License: MIT
# 
# Supported compression formats:
#   - gzip  (.tar.gz)  : tar -zcvf / tar -xzf
#   - pigz  (.tar.gz)  : tar -cf - dir | pigz > file.tar.gz (parallel gzip)
#   - xz    (.tar.xz)  : tar -Jcvf / tar -xJf
#   - bzip2 (.tar.bz2) : tar -jcvf / tar -xjf
#   - pbzip2(.tar.bz2) : tar -cf - dir | pbzip2 > file.tar.bz2 (parallel bzip2)
#   - zstd  (.tar.zst) : tar --zstd -cvf / tar --zstd -xf
#
# Requirements:
#   - Linux with /proc filesystem
#   - bash 4.0+
#   - Standard tools: awk, stat, pidof
# ============================================================================

set -uo pipefail

export LANG="en_US.UTF-8"

# Configuration
SLEEP_INTERVAL=${TAR_PROGRESS_INTERVAL:-0.1}
BAR_WIDTH=${TAR_PROGRESS_BAR_WIDTH:-50}

# Colors (can be disabled with NO_COLOR=1)
if [[ -z "${NO_COLOR:-}" ]] && [[ -t 1 ]]; then
    COLOR_GREEN="\033[32m"
    COLOR_YELLOW="\033[33m"
    COLOR_BLUE="\033[34m"
    COLOR_RESET="\033[0m"
else
    COLOR_GREEN=""
    COLOR_YELLOW=""
    COLOR_BLUE=""
    COLOR_RESET=""
fi

# ============================================================================
# Utility Functions
# ============================================================================

# Format file size to human readable (decimal, 1000-based)
format_size() {
    local size=${1:-0}
    # 处理空值或非数字
    if [[ -z "$size" ]] || ! [[ "$size" =~ ^[0-9]+$ ]]; then
        size=0
    fi
    awk -v size="$size" 'BEGIN {
        if (size < 0) size = 0
        if (size < 1000) printf "%.2f B", size
        else if (size < 1000*1000) printf "%.2f KB", size/1000
        else if (size < 1000*1000*1000) printf "%.2f MB", size/1000/1000
        else printf "%.2f GB", size/1000/1000/1000
    }'
}

# Format transfer rate (decimal, 1000-based)
format_rate() {
    local rate=${1:-0}
    # 处理空值或非数字
    if [[ -z "$rate" ]] || ! [[ "$rate" =~ ^-?[0-9]+$ ]]; then
        rate=0
    fi
    awk -v rate="$rate" 'BEGIN {
        if (rate < 0) rate = 0
        if (rate < 1000) printf "%.2f B/s", rate
        else if (rate < 1000*1000) printf "%.2f KB/s", rate/1000
        else if (rate < 1000*1000*1000) printf "%.2f MB/s", rate/1000/1000
        else printf "%.2f GB/s", rate/1000/1000/1000
    }'
}

# Format time duration
format_time() {
    local seconds=${1:-0}
    # 处理空值或非数字
    if [[ -z "$seconds" ]] || ! [[ "$seconds" =~ ^[0-9]+$ ]]; then
        seconds=0
    fi
    if (( seconds < 60 )); then
        printf "%ds" "$seconds"
    elif (( seconds < 3600 )); then
        printf "%dm%ds" $((seconds/60)) $((seconds%60))
    else
        printf "%dh%dm%ds" $((seconds/3600)) $((seconds%3600/60)) $((seconds%60))
    fi
}

# Check if process exists
process_exists() {
    [[ -d "/proc/$1" ]]
}

# Get process name
get_process_name() {
    cat "/proc/$1/comm" 2>/dev/null || echo "unknown"
}

# Get process start time (seconds since epoch)
get_process_start_time() {
    local pid=$1
    local starttime_ticks
    local boot_time
    local clk_tck
    
    # 获取进程启动时间（以系统启动后的 ticks 为单位）
    starttime_ticks=$(awk '{print $22}' "/proc/${pid}/stat" 2>/dev/null) || true
    if [[ -z "$starttime_ticks" ]]; then
        echo "0"
        return
    fi
    
    # 获取系统启动时间
    boot_time=$(awk '/btime/ {print $2}' /proc/stat 2>/dev/null) || true
    if [[ -z "$boot_time" ]]; then
        echo "0"
        return
    fi
    
    # 获取时钟频率 (通常是 100)
    clk_tck=$(getconf CLK_TCK 2>/dev/null) || clk_tck=100
    
    # 计算进程启动的 Unix 时间戳
    echo $((boot_time + starttime_ticks / clk_tck))
}

# Get file descriptor target
get_fd_target() {
    local pid=$1
    local fd=$2
    local target
    target=$(ls -l "/proc/${pid}/fd/${fd}" 2>/dev/null | awk '{print $NF}') || true
    echo "${target:-}"
}

# Read IO stats from /proc
get_io_stat() {
    local pid=$1
    local stat=$2
    local value
    value=$(awk -v stat="$stat:" '{ if ($1==stat) print $2 }' "/proc/${pid}/io" 2>/dev/null) || true
    echo "${value:-0}"
}

# Detect operation mode (compress/decompress)
# 返回: compress, decompress, 或 decompress_arg (通过参数解压)
detect_mode() {
    local pid=$1
    local fd0_link
    local cmdline
    
    fd0_link=$(get_fd_target "$pid" 0)
    cmdline=$(cat "/proc/${pid}/cmdline" 2>/dev/null | tr '\0' ' ') || true
    
    # 检查命令行是否包含 -d (解压标志)
    if [[ "$cmdline" == *" -d"* ]] || [[ "$cmdline" == *"-dc"* ]] || [[ "$cmdline" == *"-dk"* ]]; then
        echo "decompress_arg"
    elif [[ "$fd0_link" == *"pipe"* ]]; then
        echo "compress"
    else
        echo "decompress"
    fi
}

# 从命令行参数获取输入文件
get_input_file_from_cmdline() {
    local pid=$1
    local cmdline
    local filename=""
    
    cmdline=$(cat "/proc/${pid}/cmdline" 2>/dev/null | tr '\0' '\n') || true
    
    # 查找 .gz, .xz, .bz2, .zst 文件
    while IFS= read -r arg; do
        if [[ "$arg" =~ \.(gz|xz|bz2|zst)$ ]] && [[ -f "$arg" ]]; then
            filename="$arg"
            break
        fi
    done <<< "$cmdline"
    
    echo "$filename"
}

# Get decompressed size (if available)
get_decompressed_size() {
    local filename=$1
    local proname=$2
    
    # 检查文件是否存在
    if [[ -z "$filename" ]] || [[ ! -f "$filename" ]]; then
        echo "N/A"
        return
    fi
    
    case "$proname" in
        xz)
            xz -l "$filename" 2>/dev/null | tail -1 | awk '{print $5,$6}' || echo "N/A"
            ;;
        gzip|pigz)
            local size
            size=$(gzip -l "$filename" 2>/dev/null | tail -1 | awk '{print $2}') || true
            if [[ -n "$size" ]] && [[ "$size" =~ ^[0-9]+$ ]]; then
                format_size "$size"
            else
                echo "N/A"
            fi
            ;;
        bzip2|pbzip2)
            echo "N/A"  # bzip2 doesn't support listing
            ;;
        zstd)
            zstd -l "$filename" 2>/dev/null | tail -1 | awk '{print $4}' || echo "N/A"
            ;;
        *)
            echo "N/A"
            ;;
    esac
}

# ============================================================================
# Progress Bar
# ============================================================================

# draw_progress_bar - 绘制进度条
# 参数: percent (0-100)
draw_progress_bar() {
    local percent=${1:-0}
    
    # 确保 percent 在有效范围内
    if (( percent < 0 )); then percent=0; fi
    if (( percent > 100 )); then percent=100; fi
    
    local filled=$((percent * BAR_WIDTH / 100))
    local empty=$((BAR_WIDTH - filled))
    local bar=""
    
    for ((i=0; i<filled; i++)); do bar+="█"; done
    for ((i=0; i<empty; i++)); do bar+="░"; done
    
    echo -n "$bar"
}

# ============================================================================
# Monitor Functions
# ============================================================================

# Monitor decompression progress
monitor_decompress() {
    local pid=$1
    local lineno=$2
    local proname
    local filename
    local total_size
    local source_size_fmt
    local dest_size
    
    proname=$(get_process_name "$pid")
    filename=$(get_fd_target "$pid" 0)
    
    # 如果 fd/0 不是文件，尝试从命令行参数获取
    if [[ -z "$filename" ]] || [[ ! -f "$filename" ]]; then
        filename=$(get_input_file_from_cmdline "$pid")
    fi
    
    # 检查文件是否存在
    if [[ -z "$filename" ]] || [[ ! -f "$filename" ]]; then
        return
    fi
    
    total_size=$(stat -c '%s' "$filename" 2>/dev/null) || total_size=0
    if [[ -z "$total_size" ]] || [[ "$total_size" -eq 0 ]]; then
        return
    fi
    
    source_size_fmt=$(format_size "$total_size")
    dest_size=$(get_decompressed_size "$filename" "$proname")
    
    # 获取进程实际启动时间
    local process_start_time
    process_start_time=$(get_process_start_time "$pid")
    if [[ "$process_start_time" -eq 0 ]]; then
        process_start_time=$(date +%s)
    fi
    
    local current_rate="0 B/s"
    local rest_time="calculating..."
    
    while process_exists "$pid"; do
        local current_rchar
        local current_time
        local elapsed_time
        local progress
        local percent
        local bar
        
        current_rchar=$(get_io_stat "$pid" "rchar")
        current_time=$(date +%s)
        elapsed_time=$((current_time - process_start_time))
        
        # 检查数值有效性
        if [[ -z "$current_rchar" ]] || ! [[ "$current_rchar" =~ ^[0-9]+$ ]]; then
            sleep "$SLEEP_INTERVAL"
            continue
        fi
        
        # 使用累计值计算进度
        progress=$current_rchar
        
        # 确保不超过 100%
        if (( progress > total_size )); then
            progress=$total_size
        fi
        if (( progress < 0 )); then
            progress=0
        fi
        
        percent=$((progress * 100 / total_size))
        bar=$(draw_progress_bar "$percent")
        
        # 计算累计平均速率（与压缩监控保持一致）
        if (( elapsed_time > 0 )); then
            current_rate=$(format_rate $((current_rchar / elapsed_time)))
        fi
        
        # 计算剩余时间
        if (( elapsed_time > 0 && progress > 0 )); then
            local avg_rate=$((progress / elapsed_time))
            if (( avg_rate > 0 )); then
                local remaining=$((total_size - progress))
                rest_time=$(format_time $((remaining / avg_rate)))
            fi
        fi
        
        printf "\033[%d;0H${COLOR_BLUE}[Extract]${COLOR_RESET} %d: |%s| %3d%% %s ETA:%s [%s]    " \
            "$lineno" "$pid" "$bar" "$percent" "$current_rate" "$rest_time" "$(format_time $elapsed_time)"
        
        if (( progress >= total_size )); then
            break
        fi
        
        sleep "$SLEEP_INTERVAL"
    done
    
    local total_time=$(($(date +%s) - process_start_time))
    local avg_speed="N/A"
    if (( total_time > 0 )); then
        avg_speed=$(format_rate $((total_size / total_time)))
    fi
    
    printf "\033[%d;0H${COLOR_GREEN}[Extract]${COLOR_RESET} %d: Done %-20s (%s) %s → %s  Speed:%s  Time:%s          \n" \
        "$lineno" "$pid" "${filename##*/}" "$proname" "$source_size_fmt" "$dest_size" "$avg_speed" "$(format_time $total_time)"
}

# Monitor compression progress
monitor_compress() {
    local pid=$1
    local lineno=$2
    local proname
    local output_file
    
    proname=$(get_process_name "$pid")
    output_file=$(get_fd_target "$pid" 1)
    
    # 如果无法获取输出文件，尝试从 fd/3 或其他位置获取
    if [[ -z "$output_file" ]] || [[ "$output_file" == *"pipe"* ]]; then
        # pigz 可能将输出重定向到 stdout，尝试查找实际输出文件
        output_file=$(ls -l /proc/${pid}/fd/ 2>/dev/null | grep -v "pipe" | grep -v "/dev/" | tail -1 | awk '{print $NF}') || true
    fi
    
    local process_start_time
    local last_wchar
    local last_rchar
    
    # 获取进程实际启动时间
    process_start_time=$(get_process_start_time "$pid")
    if [[ "$process_start_time" -eq 0 ]]; then
        process_start_time=$(date +%s)  # 回退到当前时间
    fi
    
    last_wchar=$(get_io_stat "$pid" "wchar")
    last_rchar=$(get_io_stat "$pid" "rchar")
    
    local current_read_rate="0 B/s"
    local current_write_rate="0 B/s"
    
    printf "\033[%d;0H${COLOR_YELLOW}[Compress]${COLOR_RESET} %d (%s): Starting...                    " \
        "$lineno" "$pid" "$proname"
    
    while process_exists "$pid"; do
        local current_wchar
        local current_rchar
        local current_time
        local elapsed_time
        
        current_wchar=$(get_io_stat "$pid" "wchar")
        current_rchar=$(get_io_stat "$pid" "rchar")
        current_time=$(date +%s)
        elapsed_time=$((current_time - process_start_time))  # 使用进程实际运行时间
        
        if [[ -z "$current_wchar" ]] || [[ "$current_wchar" == "0" ]]; then
            sleep "$SLEEP_INTERVAL"
            continue
        fi
        
        # Calculate rates - 使用累计平均速度（更稳定）
        if (( elapsed_time > 0 )); then
            current_read_rate=$(format_rate $((current_rchar / elapsed_time)))
            current_write_rate=$(format_rate $((current_wchar / elapsed_time)))
        fi
        
        # 使用累计值计算压缩比（rchar/wchar 是进程启动以来的总量）
        local ratio="N/A"
        if (( current_wchar > 0 && current_rchar > 0 )); then
            ratio=$(awk -v r="$current_rchar" -v c="$current_wchar" 'BEGIN { printf "%.1f:1", r/c }')
        fi
        
        local read_fmt
        local compressed_fmt
        read_fmt=$(format_size "$current_rchar")
        compressed_fmt=$(format_size "$current_wchar")
        
        printf "\033[%d;0H${COLOR_YELLOW}[Compress]${COLOR_RESET} %d (%s): Read:%s Written:%s Ratio:%s R:%s W:%s [%s]          " \
            "$lineno" "$pid" "$proname" "$read_fmt" "$compressed_fmt" "$ratio" "$current_read_rate" "$current_write_rate" "$(format_time $elapsed_time)"
        
        last_wchar=$current_wchar
        last_rchar=$current_rchar
        sleep "$SLEEP_INTERVAL"
    done
    
    # Final stats - 使用进程实际运行时间
    local final_rchar=${last_rchar:-0}
    local final_wchar=${last_wchar:-0}
    local total_time=$(($(date +%s) - process_start_time))
    
    local final_ratio="N/A"
    if (( final_wchar > 0 && final_rchar > 0 )); then
        final_ratio=$(awk -v r="$final_rchar" -v c="$final_wchar" 'BEGIN { printf "%.2f:1", r/c }')
    fi
    
    local original_fmt=$(format_size "$final_rchar")
    local compressed_fmt=$(format_size "$final_wchar")
    local read_speed="N/A"
    local write_speed="N/A"
    if (( total_time > 0 )); then
        read_speed=$(format_rate $((final_rchar / total_time)))
        write_speed=$(format_rate $((final_wchar / total_time)))
    fi
    
    printf "\033[%d;0H${COLOR_GREEN}[Compress]${COLOR_RESET} %d (%s): Done  %s → %s  Ratio:%s  Read:%s  Write:%s  Time:%s                    \n" \
        "$lineno" "$pid" "$proname" "$original_fmt" "$compressed_fmt" "$final_ratio" "$read_speed" "$write_speed" "$(format_time $total_time)"
}

# Main monitor dispatcher
monitor_process() {
    local pid=$1
    local lineno=$2
    local mode
    
    mode=$(detect_mode "$pid")
    
    if [[ "$mode" == "compress" ]]; then
        monitor_compress "$pid" "$lineno"
    else
        # decompress 或 decompress_arg 都走解压监控
        monitor_decompress "$pid" "$lineno"
    fi
}

# ============================================================================
# Main
# ============================================================================

show_usage() {
    cat << 'EOF'
tar_progress.sh - Monitor tar compress/decompress progress

USAGE:
    ./tar_progress.sh

DESCRIPTION:
    Monitors running tar compression/decompression processes and displays
    real-time progress with speed, ETA, and compression ratio.

SUPPORTED FORMATS:
    gzip   (.tar.gz)  : tar -zcvf / tar -xzf
    pigz   (.tar.gz)  : tar -cf - dir | pigz > file.tar.gz (parallel)
                        pigz -dc file.tar.gz | tar -xf -   (parallel extract)
    xz     (.tar.xz)  : tar -Jcvf / tar -xJf  
    bzip2  (.tar.bz2) : tar -jcvf / tar -xjf
    pbzip2 (.tar.bz2) : tar -cf - dir | pbzip2 > file.tar.bz2 (parallel)
                        pbzip2 -dc file.tar.bz2 | tar -xf -   (parallel extract)
    zstd   (.tar.zst) : tar --zstd -cvf / tar --zstd -xf

ENVIRONMENT VARIABLES:
    TAR_PROGRESS_INTERVAL   - Update interval in seconds (default: 0.1)
    TAR_PROGRESS_BAR_WIDTH  - Progress bar width (default: 50)
    NO_COLOR                - Disable colored output

EXAMPLES:
    # Terminal 1: Start compression
    tar -zcvf backup.tar.gz /large/directory/

    # Terminal 2: Monitor progress
    ./tar_progress.sh

EOF
}

main() {
    # Handle help flag
    if [[ "${1:-}" == "-h" ]] || [[ "${1:-}" == "--help" ]]; then
        show_usage
        exit 0
    fi
    
    # Check for Linux
    if [[ ! -d /proc ]]; then
        echo "Error: This script requires Linux /proc filesystem" >&2
        exit 1
    fi
    
    # Find compression processes
    local pids=()
    local procs=("gzip" "pigz" "xz" "bzip2" "pbzip2" "zstd")
    
    for proc in "${procs[@]}"; do
        while IFS= read -r pid; do
            [[ -n "$pid" ]] && pids+=("$pid")
        done < <(pidof "$proc" 2>/dev/null || true)
    done
    
    if [[ ${#pids[@]} -eq 0 ]]; then
        echo "No compression process detected (gzip/pigz/xz/bzip2/pbzip2/zstd)"
        echo "Start a tar command first, then run this script."
        exit 1
    fi
    
    clear
    echo "Detected ${#pids[@]} process(es), monitoring..."
    echo ""
    
    local current_no=0
    for pid in "${pids[@]}"; do
        ((current_no++))
        monitor_process "$pid" $((current_no + 2)) &
    done
    
    wait
    echo ""
    echo "All tasks completed"
}

main "$@"
