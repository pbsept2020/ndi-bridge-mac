#!/usr/bin/env python3
"""NDI Bridge Receiver with Audio+Video support"""

import socket
import struct
import subprocess
import threading
import time
import sys
from fractions import Fraction

from cyndilib.sender import Sender
from cyndilib.video_frame import VideoSendFrame
from cyndilib.audio_frame import AudioSendFrame
from cyndilib.wrapper.ndi_structs import FourCC
import numpy as np

# Protocol
MAGIC = 0x4E444942
HEADER_SIZE = 38

class Receiver:
    def __init__(self, port=5990, name="NDI Bridge", width=1920, height=1080):
        self.port = port
        self.width = width
        self.height = height
        self.frame_size = width * height * 2  # UYVY
        self.running = True

        # Stats
        self.video_frames = 0
        self.audio_frames = 0
        self.packets = 0
        self.h264_frames = 0  # H.264 frames sent to FFmpeg

        # NDI Sender
        print(f"[NDI] Creating sender: {name}")
        self.sender = Sender(name)

        # Video frame
        self.vf = VideoSendFrame()
        self.vf.set_resolution(width, height)
        self.vf.set_frame_rate(Fraction(30, 1))
        self.vf.set_fourcc(FourCC.UYVY)
        self.sender.set_video_frame(self.vf)
        print(f"[NDI] Video: {width}x{height}")

        # Audio disabled for now - causes MemoryError
        self.af = None
        print("[NDI] Audio: DISABLED (video only)")

        # FFmpeg decoder
        print("[FFmpeg] Starting decoder...")
        self.ffmpeg = subprocess.Popen(
            ['ffmpeg', '-hide_banner', '-loglevel', 'warning',
             '-f', 'h264', '-i', 'pipe:0',
             '-f', 'rawvideo', '-pix_fmt', 'uyvy422',
             '-s', f'{width}x{height}', 'pipe:1'],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE
        )

        # Decoder thread
        self.decoder_thread = threading.Thread(target=self.decode_loop, daemon=True)

    def decode_loop(self):
        """Read decoded video from FFmpeg and send to NDI"""
        print("[Decoder] Thread started, waiting for frames...")
        while self.running:
            try:
                data = self.ffmpeg.stdout.read(self.frame_size)
                if len(data) == self.frame_size:
                    arr = np.frombuffer(data, dtype=np.uint8).copy()
                    self.sender.write_video_async(arr)
                    self.video_frames += 1
                    if self.video_frames == 1:
                        print("[Decoder] First frame decoded!")
                elif len(data) > 0:
                    print(f"[Decoder] Partial frame: {len(data)}/{self.frame_size} bytes")
                else:
                    # Check FFmpeg stderr for errors
                    err = self.ffmpeg.stderr.read(1024)
                    if err:
                        print(f"[FFmpeg] stderr: {err.decode('utf-8', errors='ignore')}")
                    break
            except Exception as e:
                print(f"[Decoder] Error: {e}")
                break
        print("[Decoder] Thread stopped")

    def send_audio(self, audio_data, channels):
        """Send audio to NDI"""
        if self.af is None:
            return  # Audio disabled
        try:
            audio_float = np.frombuffer(audio_data, dtype=np.float32).copy()
            samples = len(audio_float) // channels
            audio_2d = audio_float.reshape((channels, samples))
            self.sender.write_audio(audio_2d)
            self.audio_frames += 1
        except Exception as e:
            print(f"[Audio] Error: {e}")

    def run(self):
        # Start sender
        print("[NDI] Opening sender...")
        self.sender.open()
        print("[NDI] Sender ready!")

        # Start decoder thread
        self.decoder_thread.start()

        # UDP socket
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        sock.bind(('0.0.0.0', self.port))
        sock.settimeout(1.0)
        print(f"[UDP] Listening on port {self.port}")
        print("[Main] Ready - waiting for stream...")

        # Reassembly buffers
        video_frags = {}
        video_seq = None
        audio_frags = {}
        audio_seq = None

        last_log = time.time()

        try:
            while self.running:
                try:
                    data, _ = sock.recvfrom(65535)
                    if len(data) < HEADER_SIZE:
                        continue

                    magic = struct.unpack('>I', data[0:4])[0]
                    if magic != MAGIC:
                        continue

                    media_type = data[5]
                    seq = struct.unpack('>I', data[8:12])[0]
                    frag_idx = struct.unpack('>H', data[24:26])[0]
                    frag_count = struct.unpack('>H', data[26:28])[0]
                    payload_size = struct.unpack('>H', data[28:30])[0]
                    channels = data[34]
                    payload = data[HEADER_SIZE:HEADER_SIZE + payload_size]

                    self.packets += 1

                    if media_type == 0:  # Video
                        if video_seq != seq:
                            video_frags = {}
                            video_seq = seq
                        video_frags[frag_idx] = payload
                        if len(video_frags) == frag_count:
                            frame = b''.join(video_frags[i] for i in range(frag_count))
                            video_frags = {}
                            video_seq = None
                            self.ffmpeg.stdin.write(frame)
                            self.ffmpeg.stdin.flush()
                            self.h264_frames += 1
                            if self.h264_frames == 1:
                                print(f"[Video] First H.264 frame: {len(frame)} bytes")

                    elif media_type == 1:  # Audio
                        if audio_seq != seq:
                            audio_frags = {}
                            audio_seq = seq
                        audio_frags[frag_idx] = payload
                        if len(audio_frags) == frag_count:
                            frame = b''.join(audio_frags[i] for i in range(frag_count))
                            audio_frags = {}
                            audio_seq = None
                            self.send_audio(frame, channels if channels > 0 else 2)

                except socket.timeout:
                    pass

                # Log stats
                if time.time() - last_log >= 1.0:
                    if self.packets > 0:
                        print(f"[Stats] Packets: {self.packets} | H264→FFmpeg: {self.h264_frames} | NDI Video: {self.video_frames} | Audio: {self.audio_frames}")
                    self.packets = 0
                    last_log = time.time()

        except KeyboardInterrupt:
            print("\n[Main] Stopping...")
        finally:
            self.running = False
            sock.close()
            self.ffmpeg.terminate()
            self.sender.close()


if __name__ == '__main__':
    import argparse
    p = argparse.ArgumentParser()
    p.add_argument('--port', '-p', type=int, default=5990)
    p.add_argument('--name', '-n', default='NDI Bridge')
    p.add_argument('--width', '-w', type=int, default=1920)
    p.add_argument('--height', type=int, default=1080)
    args = p.parse_args()

    print("="*50)
    print("NDI Bridge Receiver (Audio+Video)")
    print("="*50)
    print(f"Resolution: {args.width}x{args.height}")

    try:
        r = Receiver(port=args.port, name=args.name, width=args.width, height=args.height)
        r.run()
    except Exception as e:
        print(f"FATAL: {e}")
        import traceback
        traceback.print_exc()
