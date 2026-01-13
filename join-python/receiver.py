#!/usr/bin/env python3
"""
NDI Bridge Receiver (Python)
Receives H.264 stream over UDP and outputs as NDI

Usage:
    python receiver.py --port 5990 --name "NDI Bridge"

Requirements:
    pip install ndi-python numpy
    FFmpeg in PATH
"""

import socket
import struct
import subprocess
import threading
import argparse
import time
import sys

try:
    import NDIlib as ndi
except ImportError:
    print("ERROR: ndi-python not installed. Run: pip install ndi-python")
    sys.exit(1)

import numpy as np

# Protocol constants
MAGIC = 0x4E444942  # "NDIB"
HEADER_SIZE = 38

class FrameReassembler:
    """Collects UDP fragments and reassembles complete frames"""

    def __init__(self, name):
        self.name = name
        self.fragments = {}
        self.current_sequence = None
        self.expected_count = 0

    def add_fragment(self, header, payload):
        seq = header['sequence_number']
        frag_idx = header['fragment_index']
        frag_count = header['fragment_count']

        # New sequence - reset
        if self.current_sequence != seq:
            if self.current_sequence is not None and len(self.fragments) > 0:
                print(f"[{self.name}] Incomplete frame dropped: seq={self.current_sequence}")
            self.fragments = {}
            self.current_sequence = seq
            self.expected_count = frag_count

        # Store fragment
        self.fragments[frag_idx] = payload

        # Check if complete
        if len(self.fragments) == frag_count:
            # Reassemble in order
            data = b''.join(self.fragments[i] for i in range(frag_count))
            self.fragments = {}
            self.current_sequence = None
            return data

        return None


def parse_header(data):
    """Parse 38-byte packet header"""
    if len(data) < HEADER_SIZE:
        return None

    magic = struct.unpack('>I', data[0:4])[0]
    if magic != MAGIC:
        return None

    return {
        'magic': magic,
        'version': data[4],
        'media_type': data[5],  # 0=video, 1=audio
        'source_id': data[6],
        'flags': data[7],
        'sequence_number': struct.unpack('>I', data[8:12])[0],
        'timestamp': struct.unpack('>Q', data[12:20])[0],
        'total_size': struct.unpack('>I', data[20:24])[0],
        'fragment_index': struct.unpack('>H', data[24:26])[0],
        'fragment_count': struct.unpack('>H', data[26:28])[0],
        'payload_size': struct.unpack('>H', data[28:30])[0],
        'sample_rate': struct.unpack('>I', data[30:34])[0],
        'channels': data[34],
        'is_keyframe': (data[7] & 0x01) == 1
    }


class NDIBridgeReceiver:
    def __init__(self, port=5990, ndi_name="NDI Bridge", width=1920, height=1080):
        self.port = port
        self.ndi_name = ndi_name
        self.width = width
        self.height = height
        self.running = False

        # Reassemblers
        self.video_reassembler = FrameReassembler('video')
        self.audio_reassembler = FrameReassembler('audio')

        # Stats
        self.packets_received = 0
        self.video_frames = 0
        self.audio_frames = 0
        self.bytes_received = 0
        self.last_stats_time = time.time()

        # NDI sender
        self.ndi_send = None

        # FFmpeg decoder
        self.ffmpeg_process = None
        self.decoder_thread = None

    def start_ndi(self):
        """Initialize NDI sender"""
        if not ndi.initialize():
            print("[NDI] Failed to initialize NDI")
            return False

        send_settings = ndi.SendCreate()
        send_settings.ndi_name = self.ndi_name
        send_settings.clock_video = False
        send_settings.clock_audio = False

        self.ndi_send = ndi.send_create(send_settings)
        if self.ndi_send is None:
            print("[NDI] Failed to create NDI sender")
            return False

        print(f"[NDI] Sender created: {self.ndi_name}")
        return True

    def start_ffmpeg(self):
        """Start FFmpeg decoder process"""
        cmd = [
            'ffmpeg',
            '-hide_banner',
            '-loglevel', 'warning',
            '-f', 'h264',
            '-i', 'pipe:0',
            '-f', 'rawvideo',
            '-pix_fmt', 'uyvy422',
            '-s', f'{self.width}x{self.height}',
            'pipe:1'
        ]

        self.ffmpeg_process = subprocess.Popen(
            cmd,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE
        )

        # Start decoder output thread
        self.decoder_thread = threading.Thread(target=self.decoder_loop, daemon=True)
        self.decoder_thread.start()

        print(f"[FFmpeg] Decoder started: {self.width}x{self.height}")

    def decoder_loop(self):
        """Read decoded frames from FFmpeg and send to NDI"""
        frame_size = self.width * self.height * 2  # UYVY = 2 bytes/pixel

        while self.running and self.ffmpeg_process:
            try:
                data = self.ffmpeg_process.stdout.read(frame_size)
                if len(data) == frame_size:
                    self.send_ndi_video(data)
            except Exception as e:
                print(f"[Decoder] Error: {e}")
                break

    def send_ndi_video(self, frame_data):
        """Send video frame to NDI"""
        if not self.ndi_send:
            return

        video_frame = ndi.VideoFrameV2()
        video_frame.xres = self.width
        video_frame.yres = self.height
        video_frame.FourCC = ndi.FOURCC_VIDEO_TYPE_UYVY
        video_frame.frame_rate_N = 30000
        video_frame.frame_rate_D = 1000
        video_frame.picture_aspect_ratio = self.width / self.height
        video_frame.line_stride_in_bytes = self.width * 2
        video_frame.data = np.frombuffer(frame_data, dtype=np.uint8)

        ndi.send_send_video_v2(self.ndi_send, video_frame)
        self.video_frames += 1

    def send_ndi_audio(self, audio_data, sample_rate, channels):
        """Send audio frame to NDI"""
        if not self.ndi_send:
            return

        # PCM 32-bit float
        samples = len(audio_data) // (4 * channels)

        audio_frame = ndi.AudioFrameV2()
        audio_frame.sample_rate = sample_rate
        audio_frame.no_channels = channels
        audio_frame.no_samples = samples
        audio_frame.channel_stride_in_bytes = samples * 4
        audio_frame.data = np.frombuffer(audio_data, dtype=np.float32)

        ndi.send_send_audio_v2(self.ndi_send, audio_frame)
        self.audio_frames += 1

    def process_packet(self, data):
        """Process incoming UDP packet"""
        header = parse_header(data)
        if not header:
            return

        self.packets_received += 1
        self.bytes_received += len(data)

        payload = data[HEADER_SIZE:HEADER_SIZE + header['payload_size']]

        if header['media_type'] == 0:  # Video
            frame = self.video_reassembler.add_fragment(header, payload)
            if frame and self.ffmpeg_process:
                try:
                    self.ffmpeg_process.stdin.write(frame)
                    self.ffmpeg_process.stdin.flush()
                except Exception as e:
                    print(f"[FFmpeg] Write error: {e}")

        elif header['media_type'] == 1:  # Audio
            frame = self.audio_reassembler.add_fragment(header, payload)
            if frame:
                self.send_ndi_audio(frame, header['sample_rate'], header['channels'])

    def log_stats(self):
        """Log statistics every second"""
        now = time.time()
        elapsed = now - self.last_stats_time

        if elapsed > 0 and self.packets_received > 0:
            mbps = (self.bytes_received * 8 / elapsed / 1_000_000)
            print(f"[Stats] {mbps:.2f} Mbps | Video: {self.video_frames} | Audio: {self.audio_frames} | Packets: {self.packets_received}")

        self.packets_received = 0
        self.bytes_received = 0
        self.video_frames = 0
        self.audio_frames = 0
        self.last_stats_time = now

    def run(self):
        """Main receiver loop"""
        print("=" * 50)
        print("NDI Bridge Receiver (Python)")
        print("=" * 50)
        print(f"Port: {self.port}")
        print(f"NDI Name: {self.ndi_name}")
        print(f"Resolution: {self.width}x{self.height}")
        print("=" * 50)

        # Initialize components
        if not self.start_ndi():
            return

        self.start_ffmpeg()

        # Create UDP socket
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        sock.bind(('0.0.0.0', self.port))
        sock.settimeout(1.0)

        print(f"[UDP] Listening on 0.0.0.0:{self.port}")
        print("[Main] Ready - waiting for stream...")
        print("[Main] Press Ctrl+C to stop")

        self.running = True
        last_stats = time.time()

        try:
            while self.running:
                try:
                    data, addr = sock.recvfrom(65535)
                    self.process_packet(data)
                except socket.timeout:
                    pass

                # Log stats every second
                if time.time() - last_stats >= 1.0:
                    self.log_stats()
                    last_stats = time.time()

        except KeyboardInterrupt:
            print("\n[Main] Shutting down...")

        finally:
            self.running = False
            sock.close()
            if self.ffmpeg_process:
                self.ffmpeg_process.terminate()
            if self.ndi_send:
                ndi.send_destroy(self.ndi_send)
            ndi.destroy()
            print("[Main] Stopped")


def main():
    parser = argparse.ArgumentParser(description='NDI Bridge Receiver')
    parser.add_argument('--port', '-p', type=int, default=5990, help='UDP port (default: 5990)')
    parser.add_argument('--name', '-n', type=str, default='NDI Bridge', help='NDI source name')
    parser.add_argument('--width', '-w', type=int, default=1920, help='Video width')
    parser.add_argument('--height', type=int, default=1080, help='Video height')

    args = parser.parse_args()

    receiver = NDIBridgeReceiver(
        port=args.port,
        ndi_name=args.name,
        width=args.width,
        height=args.height
    )
    receiver.run()


if __name__ == '__main__':
    main()
