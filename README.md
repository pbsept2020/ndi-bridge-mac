# NDI Bridge Mac

Production-quality NDI Bridge for macOS Apple Silicon - Stream NDI sources over WAN with hardware encoding.

## 🎯 Project Goal

Create the macOS equivalent of NDI Bridge (Windows) using:
- **VideoToolbox** for hardware H.264/H.265 encoding
- **Network.framework** for low-latency WAN streaming
- **NDI SDK 6** for local NDI integration
- **STUN/TURN** for NAT traversal

## 📁 Project Structure

```
ndi-bridge-mac/
├── Package.swift                    # Swift Package Manager config
├── run.sh                           # Launch script (sets NDI library path)
├── Sources/
│   ├── NDIBridge/                   # Main executable
│   │   ├── main.swift               # CLI entry point
│   │   ├── Host/                    # Host mode (sender)
│   │   │   ├── HostMode.swift       # Orchestrator
│   │   │   ├── NDIReceiver.swift    # NDI source capture
│   │   │   ├── VideoEncoder.swift   # H.264 encoding
│   │   │   └── NetworkSender.swift  # UDP transmission
│   │   ├── Join/                    # Join mode (receiver)
│   │   │   ├── JoinMode.swift       # Orchestrator
│   │   │   ├── NetworkReceiver.swift # UDP reception
│   │   │   ├── VideoDecoder.swift   # H.264 decoding
│   │   │   └── NDISender.swift      # NDI output broadcast
│   │   └── Common/                  # Shared utilities
│   │       └── BridgeLogger.swift   # Logging system
│   └── CNDIWrapper/                 # C bridge for NDI SDK
│       ├── include/ndi_wrapper.h
│       └── ndi_wrapper.c
├── Tests/
├── Resources/
└── Docs/
    └── ARCHITECTURE.md              # System architecture
```

## 🚀 Quick Start

### Prerequisites

1. **macOS 13+** with Apple Silicon (M1/M2/M3)
2. **Xcode 15+** installed (for Swift toolchain)
3. **NDI SDK 6** installed at `/Library/NDI SDK for Apple/`
4. **NDI Tools** (optional, for testing)

### Build

```bash
# Navigate to project
cd /Users/bessette_nouveau_macbook_pro/Projets/ndi-bridge-mac

# Build
swift build

# Or use the run script (auto-builds if needed)
./run.sh --help
```

### Usage

```bash
# Show help
./run.sh --help

# Discover NDI sources on network
./run.sh discover

# Host mode - stream NDI source to localhost (for testing)
./run.sh host --auto

# Host mode - stream to remote machine
./run.sh host --target 192.168.1.100:5990 --bitrate 15

# Join mode - receive stream and output as NDI
./run.sh join --name "Remote Camera"

# Join mode - custom port
./run.sh join --port 5991 --name "Cam 2"
```

### Test Localhost Loop

**Terminal 1 - Start receiver (Join mode):**
```bash
./run.sh join --name "NDI Bridge Test"
```

**Terminal 2 - Start sender (Host mode):**
```bash
# First, start NDI Test Pattern Generator (NDI Tools)
./run.sh host --auto
```

**Verify in NDI Studio Monitor:**
- Look for "NDI Bridge Test" source
- Should see the Test Pattern being streamed through the bridge

## 📋 Development Progress

### Phase 1: POC Video (✅ COMPLETED)
- [x] Project structure with Swift Package Manager
- [x] CNDIWrapper (C bridge for NDI SDK)
- [x] VideoToolbox H.264 encoder (hardware accelerated)
- [x] NDI source discovery and capture
- [x] UDP network transmission with fragmentation
- [x] VideoToolbox H.264 decoder
- [x] NDI output sender
- [x] Auto-detect resolution and frame rate
- [x] Source selection (interactive, --source, --auto)
- [x] CLI interface with host/join modes
- [x] Logging system

### Phase 2: Audio Support (✅ COMPLETED)
- [x] NDI audio capture (NDIReceiver)
- [x] Audio PCM transmission over network (32-bit float planar)
- [x] Packet header v2 with mediaType field (video=0, audio=1)
- [x] Packet header with sourceId (multi-source ready)
- [x] NDI audio output (NDISender)
- [x] Audio/Video synchronization validated
- [x] Separate reassemblers for video and audio streams

### Phase 3: WAN Networking
- [ ] STUN client implementation
- [ ] Hole Punch technique
- [ ] Cross-network testing (WiFi ↔ 4G)
- [ ] AAC audio encoding for bandwidth efficiency
- [ ] AWS Lambda signaling backend
- [ ] Session management

### Phase 4: UI
- [ ] SwiftUI app structure
- [ ] Source selection interface
- [ ] Connection management
- [ ] Real-time statistics display
- [ ] Settings panel

### Phase 5: Beta
- [ ] Error handling improvements
- [ ] Recovery mechanisms
- [ ] TestFlight distribution
- [ ] Documentation
- [ ] Demo videos

## 🛠️ Tech Stack

| Component | Technology |
|-----------|------------|
| Language | Swift 5.9+ |
| Encoding | VideoToolbox (H.264 hardware) |
| Networking | Network.framework (UDP) |
| NDI | NDI SDK 6 (C wrapper) |
| UI | SwiftUI (Phase 3) |
| Backend | AWS Lambda + API Gateway |

## 📊 Architecture

```
HOST MODE (Sender)                    JOIN MODE (Receiver)
┌─────────────────┐                   ┌─────────────────┐
│   NDI Source    │                   │   NDI Output    │
│ (Video + Audio) │                   │ (Video + Audio) │
└────────┬────────┘                   └────────▲────────┘
         │                                     │
         ▼                                     │
┌─────────────────┐                   ┌─────────────────┐
│  NDIReceiver    │                   │  NDISender      │
│ (Video + Audio) │                   │ (Video + Audio) │
└───┬─────────┬───┘                   └───▲─────────▲───┘
    │         │                           │         │
    ▼         │                           │         │
┌────────┐    │                           │    ┌────────┐
│ Video  │    │                           │    │ Video  │
│Encoder │    │                           │    │Decoder │
│(H.264) │    │                           │    │(H.264) │
└───┬────┘    │                           │    └───▲────┘
    │         │                           │        │
    ▼         ▼                           │        │
┌─────────────────┐    UDP/WAN        ┌─────────────────┐
│  NetworkSender  │ ───────────────── │ NetworkReceiver │
│ Video: H.264    │                   │ (Reassembly)    │
│ Audio: PCM      │                   │ Video + Audio   │
└─────────────────┘                   └─────────────────┘
```

**Data Flow:**
- Video: NDI → H.264 encode → UDP → H.264 decode → NDI
- Audio: NDI → PCM passthrough → UDP → PCM passthrough → NDI

## ⚡ Performance Targets

| Metric | Target | Status |
|--------|--------|--------|
| Latency | < 100ms e2e | TBD |
| Resolution | 1080p60 | ✅ Supported |
| Bitrate | 2-25 Mbps | ✅ Configurable |
| CPU Usage | < 30% (M1) | TBD |
| Encoding | H.264 HW | ✅ |

## 📚 Resources

### Documentation
- [VideoToolbox](https://developer.apple.com/documentation/videotoolbox)
- [Network.framework](https://developer.apple.com/documentation/network)
- [NDI SDK](https://docs.ndi.video/all/developing-with-ndi/sdk)

### Reference Projects
- [DistroAV OBS-NDI](https://github.com/DistroAV/DistroAV)
- [NDISenderExample](https://github.com/satoshi0212/NDISenderExample)

### WWDC Sessions
- [WWDC21: Low-latency encoding](https://developer.apple.com/videos/play/wwdc2021/10158/)
- [WWDC18: Network.framework](https://developer.apple.com/videos/play/wwdc2018/715/)

## 🐛 Known Issues

1. **NDI Library Path**: The NDI dynamic library must be found at runtime. Use the `run.sh` script which sets `DYLD_LIBRARY_PATH` correctly.

2. **Video Frame Structure**: The NDI SDK video frame structure offsets are approximated. May need adjustment for different NDI SDK versions.

3. **Colorimetry**: Slight color shift may occur due to BGRA→YUV conversion in H.264 encoding. BT.601 vs BT.709 colorspace handling to be improved.

4. **Compression Artifacts**: Minor pixelation visible at default 8 Mbps bitrate. Use `--bitrate 12` or higher for better quality.

## 👤 Author

Pierre Bessette - Broadcast Technology & AI Professor

## 📄 License

TBD (considering Open Core model: GPL core + Commercial integrations)
