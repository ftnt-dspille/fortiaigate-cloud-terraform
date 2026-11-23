#!/usr/bin/env bash
set -euo pipefail

# Kept for muscle memory; holds are per VM now (scripts/gpu_place.sh).
#
#   reserve_gpu.sh [N...]     hold the GPU of running VM(s) N (default 1) in their zone
#   reserve_gpu.sh --release  delete every FAIG GPU hold

cd "$(dirname "$0")"
if [ "${1:-}" = "--release" ]; then exec ./gpu_place.sh --release-all; fi
exec ./gpu_place.sh --hold "${@:-1}"
