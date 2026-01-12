# 🚀 NDI Bridge Mac - État du Projet

## 📊 Progression

| Phase | Status | Description |
|-------|--------|-------------|
| Phase 1: POC Vidéo | ✅ DONE | Streaming vidéo localhost fonctionnel |
| Phase 2: Audio | ✅ DONE | Audio PCM sync avec vidéo |
| Phase 2.5: Buffer + HX | 🎯 NOW | Buffer configurable + sortie NDI\|HX |
| Phase 3: WAN | ⏳ TODO | STUN/TURN, NAT traversal |
| Phase 4: UI | ⏳ TODO | SwiftUI app |

---

## 📁 STRUCTURE ACTUELLE

```
/Users/bessette_nouveau_macbook_pro/Projets/ndi-bridge-mac/
├── Package.swift                    ✅ Swift Package config
├── run.sh                           ✅ Script de lancement
├── Sources/
│   ├── NDIBridge/
│   │   ├── main.swift              ✅ CLI (discover, host, join)
│   │   ├── Host/                   ✅ Mode Sender
│   │   │   ├── HostMode.swift      ✅ Orchestrateur (vidéo + audio)
│   │   │   ├── NDIReceiver.swift   ✅ Capture NDI (vidéo + audio)
│   │   │   ├── VideoEncoder.swift  ✅ H.264 hardware
│   │   │   └── NetworkSender.swift ✅ UDP transmission (vidéo + audio)
│   │   ├── Join/                   ✅ Mode Receiver
│   │   │   ├── JoinMode.swift      ✅ Orchestrateur (vidéo + audio)
│   │   │   ├── NetworkReceiver.swift ✅ UDP reception + reassembly
│   │   │   ├── VideoDecoder.swift  ✅ H.264 decoding
│   │   │   └── NDISender.swift     ✅ NDI output (vidéo + audio)
│   │   └── Common/
│   │       └── BridgeLogger.swift  ✅ Logging
│   └── CNDIWrapper/                ✅ C bridge NDI SDK
│       ├── include/ndi_wrapper.h   ✅ Vidéo + Audio structures
│       └── ndi_wrapper.c           ✅ Vidéo + Audio functions
├── Tests/
├── Resources/
└── Docs/
    ├── ARCHITECTURE.md
    └── FUTURE_OPTIMIZATIONS.md     📚 Optimisations GPU/Metal (non prioritaire)
```

---

## 🎯 UTILISATION

```bash
cd /Users/bessette_nouveau_macbook_pro/Projets/ndi-bridge-mac

# Compiler
swift build

# Découvrir sources NDI
./run.sh discover

# Host mode (sender) - auto-sélection
./run.sh host --auto

# Host mode - source spécifique
./run.sh host --source "OBS"

# Host mode - bitrate custom
./run.sh host --auto --bitrate 12

# Join mode (receiver)
./run.sh join --name "NDI Bridge Output"
```

---

## ✅ PHASE 2 : AUDIO (COMPLÈTE)

### Implémentation réalisée

1. **CNDIWrapper** - Structures et fonctions audio
   - `NDIBridgeAudioFrame` (structure 64 bytes)
   - `ndi_audio_frame_create/destroy/init`
   - `ndi_receiver_free_audio`
   - `ndi_sender_send_audio`
   - Format: PCM 32-bit float planar (`NDIlib_FourCC_audio_type_FLTP`)

2. **Packet Header v2** (38 bytes)
   - `mediaType`: 0=video, 1=audio
   - `sourceId`: 0 (préparé pour multi-source)
   - `sampleRate`: taux d'échantillonnage (48000 Hz)
   - `channels`: nombre de canaux (2)
   - Backward compatible avec v1

3. **Pipeline complet**
   - NDIReceiver → NetworkSender → NetworkReceiver → NDISender
   - Audio PCM passthrough (pas d'encodage pour localhost)

### Résultat
- ✅ Audio synchronisé avec vidéo
- ✅ Pas de latence perceptible sur localhost
- ⚠️ Légers artefacts vidéo (compression H.264)
- ⚠️ Légère différence colorimétrique (à investiguer)

---

## 🎯 PHASE 2.5 : BUFFER + NDI|HX (EN COURS)

### 1. Buffer Configurable (Priorité 1)

**Objectif:** Permettre un délai configurable pour diffusion LAN stable.

**Paramètre CLI:**
```bash
./run.sh join --buffer 500  # 500ms de buffer
./run.sh join --buffer 0    # Temps réel (défaut)
```

**Implémentation:**
- Ring buffer côté Join stockant N millisecondes de frames décodées
- Sortie NDI décalée du délai configuré
- Use case: universités, institutions avec diffusion multi-salles

**Fichiers à modifier:**
- `main.swift` - Parser `--buffer <ms>`
- `JoinMode.swift` - Config buffer
- Nouveau: `Common/FrameBuffer.swift` - Ring buffer avec timestamps

### 2. Sortie NDI|HX (Priorité 2)

**Objectif:** Réduire bande passante LAN de ~125 Mbps à ~8-15 Mbps.

**Paramètre CLI:**
```bash
./run.sh join --output-format full    # UYVY/BGRA ~125 Mbps (défaut)
./run.sh join --output-format hx264   # H.264 compressé ~8-15 Mbps
./run.sh join --output-format hx265   # HEVC compressé ~5-10 Mbps
```

**Implémentation:**
- `full`: Comportement actuel (decode H.264 → BGRA → NDI)
- `hx264`: Skip decode, envoyer H.264 via NDI Advanced SDK
- `hx265`: Encoder HEVC via VideoToolbox puis envoyer

**NDI Advanced SDK:**
```c
// FourCC pour HX
NDIlib_FourCC_type_H264_highest_bandwidth  // 0x48323634
NDIlib_FourCC_type_HEVC_highest_bandwidth  // 0x48455643

// Structure pour paquets compressés
NDIlib_compressed_packet_t {
    int64_t pts, dts;
    uint32_t flags;  // NDIlib_compressed_packet_flags_keyframe
    uint8_t* p_data;
    uint32_t data_size;
    uint8_t* p_extra_data;  // SPS/PPS
    uint32_t extra_data_size;
}
```

**Fichiers à modifier:**
- `main.swift` - Parser `--output-format`
- `JoinMode.swift` - Routing selon format
- `NDISender.swift` - Nouveau mode HX
- `CNDIWrapper/ndi_wrapper.h` - Structures Advanced SDK
- `CNDIWrapper/ndi_wrapper.c` - Fonctions HX

**Use case:** Diffusion vers 50+ salles sans saturer le réseau LAN.

---

## 🎯 PHASE 3 : WAN (PROCHAINE)

### Objectifs
- STUN client pour découverte IP publique
- Hole punching UDP
- Encodage AAC pour audio (réduire bande passante)
- Signaling backend (AWS Lambda)

---

## 📋 PRÉREQUIS

- macOS 13+ Apple Silicon
- Xcode 15+
- NDI SDK 6: `/Library/NDI SDK for Apple/`
- NDI Tools (pour tester)

---

## 🔗 RÉFÉRENCES

- [VideoToolbox WWDC21](https://developer.apple.com/videos/play/wwdc2021/10158/)
- [Network.framework WWDC18](https://developer.apple.com/videos/play/wwdc2018/715/)
- [NDI SDK Docs](https://docs.ndi.video/all/developing-with-ndi/sdk)
- [NDI Advanced SDK](https://docs.ndi.video/all/developing-with-ndi/advanced-sdk)

---

## 📚 VOIR AUSSI

- `Docs/FUTURE_OPTIMIZATIONS.md` - Optimisations GPU/Metal/Zero-copy (non prioritaire)
