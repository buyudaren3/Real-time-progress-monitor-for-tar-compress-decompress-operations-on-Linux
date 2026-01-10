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
#   - xz    (.tar.xz)  : tar -Jcvf / tar -xJf
#   - bzip2 (.tar.bz2) : tar -jcvf / tar -xjf
#   - zstd  (.tar.zst) : tar --zstd -cvf / tar --zstd -xf
#
# Requirements:
#   - Linux with /proc filesystem
#   - bash 4.0+
#   - Standard tools: awk, stat, pidof
# ============================================================================

set -euo pipefail

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

# Format file size to human readable
format_size() {
    local size=$1
    awk -v size="$size" 'BEGIN {
        if (size < 1024) printf "%.2f B", size
        else if (size < 1024*1024) printf "%.2f KiB", size/1024
        else if (size < 1024*1024*1024) printf "%.2f MiB", size/1024/1024
        else printf "%.2f GiB", size/1024/1024/1024
    }'
}

# Format transfer rate
format_rate() {
    local rate=$1
    awk -v rate="$rate" 'BEGIN {
        if (rate < 1024) printf "%.2f B/s", rate
        else if (rate < 1024*1024) printf "%.2f KiB/s", rate/1024
        else if (rate < 1024*1024*1024) printf "%.2f MiB/s", rate/1024/1024
        else printf "%.2f GiB/s", rate/1024/1024/1024
    }'
}

# Format time duration
format_time() {
    local seconds=$1
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
    ls -l "/proc/${pid}/fd/${fd}" 2>/dev/null | awk '{print $NF}'
}

# Read IO stats from /proc
get_io_stat() {
    local pid=$1
    local stat=$2
    awk -v stat="$stat:" '{ if ($1==stat) print $2 }' "/proc/${pid}/io" 2>/dev/null || echo 0
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
        gzip)
            local size
            size=$(gzip -l "$filename" 2>/dev/null | tail -1 | awk '{print $2}')
            format_size "$size"
            ;;
        bzip2)
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
    
    if [[ ! -f "$filename" ]]; then
        return
    fi
    
    total_size=$(stat -c '%s' "$filename" 2>/dev/null || echo 0)
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
        progress=$((current_rchar - old_rchar))
        
        if [[ -z "$current_rchar" ]] || [[ "$current_rchar" -eq 0 ]]; then
            break
        fi
        
        # Ensure we don't exceed 100%
        if (( progress > total_size )); then
            progress=$total_size
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
    
    local old_wchar
    local old_rchar
    local start_time
    local last_wchar
    local last_time
    local current_rate="0 B/s"
    
    old_wchar=$(get_io_stat "$pid" "wchar")
    old_rchar=$(get_io_stat "$pid" "rchar")
    start_time=$(date +%s)
    last_wchar=$old_wchar
    last_time=$start_time
    
    printf "\033[%d;0H${COLOR_YELLOW}[Compress]${COLOR_RESET} %d: Starting... Output: %s                    " \
        "$lineno" "$pid" "${output_file##*/}"
    
    while process_exists "$pid"; do
        local current_wchar
        local current_rchar
        local current_time
        local time_diff
        
        current_wchar=$(get_io_stat "$pid" "wchar")
        current_rchar=$(get_io_stat "$pid" "rchar")
        current_time=$(date +%s)
        time_diff=$((current_time - start_time))
        
        if [[ -z "$current_wchar" ]]; then
            break
        fi
        
        # Calculate rate
        local interval_time=$((current_time - last_time))
        if (( interval_time > 0 )); then
            local interval_bytes=$((current_wchar - last_wchar))
            current_rate=$(format_rate $((interval_bytes / interval_time)))
        fi
        
        # Calculate compression ratio
        local compressed_size=$((current_wchar - old_wchar))
        local read_size=$((current_rchar - old_rchar))
        local ratio="N/A"
        if (( compressed_size > 0 && read_size > 0 )); then
            ratio=$(awk -v r="$read_size" -v c="$compressed_size" 'BEGIN { printf "%.1f:1", r/c }')
        fi
        
        local read_fmt
        local output_fmt
        read_fmt=$(format_size "$read_size")
        
        # Get current output file size
        local output_size=0
        if [[ -f "$output_file" ]]; then
            output_size=$(stat -c '%s' "$output_file" 2>/dev/null || echo 0)
        fi
        output_fmt=$(format_size "$output_size")
        
        printf "\033[%d;0H${COLOR_YELLOW}[Compress]${COLOR_RESET} %d: Read:%s Compressed:%s Ratio:%s %s [%s]    " \
            "$lineno" "$pid" "$read_fmt" "$output_fmt" "$ratio" "$current_rate" "$(format_time $time_diff)"
        
        last_wchar=$current_wchar
        last_time=$current_time
        sleep "$SLEEP_INTERVAL"
    done
    
    # Final stats
    local final_size=0
    if [[ -f "$output_file" ]]; then
        final_size=$(stat -c '%s' "$output_file" 2>/dev/null || echo 0)
    fi
    local final_fmt
    final_fmt=$(format_size "$final_size")
    local total_time=$(($(date +%s) - start_time))
    
    printf "\033[%d;0H${COLOR_GREEN}[Compress]${COLOR_RESET} %d: Done %-30s Size:%s [%s] (%s)                    \n" \
        "$lineno" "$pid" "${output_file##*/}" "$final_fmt" "$(format_time $total_time)" "$proname"
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
    gzip  (.tar.gz)  : tar -zcvf / tar -xzf
    xz    (.tar.xz)  : tar -Jcvf / tar -xJf  
    bzip2 (.tar.bz2) : tar -jcvf / tar -xjf
    zstd  (.tar.zst) : tar --zstd -cvf / tar --zstd -xf

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
    local procs=("gzip" "xz" "bzip2" "zstd")
    
    for proc in "${procs[@]}"; do
        while IFS= read -r pid; do
            [[ -n "$pid" ]] && pids+=("$pid")
        done < <(pidof "$proc" 2>/dev/null || true)
    done
    
    if [[ ${#pids[@]} -eq 0 ]]; then
        echo "No compression process detected (gzip/xz/bzip2/zstd)"
        echo ""
        echo "Usage:"
        echo "  1. Start tar command in one terminal:"
        echo "     tar -zcvf archive.tar.gz folder/   (compress)"
        echo "     tar -xzf archive.tar.gz            (extract)"
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
