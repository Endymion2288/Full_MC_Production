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

echo "=============================================="
echo "HELAC-Onia LHE Generation"
echo "=============================================="
echo "Pool:           $POOL_NAME"
echo "Process:        $PROCESS_STRING"
echo "Seed:           $MY_SEED"
echo "Min pT (conia): $MIN_PT_CONIA GeV"
echo "Min pT (bonia): $MIN_PT_BONIA GeV"
echo "Min pT (q):     $MIN_PT_Q GeV"
echo "Output dir:     $OUTPUT_DIR"
echo "=============================================="

# Check for HELAC package
if [ ! -f "helac_package.tar.gz" ]; then
    echo "Error: helac_package.tar.gz not found"
    exit 1
fi

# Setup environment
source /cvmfs/cms.cern.ch/cmsset_default.sh
source /cvmfs/sft.cern.ch/lcg/views/LCG_88b/x86_64-centos7-gcc62-opt/setup.sh

export LD_LIBRARY_PATH=/cvmfs/sft.cern.ch/lcg/releases/LCG_88b/Boost/1.62.0/x86_64-centos7-gcc62-opt/lib:$LD_LIBRARY_PATH
export LD_LIBRARY_PATH=/cvmfs/sft.cern.ch/lcg/contrib/gcc/6.2.0/x86_64-centos7-gcc62-opt/lib64:$LD_LIBRARY_PATH

# Unpack HELAC
echo "Unpacking HELAC-Onia..."
tar -xzf helac_package.tar.gz

# Setup HepMC paths
HEPMC_DIR="${WORKDIR}/HepMC/HepMC-2.06.11"
if [ -d "$HEPMC_DIR/install" ]; then
    export PATH=$HEPMC_DIR/install/bin:$PATH
    export LD_LIBRARY_PATH=$HEPMC_DIR/install/lib:$LD_LIBRARY_PATH
fi

# Enter HELAC directory
cd HELAC-Onia-2.7.6

# Create run configuration
cat > run_config.ho << EOF
set cmass = 1.54845d0
set bmass = 4.73020d0
set preunw = 3000000
set unwevt = 1000000000
set nmc = 200000000
set nopt = 20000000
set nopt_step = 20000000
set noptlim = 200000000
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
