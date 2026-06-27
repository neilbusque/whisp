#!/bin/bash
# Vendors whisper.cpp + ggml source into Sources/CWhisper so the repo builds
# offline as a SwiftPM C/C++ target, and downloads the default model.
#
# NOTE ON APPROACH (Task 7): this Mac has Command Line Tools only (no Xcode.app),
# so the Metal shader compiler (`xcrun metal`) is ABSENT. We therefore vendor the
# CPU backend only (Accelerate-accelerated). The model is kept warm in RAM by
# WhisperTranscriber; no per-call reload. See .superpowers/sdd/task-7-report.md.
#
# The file list below is tailored to the ACTUAL v1.7.4 layout (it differs from
# the plan brief: backend-reg/threading/opt sources are new, ggml-cpu is a dir).
set -euo pipefail
cd "$(dirname "$0")/.."

WC_VER="v1.7.4"   # pinned
DEST="Sources/CWhisper"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "› cloning whisper.cpp $WC_VER ..."
# Keep stderr visible — a shallow clone of this ~300MB repo is the most likely
# failure point, and a silent failure reads as a hang. Only stdout is hushed.
git clone --depth 1 --branch "$WC_VER" https://github.com/ggerganov/whisper.cpp "$TMP/wc" >/dev/null

# Clean any prior vendored tree (but keep our hand-written include/module.modulemap).
rm -rf "$DEST/src" "$DEST/ggml"
mkdir -p "$DEST/include"

# ---- whisper core ----
mkdir -p "$DEST/src"
cp "$TMP/wc/src/whisper.cpp"                 "$DEST/src/"
cp "$TMP/wc/include/whisper.h"               "$DEST/include/"

# ---- ggml: public headers ----
# Copied to BOTH ggml/include (for compiling ggml sources) and include/ (the
# module's publicHeadersPath) because whisper.h transitively #includes "ggml.h"
# and the Clang module is built from include/ only.
mkdir -p "$DEST/ggml/include"
cp "$TMP/wc/ggml/include/"*.h                "$DEST/ggml/include/"
cp "$TMP/wc/ggml/include/"*.h                "$DEST/include/"

# ---- ggml: core sources (CPU backend, no GPU) ----
mkdir -p "$DEST/ggml/src"
cp "$TMP/wc/ggml/src/ggml.c"                 "$DEST/ggml/src/"
cp "$TMP/wc/ggml/src/ggml-alloc.c"           "$DEST/ggml/src/"
cp "$TMP/wc/ggml/src/ggml-backend.cpp"       "$DEST/ggml/src/"
cp "$TMP/wc/ggml/src/ggml-backend-reg.cpp"   "$DEST/ggml/src/"
cp "$TMP/wc/ggml/src/ggml-quants.c"          "$DEST/ggml/src/"
cp "$TMP/wc/ggml/src/ggml-threading.cpp"     "$DEST/ggml/src/"
cp "$TMP/wc/ggml/src/ggml-opt.cpp"           "$DEST/ggml/src/"
# private headers next to the sources
cp "$TMP/wc/ggml/src/ggml-backend-impl.h"    "$DEST/ggml/src/"
cp "$TMP/wc/ggml/src/ggml-common.h"          "$DEST/ggml/src/"
cp "$TMP/wc/ggml/src/ggml-impl.h"            "$DEST/ggml/src/"
cp "$TMP/wc/ggml/src/ggml-quants.h"          "$DEST/ggml/src/"
cp "$TMP/wc/ggml/src/ggml-threading.h"       "$DEST/ggml/src/"

# ---- ggml: CPU backend dir (mixed .c/.cpp + headers) ----
# The amx sources are x86-only (guarded by __AMX_INT8__/__AVX512VNNI__) so they
# compile to empty TUs on arm64, but amx/amx.h is #included unconditionally by
# ggml-cpu.{c,cpp}, so the whole amx dir must be vendored. llamafile/sgemm is
# behind GGML_USE_LLAMAFILE (not defined) so it is skipped.
mkdir -p "$DEST/ggml/src/ggml-cpu/amx"
cp "$TMP/wc/ggml/src/ggml-cpu/ggml-cpu.c"            "$DEST/ggml/src/ggml-cpu/"
cp "$TMP/wc/ggml/src/ggml-cpu/ggml-cpu.cpp"          "$DEST/ggml/src/ggml-cpu/"
cp "$TMP/wc/ggml/src/ggml-cpu/ggml-cpu-aarch64.cpp"  "$DEST/ggml/src/ggml-cpu/"
cp "$TMP/wc/ggml/src/ggml-cpu/ggml-cpu-aarch64.h"    "$DEST/ggml/src/ggml-cpu/"
cp "$TMP/wc/ggml/src/ggml-cpu/ggml-cpu-hbm.h"        "$DEST/ggml/src/ggml-cpu/"
cp "$TMP/wc/ggml/src/ggml-cpu/ggml-cpu-quants.c"     "$DEST/ggml/src/ggml-cpu/"
cp "$TMP/wc/ggml/src/ggml-cpu/ggml-cpu-quants.h"     "$DEST/ggml/src/ggml-cpu/"
cp "$TMP/wc/ggml/src/ggml-cpu/ggml-cpu-traits.cpp"   "$DEST/ggml/src/ggml-cpu/"
cp "$TMP/wc/ggml/src/ggml-cpu/ggml-cpu-traits.h"     "$DEST/ggml/src/ggml-cpu/"
cp "$TMP/wc/ggml/src/ggml-cpu/ggml-cpu-impl.h"       "$DEST/ggml/src/ggml-cpu/"
cp "$TMP/wc/ggml/src/ggml-cpu/amx/"*.h               "$DEST/ggml/src/ggml-cpu/amx/"
cp "$TMP/wc/ggml/src/ggml-cpu/amx/"*.cpp             "$DEST/ggml/src/ggml-cpu/amx/"

echo "✓ Vendored whisper.cpp $WC_VER (CPU backend) into $DEST"

# ---- default model ----
mkdir -p "$HOME/.whisp/models"
MODEL="$HOME/.whisp/models/ggml-base.en.bin"
if [ -f "$MODEL" ]; then
  echo "✓ model already present at $MODEL"
else
  echo "› downloading ggml-base.en.bin (~150MB) ..."
  curl -L --fail \
    https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin \
    -o "$MODEL"
  echo "✓ model at $MODEL"
fi
