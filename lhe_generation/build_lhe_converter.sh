#!/bin/bash
# ==============================================================================
# build_lhe_converter.sh - Build the lhe_pythia6_pythia8 converter
# ==============================================================================
# This script builds the standalone LHE converter for both local development
# and HTCondor worker nodes.
#
# Usage:
#   ./build_lhe_converter.sh [--local|--worker]
#
# Options:
#   --local   Build using local LCG environment (for lxplus)
#   --worker  Build using CMSSW environment (for HTCondor workers)
# ==============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

BUILD_MODE="${1:---local}"

setup_local_env() {
    # LCG_88b environment on lxplus
    if [ -f "/cvmfs/sft.cern.ch/lcg/views/LCG_88b/x86_64-centos7-gcc62-opt/setup.sh" ]; then
        source /cvmfs/sft.cern.ch/lcg/views/LCG_88b/x86_64-centos7-gcc62-opt/setup.sh
    else
        echo "Warning: LCG environment not found, using system gfortran"
    fi
}

setup_worker_env() {
    # CMSSW environment on worker nodes
    source /cvmfs/cms.cern.ch/cmsset_default.sh
    # Try to use gfortran from gcc-toolset if available
    if [ -x "/opt/rh/gcc-toolset-12/root/usr/bin/gfortran" ]; then
        export PATH="/opt/rh/gcc-toolset-12/root/usr/bin:$PATH"
    fi
}

echo "=============================================="
echo "Building lhe_pythia6_pythia8 converter"
echo "=============================================="
echo "Build mode: ${BUILD_MODE}"
echo ""

case "${BUILD_MODE}" in
    --local)
        setup_local_env
        ;;
    --worker)
        setup_worker_env
        ;;
    *)
        echo "Unknown build mode: ${BUILD_MODE}"
        echo "Usage: $0 [--local|--worker]"
        exit 1
        ;;
esac

# Check for gfortran
if ! command -v gfortran &>/dev/null; then
    echo "Error: gfortran not found"
    exit 1
fi

echo "Using gfortran: $(which gfortran)"
gfortran --version | head -1

# Build
make clean
make

echo ""
echo "=============================================="
echo "Build successful!"
echo "=============================================="
echo ""
echo "Test the converter:"
echo "  ./lhe_pythia6_pythia8 input.lhe py8_onia_user.inp output.lhe"
echo ""
