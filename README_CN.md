# tar_progress

**[English](README.md)** | **[中文](README_CN.md)**

Linux 下 tar 压缩/解压操作的实时进度监控工具。

![License](https://img.shields.io/badge/license-MIT-blue.svg)
![Platform](https://img.shields.io/badge/platform-Linux-green.svg)
![Bash](https://img.shields.io/badge/bash-4.0%2B-orange.svg)

## 功能特性

- 📊 解压时显示实时进度条
- 📈 压缩时显示实时统计（已读取、已压缩、压缩比）
- ⚡ 显示传输速度和预计剩余时间
- 🔄 支持同时监控多个进程
- 🎨 彩色输出（可禁用）

## 支持的格式

| 格式 | 扩展名 | 压缩命令 | 解压命令 |
|------|--------|----------|----------|
| gzip | .tar.gz | `tar -zcvf` | `tar -xzf` |
| pigz | .tar.gz | `tar -cf - dir \| pigz > file.tar.gz` | `pigz -dc file.tar.gz \| tar -xf -` |
| xz | .tar.xz | `tar -Jcvf` | `tar -xJf` |
| bzip2 | .tar.bz2 | `tar -jcvf` | `tar -xjf` |
| pbzip2 | .tar.bz2 | `tar -cf - dir \| pbzip2 > file.tar.bz2` | `pbzip2 -dc file.tar.bz2 \| tar -xf -` |
| zstd | .tar.zst | `tar --zstd -cvf` | `tar --zstd -xf` |

## 系统要求

- Linux 系统（需要 `/proc` 文件系统）
- Bash 4.0+
- 标准工具：`awk`、`stat`、`pidof`

## 安装

```bash
# 下载
curl -O https://raw.githubusercontent.com/buyudaren3/Real-time-progress-monitor-for-tar-compress-decompress-operations-on-Linux/main/tar_progress.sh

# 添加执行权限
chmod +x tar_progress.sh

# 可选：安装到系统目录
sudo mv tar_progress.sh /usr/local/bin/tar_progress
```

## 使用方法

**终端 1** - 执行 tar 命令：
```bash
# 压缩
tar -zcvf backup.tar.gz /path/to/large/directory/

# 或解压
tar -xzf backup.tar.gz
```

**终端 2** - 监控进度：
```bash
./tar_progress.sh
```

### 输出示例

**解压时：**
```
[Extract] 12345: |████████████████████░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░| 42% 125.30 MB/s ETA:2m15s [1m30s]
```

**压缩时：**
```
[Compress] 12346 (gzip): Read:1.50 GB Written:320.00 MB Ratio:4.7:1 R:45.20 MB/s W:9.70 MB/s [32s]
```

## 配置选项

通过环境变量配置：

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `TAR_PROGRESS_INTERVAL` | 0.1 | 更新间隔（秒） |
| `TAR_PROGRESS_BAR_WIDTH` | 50 | 进度条宽度 |
| `NO_COLOR` | - | 设置后禁用彩色输出 |

示例：
```bash
TAR_PROGRESS_INTERVAL=0.5 TAR_PROGRESS_BAR_WIDTH=30 ./tar_progress.sh
```

## 工作原理

脚本通过读取 Linux `/proc` 文件系统来监控压缩进程：

- `/proc/[pid]/io` - 读写字节计数器
- `/proc/[pid]/fd/` - 文件描述符，用于检测输入/输出文件
- `/proc/[pid]/comm` - 进程名称（gzip、xz 等）

**解压时**，进度计算方式：`已读取字节数 / 压缩文件大小`

**压缩时**，由于无法预知源目录总大小，脚本显示实时统计信息而非百分比进度。

## 限制

- 仅支持 Linux（需要 `/proc` 文件系统）
- 压缩模式无法显示百分比（源大小未知）
- bzip2 无法显示解压后大小（格式限制）

## 许可证

MIT License

## 致谢

原始脚本作者 [ddcw](https://github.com/ddcw)，本项目在此基础上扩展了压缩进度监控和更多格式支持。
# tar_progress

**[English](README.md)** | **[中文](README_CN.md)**

Linux 下 tar 压缩/解压操作的实时进度监控工具。

![License](https://img.shields.io/badge/license-MIT-blue.svg)
![Platform](https://img.shields.io/badge/platform-Linux-green.svg)
![Bash](https://img.shields.io/badge/bash-4.0%2B-orange.svg)

## 功能特性

- 📊 解压时显示实时进度条
- 📈 压缩时显示实时统计（已读取、已压缩、压缩比）
- ⚡ 显示传输速度和预计剩余时间
- 🔄 支持同时监控多个进程
- 🎨 彩色输出（可禁用）

## 支持的格式

| 格式 | 扩展名 | 压缩命令 | 解压命令 |
|------|--------|----------|----------|
| gzip | .tar.gz | `tar -zcvf` | `tar -xzf` |
| pigz | .tar.gz | `tar -cf - dir \| pigz > file.tar.gz` | `pigz -dc file.tar.gz \| tar -xf -` |
| xz | .tar.xz | `tar -Jcvf` | `tar -xJf` |
| bzip2 | .tar.bz2 | `tar -jcvf` | `tar -xjf` |
| pbzip2 | .tar.bz2 | `tar -cf - dir \| pbzip2 > file.tar.bz2` | `pbzip2 -dc file.tar.bz2 \| tar -xf -` |
| zstd | .tar.zst | `tar --zstd -cvf` | `tar --zstd -xf` |

## 系统要求

- Linux 系统（需要 `/proc` 文件系统）
- Bash 4.0+
- 标准工具：`awk`、`stat`、`pidof`

## 安装

```bash
# 下载
curl -O https://raw.githubusercontent.com/buyudaren3/Real-time-progress-monitor-for-tar-compress-decompress-operations-on-Linux/main/tar_progress.sh

# 添加执行权限
chmod +x tar_progress.sh

# 可选：安装到系统目录
sudo mv tar_progress.sh /usr/local/bin/tar_progress
```

## 使用方法

**终端 1** - 执行 tar 命令：
```bash
# 压缩
tar -zcvf backup.tar.gz /path/to/large/directory/

# 或解压
tar -xzf backup.tar.gz
```

**终端 2** - 监控进度：
```bash
./tar_progress.sh
```

### 输出示例

**解压时：**
```
[Extract] 12345: |████████████████████░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░| 42% 125.30 MB/s ETA:2m15s [1m30s]
```

**压缩时：**
```
[Compress] 12346 (gzip): Read:1.50 GB Written:320.00 MB Ratio:4.7:1 R:45.20 MB/s W:9.70 MB/s [32s]
```

## 配置选项

通过环境变量配置：

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `TAR_PROGRESS_INTERVAL` | 0.1 | 更新间隔（秒） |
| `TAR_PROGRESS_BAR_WIDTH` | 50 | 进度条宽度 |
| `NO_COLOR` | - | 设置后禁用彩色输出 |

示例：
```bash
TAR_PROGRESS_INTERVAL=0.5 TAR_PROGRESS_BAR_WIDTH=30 ./tar_progress.sh
```

## 工作原理

脚本通过读取 Linux `/proc` 文件系统来监控压缩进程：

- `/proc/[pid]/io` - 读写字节计数器
- `/proc/[pid]/fd/` - 文件描述符，用于检测输入/输出文件
- `/proc/[pid]/comm` - 进程名称（gzip、xz 等）

**解压时**，进度计算方式：`已读取字节数 / 压缩文件大小`

**压缩时**，由于无法预知源目录总大小，脚本显示实时统计信息而非百分比进度。

## 限制

- 仅支持 Linux（需要 `/proc` 文件系统）
- 压缩模式无法显示百分比（源大小未知）
- bzip2 无法显示解压后大小（格式限制）

## 许可证

MIT License

## 致谢

原始脚本作者 [ddcw](https://github.com/ddcw)，本项目在此基础上扩展了压缩进度监控和更多格式支持。
