# 🐧 PROMPT: Portabilité NDI Bridge Mac → Linux

> **Généré le** : 2026-01-27
> **Source** : `/Users/bessette_nouveau_macbook_pro/Projets/ndi-bridge-mac`
> **Version macOS NDI SDK** : 6.3.0.3

---

## Contexte du Projet

Je souhaite porter mon application **NDI Bridge for Mac** (écrite en Swift) vers Linux. C'est un bridge NDI qui :
- **Host mode (sender)** : Capture NDI → Encode H.264 → Envoie via UDP
- **Join mode (receiver)** : Reçoit UDP → Décode H.264 → Output NDI

**Dépôt source** : `/Users/bessette_nouveau_macbook_pro/Projets/ndi-bridge-mac`

---

## Architecture Actuelle (macOS Swift)

```
Sources/
├── NDIBridge/
│   ├── main.swift              # CLI entry point
│   ├── Host/
│   │   ├── HostMode.swift      # Orchestrator
│   │   ├── NDIReceiver.swift   # Capture NDI source
│   │   ├── VideoEncoder.swift  # VideoToolbox H.264 encode
│   │   └── NetworkSender.swift # Network.framework UDP send
│   ├── Join/
│   │   ├── JoinMode.swift      # Orchestrator
│   │   ├── NetworkReceiver.swift # Network.framework UDP receive
│   │   ├── VideoDecoder.swift  # VideoToolbox H.264 decode
│   │   └── NDISender.swift     # Output NDI source
│   └── Common/
│       └── BridgeLogger.swift
└── CNDIWrapper/                # C bridge pour NDI SDK
    ├── include/ndi_wrapper.h
    └── ndi_wrapper.c
```

---

## Dépendances macOS à Remplacer

| Composant macOS | Remplacement Linux | Notes |
|-----------------|-------------------|-------|
| **VideoToolbox** (VTCompressionSession, VTDecompressionSession) | **FFmpeg/libav** avec libx264 (software) ou VAAPI (Intel) / NVENC (NVIDIA) | API complètement différente |
| **Network.framework** (NWConnection, NWListener) | **Sockets POSIX** (socket, bind, sendto, recvfrom) ou **libuv/asio** | UDP simple, pas besoin d'abstraction lourde |
| **CoreMedia/CoreVideo** (CVPixelBuffer, CMSampleBuffer) | **AVFrame/AVPacket** FFmpeg ou buffers bruts | Gestion mémoire différente |
| **QuartzCore** (CACurrentMediaTime) | `clock_gettime(CLOCK_MONOTONIC)` | Trivial |
| **NDI SDK for Apple** | **NDI SDK for Linux** | Même API C, juste chemins différents |

---

## NDI SDK Linux - Installation & Compatibilité

### Version Actuelle macOS
```
NDI 2026-01-21 git-43259a87 v6.3.0.3
Installé dans: /Library/NDI SDK for Apple/
```

### Téléchargement SDK Linux

```bash
# Télécharger NDI SDK 6.x pour Linux
wget https://downloads.ndi.tv/SDK/NDI_SDK_Linux/Install_NDI_SDK_v6_Linux.tar.gz
tar xzf Install_NDI_SDK_v6_Linux.tar.gz

# Installer (accepter la licence interactivement)
./Install_NDI_SDK_v6_Linux.sh

# Le SDK sera extrait dans ~/NDI SDK for Linux/
```

### Installation Système

```bash
# Copier les bibliothèques
sudo cp -r "$HOME/NDI SDK for Linux/lib/x86_64-linux-gnu/"* /usr/lib/
# Ou pour ARM64:
# sudo cp -r "$HOME/NDI SDK for Linux/lib/aarch64-linux-gnu/"* /usr/lib/

# Copier les headers
sudo cp -r "$HOME/NDI SDK for Linux/include/"* /usr/include/

# Mettre à jour le cache des libs
sudo ldconfig

# Vérifier
ls -la /usr/lib/libndi*
ls -la /usr/include/Processing.NDI*
```

### Nouveautés NDI 6.x Pertinentes pour Linux

| Version | Amélioration |
|---------|-------------|
| **6.3.0** | NDI Discovery Server standalone pour Linux, APIs sender discovery/monitoring |
| **6.2.0** | Discovery Server comme service Linux, receiver discovery APIs |
| **6.1.0** | NDI Free Audio pour Linux, améliorations RUDP |
| **6.0.0** | Support P216/PA16 16-bit, NDI Bridge Utility pour hardware Linux |
| **5.1.0** | **GSO (Generic Segmentation Offload)** pour RUDP - gains CPU majeurs (kernel 4.18+) |

### Compatibilité API

L'API C du NDI SDK est **identique** entre macOS et Linux. Le `CNDIWrapper` existant fonctionnera avec des modifications mineures :

```c
// macOS - actuel
#include "/Library/NDI SDK for Apple/include/Processing.NDI.Lib.h"

// Linux - à modifier
#include <Processing.NDI.Lib.h>  // Si installé dans /usr/include
// ou
#include "Processing.NDI.Lib.h"  // Si chemin relatif
```

### CMake pour NDI SDK Linux

```cmake
# FindNDI.cmake
find_path(NDI_INCLUDE_DIR
    NAMES Processing.NDI.Lib.h
    PATHS
        /usr/include
        /usr/local/include
        $ENV{HOME}/NDI\ SDK\ for\ Linux/include
)

find_library(NDI_LIBRARY
    NAMES ndi
    PATHS
        /usr/lib
        /usr/lib/x86_64-linux-gnu
        /usr/local/lib
        $ENV{HOME}/NDI\ SDK\ for\ Linux/lib/x86_64-linux-gnu
)

include(FindPackageHandleStandardArgs)
find_package_handle_standard_args(NDI DEFAULT_MSG NDI_LIBRARY NDI_INCLUDE_DIR)

if(NDI_FOUND)
    set(NDI_LIBRARIES ${NDI_LIBRARY})
    set(NDI_INCLUDE_DIRS ${NDI_INCLUDE_DIR})
endif()
```

---

## Protocole UDP Préservé (38 bytes header)

Le protocole réseau reste **identique** pour compatibilité cross-platform :

```
Offset | Champ          | Type   | Description
-------|----------------|--------|------------------
0-3    | magic          | U32    | 0x4E444942 "NDIB"
4      | version        | U8     | 2
5      | mediaType      | U8     | 0=video, 1=audio
6      | sourceId       | U8     | Multi-source (futur)
7      | flags          | U8     | bit 0 = keyframe
8-11   | sequenceNumber | U32    | Frame number
12-19  | timestamp      | U64    | PTS (10MHz clock)
20-23  | totalSize      | U32    | Frame size totale
24-25  | fragmentIndex  | U16    | Index fragment
26-27  | fragmentCount  | U16    | Nombre fragments
28-29  | payloadSize    | U16    | Taille ce packet
30-33  | sampleRate     | U32    | Audio: 48000
34     | channels       | U8     | Audio: 2
35-37  | reserved       | U8[3]  | Padding
```

**Formats** : Video = H.264 Annex-B, Audio = PCM 32-bit float planar 48kHz

---

## Options de Langage pour Linux

### Option A : Swift sur Linux (si expertise Swift)
- Swift 5.9+ fonctionne sur Linux
- Foundation fonctionne (avec limitations)
- Avantage : réutiliser logique métier
- Inconvénient : FFmpeg bindings Swift moins matures

### Option B : C++ (recommandé pour performance)
- FFmpeg natif
- Contrôle total mémoire
- Intégration NDI SDK directe
- Pattern similaire : obs-ndi, DistroAV

### Option C : Rust (moderne, safe)
- ffmpeg-next crate
- Excellent pour concurrence
- Courbe apprentissage si pas familier

**Recommandation** : C++ pour Linux (plus proche de l'écosystème broadcast)

---

## Structure Cible Linux (C++)

```
ndi-bridge-linux/
├── CMakeLists.txt
├── cmake/
│   └── FindNDI.cmake
├── src/
│   ├── main.cpp              # CLI entry
│   ├── host/
│   │   ├── HostMode.cpp
│   │   ├── HostMode.h
│   │   ├── NDIReceiver.cpp   # NDI SDK Linux
│   │   ├── NDIReceiver.h
│   │   ├── VideoEncoder.cpp  # FFmpeg libx264/VAAPI/NVENC
│   │   ├── VideoEncoder.h
│   │   ├── NetworkSender.cpp # POSIX sockets UDP
│   │   └── NetworkSender.h
│   ├── join/
│   │   ├── JoinMode.cpp
│   │   ├── JoinMode.h
│   │   ├── NetworkReceiver.cpp
│   │   ├── NetworkReceiver.h
│   │   ├── VideoDecoder.cpp
│   │   ├── VideoDecoder.h
│   │   ├── NDISender.cpp
│   │   └── NDISender.h
│   ├── common/
│   │   ├── Logger.cpp
│   │   ├── Logger.h
│   │   ├── FrameBuffer.cpp
│   │   ├── FrameBuffer.h
│   │   └── Protocol.h        # Header 38 bytes
│   └── ndi/
│       ├── NDIWrapper.cpp    # Wrapper NDI SDK (basé sur CNDIWrapper)
│       └── NDIWrapper.h
├── include/
│   └── ndi_bridge.h
├── scripts/
│   ├── build.sh
│   └── run.sh
└── README.md
```

---

## Tâches de Portabilité

### Phase 1 : Infrastructure
- [ ] Setup CMake avec find_package(FFmpeg) et FindNDI.cmake
- [ ] Intégrer NDI SDK Linux (`/usr/lib`, `/usr/include`)
- [ ] Implémenter Logger équivalent (spdlog ou custom)
- [ ] Implémenter Protocol.h (header 38 bytes - identique)

### Phase 2 : Networking (le plus simple)
- [ ] NetworkSender avec sockets POSIX UDP
- [ ] NetworkReceiver avec sockets POSIX UDP  
- [ ] FrameReassembler (logique identique au Swift)

### Phase 3 : Video Encoding
- [ ] VideoEncoder avec FFmpeg (AVCodecContext, AVFrame, AVPacket)
- [ ] Support libx264 (software, universel)
- [ ] Support optionnel VAAPI (Intel)
- [ ] Support optionnel NVENC (NVIDIA)
- [ ] Output Annex-B (sps/pps + NAL units)

### Phase 4 : Video Decoding
- [ ] VideoDecoder avec FFmpeg
- [ ] Parse Annex-B → extradata + NAL units
- [ ] Output AVFrame BGRA ou NV12

### Phase 5 : NDI Integration
- [ ] NDIReceiver avec NDI SDK Linux (basé sur CNDIWrapper)
- [ ] NDISender avec NDI SDK Linux
- [ ] Gestion formats pixel (BGRA, UYVY)

### Phase 6 : CLI & Polish
- [ ] CLI avec getopt ou cxxopts
- [ ] Graceful shutdown (signal handlers)
- [ ] Documentation

---

## Dépendances Linux

```bash
# Ubuntu 22.04 / 24.04
sudo apt update
sudo apt install -y \
    build-essential \
    cmake \
    pkg-config \
    libavcodec-dev \
    libavformat-dev \
    libavutil-dev \
    libswscale-dev \
    libswresample-dev \
    libx264-dev

# Optionnel - Hardware acceleration
sudo apt install -y \
    libva-dev \          # VAAPI (Intel)
    libnvidia-encode-dev # NVENC (si GPU NVIDIA)

# NDI SDK - voir section "NDI SDK Linux" ci-dessus
```

---

## Code Référence

### Protocol.h (identique Swift)

```cpp
#pragma once
#include <cstdint>
#include <cstring>
#include <vector>

constexpr uint32_t NDIB_MAGIC = 0x4E444942;  // "NDIB"
constexpr uint8_t NDIB_VERSION = 2;
constexpr size_t NDIB_HEADER_SIZE = 38;

enum class MediaType : uint8_t {
    Video = 0,
    Audio = 1
};

#pragma pack(push, 1)
struct MediaPacketHeader {
    uint32_t magic = NDIB_MAGIC;
    uint8_t version = NDIB_VERSION;
    uint8_t mediaType = 0;
    uint8_t sourceId = 0;
    uint8_t flags = 0;
    uint32_t sequenceNumber = 0;
    uint64_t timestamp = 0;
    uint32_t totalSize = 0;
    uint16_t fragmentIndex = 0;
    uint16_t fragmentCount = 0;
    uint16_t payloadSize = 0;
    uint32_t sampleRate = 48000;
    uint8_t channels = 2;
    uint8_t reserved[3] = {0, 0, 0};
    
    bool isKeyframe() const { return flags & 1; }
    bool isVideo() const { return mediaType == 0; }
    bool isAudio() const { return mediaType == 1; }
    
    std::vector<uint8_t> toBytes() const {
        std::vector<uint8_t> data(NDIB_HEADER_SIZE);
        size_t offset = 0;
        
        auto writeBE32 = [&](uint32_t v) {
            data[offset++] = (v >> 24) & 0xFF;
            data[offset++] = (v >> 16) & 0xFF;
            data[offset++] = (v >> 8) & 0xFF;
            data[offset++] = v & 0xFF;
        };
        auto writeBE64 = [&](uint64_t v) {
            for (int i = 7; i >= 0; --i)
                data[offset++] = (v >> (i * 8)) & 0xFF;
        };
        auto writeBE16 = [&](uint16_t v) {
            data[offset++] = (v >> 8) & 0xFF;
            data[offset++] = v & 0xFF;
        };
        
        writeBE32(magic);
        data[offset++] = version;
        data[offset++] = mediaType;
        data[offset++] = sourceId;
        data[offset++] = flags;
        writeBE32(sequenceNumber);
        writeBE64(timestamp);
        writeBE32(totalSize);
        writeBE16(fragmentIndex);
        writeBE16(fragmentCount);
        writeBE16(payloadSize);
        writeBE32(sampleRate);
        data[offset++] = channels;
        data[offset++] = 0; data[offset++] = 0; data[offset++] = 0;
        
        return data;
    }
    
    static MediaPacketHeader fromBytes(const uint8_t* data) {
        MediaPacketHeader h;
        size_t offset = 0;
        
        auto readBE32 = [&]() -> uint32_t {
            uint32_t v = (data[offset] << 24) | (data[offset+1] << 16) |
                         (data[offset+2] << 8) | data[offset+3];
            offset += 4;
            return v;
        };
        auto readBE64 = [&]() -> uint64_t {
            uint64_t v = 0;
            for (int i = 0; i < 8; ++i)
                v = (v << 8) | data[offset++];
            return v;
        };
        auto readBE16 = [&]() -> uint16_t {
            uint16_t v = (data[offset] << 8) | data[offset+1];
            offset += 2;
            return v;
        };
        
        h.magic = readBE32();
        h.version = data[offset++];
        h.mediaType = data[offset++];
        h.sourceId = data[offset++];
        h.flags = data[offset++];
        h.sequenceNumber = readBE32();
        h.timestamp = readBE64();
        h.totalSize = readBE32();
        h.fragmentIndex = readBE16();
        h.fragmentCount = readBE16();
        h.payloadSize = readBE16();
        h.sampleRate = readBE32();
        h.channels = data[offset++];
        
        return h;
    }
};
#pragma pack(pop)
```

### VideoEncoder FFmpeg (exemple)

```cpp
// VideoEncoder.cpp - Équivalent de VideoToolbox
#include "VideoEncoder.h"

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavutil/opt.h>
#include <libavutil/imgutils.h>
}

class VideoEncoder {
    AVCodecContext* ctx_ = nullptr;
    AVFrame* frame_ = nullptr;
    AVPacket* pkt_ = nullptr;
    
public:
    bool configure(int width, int height, int bitrate, int fps) {
        const AVCodec* codec = avcodec_find_encoder_by_name("libx264");
        if (!codec) return false;
        
        ctx_ = avcodec_alloc_context3(codec);
        ctx_->width = width;
        ctx_->height = height;
        ctx_->pix_fmt = AV_PIX_FMT_NV12;  // ou YUV420P
        ctx_->bit_rate = bitrate;
        ctx_->time_base = {1, fps};
        ctx_->framerate = {fps, 1};
        ctx_->gop_size = fps;  // 1 keyframe/sec
        ctx_->max_b_frames = 0;  // Low latency
        
        // Low latency preset
        av_opt_set(ctx_->priv_data, "preset", "ultrafast", 0);
        av_opt_set(ctx_->priv_data, "tune", "zerolatency", 0);
        
        if (avcodec_open2(ctx_, codec, nullptr) < 0) return false;
        
        frame_ = av_frame_alloc();
        frame_->format = ctx_->pix_fmt;
        frame_->width = width;
        frame_->height = height;
        av_frame_get_buffer(frame_, 0);
        
        pkt_ = av_packet_alloc();
        return true;
    }
    
    bool encode(const uint8_t* data, int64_t pts,
                std::function<void(const uint8_t*, size_t, bool)> callback) {
        // Copy data to frame (assuming BGRA input, convert to NV12)
        // ... conversion code ...
        
        frame_->pts = pts;
        
        int ret = avcodec_send_frame(ctx_, frame_);
        if (ret < 0) return false;
        
        while (ret >= 0) {
            ret = avcodec_receive_packet(ctx_, pkt_);
            if (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF) break;
            if (ret < 0) return false;
            
            bool isKeyframe = pkt_->flags & AV_PKT_FLAG_KEY;
            callback(pkt_->data, pkt_->size, isKeyframe);
            av_packet_unref(pkt_);
        }
        return true;
    }
    
    ~VideoEncoder() {
        if (pkt_) av_packet_free(&pkt_);
        if (frame_) av_frame_free(&frame_);
        if (ctx_) avcodec_free_context(&ctx_);
    }
};
```

### NetworkSender POSIX (exemple)

```cpp
// NetworkSender.cpp - Équivalent de Network.framework
#include "NetworkSender.h"
#include "Protocol.h"

#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>

class NetworkSender {
    int sockfd_ = -1;
    sockaddr_in dest_addr_;
    uint32_t sequence_ = 0;
    static constexpr int MTU = 1400;
    
public:
    bool connect(const std::string& host, uint16_t port) {
        sockfd_ = socket(AF_INET, SOCK_DGRAM, 0);
        if (sockfd_ < 0) return false;
        
        memset(&dest_addr_, 0, sizeof(dest_addr_));
        dest_addr_.sin_family = AF_INET;
        dest_addr_.sin_port = htons(port);
        inet_pton(AF_INET, host.c_str(), &dest_addr_.sin_addr);
        
        return true;
    }
    
    void sendVideo(const uint8_t* data, size_t size, bool keyframe, uint64_t ts) {
        const int maxPayload = MTU - NDIB_HEADER_SIZE;
        const int fragmentCount = (size + maxPayload - 1) / maxPayload;
        
        ++sequence_;
        
        for (int i = 0; i < fragmentCount; ++i) {
            size_t start = i * maxPayload;
            size_t end = std::min(start + maxPayload, size);
            size_t fragSize = end - start;
            
            MediaPacketHeader header;
            header.mediaType = static_cast<uint8_t>(MediaType::Video);
            header.flags = keyframe ? 1 : 0;
            header.sequenceNumber = sequence_;
            header.timestamp = ts;
            header.totalSize = static_cast<uint32_t>(size);
            header.fragmentIndex = static_cast<uint16_t>(i);
            header.fragmentCount = static_cast<uint16_t>(fragmentCount);
            header.payloadSize = static_cast<uint16_t>(fragSize);
            
            auto headerBytes = header.toBytes();
            std::vector<uint8_t> packet(headerBytes.begin(), headerBytes.end());
            packet.insert(packet.end(), data + start, data + end);
            
            sendto(sockfd_, packet.data(), packet.size(), 0,
                   (sockaddr*)&dest_addr_, sizeof(dest_addr_));
        }
    }
    
    void disconnect() {
        if (sockfd_ >= 0) {
            close(sockfd_);
            sockfd_ = -1;
        }
    }
    
    ~NetworkSender() { disconnect(); }
};
```

---

## Questions pour Démarrer

1. **Langage préféré** : Swift (porter la logique) ou C++ (réécrire propre) ?
2. **Hardware acceleration** : Software only (libx264) ou VAAPI/NVENC ?
3. **Target distro** : Ubuntu 22.04/24.04 ? Debian ? Autre ?
4. **Priorité** : Host mode first ou Join mode first ?

---

## Commande pour Lancer le Portage

```
Commence le portage de ndi-bridge-mac vers Linux en C++.
- Lis d'abord les fichiers Swift de référence dans ~/Projets/ndi-bridge-mac/
- Crée la structure CMake avec FindNDI.cmake
- Implémente en priorité : Protocol.h, NetworkSender, NetworkReceiver
- Puis VideoEncoder avec FFmpeg libx264
- Enfin intégration NDI SDK Linux
- Assure la compatibilité du protocole UDP avec la version macOS
```

---

## Fichiers de Référence (macOS Swift)

| Fichier | Description | Priorité portage |
|---------|-------------|------------------|
| `Sources/NDIBridge/main.swift` | CLI entry point | Medium |
| `Sources/NDIBridge/Host/VideoEncoder.swift` | VideoToolbox H.264 | High |
| `Sources/NDIBridge/Host/NetworkSender.swift` | UDP send + fragmentation | High |
| `Sources/NDIBridge/Join/VideoDecoder.swift` | VideoToolbox H.264 | High |
| `Sources/NDIBridge/Join/NetworkReceiver.swift` | UDP receive + reassembly | High |
| `Sources/CNDIWrapper/ndi_wrapper.c` | C bridge NDI SDK | Medium (réutilisable) |
| `Sources/CNDIWrapper/include/ndi_wrapper.h` | Header NDI wrapper | Medium (réutilisable) |

---

*Ce prompt a été généré automatiquement depuis l'analyse du projet ndi-bridge-mac.*
