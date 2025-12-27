#!/bin/bash
# ==============================================================================
# run_helac.sh - HELAC-Onia LHE generation script
# ==============================================================================
# This script runs HELAC-Onia to generate LHE files for various physics processes.
# It is designed to run on HTCondor worker nodes within a cmssw-el7 container.
#
# Usage:
#   ./run_helac.sh --pool <pool_name> --seed <seed> [--process <process_string>]
#
# Examples:
#   ./run_helac.sh --pool pool_jpsi_g --seed 100
#   ./run_helac.sh --pool pool_gg --seed 200 --process "g g > g g"
# ==============================================================================

set -e

# Default values
POOL_NAME=""
MY_SEED=100
PROCESS_STRING=""
MIN_PT_CONIA=6.0
MIN_PT_BONIA=2.0
MIN_PT_Q=4.0
WORKDIR=$(pwd)
OUTPUT_DIR=""
# Integration and event-generation controls (can be overridden for fast tests)
PREUNW=3000000
UNWEVT=1000000000
NMC=200000000
NOPT=20000000
NOPT_STEP=20000000
NOPT_LIM=200000000
FAST_TEST=0
# Build locations (populated after unpacking helac_package.tar.gz)
HEPMC_SRC_TGZ=""
HELAC_SRC_TAR=""
HEPMC_PREFIX="${WORKDIR}/HepMC/HepMC-2.06.11"

# ----------------------------------------------------------------------------
# Helper functions
# ----------------------------------------------------------------------------

setup_build_env() {
    # Minimal environment for building HepMC/HELAC inside the worker node
    source /cvmfs/cms.cern.ch/cmsset_default.sh
    source /cvmfs/sft.cern.ch/lcg/views/LCG_88b/x86_64-centos7-gcc62-opt/setup.sh
    export LD_LIBRARY_PATH=/cvmfs/sft.cern.ch/lcg/releases/LCG_88b/Boost/1.62.0/x86_64-centos7-gcc62-opt/lib:$LD_LIBRARY_PATH
    export LD_LIBRARY_PATH=/cvmfs/sft.cern.ch/lcg/contrib/gcc/6.2.0/x86_64-centos7-gcc62-opt/lib64:$LD_LIBRARY_PATH
}

ensure_hepmc() {
    if [ -d "${HEPMC_PREFIX}/install" ]; then
        echo "[INFO] Reusing existing HepMC build at ${HEPMC_PREFIX}"
        return 0
    fi

    if [ -z "${HEPMC_SRC_TGZ}" ] || [ ! -f "${HEPMC_SRC_TGZ}" ]; then
        echo "Error: HepMC source tarball not found"
        return 1
    fi

    echo "[INFO] Building HepMC from ${HEPMC_SRC_TGZ}..."
    mkdir -p "${WORKDIR}/HepMC"
    tar -xzf "${HEPMC_SRC_TGZ}" -C "${WORKDIR}/HepMC"
    cd "${HEPMC_PREFIX}"
    mkdir -p build install
    cd build
    "${HEPMC_PREFIX}/configure" --prefix="${HEPMC_PREFIX}/install" --with-momentum=GEV --with-length=MM
    make -j 2
    make check
    make install
    cd "${WORKDIR}"
}

ensure_helac() {
    if [ -d "${WORKDIR}/HELAC-Onia-2.7.6" ] && [ -x "${WORKDIR}/HELAC-Onia-2.7.6/ho_cluster" ]; then
        echo "[INFO] Reusing existing HELAC-Onia build"
        return 0
    fi

    if [ -z "${HELAC_SRC_TAR}" ] || [ ! -f "${HELAC_SRC_TAR}" ]; then
        echo "Error: HELAC-Onia source tarball not found"
        return 1
    fi

    echo "[INFO] Unpacking HELAC-Onia from ${HELAC_SRC_TAR}..."
    tar -xzf "${HELAC_SRC_TAR}" -C "${WORKDIR}"

    cd "${WORKDIR}/HELAC-Onia-2.7.6"

    # Keep HepMC optional on worker nodes (avoid linking HepMC2Plot)
    sed -i -r -e 's|^[[:space:]]*hepmc_path[[:space:]]*=.*|# hepmc_path is left unset for condor runs|' input/ho_configuration.txt

    # Fix heptoptagger interface to compile with newer gcc
    sed -i 's/HEPTopTagger::HEPTopTagger /HEPTopTagger /g' analysis/heptoptagger/heptoptagger_fjcore_interface.cc

    echo "[INFO] Configuring HELAC-Onia..."
    ./config
    cd "${WORKDIR}"
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --pool)
            POOL_NAME="$2"
            shift 2
            ;;
        --seed|-s)
            MY_SEED="$2"
            shift 2
            ;;
        --process)
            PROCESS_STRING="$2"
            shift 2
            ;;
        --min-pt-conia)
            MIN_PT_CONIA="$2"
            shift 2
            ;;
        --min-pt-bonia)
            MIN_PT_BONIA="$2"
            shift 2
            ;;
        --min-pt-q)
            MIN_PT_Q="$2"
            shift 2
            ;;
        --output-dir)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --unwevt)
            UNWEVT="$2"
            shift 2
            ;;
        --fast-test)
            FAST_TEST=1
            shift 1
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Validate required arguments
if [ -z "$POOL_NAME" ]; then
    echo "Error: --pool is required"
    exit 1
fi

# Set default process string based on pool name if not specified
if [ -z "$PROCESS_STRING" ]; then
    case "$POOL_NAME" in
        "pool_jpsi_g")
            PROCESS_STRING="g g > cc~(3S11) g"
            ;;
        "pool_upsilon_g")
            PROCESS_STRING="g g > bb~(3S11) g"
            ;;
        "pool_gg")
            PROCESS_STRING="g g > g g"
            ;;
        "pool_2jpsi_g")
            PROCESS_STRING="g g > cc~(3S11) cc~(3S11) g"
            ;;
        "pool_jpsi_upsilon_g")
            PROCESS_STRING="g g > cc~(3S11) bb~(3S11) g"
            ;;
        *)
            echo "Error: Unknown pool name and no process string specified"
            exit 1
            ;;
    esac
fi

# Set default output directory
if [ -z "$OUTPUT_DIR" ]; then
    OUTPUT_DIR="/eos/user/x/xcheng/MC_Production/lhe_pools/${POOL_NAME}"
fi

# Validate seed
if ! [[ "$MY_SEED" =~ ^[0-9]+$ ]]; then
    echo "Error: Seed must be a valid integer"
    exit 1
fi

if [ "$MY_SEED" -le 10 ] || [ "$MY_SEED" -ge 100000 ]; then
    echo "Error: Seed must be between 11 and 99999"
    exit 1
fi

# Apply fast-test presets (drastically fewer integration/event counts)
if [ "$FAST_TEST" -eq 1 ]; then
    PREUNW=3000
    UNWEVT=100
    NMC=20000
    NOPT=2000
    NOPT_STEP=2000
    NOPT_LIM=20000
fi

# Validate unweighted event target
if ! [[ "$UNWEVT" =~ ^[0-9]+$ ]] || [ "$UNWEVT" -le 0 ]; then
    echo "Error: --unwevt must be a positive integer"
    exit 1
fi

echo "=============================================="
echo "HELAC-Onia LHE Generation"
echo "=============================================="
echo "Pool:           $POOL_NAME"
echo "Process:        $PROCESS_STRING"
echo "Seed:           $MY_SEED"
echo "Min pT (conia): $MIN_PT_CONIA GeV"
echo "Min pT (bonia): $MIN_PT_BONIA GeV"
echo "Min pT (q):     $MIN_PT_Q GeV"
echo "Unw. events:    $UNWEVT"
if [ "$FAST_TEST" -eq 1 ]; then
    echo "Mode:           FAST TEST (integration cuts reduced)"
fi
echo "Output dir:     $OUTPUT_DIR"
echo "=============================================="

# Check for HELAC package
if [ ! -f "helac_package.tar.gz" ]; then
    echo "Error: helac_package.tar.gz not found"
    exit 1
fi

# Prepare build environment and unpack archives
setup_build_env
echo "Unpacking helac_package.tar.gz..."
tar -xzf helac_package.tar.gz

# Locate source tarballs (either freshly unpacked or already present)
[ -f "${WORKDIR}/hepmc2.06.11.tgz" ] && HEPMC_SRC_TGZ="${WORKDIR}/hepmc2.06.11.tgz"
[ -f "${WORKDIR}/HELAC-Onia-2.7.6.tar.gz" ] && HELAC_SRC_TAR="${WORKDIR}/HELAC-Onia-2.7.6.tar.gz"

# Build dependencies from packaged sources
ensure_hepmc

# Setup HepMC paths after build
if [ -d "${HEPMC_PREFIX}/install" ]; then
    export PATH=${HEPMC_PREFIX}/install/bin:$PATH
    export LD_LIBRARY_PATH=${HEPMC_PREFIX}/install/lib:$LD_LIBRARY_PATH
fi

ensure_helac

# Enter HELAC directory
cd HELAC-Onia-2.7.6

# Create run configuration
cat > run_config.ho << EOF
set cmass = 1.54845d0
set bmass = 4.73020d0
set preunw = ${PREUNW}
set unwevt = ${UNWEVT}
set nmc = ${NMC}
set nopt = ${NOPT}
set nopt_step = ${NOPT_STEP}
set noptlim = ${NOPT_LIM}
set seed = ${MY_SEED}
set parton_shower = 0
set minptconia = ${MIN_PT_CONIA}d0
set minptbonia = ${MIN_PT_BONIA}d0
set maxrapconia = 2.4
set minptq = ${MIN_PT_Q}
set ranhel = 4
generate ${PROCESS_STRING}
launch
exit
EOF

# Copy user.inp if exists
if [ -f "../input_templates/user.inp" ]; then
    cp ../input_templates/user.inp input/user.inp
fi

echo "Running HELAC-Onia..."
./ho_cluster < run_config.ho | tee ../helac_run.log

# Find output LHE file
RUN_DIR=$(grep "INFO: Results are collected in" ../helac_run.log | \
          sed -r -e "s,^.*(PROC_HO_[0-9]+)\/.*$,\1,g" | head -1)

if [ -z "$RUN_DIR" ]; then
    echo "Error: Could not find run directory in log"
    exit 1
fi

# Find the LHE file
LHE_FILE=$(find . -name "*.lhe" -type f | head -1)

if [ -z "$LHE_FILE" ] || [ ! -f "$LHE_FILE" ]; then
    echo "Error: LHE file not found"
    exit 1
fi

echo "Found LHE file: $LHE_FILE"

# Copy to output directory
mkdir -p "$OUTPUT_DIR"
OUTPUT_FILE="${OUTPUT_DIR}/sample_${POOL_NAME}_${MY_SEED}.lhe"
cp "$LHE_FILE" "$OUTPUT_FILE"

echo "=============================================="
echo "LHE generation complete!"
echo "Output: $OUTPUT_FILE"
echo "=============================================="

# Return to work directory
cd "$WORKDIR"

# Cleanup (optional, saves disk space on worker)
# rm -rf HELAC-Onia-2.7.6 HepMC
