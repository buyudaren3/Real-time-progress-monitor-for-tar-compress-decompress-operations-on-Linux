# Real-time-progress-monitor-for-tar-compress-decompress-operations-on-Linux
# tar_progress

Real-time progress monitor for tar compress/decompress operations on Linux.

![License](https://img.shields.io/badge/license-MIT-blue.svg)
![Platform](https://img.shields.io/badge/platform-Linux-green.svg)
![Bash](https://img.shields.io/badge/bash-4.0%2B-orange.svg)

## Features

- 📊 Real-time progress bar for decompression
- 📈 Live statistics for compression (read size, compressed size, ratio)
- ⚡ Transfer speed and ETA display
- 🔄 Supports multiple simultaneous processes
- 🎨 Colored output (can be disabled)

## Supported Formats

| Format | Extension | Compress | Extract |
|--------|-----------|----------|---------|
| gzip | .tar.gz | `tar -zcvf` | `tar -xzf` |
| xz | .tar.xz | `tar -Jcvf` | `tar -xJf` |
| bzip2 | .tar.bz2 | `tar -jcvf` | `tar -xjf` |
| zstd | .tar.zst | `tar --zstd -cvf` | `tar --zstd -xf` |

## Requirements

- Linux (requires `/proc` filesystem)
- Bash 4.0+
- Standard tools: `awk`, `stat`, `pidof`

## Installation

```bash
# Download
curl -O https://raw.githubusercontent.com/YOUR_USERNAME/tar_progress/main/tar_progress.sh

# Make executable
chmod +x tar_progress.sh

# Optional: Install system-wide
sudo mv tar_progress.sh /usr/local/bin/tar_progress
```

## Usage

**Terminal 1** - Start your tar operation:
```bash
# Compress
tar -zcvf backup.tar.gz /path/to/large/directory/

# Or extract
tar -xzf backup.tar.gz
```

**Terminal 2** - Monitor progress:
```bash
./tar_progress.sh
```

### Output Examples

**Decompression:**
```
[Extract] 12345: |████████████████████░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░| 42% 125.30 MiB/s ETA:2m15s
```

**Compression:**
```
[Compress] 12346: Read:1.50 GiB Compressed:320.00 MiB Ratio:4.8:1 45.20 MiB/s [32s]
```

## Configuration

Environment variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `TAR_PROGRESS_INTERVAL` | 0.1 | Update interval (seconds) |
| `TAR_PROGRESS_BAR_WIDTH` | 50 | Progress bar width |
| `NO_COLOR` | - | Set to disable colors |

Example:
```bash
TAR_PROGRESS_INTERVAL=0.5 TAR_PROGRESS_BAR_WIDTH=30 ./tar_progress.sh
```

## How It Works

The script monitors compression processes by reading from Linux's `/proc` filesystem:

- `/proc/[pid]/io` - Read/write byte counters
- `/proc/[pid]/fd/` - File descriptors to detect input/output files
- `/proc/[pid]/comm` - Process name (gzip, xz, etc.)

For **decompression**, progress is calculated as: `bytes_read / compressed_file_size`

For **compression**, since total size is unknown beforehand, the script displays real-time statistics instead of a percentage.

## Limitations

- Linux only (requires `/proc` filesystem)
- Compression mode cannot show percentage (source size unknown)
- bzip2 cannot display decompressed size (format limitation)

## License

MIT License

## Credits

Original script by [ddcw](https://github.com/ddcw), extended with compression monitoring and additional format support.
