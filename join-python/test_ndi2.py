#!/usr/bin/env python3
"""Test exact same code as test_ndi.py but with different name"""

from cyndilib.sender import Sender
from cyndilib.video_frame import VideoSendFrame
from cyndilib.wrapper.ndi_structs import FourCC
from fractions import Fraction

print("Test 1: Creating Sender with 'NDI Bridge EC2'...")
try:
    sender = Sender("NDI Bridge EC2")
    print("  OK")
except Exception as e:
    print(f"  FAILED: {e}")
    exit(1)

print("Test 2: Creating VideoSendFrame...")
try:
    vf = VideoSendFrame()
    vf.set_resolution(1920, 1080)
    vf.set_frame_rate(Fraction(30, 1))
    vf.set_fourcc(FourCC.UYVY)
    print("  OK")
except Exception as e:
    print(f"  FAILED: {e}")
    exit(1)

print("Test 3: Adding frame to sender...")
try:
    sender.set_video_frame(vf)
    print("  OK")
except Exception as e:
    print(f"  FAILED: {e}")
    exit(1)

print("Test 4: Opening sender...")
try:
    sender.open()
    print("  OK")
except Exception as e:
    print(f"  FAILED: {e}")
    import traceback
    traceback.print_exc()
    exit(1)

print("Test 5: Closing sender...")
sender.close()
print("  OK")

print("\nALL TESTS PASSED!")
