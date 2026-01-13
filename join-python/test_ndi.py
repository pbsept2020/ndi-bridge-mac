#!/usr/bin/env python3
"""Test NDI initialization with cyndilib"""

import sys
import os

print("=" * 50)
print("NDI Diagnostic Test")
print("=" * 50)

# Check NDI Runtime paths
ndi_paths = [
    r"C:\Program Files\NDI\NDI 6 Runtime\bin\x64",
    r"C:\Program Files\NDI\NDI 5 Runtime\bin\x64",
    r"C:\Program Files\NewTek\NDI 5 Runtime\bin\x64",
]

print("\n[1] Checking NDI Runtime paths...")
found_ndi = False
for path in ndi_paths:
    if os.path.exists(path):
        print(f"  FOUND: {path}")
        found_ndi = True
        # Check for Processing.NDI.Lib.x64.dll
        dll_path = os.path.join(path, "Processing.NDI.Lib.x64.dll")
        if os.path.exists(dll_path):
            print(f"  DLL OK: {dll_path}")
        else:
            print(f"  DLL MISSING: {dll_path}")
    else:
        print(f"  not found: {path}")

if not found_ndi:
    print("\n  WARNING: NDI Runtime not found!")
    print("  Download from: https://ndi.video/tools/")

# Check environment variable
print("\n[2] Checking NDI_RUNTIME_DIR_V6 environment variable...")
ndi_env = os.environ.get("NDI_RUNTIME_DIR_V6")
if ndi_env:
    print(f"  NDI_RUNTIME_DIR_V6 = {ndi_env}")
else:
    print("  NDI_RUNTIME_DIR_V6 not set")
    # Try V5
    ndi_env5 = os.environ.get("NDI_RUNTIME_DIR_V5")
    if ndi_env5:
        print(f"  NDI_RUNTIME_DIR_V5 = {ndi_env5}")

# Try importing cyndilib
print("\n[3] Testing cyndilib import...")
try:
    import cyndilib
    print(f"  cyndilib version: {cyndilib.__version__ if hasattr(cyndilib, '__version__') else 'unknown'}")
    print("  Import OK")
except Exception as e:
    print(f"  Import FAILED: {e}")
    sys.exit(1)

# Try creating sender
print("\n[4] Testing Sender creation...")
try:
    from cyndilib.sender import Sender
    from cyndilib.video_frame import VideoSendFrame
    from cyndilib.wrapper.ndi_structs import FourCC
    from fractions import Fraction

    print("  Creating Sender...")
    sender = Sender("Test NDI")
    print("  Sender created OK")

    print("  Creating VideoSendFrame...")
    vf = VideoSendFrame()
    vf.set_resolution(1920, 1080)
    vf.set_frame_rate(Fraction(30, 1))
    vf.set_fourcc(FourCC.UYVY)
    print("  VideoSendFrame created OK")

    print("  Adding video frame to sender...")
    sender.set_video_frame(vf)
    print("  Video frame added OK")

    print("  Opening sender...")
    sender.open()
    print("  Sender opened OK!")

    print("  Closing sender...")
    sender.close()
    print("  Sender closed OK")

    print("\n" + "=" * 50)
    print("ALL TESTS PASSED!")
    print("=" * 50)

except Exception as e:
    print(f"  FAILED: {e}")
    import traceback
    traceback.print_exc()
    sys.exit(1)
