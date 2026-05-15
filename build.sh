#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SPEECHSWIFT_DIR="${SCRIPT_DIR}/../personaplex-mlx-swift/speech-swift"

echo "=== Building MyLlamaSpeechAssistant ==="

echo "[1/3] Building..."
cd "${SCRIPT_DIR}"
swift build --disable-sandbox

echo "[2/3] Copying MLX Metallib..."
METALLIB_SRC="${SPEECHSWIFT_DIR}/Examples/PersonaPlexDemo/.build/arm64-apple-macosx/release/mlx.metallib"
METALLIB_DST="${SCRIPT_DIR}/.build/debug/mlx.metallib"

if [ -f "${METALLIB_SRC}" ]; then
    cp "${METALLIB_SRC}" "${METALLIB_DST}"
    echo "Successfully copied mlx.metallib"
else
    echo "Warning: mlx.metallib not found at ${METALLIB_SRC}"
    echo "GPU inference will be slow (JIT shader compilation)."
    echo "Build PersonaPlexDemo first: cd ${SPEECHSWIFT_DIR}/Examples/PersonaPlexDemo && bash build.sh"
fi

echo ""
echo "=== Build Complete ==="
echo "Run: ${SCRIPT_DIR}/.build/debug/MyLlamaSpeechAssistant"

if [ "$1" == "--run" ]; then
    echo ""
    echo "=== Starting ==="
    "${SCRIPT_DIR}/.build/debug/MyLlamaSpeechAssistant"
fi
