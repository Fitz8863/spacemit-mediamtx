# SpaceMIT K3 MediaMTX（linux/riscv64）

本仓库提供适用于 **SpaceMIT K3 / Bianbu Linux / RISC-V 64 位**的 MediaMTX 构建脚本、运行配置、systemd 示例和部署文档。

## 上游源码声明

MediaMTX 的原始源码来自官方项目：

```text
https://github.com/bluenviron/mediamtx
```

本仓库不是 MediaMTX 的独立实现，也不修改或复制一套私有协议实现。当前 RISC-V 可执行文件基于以下官方源码构建：

```text
Upstream repository: https://github.com/bluenviron/mediamtx
Upstream tag:        v1.20.1
Upstream commit:     883194a19b7244355c9bc975c0574c9842733637
Source modifications: none
```

之所以单独提供构建和 Release，是因为上游 `v1.20.1` Release 没有提供 `linux/riscv64` 预编译包。我们只增加了面向 K3 的交叉编译、配置和部署说明。

MediaMTX 及其原始源码版权归原项目作者所有，使用 MIT License，详见本仓库的 `LICENSE` 和上游项目。

## 仓库内容

```text
.
├── config/
│   └── mediamtx.yml                 K3 RTSP → WebRTC 示例配置
├── docs/
│   └── MEDIAMTX_K3_DEPLOYMENT.md    完整编译、部署和排错教程
├── scripts/
│   └── build-riscv64.sh             可复现的 RISC-V 交叉编译脚本
├── systemd/
│   └── mediamtx.service             用户级 systemd 服务示例
├── LICENSE                          上游 MIT License
└── RELEASE_NOTES_v1.20.1.md         Release 说明
```

本仓库**不提交 MediaMTX 上游源码副本**。构建脚本会在临时目录中从官方仓库克隆指定 tag，编译结束后自动清理临时源码和 Go SDK。

## 下载预编译版本

在本仓库的 GitHub Releases 下载：

```text
mediamtx_v1.20.1_linux_riscv64.tar.gz
mediamtx_v1.20.1_linux_riscv64.tar.gz.sha256
```

压缩包结构与上游官方 Release 的风格一致：

```text
mediamtx_v1.20.1_linux_riscv64/
├── LICENSE
├── mediamtx
└── mediamtx.yml
```

下载后验证：

```bash
sha256sum -c mediamtx_v1.20.1_linux_riscv64.tar.gz.sha256
```

解压并检查架构：

```bash
tar -xzf mediamtx_v1.20.1_linux_riscv64.tar.gz
cd mediamtx_v1.20.1_linux_riscv64

file mediamtx
./mediamtx --version
```

正确结果应包含：

```text
ELF 64-bit LSB executable, UCB RISC-V
v1.20.1
```

## 在 K3 上快速运行

```bash
./mediamtx mediamtx.yml
```

默认配置提供：

| 功能 | 地址 |
| --- | --- |
| RTSP 发布 | `rtsp://127.0.0.1:8554/dice` |
| 局域网 RTSP 读取 | `rtsp://<K3-IP>:8554/dice` |
| WebRTC 页面 | `http://<K3-IP>:8889/dice/` |
| WHEP | `http://<K3-IP>:8889/dice/whep` |
| Control API | `http://127.0.0.1:9997`，仅板端本机 |

`mediamtx.yml` 默认只开启当前项目需要的 RTSP、WebRTC/WHEP 和本机 Control API。HLS、RTMP、SRT、MoQ 等能力没有从二进制中删除，只是在配置中关闭，可按需重新启用。

## 如何从官方源码交叉编译

### 构建环境

推荐在 **x86-64 Linux 开发电脑**上构建，而不是在骰子项目目录或 K3 运行目录中直接展开上游源码。

需要以下工具：

```text
git
wget
tar
file
sha256sum
```

MediaMTX v1.20.1 要求 Go 1.26.0。构建脚本会自动下载官方 Go SDK，不会修改系统 Go。

### 推荐方式：使用构建脚本

克隆本仓库到一个独立目录：

```bash
git clone git@github.com:Fitz8863/spacemit-mediamtx.git
cd spacemit-mediamtx
```

执行：

```bash
./scripts/build-riscv64.sh
```

脚本执行以下过程：

1. 在 `/tmp/spacemit-mediamtx-build.XXXXXX` 创建临时工作目录；
2. 下载 Go 1.26.0 x86-64 SDK；
3. 从 `https://github.com/bluenviron/mediamtx` 克隆官方 `v1.20.1` tag；
4. 执行 `go generate ./...`，生成版本文件和嵌入资源；
5. 使用 `GOOS=linux`、`GOARCH=riscv64`、`CGO_ENABLED=0` 交叉编译；
6. 将 `mediamtx`、`mediamtx.yml` 和 `LICENSE` 打包；
7. 生成 SHA-256 校验文件；
8. 自动删除 `/tmp` 下的临时 Go SDK 和上游源码。

最终只在本仓库的 `dist/` 中生成：

```text
dist/mediamtx_v1.20.1_linux_riscv64.tar.gz
dist/mediamtx_v1.20.1_linux_riscv64.tar.gz.sha256
```

`dist/` 已被 `.gitignore` 忽略，构建产物通过 GitHub Releases 发布，不提交进 Git 历史。

### 核心交叉编译命令

构建脚本的核心逻辑如下：

```bash
git clone --depth 1 --branch v1.20.1 \
  https://github.com/bluenviron/mediamtx.git \
  /tmp/mediamtx-src

cd /tmp/mediamtx-src

/path/to/go1.26.0/bin/go generate ./...

CGO_ENABLED=0 \
GOOS=linux \
GOARCH=riscv64 \
/path/to/go1.26.0/bin/go build \
  -trimpath \
  -o mediamtx \
  .
```

参数说明：

| 参数 | 说明 |
| --- | --- |
| `CGO_ENABLED=0` | 生成不依赖开发电脑动态库组合的静态 Go 程序 |
| `GOOS=linux` | 目标系统为 Linux |
| `GOARCH=riscv64` | 目标架构为 64 位 RISC-V |
| `-trimpath` | 去除开发电脑上的临时源码路径 |

不能跳过：

```bash
go generate ./...
```

否则可能出现：

```text
pattern hls.min.js: no matching files found
pattern VERSION: no matching files found
```

### 可追溯性检查

构建后检查：

```bash
file dist-build/mediamtx
go version -m dist-build/mediamtx
```

应能确认：

```text
module: github.com/bluenviron/mediamtx v1.20.1
GOOS: linux
GOARCH: riscv64
CGO_ENABLED: 0
vcs.revision: 883194a19b7244355c9bc975c0574c9842733637
vcs.modified: false
```

`vcs.modified=false` 表示编译使用的上游源码没有被修改。

## 与官方 Release 的差别

当前可执行文件与官方 Release 使用同一个 `v1.20.1` tag 和同一个 commit，MediaMTX 源码没有修改。主要差别只有：

1. 目标架构是上游未预编译发布的 `linux/riscv64`；
2. 使用 Go 官方的交叉编译能力生成静态程序；
3. 附带一份适合 K3 RTSP → WebRTC 场景的配置；
4. 在 K3/Bianbu 上完成了 RTSP、WHEP 和 WebRTC 验证。

MediaMTX 本身不调用 SpaceMIT VPU。K3 VPU 编码由应用或 GStreamer/FFmpeg 完成：

```text
摄像头/YOLO 最终画面
  -> spacemith264enc 或 h264_stcodec
  -> H.264/RTSP
  -> MediaMTX
  -> WebRTC/WHEP
  -> 浏览器
```

## 完整教程

详细步骤参见：

```text
docs/MEDIAMTX_K3_DEPLOYMENT.md
```

内容包括：

- K3 架构和端口检查；
- SpaceMIT H.264 VPU 编码器检查；
- Go SDK 准备；
- `go generate` 和 RISC-V 交叉编译；
- Release 包结构；
- MediaMTX YAML 配置；
- 用户级 systemd 和 linger；
- RTSP、WebRTC/WHEP 验证；
- 常见故障排查。

## License

MediaMTX 使用 MIT License。本仓库中的二进制由官方 `v1.20.1` 未修改源码构建。请同时遵守上游项目的许可证和第三方依赖许可证。
