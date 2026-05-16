#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

echo "=== Building MyLlamaSpeechAssistant ==="

# Step 1: Build (SwiftPM fetches mlx-swift, swift-transformers, etc. from GitHub)
echo "[1/2] Building (fetching dependencies + compiling)..."
swift build --disable-sandbox

# Step 2: Compile MLX Metal library from the fetched mlx-swift checkout
echo "[2/2] Compiling MLX Metal library..."

BUILD_DIR="${SCRIPT_DIR}/.build"
ARCH="$(uname -m)-apple-macosx"
CONFIG="debug"
OUT_DIR="${BUILD_DIR}/${ARCH}/${CONFIG}"
if [[ ! -d "${OUT_DIR}" ]]; then
    OUT_DIR="$(find "${BUILD_DIR}" -maxdepth 3 -type d -path "*/${CONFIG}" 2>/dev/null | head -n1 || true)"
fi

# mlx-swift is fetched by SwiftPM into .build/checkouts/
MLX_SWIFT_DIR="${BUILD_DIR}/checkouts/mlx-swift"
KERNELS_DIR="${MLX_SWIFT_DIR}/Source/Cmlx/mlx/mlx/backend/metal/kernels"

if [[ -d "${KERNELS_DIR}" && -n "${OUT_DIR}" ]]; then
    OUT_METALLIB="${OUT_DIR}/mlx.metallib"
    HASH_FILE="${OUT_DIR}/.mlx.metallib.sha"

    CURRENT_HASH="$(find "${KERNELS_DIR}" -type f \( -name '*.metal' -o -name '*.h' \) ! -name '*_nax.metal' 2>/dev/null | LC_ALL=C sort | xargs cat 2>/dev/null | shasum -a 256 | awk '{print $1}')"

    SKIP=0
    if [[ -f "${OUT_METALLIB}" && -f "${HASH_FILE}" ]]; then
        PREV_HASH="$(cat "${HASH_FILE}" 2>/dev/null || true)"
        if [[ "${CURRENT_HASH}" == "${PREV_HASH}" ]]; then
            echo "mlx.metallib up to date, skipped"
            SKIP=1
        fi
    fi

    if [[ "${SKIP}" != "1" ]]; then
        TMP="$(mktemp -d /tmp/mlx-metallib.XXXXXX)"
        trap "rm -rf ${TMP}" EXIT

        AIR_FILES=()
        while IFS= read -r f; do
            AIR="${TMP}/$(basename "${f}" .metal).air"
            xcrun -sdk macosx metal \
                -x metal -Wall -Wextra -fno-fast-math \
                -Wno-c++17-extensions -Wno-c++20-extensions \
                -c "${f}" \
                -I"${KERNELS_DIR}" \
                -I"${MLX_SWIFT_DIR}/Source/Cmlx/mlx" \
                -o "${AIR}"
            AIR_FILES+=("${AIR}")
        done < <(find "${KERNELS_DIR}" -name '*.metal' ! -name '*_nax.metal' | LC_ALL=C sort)

        echo "Linking mlx.metallib -> ${OUT_METALLIB}"
        xcrun -sdk macosx metallib "${AIR_FILES[@]}" -o "${OUT_METALLIB}"
        echo "${CURRENT_HASH}" > "${HASH_FILE}"
        echo "OK"
    fi
else
    echo "Warning: MLX kernels not found at ${KERNELS_DIR}"
    echo "GPU inference will use slower JIT shader compilation."
fi

echo ""
echo "=== Build Complete ==="
echo "Run: ${OUT_DIR:-.build/debug}/MyLlamaSpeechAssistant"

if [ "$1" == "--run" ]; then
    echo ""
    echo "=== Starting ==="
    "${OUT_DIR:-.build/debug}/MyLlamaSpeechAssistant"
fi
