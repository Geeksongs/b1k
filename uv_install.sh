#!/usr/bin/env bash
set -e

# =========================
# Config
# =========================
CUDA_VERSION="12.4"
PYTHON_VERSION="3.10" # Isaac Sim wheels are only published for cp310
WORKDIR=$(pwd)

# Optional flags
DATASET=false
ACCEPT_DATASET_TOS=false

export OMNI_KIT_ACCEPT_EULA=YES


# =========================
# Parse arguments
# =========================
HELP=false
while [[ $# -gt 0 ]]; do
  case $1 in
    -h|--help) HELP=true; shift ;;
    --dataset) DATASET=true; shift ;;
    --accept-dataset-tos) ACCEPT_DATASET_TOS=true; shift ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

if [ "$HELP" = true ]; then
  cat << EOF
Usage: ./uv_install.sh [OPTIONS]

Options:
  -h, --help              Show this help
  --dataset               Download OmniGibson robot assets + BEHAVIOR-1K assets + 2025 challenge instances
  --accept-dataset-tos    Auto-accept BEHAVIOR dataset license (passed to download_behavior_1k_assets)

Example:
  ./uv_install.sh --dataset --accept-dataset-tos
EOF
  exit 0
fi


# =========================
# Sanity checks
# =========================
command -v uv >/dev/null || {
  echo "ERROR: uv not found. Install with: pip install uv"
  exit 1
}

python --version | grep -q "Python ${PYTHON_VERSION}" || {
  echo "ERROR: Python ${PYTHON_VERSION} required (Isaac Sim wheels are cp310-only)"
  exit 1
}

[ -d "OmniGibson" ] || {
  echo "ERROR: OmniGibson directory not found"
  exit 1
}

# Isaac Sim env conflicts
if [[ -n "$EXP_PATH" || -n "$CARB_APP_PATH" || -n "$ISAAC_PATH" ]]; then
  echo "ERROR: Existing Isaac Sim environment variables detected"
  exit 1
fi

# =========================
# Initialize uv project
# =========================
if [ ! -f pyproject.toml ]; then
  echo "Initializing uv project..."
  uv init
fi


# =========================
# Install OmniGibson (editable)
# =========================
echo "Installing OmniGibson (editable)..."
uv pip install -e "$WORKDIR/bddl3"
uv pip install -e "$WORKDIR/OmniGibson"

# =========================
# Isaac Sim installation
# =========================
echo "Installing Isaac Sim..."

check_glibc_old() {
  ldd --version 2>&1 | grep -qE "2\.(31|32|33)"
}

TMPDIR=$(mktemp -d)

ISAAC_PKGS=(
  omniverse_kit-106.5.0.162521
  isaacsim_kernel-4.5.0.0
  isaacsim_app-4.5.0.0
  isaacsim_core-4.5.0.0
  isaacsim_gui-4.5.0.0
  isaacsim_utils-4.5.0.0
  isaacsim_storage-4.5.0.0
  isaacsim_asset-4.5.0.0
  isaacsim_sensor-4.5.0.0
  isaacsim_robot_motion-4.5.0.0
  isaacsim_robot-4.5.0.0
  isaacsim_benchmark-4.5.0.0
  isaacsim_code_editor-4.5.0.0
  isaacsim_ros1-4.5.0.0
  isaacsim_ros2-4.5.0.0
  isaacsim_cortex-4.5.0.0
  isaacsim_example-4.5.0.0
  isaacsim_replicator-4.5.0.0
  isaacsim_rl-4.5.0.0
  isaacsim_robot_setup-4.5.0.0
  isaacsim_template-4.5.0.0
  isaacsim_test-4.5.0.0
  isaacsim-4.5.0.0
  isaacsim_extscache_physics-4.5.0.0
  isaacsim_extscache_kit-4.5.0.0
  isaacsim_extscache_kit_sdk-4.5.0.0
)

WHEELS=()

for pkg in "${ISAAC_PKGS[@]}"; do
  name=${pkg%-*}
  wheel="${pkg}-cp310-none-manylinux_2_34_x86_64.whl"
  url="https://pypi.nvidia.com/${name//_/-}/${wheel}"
  path="${TMPDIR}/${wheel}"

  echo "Downloading $pkg..."
  curl -fsSL "$url" -o "$path"

  if check_glibc_old; then
    newpath="${path/manylinux_2_34/manylinux_2_31}"
    mv "$path" "$newpath"
    path="$newpath"
  fi

  WHEELS+=("$path")
done

echo "Installing Isaac Sim wheels..."
uv pip install "${WHEELS[@]}"

rm -rf "$TMPDIR"

# =========================
# Fix websockets conflict
# =========================
ISAAC_PATH=$(python - << 'EOF'
import isaacsim, os
print(os.environ.get("ISAAC_PATH", ""))
EOF
)

if [ -n "$ISAAC_PATH" ] && [ -d "$ISAAC_PATH/extscache" ]; then
  echo "Fixing websockets conflict..."
  find "$ISAAC_PATH/extscache" \
    -type d \
    -path "*/pip_prebundle/websockets" \
    -exec rm -rf {} + || true
fi

# =========================
# Verify
# =========================
python - << 'EOF'
import omnigibson
import isaacsim
print("✓ OmniGibson and Isaac Sim installed successfully")
EOF

echo ""
echo "=== OmniGibson + Isaac Sim (uv) installation complete ==="

# =========================
# Datasets (optional)
# =========================
if [ "$DATASET" = true ]; then
  # Ensure we accept Isaac EULA for any OmniKit-backed downloads
  export OMNI_KIT_ACCEPT_EULA=YES

  # Ensure OmniGibson is importable in this uv env
  uv run python -c "import omnigibson" >/dev/null 2>&1 || {
    echo "ERROR: OmniGibson import failed. Install OmniGibson in this uv env before downloading datasets."
    echo "       (e.g., uncomment uv pip install -e \$WORKDIR/OmniGibson and base deps / torch blocks.)"
    exit 1
  }

  echo "Installing datasets..."

  if [ "$ACCEPT_DATASET_TOS" = true ]; then
    DATASET_ACCEPT_FLAG="True"
  else
    DATASET_ACCEPT_FLAG="False"
  fi

  echo "Downloading OmniGibson robot assets..."
  set -euo pipefail
  # 0) Resolve OmniGibson DATA_PATH from the uv environment
  DATA_PATH="$(uv run python - <<'PY'
from omnigibson.macros import gm
print(gm.DATA_PATH)
PY
)"
  ASSETS_DIR="${DATA_PATH}/omnigibson-robot-assets"
  CUSTOM_REL="models/r1pro/urdf/r1pro_ik.urdf"
  CUSTOM_SRC="${ASSETS_DIR}/${CUSTOM_REL}"

  STAMP="$(date +%Y%m%d_%H%M%S)"
  STASH_DIR="${DATA_PATH}/_custom_overlays_${STAMP}"
  # 1) Stash the custom file (if it exists)
  mkdir -p "${STASH_DIR}/$(dirname "${CUSTOM_REL}")"

  if [ -f "${CUSTOM_SRC}" ]; then
    echo "Stashing custom file..."
    cp -a "${CUSTOM_SRC}" "${STASH_DIR}/${CUSTOM_REL}"
  else
    echo "WARNING: r1pro_ik.urdf file not found at ${CUSTOM_SRC}"
    echo "         Continuing anyway (will just reinstall assets). but you need to download it manually"
  fi

  rm -rf "${ASSETS_DIR}"

  uv run python -c "from omnigibson.utils.asset_utils import download_omnigibson_robot_assets; download_omnigibson_robot_assets()" || {
    echo "ERROR: OmniGibson robot assets installation failed"
    exit 1
  }

  # 4) Restore (overlay) the custom file back into the new install
  if [ -f "${STASH_DIR}/${CUSTOM_REL}" ]; then
    echo "Restoring custom file into fresh install..."
    mkdir -p "${ASSETS_DIR}/$(dirname "${CUSTOM_REL}")"
    cp -a "${STASH_DIR}/${CUSTOM_REL}" "${CUSTOM_SRC}"
    echo "✓ Restored: ${CUSTOM_SRC}"
  else
    echo "NOTE: No stashed custom file to restore."
  fi

  echo "Downloading BEHAVIOR-1K assets..."
  uv run python -c "from omnigibson.utils.asset_utils import download_behavior_1k_assets; download_behavior_1k_assets(accept_license=${DATASET_ACCEPT_FLAG})" || {
    echo "ERROR: BEHAVIOR-1K assets installation failed"
    exit 1
  }

  echo "Downloading 2025 BEHAVIOR Challenge Task Instances..."
  uv run python -c "from omnigibson.utils.asset_utils import download_2025_challenge_task_instances; download_2025_challenge_task_instances()" || {
    echo "ERROR: 2025 BEHAVIOR Challenge Task Instances installation failed"
    exit 1
  }

  echo "✓ Dataset installation completed"
fi

# =========================
# install curobo
# =========================
export GIT_LFS_SKIP_SMUDGE=1
uv pip install nvidia_curobo@git+https://github.com/StanfordVL/curobo@cbaf7d32436160956dad190a9465360fad6aba73

# =========================
# reinstall pyroki
# =========================
uv pip install pyroki@git+https://github.com/chungmin99/pyroki.git