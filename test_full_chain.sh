#!/bin/bash
# ==============================================================================
# test_full_chain.sh - Full MC Production Chain Test
# ==============================================================================
# This script performs a complete test of the MC production chain from LHE
# generation through to Ntuple production.
#
# Test scope:
#   1. LHE Generation (HELAC-Onia) - generates 100 events
#   2. Pythia8 Shower (normal + phi modes)
#   3. Event Mixing (multi-source)
#   4. GEN-SIM (CMSSW)
#   5. RAW (DIGI + HLT + Pileup)
#   6. RECO
#   7. MiniAOD
#   8. Ntuple (JJP analyzer)
#
# Usage:
#   ./test_full_chain.sh [--quick] [--skip-lhe] [--campaign CAMPAIGN]
#
# Options:
#   --quick       Skip RAW/RECO/MiniAOD/Ntuple steps (test shower+mix only)
#   --skip-lhe    Skip LHE generation (use existing LHE files)
#   --campaign    Campaign to test (default: JJP_DPS1)
#   --clean       Clean up test directory before starting
#
# Prerequisites:
#   - CMS environment available (CVMFS)
#   - Valid VOMS proxy for pileup access
#   - helac_package.tar.gz in common/packages/
#   - jjp_code.tar.gz in common/packages/ (for ntuple step)
# ==============================================================================

set -e

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_DIR="${SCRIPT_DIR}/test_output"
LOG_DIR="${TEST_DIR}/logs"

# Test parameters
TEST_EVENTS=100
TEST_SEED=12345
TEST_CAMPAIGN="JJP_DPS1"
QUICK_MODE=false
SKIP_LHE=false
CLEAN_FIRST=false

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

msg_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
msg_ok() { echo -e "${GREEN}[OK]${NC} $1"; }
msg_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
msg_error() { echo -e "${RED}[ERROR]${NC} $1"; }
msg_step() { 
    echo ""
    echo -e "${YELLOW}============================================${NC}"
    echo -e "${YELLOW}  STEP: $1${NC}"
    echo -e "${YELLOW}============================================${NC}"
    echo ""
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --quick)
            QUICK_MODE=true
            shift
            ;;
        --skip-lhe)
            SKIP_LHE=true
            shift
            ;;
        --campaign)
            TEST_CAMPAIGN="$2"
            shift 2
            ;;
        --clean)
            CLEAN_FIRST=true
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [--quick] [--skip-lhe] [--campaign CAMPAIGN] [--clean]"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

echo ""
echo "=============================================="
echo "  Full MC Production Chain Test"
echo "=============================================="
echo "Campaign:     ${TEST_CAMPAIGN}"
echo "Test events:  ${TEST_EVENTS}"
echo "Test seed:    ${TEST_SEED}"
echo "Quick mode:   ${QUICK_MODE}"
echo "Skip LHE:     ${SKIP_LHE}"
echo "Test dir:     ${TEST_DIR}"
echo "=============================================="
echo ""

# Campaign configuration (strictly follow workbook logic)
case "${TEST_CAMPAIGN}" in
    JJP_SPS)
        POOLS=(pool_2jpsi_g)
        MODES=(phi)
        ANALYSIS="JJP"
        ;;
    JJP_DPS1)
        POOLS=(pool_jpsi_CSCO_g pool_jpsi_CSCO_g)
        MODES=(normal phi)
        ANALYSIS="JJP"
        ;;
    JJP_DPS2)
        POOLS=(pool_2jpsi pool_gg)
        MODES=(normal phi)
        ANALYSIS="JJP"
        ;;
    JJP_TPS)
        POOLS=(pool_jpsi_CSCO_g pool_jpsi_CSCO_g pool_gg)
        MODES=(normal normal phi)
        ANALYSIS="JJP"
        ;;
    JUP_DPS1)
        POOLS=(pool_jpsi_CSCO_g pool_upsilon_CSCO_g)
        MODES=(phi normal)
        ANALYSIS="JUP"
        ;;
    JUP_DPS2)
        POOLS=(pool_jpsi_CSCO_g pool_upsilon_CSCO_g)
        MODES=(normal phi)
        ANALYSIS="JUP"
        ;;
    JUP_DPS3)
        POOLS=(pool_jpsi_upsilon_CSCO pool_gg)
        MODES=(normal phi)
        ANALYSIS="JUP"
        ;;
    JUP_TPS)
        POOLS=(pool_jpsi_CSCO_g pool_upsilon_CSCO_g pool_gg)
        MODES=(normal normal phi)
        ANALYSIS="JUP"
        ;;
    JUP_SPS)
        msg_error "JUP_SPS is not supported for test_full_chain"
        exit 1
        ;;
    *)
        msg_error "Unknown campaign: ${TEST_CAMPAIGN}"
        exit 1
        ;;
esac

if [[ "${#POOLS[@]}" -ne "${#MODES[@]}" ]]; then
    msg_error "Campaign config mismatch: pools=${#POOLS[@]} modes=${#MODES[@]}"
    exit 1
fi

# Clean up if requested
if [[ "${CLEAN_FIRST}" == "true" ]]; then
    msg_info "Cleaning test directory..."
    rm -rf "${TEST_DIR}"
fi

# Create directories
mkdir -p "${TEST_DIR}" "${LOG_DIR}"
cd "${TEST_DIR}"

# Build LHE file list for the campaign
LHE_FILES=()
INPUTS_LIST=()
for i in "${!POOLS[@]}"; do
    LHE_FILES+=("test_input_${POOLS[$i]}.lhe")
    INPUTS_LIST+=("file:${TEST_DIR}/test_input_${POOLS[$i]}.lhe")
done
INPUTS=$(IFS=,; echo "${INPUTS_LIST[*]}")
MODES_CSV=$(IFS=,; echo "${MODES[*]}")

# ==============================================================================
# Step 1: LHE Generation
# ==============================================================================
if [[ "${SKIP_LHE}" == "false" ]]; then
    msg_step "1. LHE Generation (HELAC-Onia)"
    
    # Check for helac package
    HELAC_PKG="${SCRIPT_DIR}/common/packages/helac_package.tar.gz"
    if [[ ! -f "${HELAC_PKG}" ]]; then
        msg_error "helac_package.tar.gz not found at ${HELAC_PKG}"
        msg_info "Please create it first. See common/packages/README.md"
        exit 1
    fi
    
    # Copy necessary files
    cp "${HELAC_PKG}" .
    cp "${SCRIPT_DIR}/lhe_generation/input_templates/user.inp" . 2>/dev/null || true

    msg_info "Testing pools: ${POOLS[*]}"
    msg_info "This step requires cmssw-el7 container for HELAC-Onia..."

    # Run LHE generation with fast-test mode
    # Note: This needs to run in el7 container
    cat > run_lhe_test.sh << 'LHESCRIPT'
#!/bin/bash
set -e
cd "$(dirname "$0")"

POOL="$1"
OUTFILE="$2"
TEST_EVENTS="$3"
TEST_SEED="$4"

# Source build environment
source /cvmfs/cms.cern.ch/cmsset_default.sh
source /cvmfs/sft.cern.ch/lcg/views/LCG_88b/x86_64-centos7-gcc62-opt/setup.sh
export LD_LIBRARY_PATH=/cvmfs/sft.cern.ch/lcg/releases/LCG_88b/Boost/1.62.0/x86_64-centos7-gcc62-opt/lib:$LD_LIBRARY_PATH
export LD_LIBRARY_PATH=/cvmfs/sft.cern.ch/lcg/contrib/gcc/6.2.0/x86_64-centos7-gcc62-opt/lib64:$LD_LIBRARY_PATH

echo "Unpacking HELAC package..."
tar -xzf helac_package.tar.gz

# Build HepMC
if [[ -f "hepmc2.06.11.tgz" ]] && [[ ! -d "HepMC/HepMC-2.06.11/install" ]]; then
    echo "Building HepMC..."
    mkdir -p HepMC
    tar -xzf hepmc2.06.11.tgz -C HepMC
    cd HepMC/HepMC-2.06.11
    mkdir -p build install
    cd build
    ../configure --prefix="$(pwd)/../install" --with-momentum=GEV --with-length=MM
    make -j4
    make install
    cd ../../..
fi

# Build HELAC
if [[ -f "HELAC-Onia-2.7.6.tar.gz" ]] && [[ ! -d "HELAC-Onia-2.7.6" ]]; then
    echo "Building HELAC-Onia..."
    tar -xzf HELAC-Onia-2.7.6.tar.gz
    cd HELAC-Onia-2.7.6
    sed -i -r -e 's|^[[:space:]]*hepmc_path[[:space:]]*=.*|# hepmc_path disabled|' input/ho_configuration.txt
    sed -i 's/HEPTopTagger::HEPTopTagger /HEPTopTagger /g' analysis/heptoptagger/heptoptagger_fjcore_interface.cc
    ./config
    cd ..
fi

cd HELAC-Onia-2.7.6

# Create run configuration for selected pool
cat > run_config.ho << HOCONFIG
set cmass = 1.54845d0
set bmass = 4.73020d0
set LDMEcc3S11 = 1.16d0
set LDMEcc3S18 = 0.00902923d0
set LDMEcc1S08 = 0.0146d0
set LDMEbb3S11 = 9.28d0
set LDMEbb3S18 = 0.0297426d0
set LDMEbb1S08 = 0.000170128d0
set preunw = 3000
set unwevt = ${TEST_EVENTS}
set nmc = 20000
set nopt = 2000
set nopt_step = 2000
set noptlim = 20000
set seed = ${TEST_SEED}
set parton_shower = 0
set minptconia = 6.0d0
set minptbonia = 2.0d0
set maxrapconia = 2.4
set minptq = 4.0
set ranhel = 4
HOCONFIG

case "${POOL}" in
    "pool_jpsi_CSCO_g")
        echo 'define jpsi_all = cc~(3S11) cc~(3S18) cc~(1S08)' >> run_config.ho
        echo "generate g g > jpsi_all g" >> run_config.ho
        ;;
    "pool_upsilon_CSCO_g")
        echo 'define upsilon_all = bb~(3S11) bb~(3S18) bb~(1S08)' >> run_config.ho
        echo "generate g g > upsilon_all g" >> run_config.ho
        ;;
    "pool_2jpsi_g")
        echo "generate g g > cc~(3S11) cc~(3S11) g" >> run_config.ho
        ;;
    "pool_2jpsi")
        echo "generate g g > cc~(3S11) cc~(3S11)" >> run_config.ho
        ;;
    "pool_jpsi_upsilon_CSCO")
        echo "generate g g > jpsi y(1s)" >> run_config.ho
        ;;
    "pool_gg")
        echo "generate g g > g g" >> run_config.ho
        ;;
    *)
        echo "ERROR: Unknown pool: ${POOL}"
        exit 1
        ;;
esac

echo "launch" >> run_config.ho
echo "exit" >> run_config.ho

echo "Running HELAC-Onia..."
./ho_cluster < run_config.ho | tee ../helac_run.log

# Find output LHE file from the latest run directory
RUN_DIR=$(grep "INFO: Results are collected in" ../helac_run.log | \
          sed -r -e "s,^.*(PROC_HO_[0-9]+)\/.*$,\1,g" | tail -1)

if [[ -n "${RUN_DIR}" ]] && [[ -d "${RUN_DIR}/results" ]]; then
    LHE_FILE=$(find "${RUN_DIR}/results" -name "*.lhe" -type f | head -1)
else
    LHE_FILE=$(find . -path "./PROC_HO_*/results/*.lhe" -type f | sort | tail -1)
fi
if [[ -n "$LHE_FILE" ]]; then
    cp "$LHE_FILE" "../${OUTFILE}"
    echo "LHE file created: ${OUTFILE}"
    wc -l "../${OUTFILE}"
else
    echo "ERROR: No LHE file found"
    exit 1
fi
LHESCRIPT

    chmod +x run_lhe_test.sh
    
    msg_info "Running LHE generation in el7 container..."
    msg_info "(This may take 10-30 minutes for the first run due to HELAC build)"

    for i in "${!POOLS[@]}"; do
        POOL="${POOLS[$i]}"
        OUTFILE="${LHE_FILES[$i]}"
        msg_info "Generating LHE for pool: ${POOL} -> ${OUTFILE}"

        if command -v apptainer &>/dev/null; then
            apptainer exec \
                --bind /cvmfs:/cvmfs \
                --bind "${TEST_DIR}:${TEST_DIR}" \
                /cvmfs/unpacked.cern.ch/registry.hub.docker.com/cmssw/el7:x86_64 \
                /bin/bash "${TEST_DIR}/run_lhe_test.sh" "${POOL}" "${OUTFILE}" "${TEST_EVENTS}" "${TEST_SEED}" 2>&1 | tee "${LOG_DIR}/lhe_gen_${POOL}.log"
        else
            msg_warn "apptainer not available, trying singularity..."
            singularity exec \
                --bind /cvmfs:/cvmfs \
                --bind "${TEST_DIR}:${TEST_DIR}" \
                /cvmfs/unpacked.cern.ch/registry.hub.docker.com/cmssw/el7:x86_64 \
                /bin/bash "${TEST_DIR}/run_lhe_test.sh" "${POOL}" "${OUTFILE}" "${TEST_EVENTS}" "${TEST_SEED}" 2>&1 | tee "${LOG_DIR}/lhe_gen_${POOL}.log"
        fi

        if [[ -f "${OUTFILE}" ]]; then
            msg_ok "LHE generation complete: ${OUTFILE}"
            msg_info "LHE file size: $(du -h "${OUTFILE}" | cut -f1)"
        else
            msg_error "LHE generation failed for pool: ${POOL}"
            exit 1
        fi

        # Replace color-octet PDG codes (9900000+PDG or 9900+PDG) with 99nqnsnrnLnJ encoding
        msg_info "Updating color-octet PDG codes in ${OUTFILE}..."
        OUTFILE_PATH="${OUTFILE}" python3 - << 'PY'
import re
import os
from pathlib import Path

lhe_path = Path(os.environ["OUTFILE_PATH"])
text = lhe_path.read_text()

def _target_from_helac(helac_pdg: int):
    # HELAC octet codes observed: 9900441 (J/psi 3S1 octet), 9900551 (Upsilon 3S1 octet)
    if helac_pdg in (441, 443, 445):
        nq = 4
        if helac_pdg == 441:
            ns, target = 1, 443  # 1S0 octet -> J/psi
        elif helac_pdg == 443:
            ns, target = 0, 443  # 3S1 octet -> J/psi
        else:
            ns, target = 2, 443  # 3PJ octet -> J/psi
        return nq, ns, target
    if helac_pdg in (551, 553, 555):
        nq = 5
        if helac_pdg == 551:
            ns, target = 1, 553  # 1S0 octet -> Upsilon(1S)
        elif helac_pdg == 553:
            ns, target = 0, 553  # 3S1 octet -> Upsilon(1S)
        else:
            ns, target = 2, 553  # 3PJ octet -> Upsilon(1S)
        return nq, ns, target
    return None

def _singlet_LJ(target_pdg: int):
    base = target_pdg % 1000
    if base in (443, 553):
        return 0, 1  # S-wave vector
    if base in (441, 551):
        return 0, 0  # S-wave pseudoscalar
    if base in (445, 555):
        return 1, 2  # P-wave J=2 (fallback)
    return None

def convert_octet_code(val: int):
    if not str(val).startswith("9900"):
        return None
    helac_pdg = val - 9900000 if val >= 9900000 else val - 9900
    mapping = _target_from_helac(helac_pdg)
    if mapping is None:
        return None
    nq, ns, target = mapping
    nr = target // 100000
    lj = _singlet_LJ(target)
    if lj is None:
        return None
    nL, J = lj
    nJ = 2 * J + 1
    return int(f"99{nq}{ns}{nr}{nL}{nJ}")

def replace_match(m):
    val = int(m.group(0))
    new_code = convert_octet_code(val)
    return str(new_code) if new_code is not None else m.group(0)

new_text = re.sub(r"\b\d+\b", replace_match, text)
lhe_path.write_text(new_text)
PY
    done
else
    msg_step "1. LHE Generation (SKIPPED)"
    for OUTFILE in "${LHE_FILES[@]}"; do
        if [[ ! -f "${OUTFILE}" ]]; then
            msg_error "Missing LHE file: ${OUTFILE}. Run without --skip-lhe first."
            exit 1
        fi
    done
fi

# ==============================================================================
# Step 2-3: Shower and Mix (via run_chain.sh)
# ==============================================================================
msg_step "2-3. Shower + Mix Test"

msg_info "Inputs: ${INPUTS}"
msg_info "Modes: ${MODES_CSV}"
msg_info "Analysis: ${ANALYSIS}"

# Run shower and mix steps
if [[ "${QUICK_MODE}" == "true" ]]; then
    STOP_AT="--stop-at mix"
else
    STOP_AT=""
fi

msg_info "Running production chain..."
cd "${SCRIPT_DIR}"

# Run in el8 container for CMSSW_12 compatibility
bash "${SCRIPT_DIR}/processing/run_chain.sh" \
    --inputs "${INPUTS}" \
    --modes "${MODES_CSV}" \
    --analysis "${ANALYSIS}" \
    --campaign "${TEST_CAMPAIGN}_TEST" \
    --job-id 0 \
    --workdir "${TEST_DIR}" \
    --max-events ${TEST_EVENTS} \
    --no-cleanup \
    ${STOP_AT} 2>&1 | tee "${LOG_DIR}/chain.log"

# ==============================================================================
# Results Summary
# ==============================================================================
msg_step "Test Results Summary"

echo "Output files:"
echo "-------------"
ls -lh "${TEST_DIR}"/*.hepmc 2>/dev/null || echo "  (no HepMC files)"
ls -lh "${TEST_DIR}"/*.root 2>/dev/null || echo "  (no ROOT files)"

echo ""
echo "Log files:"
echo "----------"
ls -lh "${LOG_DIR}"/*.log 2>/dev/null || echo "  (no log files)"

if [[ -f "${TEST_DIR}/mixed.hepmc" ]]; then
    msg_ok "Shower + Mix test PASSED"
    HEPMC_EVENTS=$(grep -c "^E " "${TEST_DIR}/mixed.hepmc" 2>/dev/null || echo "0")
    msg_info "Mixed HepMC events: ${HEPMC_EVENTS}"
else
    msg_error "Shower + Mix test FAILED - no mixed.hepmc found"
fi

if [[ "${QUICK_MODE}" == "false" ]]; then
    if [[ -f "${TEST_DIR}/output_MINIAOD.root" ]]; then
        msg_ok "Full chain test PASSED"
    else
        msg_warn "Full chain may have stopped early - check logs"
    fi
    
    if [[ -f "${TEST_DIR}/output_ntuple.root" ]]; then
        msg_ok "Ntuple production PASSED"
    fi
fi

echo ""
echo "=============================================="
echo "  Test Complete"
echo "=============================================="
echo "Test directory: ${TEST_DIR}"
echo "Log directory:  ${LOG_DIR}"
echo ""

