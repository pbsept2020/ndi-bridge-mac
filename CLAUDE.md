# NDI Bridge - Instructions Claude Code

## Projet
NDI Bridge multi-plateforme - Streaming NDI sur WAN avec encodage hardware.
- **Host (sender)**: macOS Swift
- **Join (receiver)**: macOS Swift OU Windows Node.js

## Build & Run (macOS Swift)

```bash
# Builder
swift build

# Lancer (utilise DYLD_LIBRARY_PATH)
./run.sh --help
./run.sh discover          # Découvrir sources NDI
./run.sh host --auto       # Mode sender
./run.sh join --name "X"   # Mode receiver
```

## Build & Run (Windows Node.js)

```bash
cd join-node
npm install
node index.js --port 5990 --name "NDI Bridge"
```

## Dépendances

**macOS Swift:**
- NDI SDK 6 : `/Library/NDI SDK for Apple/`

**Windows Node.js:**
- Node.js 18+, FFmpeg dans PATH, NDI Runtime

## Architecture

```
Sources/NDIBridge/       # macOS Swift
├── main.swift           # CLI entry point
├── Host/                # Mode sender (NDI → H.264 → UDP)
├── Join/                # Mode receiver (UDP → H.264 → NDI)
└── Common/              # Logger, FrameBuffer

Sources/CNDIWrapper/     # Bridge C pour NDI SDK

join-node/               # Windows Node.js receiver
├── src/protocol.js      # Header parsing (38 bytes)
├── src/NetworkReceiver.js
├── src/VideoDecoder.js  # FFmpeg H.264 decode
└── src/NDISender.js     # grandiose NDI output
```

## Protocole UDP (38 bytes header, Big-Endian)

```
Offset | Champ          | Type   | Description
-------|----------------|--------|------------------
0-3    | magic          | U32    | 0x4E444942 "NDIB"
4      | version        | U8     | 2
5      | mediaType      | U8     | 0=video, 1=audio
8-11   | sequenceNumber | U32    | Frame number
12-19  | timestamp      | U64    | PTS (10M/sec)
20-23  | totalSize      | U32    | Frame size
24-27  | fragment info  | U16x2  | index, count
28-29  | payloadSize    | U16    | This packet
30-33  | sampleRate     | U32    | Audio: 48000
34     | channels       | U8     | Audio: 2
```

**Formats:** Video=H.264 Annex-B, Audio=PCM 32-bit float planar 48kHz

## État du projet

| Phase | Status |
|-------|--------|
| 1. POC Video | DONE |
| 2. Audio | DONE |
| 3. Buffer | EN COURS |
| 4. WAN | TODO |
| 5. UI | TODO |
| 6. NDI\|HX | BLOCKED (SDK Advanced requis) |

## Conventions

- Swift 5.9+, macOS 13+
- Pas de dépendances externes (frameworks Apple natifs uniquement)
- VideoToolbox pour encodage/décodage H.264
- Network.framework pour UDP
- Logs via `BridgeLogger` (utiliser `logger.info()`, etc.)

## Fichiers de référence
- `README.md` - Documentation complète
- `CLAUDE_CODE_START.md` - Progression détaillée
- `Docs/ARCHITECTURE.md` - Architecture système
- `Docs/FUTURE_OPTIMIZATIONS.md` - Roadmap optimisations
