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
detect_mode() {
    local pid=$1
    local fd0_link
    fd0_link=$(get_fd_target "$pid" 0)
    if [[ "$fd0_link" == *"pipe"* ]]; then
        echo "compress"
    else
        echo "decompress"
    fi
}

# Get decompressed size (if available)
get_decompressed_size() {
    local filename=$1
    local proname=$2
    
    case "$proname" in
        xz)
            xz -l "$filename" 2>/dev/null | tail -1 | awk '{print $5,$6}'
            ;;
        gzip|pigz)
            local size
            size=$(gzip -l "$filename" 2>/dev/null | tail -1 | awk '{print $2}')
            format_size "$size"
            ;;
        bzip2|pbzip2)
            echo "N/A"  # bzip2 doesn't support listing
            ;;
        zstd)
            zstd -l "$filename" 2>/dev/null | tail -1 | awk '{print $4}'
            ;;
        *)
            echo "N/A"
            ;;
    esac
}

# ============================================================================
# Progress Bar
# ============================================================================

draw_progress_bar() {
    local percent=$1
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
    
    local old_rchar
    local start_time
    local current_rate="0 B/s"
    local rest_time="calculating..."
    
    old_rchar=$(get_io_stat "$pid" "rchar")
    start_time=$(date +%s)
    
    while process_exists "$pid"; do
        local current_rchar
        local time_diff
        local progress
        local percent
        local bar
        
        current_rchar=$(get_io_stat "$pid" "rchar")
        time_diff=$(($(date +%s) - start_time))
        
        # 检查数值有效性
        if [[ -z "$current_rchar" ]] || ! [[ "$current_rchar" =~ ^[0-9]+$ ]]; then
            sleep "$SLEEP_INTERVAL"
            continue
        fi
        
        progress=$((current_rchar - old_rchar))
        
        # 确保不超过 100%
        if (( progress > total_size )); then
            progress=$total_size
        fi
        if (( progress < 0 )); then
            progress=0
        fi
        
        percent=$((progress * 100 / total_size))
        bar=$(draw_progress_bar "$percent")
        
        if (( time_diff > 0 )); then
            local rate=$((progress / time_diff))
            current_rate=$(format_rate "$rate")
            if (( rate > 0 )); then
                local remaining=$((total_size - progress))
                rest_time=$(format_time $((remaining / rate)))
            fi
        fi
        
        printf "\033[%d;0H${COLOR_BLUE}[Extract]${COLOR_RESET} %d: |%s| %3d%% %s ETA:%s    " \
            "$lineno" "$pid" "$bar" "$percent" "$current_rate" "$rest_time"
        
        if (( progress >= total_size )); then
            break
        fi
        
        sleep "$SLEEP_INTERVAL"
    done
    
    local elapsed=$(($(date +%s) - start_time))
    printf "\033[%d;0H${COLOR_GREEN}[Extract]${COLOR_RESET} %d: Done %-30s (%s) %s → %s [%s]          \n" \
        "$lineno" "$pid" "${filename##*/}" "$proname" "$source_size_fmt" "$dest_size" "$(format_time $elapsed)"
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
    
    local old_wchar
    local old_rchar
    local start_time
    local last_wchar
    local last_time
    local current_rate="0 B/s"
    
    old_wchar=$(get_io_stat "$pid" "wchar")
    old_rchar=$(get_io_stat "$pid" "rchar")
    start_time=$(date +%s)
    last_wchar=${old_wchar:-0}
    last_time=$start_time
    
    printf "\033[%d;0H${COLOR_YELLOW}[Compress]${COLOR_RESET} %d (%s): Starting...                    " \
        "$lineno" "$pid" "$proname"
    
    while process_exists "$pid"; do
        local current_wchar
        local current_rchar
        local current_time
        local time_diff
        
        current_wchar=$(get_io_stat "$pid" "wchar")
        current_rchar=$(get_io_stat "$pid" "rchar")
        current_time=$(date +%s)
        time_diff=$((current_time - start_time))
        
        if [[ -z "$current_wchar" ]] || [[ "$current_wchar" == "0" ]]; then
            sleep "$SLEEP_INTERVAL"
            continue
        fi
        
        # Calculate rate
        local interval_time=$((current_time - last_time))
        if (( interval_time > 0 )); then
            local interval_bytes=$((current_wchar - last_wchar))
            if (( interval_bytes > 0 )); then
                current_rate=$(format_rate $((interval_bytes / interval_time)))
            fi
        fi
        
        # Calculate compression ratio
        local compressed_size=$((current_wchar - old_wchar))
        local read_size=$((current_rchar - old_rchar))
        local ratio="N/A"
        if (( compressed_size > 0 && read_size > 0 )); then
            ratio=$(awk -v r="$read_size" -v c="$compressed_size" 'BEGIN { printf "%.1f:1", r/c }')
        fi
        
        local read_fmt
        local compressed_fmt
        read_fmt=$(format_size "$read_size")
        compressed_fmt=$(format_size "$compressed_size")
        
        printf "\033[%d;0H${COLOR_YELLOW}[Compress]${COLOR_RESET} %d (%s): Read:%s Written:%s Ratio:%s %s [%s]          " \
            "$lineno" "$pid" "$proname" "$read_fmt" "$compressed_fmt" "$ratio" "$current_rate" "$(format_time $time_diff)"
        
        last_wchar=$current_wchar
        last_time=$current_time
        sleep "$SLEEP_INTERVAL"
    done
    
    # Final stats
    local final_wchar
    final_wchar=$((last_wchar - old_wchar))
    local final_fmt
    final_fmt=$(format_size "$final_wchar")
    local total_time=$(($(date +%s) - start_time))
    
    printf "\033[%d;0H${COLOR_GREEN}[Compress]${COLOR_RESET} %d (%s): Done  Written:%s [%s]                              \n" \
        "$lineno" "$pid" "$proname" "$final_fmt" "$(format_time $total_time)"
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
    xz     (.tar.xz)  : tar -Jcvf / tar -xJf  
    bzip2  (.tar.bz2) : tar -jcvf / tar -xjf
    pbzip2 (.tar.bz2) : tar -cf - dir | pbzip2 > file.tar.bz2 (parallel)
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
        echo ""
        echo "Usage:"
        echo "  1. Start tar command in one terminal:"
        echo "     tar -zcvf archive.tar.gz folder/        (gzip)"
        echo "     tar -cf - folder/ | pigz > archive.tar.gz  (pigz)"
        echo "     tar -xzf archive.tar.gz                 (extract)"
        echo ""
        echo "  2. Run this script in another terminal"
        echo ""
        echo "Run with --help for more information"
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
