# NDI Bridge Mac - Architecture

## System Overview

NDI Bridge Mac enables streaming NDI sources over WAN with hardware acceleration.

```
┌─────────────────────────────────────────────────────────────────────────┐
│                          NDI Bridge Architecture                         │
└─────────────────────────────────────────────────────────────────────────┘

HOST MODE (Sender)                           JOIN MODE (Receiver)
┌────────────────────┐                      ┌────────────────────┐
│   NDI Source       │                      │   NDI Output       │
│   (Local LAN)      │                      │   (Local LAN)      │
└──────────┬─────────┘                      └──────────▲─────────┘
           │                                           │
           ▼                                           │
┌────────────────────┐                      ┌────────────────────┐
│  NDI Receiver      │                      │  NDI Sender        │
│  (NDI SDK)         │                      │  (NDI SDK)         │
└──────────┬─────────┘                      └──────────▲─────────┘
           │                                           │
           ▼                                           │
┌────────────────────┐                      ┌────────────────────┐
│  CVPixelBuffer     │                      │  CVPixelBuffer     │
│  (Native format)   │                      │  (Decoded)         │
└──────────┬─────────┘                      └──────────▲─────────┘
           │                                           │
           ▼                                           │
┌────────────────────┐                      ┌────────────────────┐
│  VideoToolbox      │                      │  VideoToolbox      │
│  Encoder           │                      │  Decoder           │
│  (H.264/H.265)     │                      │  (Hardware)        │
└──────────┬─────────┘                      └──────────▲─────────┘
           │                                           │
           ▼                                           │
┌────────────────────┐                      ┌────────────────────┐
│  Packetization     │                      │  De-packetization  │
│  + Encryption      │                      │  + Decryption      │
└──────────┬─────────┘                      └──────────▲─────────┘
           │                                           │
           ▼                                           │
┌────────────────────┐    WAN (Internet)    ┌────────────────────┐
│  Network.framework │◄────────────────────►│  Network.framework │
│  (UDP/TCP)         │  STUN/Hole Punch     │  (UDP/TCP)         │
└────────────────────┘                      └────────────────────┘
```

## Core Components

### 1. NDI Integration Layer
- **CNDIWrapper**: C bridge to NDI SDK
- **NDIReceiver**: Captures local NDI sources
- **NDISender**: Outputs as NDI on local network

### 2. Video Processing
- **VideoToolbox Encoder**: Hardware H.264/H.265 compression
- **VideoToolbox Decoder**: Hardware decompression
- **Pixel Format Conversion**: BGRA ↔ NV12 ↔ UYVY

### 3. Network Layer
- **Network.framework**: Modern UDP/TCP async I/O
- **STUN Client**: Discovers public IP:port
- **Hole Punch**: Establishes P2P connection
- **Packet Manager**: Handles fragmentation/reassembly

### 4. Signaling Backend (AWS)
- **API Gateway WebSocket**: Real-time signaling
- **Lambda Functions**: Session management
- **DynamoDB**: Store session/peer info
- **Cognito**: User authentication

## Data Flow

### Host Mode Flow
```
1. Discover NDI sources on LAN
2. User selects source to share
3. Connect NDI receiver to source
4. For each video frame:
   a. Receive NDIlib_video_frame_v2_t
   b. Extract CVPixelBuffer
   c. Feed to VTCompressionSession
   d. Receive CMSampleBuffer (compressed)
   e. Extract NAL units
   f. Packetize (MTU-sized chunks)
   g. Send via Network.framework UDP
5. Maintain statistics (bitrate, RTT, loss)
```

### Join Mode Flow
```
1. Connect to Host via signaling server
2. Perform STUN to get addresses
3. Establish UDP connection
4. For each packet received:
   a. Reassemble into CMSampleBuffer
   b. Feed to VTDecompressionSession
   c. Receive CVImageBuffer
   d. Convert to NDI format
   e. Send via NDIlib_send_send_video_v2
5. Broadcast as NDI source on LAN
```

## Threading Model

```
┌─────────────────────────────────────────────┐
│              Main Thread                    │
│  - UI updates                               │
│  - User interactions                        │
└─────────────────────────────────────────────┘
                    │
    ┌───────────────┼───────────────┐
    ▼               ▼               ▼
┌─────────┐  ┌─────────┐  ┌─────────┐
│ NDI     │  │ Encode  │  │ Network │
│ Thread  │  │ Thread  │  │ Thread  │
│         │  │         │  │         │
│ Capture │  │ Video   │  │ Send/   │
│ frames  │  │ process │  │ Receive │
└─────────┘  └─────────┘  └─────────┘
```

**Key Points:**
- NDI capture on dedicated thread (high priority)
- VideoToolbox callbacks on separate queue
- Network I/O fully async (no blocking)
- Main thread only for UI

## Memory Management

### Zero-Copy Pipeline (Goal)
```
NDI → CVPixelBuffer → VideoToolbox → Network
          ▲                              │
          └──────────── Pool ────────────┘
```

**Strategy:**
- Reuse CVPixelBuffer pool
- IOSurface backing for GPU access
- Minimal memcpy operations
- ARC for Swift objects

## Performance Targets

| Metric | Target | Notes |
|--------|--------|-------|
| End-to-end latency | < 100ms | Network RTT dependent |
| CPU usage | < 30% | M1 base, 1080p60 |
| GPU usage | < 20% | Hardware encoder |
| Memory | < 200MB | Includes buffers |
| Bitrate | 2-25 Mbps | Adaptive |

## Error Handling

### Retry Strategy
- **Network errors**: Exponential backoff (1s, 2s, 4s, 8s)
- **Encoder errors**: Restart compression session
- **NDI disconnects**: Auto-reconnect every 5s

### Graceful Degradation
- If H.265 unavailable → fallback to H.264
- If UDP fails → fallback to TCP
- If STUN fails → prompt for manual IP

## Security

### Encryption
- **In transit**: TLS 1.3 for TCP mode
- **Optional**: AES-256-GCM for UDP payloads
- **Signaling**: WSS (WebSocket Secure)

### Authentication
- AWS Cognito for user accounts
- JWT tokens for API Gateway
- Per-session encryption keys

## Scalability

### Single Machine Limits
- **M1 base**: 2-3 streams @ 1080p60
- **M1 Pro**: 4-6 streams
- **M3 Max**: 8+ streams @ 4K60

### Cloud Deployment
- Host on AWS EC2 (Linux) for cost efficiency
- Join on Mac for NDI output
- Horizontal scaling via load balancer

## Future Enhancements

### Phase 2 (Weeks 3-4)
- Audio bridging
- HDR support (HLG, PQ)
- Multi-stream simultaneous

### Phase 3 (Weeks 5-8)
- Companion integration
- PTZ control signals
- Tally over WAN

### Phase 4 (Weeks 9-12)
- Analytics dashboard
- Multi-tenant SaaS
- Mobile app (iOS/iPadOS)
