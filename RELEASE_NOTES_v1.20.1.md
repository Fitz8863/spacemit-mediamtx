# MediaMTX v1.20.1 for SpaceMIT K3 (linux/riscv64)

这是从上游 MediaMTX 官方 `v1.20.1` tag 交叉编译的 Linux RISC-V 64 位版本，面向 SpaceMIT K3 / Bianbu 系统。

## 构建信息

```text
Upstream: github.com/bluenviron/mediamtx
Version: v1.20.1
Commit: 883194a19b7244355c9bc975c0574c9842733637
Go: 1.26.0
GOOS: linux
GOARCH: riscv64
CGO_ENABLED: 0
Source modifications: none
```

## Release 文件

- `mediamtx_v1.20.1_linux_riscv64.tar.gz`
- `mediamtx_v1.20.1_linux_riscv64.tar.gz.sha256`

压缩包包含：

```text
LICENSE
mediamtx
mediamtx.yml
```

`mediamtx.yml` 是上游 MediaMTX `v1.20.1` 的原始默认配置，未针对 K3 修改，SHA-256 为 `bc3c9771d125fd632c834b5abf2e00d305a004659f4900cd2c0977b429f56946`。K3 的 RTSP → WebRTC 精简示例单独位于仓库的 `config/mediamtx-k3.yml`，不会替换 Release 中的官方配置。

## 已验证

- Bianbu 4.0.6 / linux-riscv64 可执行；
- RTSP/TCP H.264 发布和读取；
- MediaMTX WebRTC 内置页面和 WHEP；
- K3 `h264_stcodec` 硬件编码测试流；
- 用户级 systemd 服务运行。
