#!/bin/bash
# NDI Bridge Mac - Run Script
# Sets up the NDI library path and runs the bridge

export DYLD_LIBRARY_PATH="/Library/NDI SDK for Apple/lib/macOS:$DYLD_LIBRARY_PATH"

# Build if needed
if [ ! -f ".build/debug/ndi-bridge" ] || [ "$1" == "--build" ]; then
    echo "Building NDI Bridge..."
    swift build
    if [ $? -ne 0 ]; then
        echo "Build failed!"
        exit 1
    fi
    # Remove --build from args if present
    if [ "$1" == "--build" ]; then
        shift
    fi
fi

# Run with all arguments
exec .build/debug/ndi-bridge "$@"
