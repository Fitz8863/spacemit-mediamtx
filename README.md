# SpaceMIT K3 MediaMTX

MediaMTX v1.20.1 的 `linux/riscv64` 构建、SpaceMIT K3 局域网 RTSP → WebRTC 配置，以及可复现的交叉编译和部署教程。

上游项目：`bluenviron/mediamtx`。本仓库不修改 MediaMTX 源代码，只从官方 `v1.20.1` tag 交叉编译 RISC-V 静态可执行程序。

## 下载

在 GitHub Releases 下载：

```text
mediamtx_v1.20.1_linux_riscv64.tar.gz
mediamtx_v1.20.1_linux_riscv64.tar.gz.sha256
```

压缩包结构与官方 Release 保持一致：

```text
mediamtx_v1.20.1_linux_riscv64/
├── LICENSE
├── mediamtx
└── mediamtx.yml
```

## 快速部署

在 K3 板端执行：

```bash
tar -xzf mediamtx_v1.20.1_linux_riscv64.tar.gz
cd mediamtx_v1.20.1_linux_riscv64
file mediamtx
./mediamtx --version
./mediamtx mediamtx.yml
```

正确架构应显示：

```text
ELF 64-bit LSB executable, UCB RISC-V
```

默认配置提供：

```text
RTSP 发布：rtsp://127.0.0.1:8554/dice
RTSP 读取：rtsp://<K3-IP>:8554/dice
WebRTC：   http://<K3-IP>:8889/dice/
WHEP：     http://<K3-IP>:8889/dice/whep
Control API（仅本机）：http://127.0.0.1:9997
```

## 从源码构建

要求：x86-64 Linux、Git、wget、tar、file。脚本会自动下载 Go 1.26.0，并从官方 tag 构建：

```bash
./scripts/build-riscv64.sh
```

产物写入：

```text
dist/mediamtx_v1.20.1_linux_riscv64.tar.gz
```

构建使用：

```text
CGO_ENABLED=0
GOOS=linux
GOARCH=riscv64
```

## 完整教程

参见：

```text
docs/MEDIAMTX_K3_DEPLOYMENT.md
```

教程包含架构检查、`go generate`、交叉编译、systemd 用户服务、linger、K3 VPU H.264 测试、RTSP 和 WebRTC/WHEP 验证以及故障排查。

## License

MediaMTX 使用 MIT License，详见 `LICENSE`。本仓库中的 MediaMTX 二进制由官方 v1.20.1 未修改源码构建。
