#!/bin/bash
# Builds the standalone Bluetooth-headset diagnostic monitor.
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${PROJECT_DIR}"

mkdir -p binaries logs

echo "=== Building HeadsetMonitor ==="
swiftc -O \
    -o binaries/HeadsetMonitor \
    scripts/HeadsetMonitor.swift \
    -framework AppKit \
    -framework AVFoundation \
    -framework MediaPlayer \
    -framework CoreGraphics \
    -framework ApplicationServices \
    -framework IOKit \
    -framework CoreAudio

echo "Built: ${PROJECT_DIR}/binaries/HeadsetMonitor"
echo
echo "Run from the project root:"
echo "  ./binaries/HeadsetMonitor"
echo "  ./binaries/HeadsetMonitor --check   # quick setup/device check only"
