#!/usr/bin/env python3
"""Minimal NDI receiver - video only, no frills"""

import socket
import struct
import subprocess
import threading
import time
import sys
from fractions import Fraction

from cyndilib.sender import Sender
from cyndilib.video_frame import VideoSendFrame
from cyndilib.wrapper.ndi_structs import FourCC
import numpy as np

# Protocol
MAGIC = 0x4E444942
HEADER_SIZE = 38

class MinimalReceiver:
    def __init__(self, port=5990, name="NDI Bridge", width=1920, height=1080):
        self.port = port
        self.width = width
        self.height = height
        self.frame_size = self.width * self.height * 2

        # NDI
        print("[1] Creating Sender...")
        self.sender = Sender(name)

        print("[2] Creating VideoSendFrame...")
        self.vf = VideoSendFrame()
        self.vf.set_resolution(self.width, self.height)
        self.vf.set_frame_rate(Fraction(30, 1))
        self.vf.set_fourcc(FourCC.UYVY)

        print("[3] Adding frame to sender...")
        self.sender.set_video_frame(self.vf)

        print("[4] Opening sender...")
        self.sender.open()
        print("[5] NDI Ready!")

        # FFmpeg
        print("[6] Starting FFmpeg...")
        self.ffmpeg = subprocess.Popen(
            ['ffmpeg', '-hide_banner', '-loglevel', 'warning',
             '-f', 'h264', '-i', 'pipe:0',
             '-f', 'rawvideo', '-pix_fmt', 'uyvy422',
             '-s', f'{self.width}x{self.height}', 'pipe:1'],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE
        )
        print("[7] FFmpeg started!")

        # Decoder thread
        self.running = True
        self.video_frames = 0
        self.decoder_thread = threading.Thread(target=self.decode_loop, daemon=True)
        self.decoder_thread.start()

    def decode_loop(self):
        while self.running:
            try:
                data = self.ffmpeg.stdout.read(self.frame_size)
                if len(data) == self.frame_size:
                    arr = np.frombuffer(data, dtype=np.uint8).copy()
                    self.sender.write_video_async(arr)
                    self.video_frames += 1
            except:
                break

    def run(self):
        # UDP socket
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        sock.bind(('0.0.0.0', self.port))
        sock.settimeout(1.0)
        print(f"[8] Listening on UDP {self.port}")
        print("[9] Ready - waiting for stream...")

        # Reassembly
        fragments = {}
        current_seq = None
        packets = 0
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
                    if media_type != 0:  # Skip audio
                        continue

                    seq = struct.unpack('>I', data[8:12])[0]
                    frag_idx = struct.unpack('>H', data[24:26])[0]
                    frag_count = struct.unpack('>H', data[26:28])[0]
                    payload_size = struct.unpack('>H', data[28:30])[0]
                    payload = data[HEADER_SIZE:HEADER_SIZE + payload_size]

                    packets += 1

                    if current_seq != seq:
                        fragments = {}
                        current_seq = seq

                    fragments[frag_idx] = payload

                    if len(fragments) == frag_count:
                        frame = b''.join(fragments[i] for i in range(frag_count))
                        fragments = {}
                        current_seq = None
                        self.ffmpeg.stdin.write(frame)
                        self.ffmpeg.stdin.flush()

                except socket.timeout:
                    pass

                # Log stats
                if time.time() - last_log >= 1.0:
                    if packets > 0:
                        print(f"[Stats] Packets: {packets} | Video frames sent: {self.video_frames}")
                    packets = 0
                    last_log = time.time()

        except KeyboardInterrupt:
            print("\nStopping...")
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
    print("Minimal NDI Receiver")
    print("="*50)
    print(f"Resolution: {args.width}x{args.height}")

    try:
        r = MinimalReceiver(port=args.port, name=args.name, width=args.width, height=args.height)
        r.run()
    except Exception as e:
        print(f"FATAL: {e}")
        import traceback
        traceback.print_exc()
