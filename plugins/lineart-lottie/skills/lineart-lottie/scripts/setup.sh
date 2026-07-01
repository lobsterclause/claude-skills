#!/usr/bin/env bash
# One-time setup for the lineart-lottie pipeline: a Python venv with the
# vectorizer's deps. Node scripts have no npm deps (pure ESM); preview/gif-grid
# load lottie-web from a CDN.
#
# Usage:  bash scripts/setup.sh [VENV_DIR]   (default: .venv next to this skill)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV="${1:-$HERE/../.venv}"

if ! command -v python3 >/dev/null; then
  echo "python3 not found — install Python 3.10+ first." >&2
  exit 1
fi

echo "Creating venv at: $VENV"
python3 -m venv "$VENV"
"$VENV/bin/pip" install --quiet --upgrade pip
# Vectorizer deps. numpy 2.x is fine (tracer.py avoids the removed np.cross scalar form).
"$VENV/bin/pip" install --quiet numpy Pillow scikit-image scipy

echo
echo "Done. The venv python is: $VENV/bin/python"
"$VENV/bin/python" - <<'PY'
import numpy, PIL, skimage, scipy
print(f"  numpy {numpy.__version__}  Pillow {PIL.__version__}  scikit-image {skimage.__version__}  scipy {scipy.__version__}")
PY
echo
echo "Node: v18+ (uses only built-ins). Check: node --version"
echo "Next: see SKILL.md — generate a raster, then tracer.py -> build_lottie.mjs -> preview.mjs"
