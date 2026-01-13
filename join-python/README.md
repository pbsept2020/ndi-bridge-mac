# NDI Bridge Receiver (Python)

Receives H.264 stream over UDP and outputs as NDI.
Designed to run on Windows EC2 instance.

## Prerequisites

- Python 3.8+
- FFmpeg in PATH
- NDI Runtime (download from https://ndi.video/tools/)

## Installation

### Windows (EC2)

```powershell
# Run setup script
powershell -ExecutionPolicy Bypass -File setup_windows.ps1

# Or manual install
pip install cyndilib numpy
```

### Linux/macOS

```bash
pip install cyndilib numpy
```

## Usage

```bash
python receiver_cyndilib.py --port 5990 --name "NDI Bridge EC2"
```

### Options

| Option | Short | Default | Description |
|--------|-------|---------|-------------|
| --port | -p | 5990 | UDP port to listen on |
| --name | -n | NDI Bridge | NDI source name |
| --width | -w | 1920 | Video width hint |
| --height | | 1080 | Video height hint |

## Network Setup (AWS EC2)

### Security Group

Open UDP port 5990:
```bash
aws ec2 authorize-security-group-ingress \
  --group-id sg-xxxxx \
  --protocol udp \
  --port 5990 \
  --cidr 0.0.0.0/0
```

### Windows Firewall

```powershell
New-NetFirewallRule -DisplayName "NDI Bridge UDP" -Direction Inbound -Protocol UDP -LocalPort 5990 -Action Allow
```

## Architecture

```
Mac (Host)                           EC2 Windows (Join)
┌─────────────────┐                  ┌──────────────────┐
│ NDI Source      │                  │ receiver.py      │
│ → VideoToolbox  │                  │ ├── UDP Socket   │
│ → H.264 encode  │── UDP:5990 ────►│ ├── Reassembly   │
│ → UDP fragment  │                  │ ├── FFmpeg decode│
└─────────────────┘                  │ └── NDI output   │
                                     └────────┬─────────┘
                                              │ NDI local
                                         vMix / OBS
```

## Protocol

38-byte header (Big-Endian):
- 4 bytes: Magic ("NDIB" = 0x4E444942)
- 1 byte: Version
- 1 byte: Media type (0=video, 1=audio)
- 1 byte: Source ID
- 1 byte: Flags (bit 0 = keyframe)
- 4 bytes: Sequence number
- 8 bytes: Timestamp (nanoseconds)
- 4 bytes: Total frame size
- 2 bytes: Fragment index
- 2 bytes: Fragment count
- 2 bytes: Payload size
- 4 bytes: Sample rate (audio only)
- 1 byte: Channels (audio only)
- 3 bytes: Reserved
