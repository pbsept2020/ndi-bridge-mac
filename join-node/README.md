# NDI Bridge Join (Node.js)

Receiver Node.js pour NDI Bridge - Reçoit un flux H.264 sur UDP et le diffuse en NDI local.

## Architecture

```
Mac (Swift Host)                    Windows (Node.js Join)
┌─────────────────┐                 ┌─────────────────┐
│ NDI Source      │                 │ NetworkReceiver │
│       ↓         │                 │       ↓         │
│ VideoEncoder    │── UDP/WAN ────► │ VideoDecoder    │
│ (H.264)         │                 │ (FFmpeg)        │
│       ↓         │                 │       ↓         │
│ NetworkSender   │                 │ NDISender       │
└─────────────────┘                 │ (grandiose)     │
                                    └───────┬─────────┘
                                            │
                                       NDI local
                                            │
                                      vMix / OBS
```

## Prérequis

- **Node.js** 18+
- **FFmpeg** dans le PATH système
- **NDI Runtime** installé (NDI Tools)

## Installation

```bash
cd join-node
npm install
```

## Utilisation

```bash
# Basique (port 5990, nom "NDI Bridge")
node index.js

# Port et nom custom
node index.js --port 5990 --name "Remote Camera"

# Avec résolution hint
node index.js --port 5990 --name "HD Feed" --width 1920 --height 1080
```

## Options

| Option | Court | Défaut | Description |
|--------|-------|--------|-------------|
| `--port` | `-p` | 5990 | Port UDP d'écoute |
| `--name` | `-n` | "NDI Bridge" | Nom de la source NDI |
| `--width` | `-w` | 1920 | Largeur vidéo (hint) |
| `--height` | | 1080 | Hauteur vidéo (hint) |
| `--help` | | | Affiche l'aide |

## Test

### Sur Windows (EC2)
```bash
node index.js --port 5990 --name "NDI Bridge Test"
```

### Sur Mac (sender)
```bash
cd /path/to/ndi-bridge-mac
./run.sh host --auto --target <IP_WINDOWS>:5990
```

### Vérification
- Ouvrir vMix ou OBS
- La source "NDI Bridge Test" devrait apparaître

## Protocole

Compatible avec NDI Bridge Mac (header 38 bytes, version 2) :
- **Video** : H.264 Annex-B
- **Audio** : PCM 32-bit float planar, 48kHz, stereo

## Dépendances

- `grandiose` - Bindings NDI pour Node.js
- `dgram` - Socket UDP (natif Node.js)
- FFmpeg (externe) - Décodage H.264

## Troubleshooting

### "Cannot find module 'grandiose'"
```bash
npm install grandiose
```

### "FFmpeg not found"
Installer FFmpeg et l'ajouter au PATH :
- Windows : `choco install ffmpeg` ou télécharger depuis ffmpeg.org
- Vérifier : `ffmpeg -version`

### "NDI source not visible"
- Vérifier que NDI Runtime est installé
- Vérifier le firewall (port UDP + NDI discovery)
- Redémarrer l'application NDI cliente
