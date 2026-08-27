# 在 SpaceMIT K3（RISC-V）上编译、部署和运行 MediaMTX

本文记录在 SpaceMIT K3 Pico ITX 板端部署 MediaMTX 的完整过程，适用于以下环境：

```text
板端架构：riscv64
操作系统：Bianbu 4.0.6
MediaMTX：v1.20.1
部署日期：2026-08-27
```

最终实现的链路是：

```text
摄像头/YOLO 处理后的画面
  -> K3 VPU H.264 编码
  -> RTSP 发布到 rtsp://127.0.0.1:8554/dice
  -> MediaMTX
  -> WebRTC/WHEP
  -> 局域网浏览器 <video>
```

> 重要：MediaMTX 在这里是媒体服务器和协议路由器。它负责 RTSP 到 WebRTC 的协议转换，但不负责把 BGR、NV12 或 MJPEG 自动转码成浏览器可播放的 H.264。H.264 编码仍由骰子程序、GStreamer 或 FFmpeg 完成。

---

## 1. 为什么需要自行编译

K3 的 CPU 架构是 RISC-V：

```bash
uname -m
```

输出：

```text
riscv64
```

截至 MediaMTX v1.20.1，官方 Release 提供 Linux `amd64`、`arm64`、`armv6`、`armv7` 等包，但没有提供 `linux_riscv64` 预编译包。

不能把 `amd64` 或 `arm64` 文件复制到 K3 运行。错误架构通常会得到：

```text
cannot execute binary file: Exec format error
```

MediaMTX 使用 Go 开发，并且常规构建可以关闭 CGO，因此可以在 x86-64 Linux 主机上交叉编译出静态链接的 RISC-V 程序：

```text
x86-64 Linux + Go
  -> GOOS=linux GOARCH=riscv64 CGO_ENABLED=0
  -> riscv64 MediaMTX 静态可执行文件
```

静态链接的好处是板端不需要另外安装 Go 运行时或匹配一组动态库。

---

## 2. 检查板端环境

先确认可以通过 SSH 访问板端。本文示例为：

```bash
ssh spacemit@10.0.90.160
```

在板端执行：

```bash
hostname
uname -a
uname -m
cat /etc/os-release | head
nproc
free -h
df -h /home
```

本次实际环境：

```text
hostname: bianbu-spacemitk3picoitx
architecture: riscv64
system: Bianbu 4.0.6
CPU logical cores: 8
memory: 15 GiB
```

确认计划使用的端口没有被占用：

```bash
ss -lntup | grep -E ':(8554|8889|8189|9997)\b' || true
```

本文使用：

| 端口 | 协议 | 用途 |
| --- | --- | --- |
| `8554/TCP` | RTSP | 接收应用发布的 H.264 流 |
| `8889/TCP` | HTTP | WebRTC 内置页面和 WHEP 信令 |
| `8189/UDP` | ICE/SRTP | WebRTC 实际媒体传输 |
| `9997/TCP` | HTTP | MediaMTX Control API，仅监听本机 |

---

## 3. 检查 K3 硬件编码能力

MediaMTX 不负责原始画面到 H.264 的编码，因此需要先确认板端存在 H.264 编码器。

检查 GStreamer：

```bash
gst-inspect-1.0 | grep -Ei '(h264|264enc|spacemit.*enc|vpu.*enc)'
```

本次板端存在：

```text
spacemith264enc: Spacemit H264 Encoder
openh264enc: OpenH264 video encoder
x264enc: x264 H.264 encoder
```

查看 SpaceMIT VPU 编码插件：

```bash
gst-inspect-1.0 spacemith264enc
```

它支持输入：

```text
I420
NV21
NV12
```

输出：

```text
video/x-h264
stream-format=byte-stream
alignment=au
```

板端 FFmpeg 也提供 SpaceMIT 硬件编码器：

```bash
ffmpeg -hide_banner -encoders | grep -Ei 'h264|stcodec'
```

可以看到：

```text
h264_stcodec  h264 (stcodec encoder)
```

因此可用两条编码路径：

```text
GStreamer: spacemith264enc
FFmpeg:    h264_stcodec
```

骰子程序实际接入建议使用 GStreamer `appsrc + spacemith264enc`，测试 MediaMTX 时可以先用 FFmpeg 的 `h264_stcodec`。

---

## 4. 在 x86-64 主机准备 Go

MediaMTX v1.20.1 的 `go.mod` 要求 Go 1.26.0。不要直接使用过旧的系统 Go。

在开发主机执行：

```bash
BUILD_ROOT="$(mktemp -d /tmp/mediamtx-build.XXXXXX)"
echo "$BUILD_ROOT"
```

下载 Go 1.26.0：

```bash
wget -O "$BUILD_ROOT/go.tar.gz" \
  https://dl.google.com/go/go1.26.0.linux-amd64.tar.gz
```

解压到临时目录，不修改系统 Go：

```bash
tar -xzf "$BUILD_ROOT/go.tar.gz" -C "$BUILD_ROOT"
"$BUILD_ROOT/go/bin/go" version
```

预期输出：

```text
go version go1.26.0 linux/amd64
```

这种方式不会向 `/usr/local/go` 写文件，也不要求 root 权限。

---

## 5. 获取固定版本的 MediaMTX 源码

使用固定 tag，避免 `main` 分支变化导致以后无法复现：

```bash
SRC_ROOT="$(mktemp -d /tmp/mediamtx-src.XXXXXX)"

git clone --depth 1 --branch v1.20.1 \
  https://github.com/bluenviron/mediamtx.git \
  "$SRC_ROOT"
```

确认版本和提交：

```bash
cd "$SRC_ROOT"
git describe --tags --always
git rev-parse HEAD
```

本次 v1.20.1 对应的 tag commit 为：

```text
883194a19b7244355c9bc975c0574c9842733637
```

---

## 6. 生成编译所需的嵌入资源

不能克隆后直接执行 `go build`。MediaMTX 的源码通过 `go:embed` 嵌入以下生成文件：

```text
internal/core/VERSION
internal/servers/hls/hls.min.js
```

如果跳过生成步骤，可能出现：

```text
pattern hls.min.js: no matching files found
pattern VERSION: no matching files found
```

因此先运行：

```bash
cd "$SRC_ROOT"
"$BUILD_ROOT/go/bin/go" generate ./...
```

该命令会：

1. 根据 Git tag 生成 MediaMTX 版本文件；
2. 下载并准备嵌入的 `hls.js`；
3. 准备源码要求的其他生成资源。

即使配置中最终关闭 HLS，编译阶段仍需要 `hls.min.js`，因为 Go 编译器必须完成嵌入资源解析。

---

## 7. 交叉编译 riscv64 静态程序

执行：

```bash
cd "$SRC_ROOT"

CGO_ENABLED=0 \
GOOS=linux \
GOARCH=riscv64 \
"$BUILD_ROOT/go/bin/go" build \
  -trimpath \
  -ldflags='-s -w' \
  -o "$BUILD_ROOT/mediamtx" \
  .
```

参数含义：

| 参数 | 作用 |
| --- | --- |
| `CGO_ENABLED=0` | 禁用 CGO，生成不依赖板端 C 运行库组合的静态 Go 程序 |
| `GOOS=linux` | 目标系统为 Linux |
| `GOARCH=riscv64` | 目标 CPU 为 64 位 RISC-V |
| `-trimpath` | 去掉编译主机上的源码绝对路径，提高可复现性 |
| `-ldflags='-s -w'` | 去掉符号表和 DWARF 调试信息，减小文件体积 |

检查产物：

```bash
file "$BUILD_ROOT/mediamtx"
ls -lh "$BUILD_ROOT/mediamtx"
sha256sum "$BUILD_ROOT/mediamtx"
```

正确输出应包含：

```text
ELF 64-bit LSB executable, UCB RISC-V
statically linked
```

本次构建产物约为 33 MiB。绝不能出现：

```text
x86-64
aarch64
```

---

## 8. 创建板端安装目录

在开发主机执行：

```bash
ssh spacemit@10.0.90.160 '
  mkdir -p \
    /home/spacemit/projects/mediamtx/bin \
    /home/spacemit/projects/mediamtx/config \
    /home/spacemit/projects/mediamtx/logs \
    /home/spacemit/.config/systemd/user
'
```

复制程序和许可证：

```bash
scp "$BUILD_ROOT/mediamtx" \
  spacemit@10.0.90.160:/home/spacemit/projects/mediamtx/bin/mediamtx

scp "$SRC_ROOT/LICENSE" \
  spacemit@10.0.90.160:/home/spacemit/projects/mediamtx/LICENSE
```

在板端检查：

```bash
ssh spacemit@10.0.90.160 '
  chmod +x /home/spacemit/projects/mediamtx/bin/mediamtx
  file /home/spacemit/projects/mediamtx/bin/mediamtx
  /home/spacemit/projects/mediamtx/bin/mediamtx --version
'
```

预期：

```text
v1.20.1
```

---

## 9. 编写 MediaMTX 配置

> Release 压缩包里的 `mediamtx.yml` 保持上游 v1.20.1 官方原样。下面是骰子项目的 K3 精简示例；仓库中对应文件为 `config/mediamtx-k3.yml`。部署时可以将它复制到板端并按实际 IP 修改。

在板端创建：

```text
/home/spacemit/projects/mediamtx/config/mediamtx.yml
```

内容：

```yaml
logLevel: info
logDestinations: [stdout]

# Control API 只允许板端本机访问。
api: true
apiAddress: 127.0.0.1:9997
metrics: false
pprof: false
playback: false

# 骰子程序通过 RTSP/TCP 发布 H.264。
rtsp: true
rtspTransports: [tcp]
rtspAddress: :8554

# 第一阶段只开启 RTSP 和 WebRTC，减少不需要的监听端口。
rtmp: false
hls: false
srt: false
moq: false

# WebRTC 的 HTTP/WHEP 信令和 UDP/ICE 媒体端口。
webrtc: true
webrtcAddress: :8889
webrtcEncryption: false
webrtcAllowOrigins: ["*"]
webrtcLocalUDPAddress: :8189
webrtcLocalTCPAddress: ""
webrtcIPsFromInterfaces: true
webrtcAdditionalHosts:
  - 10.0.90.160
webrtcICEServers2: []

pathDefaults:
  source: publisher
  sourceOnDemand: false
  maxReaders: 0

paths:
  dice:
    source: publisher
```

可以从开发主机写入：

```bash
cat > /tmp/mediamtx-k3.yml <<'EOF_CONFIG'
logLevel: info
logDestinations: [stdout]

api: true
apiAddress: 127.0.0.1:9997
metrics: false
pprof: false
playback: false

rtsp: true
rtspTransports: [tcp]
rtspAddress: :8554

rtmp: false
hls: false
srt: false
moq: false

webrtc: true
webrtcAddress: :8889
webrtcEncryption: false
webrtcAllowOrigins: ["*"]
webrtcLocalUDPAddress: :8189
webrtcLocalTCPAddress: ""
webrtcIPsFromInterfaces: true
webrtcAdditionalHosts:
  - 10.0.90.160
webrtcICEServers2: []

pathDefaults:
  source: publisher
  sourceOnDemand: false
  maxReaders: 0

paths:
  dice:
    source: publisher
EOF_CONFIG

scp /tmp/mediamtx-k3.yml \
  spacemit@10.0.90.160:/home/spacemit/projects/mediamtx/config/mediamtx.yml
```

### 9.1 `webrtcAdditionalHosts` 为什么要填写板端 IP

浏览器通过 WHEP 完成 SDP 协商后，还需要通过 ICE 找到 MediaMTX 的媒体端口。`webrtcAdditionalHosts` 会把可访问的板端局域网地址加入候选地址。

如果板端 IP 变化，需要修改：

```yaml
webrtcAdditionalHosts:
  - 新的板端IP
```

然后重启 MediaMTX。

如果只在同一个局域网使用，一般不需要 STUN/TURN，因此保持：

```yaml
webrtcICEServers2: []
```

跨 NAT 或公网部署时再增加 STUN/TURN。

### 9.2 为什么只启用 RTSP TCP

配置：

```yaml
rtspTransports: [tcp]
```

用于让应用到 MediaMTX 的本机 RTSP 发布链路更简单：

- 不需要额外分配 RTP/RTCP UDP 端口；
- 本机回环地址不存在明显 UDP 延迟优势；
- 更容易通过日志和端口排查。

浏览器侧 WebRTC 媒体仍然走 `8189/UDP`。

---

## 10. 创建用户级 systemd 服务

不使用 root 系统服务，而是为 `spacemit` 用户创建：

```text
/home/spacemit/.config/systemd/user/mediamtx.service
```

内容：

```ini
[Unit]
Description=MediaMTX RTSP and WebRTC server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=/home/spacemit/projects/mediamtx
ExecStart=/home/spacemit/projects/mediamtx/bin/mediamtx /home/spacemit/projects/mediamtx/config/mediamtx.yml
Restart=on-failure
RestartSec=2
LimitNOFILE=65536

[Install]
WantedBy=default.target
```

从开发主机写入：

```bash
cat > /tmp/mediamtx.service <<'EOF_SERVICE'
[Unit]
Description=MediaMTX RTSP and WebRTC server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=/home/spacemit/projects/mediamtx
ExecStart=/home/spacemit/projects/mediamtx/bin/mediamtx /home/spacemit/projects/mediamtx/config/mediamtx.yml
Restart=on-failure
RestartSec=2
LimitNOFILE=65536

[Install]
WantedBy=default.target
EOF_SERVICE

scp /tmp/mediamtx.service \
  spacemit@10.0.90.160:/home/spacemit/.config/systemd/user/mediamtx.service
```

加载并启动：

```bash
ssh spacemit@10.0.90.160 '
  systemctl --user daemon-reload
  systemctl --user enable --now mediamtx.service
  systemctl --user status mediamtx.service --no-pager
'
```

正常日志：

```text
MediaMTX v1.20.1, linux, riscv64
configuration loaded from .../mediamtx.yml
[RTSP] started with listeners on :8554 (TCP/RTSP)
[WebRTC] started with listeners on :8889 (TCP/HTTP), :8189 (UDP/ICE)
[API] started with listener on 127.0.0.1:9997 (TCP/HTTP)
```

---

## 11. 允许用户服务在退出 SSH 后继续运行

仅执行 `systemctl --user enable` 不一定能保证用户退出登录后服务继续存在。为 `spacemit` 启用 linger：

```bash
ssh spacemit@10.0.90.160 'loginctl enable-linger spacemit'
```

在部分系统中，当前用户也可以执行：

```bash
loginctl enable-linger
```

验证：

```bash
loginctl show-user spacemit -p Linger
```

应输出：

```text
Linger=yes
```

再确认：

```bash
systemctl --user is-enabled mediamtx.service
systemctl --user is-active mediamtx.service
```

应输出：

```text
enabled
active
```

---

## 12. 检查服务和端口

在板端执行：

```bash
systemctl --user status mediamtx --no-pager

ss -lntup | grep -E ':(8554|8889|8189|9997)\b'
```

预期包括：

```text
TCP *:8554
TCP *:8889
UDP *:8189
TCP 127.0.0.1:9997
```

检查 Control API：

```bash
curl http://127.0.0.1:9997/v3/paths/list
```

还没有发布流时，`dice` 应类似：

```json
{
  "name": "dice",
  "ready": false,
  "online": false,
  "tracks": []
}
```

这说明 MediaMTX 已经运行，只是在等待发布者。

---

## 13. 使用 K3 VPU 发布测试 H.264 流

先不用骰子程序，使用 FFmpeg 测试 MediaMTX 的完整输入链路。

在板端执行：

```bash
ffmpeg \
  -hide_banner \
  -loglevel info \
  -re \
  -f lavfi \
  -i 'testsrc2=size=640x360:rate=15' \
  -an \
  -c:v h264_stcodec \
  -pix_fmt nv12 \
  -g 15 \
  -bf 0 \
  -f rtsp \
  -rtsp_transport tcp \
  rtsp://127.0.0.1:8554/dice
```

关键参数：

| 参数 | 作用 |
| --- | --- |
| `testsrc2` | 生成测试视频，无需占用摄像头 |
| `h264_stcodec` | 使用 SpaceMIT 硬件 H.264 编码 |
| `nv12` | 使用 K3 编码器支持的输入格式 |
| `-g 15` | 15 FPS 下约每秒一个关键帧，便于快速开始播放 |
| `-bf 0` | 禁止 B 帧，降低 WebRTC 延迟和浏览器兼容风险 |
| `-rtsp_transport tcp` | 使用 RTSP/TCP 向 MediaMTX 发布 |

另开一个 SSH 终端检查：

```bash
curl http://127.0.0.1:9997/v3/paths/list
```

发布成功后应看到：

```json
{
  "name": "dice",
  "ready": true,
  "online": true,
  "tracks": ["H264"]
}
```

本次实际识别结果：

```text
codec: H264
resolution: 640x360
framerate: 15 FPS
```

停止测试流按：

```text
Ctrl+C
```

停止发布者不会停止 MediaMTX，路径会恢复为 `ready=false`，等待下一个发布者。

---

## 14. 验证 RTSP 读取

发布测试流期间，在板端执行：

```bash
ffprobe \
  -v error \
  -rtsp_transport tcp \
  -show_entries stream=codec_name,profile,width,height,r_frame_rate \
  -of default=noprint_wrappers=1 \
  rtsp://127.0.0.1:8554/dice
```

预期类似：

```text
codec_name=h264
profile=Main
width=640
height=360
r_frame_rate=15/1
```

也可以在局域网电脑通过 VLC/FFplay读取：

```text
rtsp://10.0.90.160:8554/dice
```

如果 RTSP 可以播放，而 WebRTC 不能播放，问题一般集中在：

- WebRTC 端口或 ICE 候选；
- 浏览器 H.264 兼容性；
- HTTPS 页面加载 HTTP WebRTC 页的混合内容限制；
- 防火墙未开放 `8189/UDP`。

---

## 15. 验证 WebRTC 和 WHEP

### 15.1 内置播放页面

发布测试流期间，在同一局域网的浏览器打开：

```text
http://10.0.90.160:8889/dice/
```

MediaMTX 会提供一个包含 `<video>` 的内置页面，并通过 WHEP 建立 WebRTC。

### 15.2 WHEP 接口

WHEP 地址：

```text
http://10.0.90.160:8889/dice/whep
```

检查接口能力：

```bash
curl -i -X OPTIONS http://10.0.90.160:8889/dice/whep
```

正常响应包括：

```text
HTTP/1.1 204 No Content
Accept-Post: application/sdp
Access-Control-Allow-Methods: OPTIONS, GET, POST, PATCH, DELETE
Access-Control-Allow-Origin: *
```

### 15.3 检查 WebRTC 会话

浏览器播放期间，在板端执行：

```bash
curl http://127.0.0.1:9997/v3/webrtcsessions/list
```

正常情况下会出现 `webRTCSession`。

也可以查看路径的 readers：

```bash
curl http://127.0.0.1:9997/v3/paths/list
```

浏览器连接后会看到类似：

```json
"readers": [
  {
    "type": "webRTCSession"
  }
]
```

本次部署已验证：

```text
RTSP H.264 发布成功
RTSP 读取成功
WHEP OPTIONS 响应成功
浏览器建立 WebRTC session
MediaMTX 产生 WebRTC outbound bytes
```

---

## 16. 前端嵌入方式

### 16.1 最简单：iframe

```html
<iframe
  src="http://10.0.90.160:8889/dice/"
  style="width: 100%; aspect-ratio: 16 / 9; border: 0"
  allow="autoplay; fullscreen"
></iframe>
```

这种方式开发量最小，但播放器 UI 由 MediaMTX 页面控制。

### 16.2 正式项目：WHEP + 自己的 `<video>`

前端页面：

```html
<video id="dice-video" autoplay muted playsinline></video>
```

然后使用 MediaMTX 提供的 reader 逻辑或兼容 WHEP 的客户端，把：

```text
http://10.0.90.160:8889/dice/whep
```

建立成 `RTCPeerConnection`，在 `ontrack` 中设置：

```javascript
peerConnection.ontrack = (event) => {
  document.getElementById('dice-video').srcObject = event.streams[0]
}
```

WHEP 的信令由 MediaMTX 处理，不需要再写一个独立 Node.js WebSocket 信令服务器。

---

## 17. 接入骰子识别程序

MediaMTX 部署完成后，骰子程序只需要成为 RTSP 发布者。

建议数据流：

```text
摄像头 NV12
  -> YOLOv8
  -> OpenCV 绘制检测框、分界线和胜负结果
  -> BGR
  -> GStreamer appsrc
  -> videoconvert
  -> NV12
  -> spacemith264enc
  -> h264parse
  -> rtspclientsink
  -> rtsp://127.0.0.1:8554/dice
```

参考 GStreamer 管线：

```text
appsrc name=source is-live=true do-timestamp=true format=time block=false
  caps=video/x-raw,format=BGR,width=1280,height=720,framerate=25/1
! queue max-size-buffers=2 leaky=downstream
! videoconvert
! video/x-raw,format=NV12
! spacemith264enc coding-width=1280 code-hight=720
! h264parse config-interval=-1
! video/x-h264,stream-format=byte-stream,alignment=au
! rtspclientsink location=rtsp://127.0.0.1:8554/dice protocols=tcp latency=0
```

注意：

1. `rtspclientsink` 会自行创建 RTP payloader，通常不要在前面额外添加 `rtph264pay`；
2. `appsrc` 必须提供合理的 PTS、DTS 和帧 duration；
3. 使用仅保留最新帧的有界队列，避免编码或网络慢时延迟持续累积；
4. WebRTC 正式播放前应确认编码器没有产生 B 帧；
5. RTSP 目标应使用 `127.0.0.1`，不要把配置中的服务监听地址 `0.0.0.0` 当作发布目标；
6. MediaMTX 必须先启动，应用的 `rtspclientsink` 才能连接成功；应用侧应考虑断线重连。

项目配置可以写成：

```json
"rtsp": {
  "enabled": true,
  "host": "127.0.0.1",
  "port": 8554,
  "path": "/dice"
}
```

如果为了兼容把 `host` 配成 `0.0.0.0`，程序应在作为客户端发布时将其规范化为 `127.0.0.1`。`0.0.0.0` 只能用于服务端监听，不能作为可靠的远程连接目标。

---

## 18. 常用运维命令

查看状态：

```bash
systemctl --user status mediamtx --no-pager
```

启动：

```bash
systemctl --user start mediamtx
```

停止：

```bash
systemctl --user stop mediamtx
```

重启：

```bash
systemctl --user restart mediamtx
```

查看实时日志：

```bash
journalctl --user -u mediamtx -f
```

查看最近 100 行日志：

```bash
journalctl --user -u mediamtx -n 100 --no-pager
```

检查流：

```bash
curl http://127.0.0.1:9997/v3/paths/list
```

检查 RTSP 会话：

```bash
curl http://127.0.0.1:9997/v3/rtspsessions/list
```

检查 WebRTC 会话：

```bash
curl http://127.0.0.1:9997/v3/webrtcsessions/list
```

检查端口：

```bash
ss -lntup | grep -E ':(8554|8889|8189|9997)\b'
```

---

## 19. 常见故障排查

### 19.1 `Exec format error`

原因：复制了 x86-64 或 ARM 二进制到 RISC-V 板子。

检查：

```bash
file /home/spacemit/projects/mediamtx/bin/mediamtx
```

必须包含：

```text
UCB RISC-V
```

### 19.2 编译时报 `hls.min.js` 或 `VERSION` 不存在

原因：跳过了生成步骤。

修复：

```bash
"$BUILD_ROOT/go/bin/go" generate ./...
```

然后重新执行 `go build`。

### 19.3 `/dice/` 页面能打开，但没有画面

先查流是否在线：

```bash
curl http://127.0.0.1:9997/v3/paths/list
```

如果：

```json
"ready": false
```

说明没有发布者，应该先检查骰子程序或 FFmpeg 是否成功推送到：

```text
rtsp://127.0.0.1:8554/dice
```

### 19.4 RTSP 正常，但 WebRTC 连不上

依次检查：

```bash
ss -lunp | grep 8189
curl -i -X OPTIONS http://板端IP:8889/dice/whep
journalctl --user -u mediamtx -f
```

确认：

- 浏览器能访问 `8889/TCP`；
- 浏览器能访问 `8189/UDP`；
- `webrtcAdditionalHosts` 是板端当前 IP；
- 前端不是 HTTPS 页面嵌入 HTTP 子资源而被浏览器拦截；
- H.264 编码参数适合浏览器。

### 19.5 板端 IP 改变后无法连接

修改：

```text
/home/spacemit/projects/mediamtx/config/mediamtx.yml
```

更新：

```yaml
webrtcAdditionalHosts:
  - 新IP
```

然后：

```bash
systemctl --user restart mediamtx
```

### 19.6 MediaMTX 重启后骰子程序不再发布

`rtspclientsink` 建立的是长连接。MediaMTX 重启会断开现有发布连接，应用必须具备以下一种能力：

- 监听 GStreamer bus error 后重建发布 pipeline；
- 在推流线程中实现有限退避重连；
- 由 systemd 设置应用依赖 MediaMTX，并在 MediaMTX 重启后同步重启应用。

### 19.7 用户退出 SSH 后服务停止

检查：

```bash
loginctl show-user spacemit -p Linger
```

如果是：

```text
Linger=no
```

执行：

```bash
loginctl enable-linger spacemit
```

---

## 20. 安全和生产化建议

当前配置针对可信局域网测试，使用：

```yaml
webrtcEncryption: false
webrtcAllowOrigins: ["*"]
```

这里的 `webrtcEncryption: false` 仅表示 WHEP HTTP 握手页面没有 HTTPS；WebRTC 媒体本身仍使用 DTLS-SRTP 加密。

生产环境建议进一步处理：

1. 在 Nginx/Caddy 后面提供 HTTPS；
2. 限制 `webrtcAllowOrigins`，不要长期使用 `*`；
3. 给 RTSP 发布和 WebRTC 读取增加认证；
4. 保持 Control API 只监听 `127.0.0.1`；
5. 只开放必要端口；
6. 公网场景部署 TURN，并控制 TURN 带宽；
7. 对 MediaMTX 和骰子程序分别设置 systemd 资源限制与自动重启；
8. 固定 MediaMTX tag 和交叉编译 Go 版本，记录 SHA-256；
9. 不要把 API Key、摄像头密码或 TURN 密钥写入公开仓库。

---

## 21. 本次部署结果摘要

板端最终文件：

```text
/home/spacemit/projects/mediamtx/bin/mediamtx
/home/spacemit/projects/mediamtx/config/mediamtx.yml
/home/spacemit/.config/systemd/user/mediamtx.service
```

最终服务状态：

```text
MediaMTX: v1.20.1 linux/riscv64
systemd user service: enabled + active
linger: enabled
RTSP: :8554/TCP
WebRTC/WHEP: :8889/TCP
ICE/SRTP: :8189/UDP
Control API: 127.0.0.1:9997/TCP
```

发布地址：

```text
rtsp://127.0.0.1:8554/dice
```

浏览器地址：

```text
http://10.0.90.160:8889/dice/
```

WHEP 地址：

```text
http://10.0.90.160:8889/dice/whep
```

本次已实际验证：

```text
riscv64 程序可运行
systemd 用户服务可运行
K3 h264_stcodec 硬件编码可发布 RTSP
MediaMTX 可识别 H.264 流
RTSP 客户端可读取
浏览器可建立 WebRTC/WHEP 会话
```
