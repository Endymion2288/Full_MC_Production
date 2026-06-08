#!/bin/bash
# ==============================================================================
# test_shower_chain.sh - Test Pythia8 shower and event mixing
# ==============================================================================
# This script tests the shower programs (shower_normal, shower_phi, shower_sps)
# and event mixer with minimal events.
#
# Tests:
#   1. CMSSW_12 environment setup
#   2. Shower program compilation
#   3. shower_normal execution
#   4. shower_phi execution (phi enrichment)
#   5. shower_sps execution (SPS mode, MPI off)
#   6. Event mixer execution
#
# Usage:
#   ./test_shower_chain.sh [--use-existing-lhe PATH]
# ==============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
PROCESSING_DIR="${BASE_DIR}/processing"
SHOWER_DIR="${PROCESSING_DIR}/pythia_shower"
TEST_WORKDIR="${SCRIPT_DIR}/workdir_shower_test"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

msg_info() { echo -e "${BLUE}[TEST INFO]${NC} $1"; }
msg_ok() { echo -e "${GREEN}[TEST OK]${NC} $1"; }
msg_warn() { echo -e "${YELLOW}[TEST WARN]${NC} $1"; }
msg_error() { echo -e "${RED}[TEST ERROR]${NC} $1"; }
msg_step() { echo -e "\n${YELLOW}======== $1 ========${NC}\n"; }

# Default values
EXISTING_LHE=""
CREATE_TEST_LHE=1

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --use-existing-lhe)
            EXISTING_LHE="$2"
            CREATE_TEST_LHE=0
            shift 2
            ;;
        --help|-h)
            echo "Usage: $0 [--use-existing-lhe PATH]"
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
echo "  Shower Chain Test"
echo "=============================================="
echo "Work dir:  ${TEST_WORKDIR}"
echo "=============================================="
echo ""

# Create test workdir
rm -rf "${TEST_WORKDIR}"
mkdir -p "${TEST_WORKDIR}"
cd "${TEST_WORKDIR}"

# ============================================================================
# Test 1: Check CVMFS and CMSSW availability
# ============================================================================
msg_step "Test 1: Check CVMFS and CMSSW"

if [[ ! -f "/cvmfs/cms.cern.ch/cmsset_default.sh" ]]; then
    msg_error "CVMFS not accessible"
    exit 1
fi
msg_ok "CVMFS accessible"

# Check CMSSW_12 (el8)
CMSSW_12_CVMFS="/cvmfs/cms.cern.ch/el8_amd64_gcc10/cms/cmssw/CMSSW_12_4_14"
if [[ ! -d "${CMSSW_12_CVMFS}" ]]; then
    msg_error "CMSSW_12_4_14 not found on CVMFS"
    exit 1
fi
msg_ok "CMSSW_12_4_14 available"

# ============================================================================
# Test 2: Setup CMSSW_12 environment
# ============================================================================
msg_step "Test 2: Setup CMSSW_12 environment"

source /cvmfs/cms.cern.ch/cmsset_default.sh
export SCRAM_ARCH=el8_amd64_gcc10

# Create local CMSSW project
msg_info "Creating CMSSW_12_4_14 project..."
scramv1 project CMSSW CMSSW_12_4_14
cd CMSSW_12_4_14/src
eval $(scramv1 runtime -sh)
cd "${TEST_WORKDIR}"

msg_info "CMSSW_VERSION: ${CMSSW_VERSION}"
msg_info "SCRAM_ARCH: ${SCRAM_ARCH}"
msg_ok "CMSSW_12 environment setup successful"

# ============================================================================
# Test 3: Check Pythia8 and HepMC3 availability
# ============================================================================
msg_step "Test 3: Check Pythia8 and HepMC3"

# Check Pythia8
PYTHIA8_BASE="/cvmfs/cms.cern.ch/el8_amd64_gcc10/external/pythia8/306-494ded5c626b685d055d5b022e918c0c"
if [[ ! -d "${PYTHIA8_BASE}" ]]; then
    msg_error "Pythia8 not found: ${PYTHIA8_BASE}"
    exit 1
fi
msg_ok "Pythia8 found: ${PYTHIA8_BASE}"

# Check HepMC3
HEPMC3_BASE="/cvmfs/cms.cern.ch/el8_amd64_gcc10/external/hepmc3/3.2.5-c3cd50aeecf06b194814f1a75bf7872e"
if [[ ! -d "${HEPMC3_BASE}" ]]; then
    msg_error "HepMC3 not found: ${HEPMC3_BASE}"
    exit 1
fi
msg_ok "HepMC3 found: ${HEPMC3_BASE}"

# ============================================================================
# Test 4: Build shower programs
# ============================================================================
msg_step "Test 4: Build shower programs"

cd "${SHOWER_DIR}"

# Clean previous builds
make clean 2>/dev/null || true

# Build all programs
msg_info "Building shower programs..."
make all 2>&1 | tee "${TEST_WORKDIR}/build.log"

# Verify executables
for prog in shower_normal shower_phi shower_sps event_mixer_multisource; do
    if [[ ! -x "${prog}" ]]; then
        msg_error "Failed to build: ${prog}"
        exit 1
    fi
    msg_ok "Built: ${prog}"
done

cd "${TEST_WORKDIR}"

# ============================================================================
# Test 5: Create test LHE file
# ============================================================================
msg_step "Test 5: Create/obtain test LHE file"

if [[ ${CREATE_TEST_LHE} -eq 1 ]]; then
    msg_info "Creating minimal test LHE file..."
    
    # Create a minimal valid LHE file for testing
    # This simulates a gg -> J/psi J/psi process
    cat > test_input.lhe << 'LHEFILE'
<LesHouchesEvents version="1.0">
<header>
<!-- Test LHE file for shower testing -->
</header>
<init>
     2212     2212  6.800000e+03  6.800000e+03 0 0 10042 10042 3  1
  1.000000e-01 1.000000e-03 1.000000e+00 1
</init>
<event>
 6      1 +1.0000000e+00 1.00000000e+02 7.81860800e-03 1.18000000e-01
       21 -1    0    0  501  502  0.00000000000e+00  0.00000000000e+00  1.50000000000e+02  1.50000000000e+02  0.00000000000e+00 0. -1.
       21 -1    0    0  502  501  0.00000000000e+00  0.00000000000e+00 -1.50000000000e+02  1.50000000000e+02  0.00000000000e+00 0.  1.
      443  1    1    2    0    0  5.00000000000e+00  3.00000000000e+00  5.00000000000e+01  5.20000000000e+01  3.09690000000e+00 0. -1.
      443  1    1    2    0    0 -3.00000000000e+00  2.00000000000e+00  4.00000000000e+01  4.20000000000e+01  3.09690000000e+00 0.  1.
       21  1    1    2  503  504  2.00000000000e+00 -3.00000000000e+00  3.00000000000e+01  3.05000000000e+01  0.00000000000e+00 0. -1.
       21  1    1    2  504  503 -4.00000000000e+00 -2.00000000000e+00  3.00000000000e+01  3.05000000000e+01  0.00000000000e+00 0.  1.
</event>
<event>
 6      1 +1.0000000e+00 1.00000000e+02 7.81860800e-03 1.18000000e-01
       21 -1    0    0  501  502  0.00000000000e+00  0.00000000000e+00  1.60000000000e+02  1.60000000000e+02  0.00000000000e+00 0. -1.
       21 -1    0    0  502  501  0.00000000000e+00  0.00000000000e+00 -1.60000000000e+02  1.60000000000e+02  0.00000000000e+00 0.  1.
      443  1    1    2    0    0  6.00000000000e+00  4.00000000000e+00  6.00000000000e+01  6.20000000000e+01  3.09690000000e+00 0. -1.
      443  1    1    2    0    0 -4.00000000000e+00  3.00000000000e+00  5.00000000000e+01  5.20000000000e+01  3.09690000000e+00 0.  1.
       21  1    1    2  503  504  3.00000000000e+00 -4.00000000000e+00  2.50000000000e+01  2.60000000000e+01  0.00000000000e+00 0. -1.
       21  1    1    2  504  503 -5.00000000000e+00 -3.00000000000e+00  2.50000000000e+01  2.60000000000e+01  0.00000000000e+00 0.  1.
</event>
<event>
 6      1 +1.0000000e+00 1.00000000e+02 7.81860800e-03 1.18000000e-01
       21 -1    0    0  501  502  0.00000000000e+00  0.00000000000e+00  1.40000000000e+02  1.40000000000e+02  0.00000000000e+00 0. -1.
       21 -1    0    0  502  501  0.00000000000e+00  0.00000000000e+00 -1.40000000000e+02  1.40000000000e+02  0.00000000000e+00 0.  1.
      443  1    1    2    0    0  4.00000000000e+00  2.00000000000e+00  4.00000000000e+01  4.20000000000e+01  3.09690000000e+00 0. -1.
      443  1    1    2    0    0 -2.00000000000e+00  1.00000000000e+00  3.00000000000e+01  3.20000000000e+01  3.09690000000e+00 0.  1.
       21  1    1    2  503  504  1.00000000000e+00 -2.00000000000e+00  3.50000000000e+01  3.55000000000e+01  0.00000000000e+00 0. -1.
       21  1    1    2  504  503 -3.00000000000e+00 -1.00000000000e+00  3.50000000000e+01  3.55000000000e+01  0.00000000000e+00 0.  1.
</event>
</LesHouchesEvents>
LHEFILE
    
    LHE_FILE="${TEST_WORKDIR}/test_input.lhe"
    msg_ok "Created test LHE with 3 events"
else
    if [[ ! -f "${EXISTING_LHE}" ]]; then
        msg_error "Specified LHE file not found: ${EXISTING_LHE}"
        exit 1
    fi
    cp "${EXISTING_LHE}" "${TEST_WORKDIR}/test_input.lhe"
    LHE_FILE="${TEST_WORKDIR}/test_input.lhe"
    msg_ok "Using existing LHE: ${EXISTING_LHE}"
fi

EVENT_COUNT=$(grep -c "<event>" "${LHE_FILE}" || echo "0")
msg_info "LHE events: ${EVENT_COUNT}"

# ============================================================================
# Test 6: Run shower_normal
# ============================================================================
msg_step "Test 6: Run shower_normal"

"${SHOWER_DIR}/shower_normal" \
    "${LHE_FILE}" \
    "${TEST_WORKDIR}/output_normal.hepmc" \
    -1 2.5 2.4 100 2>&1 | tee "${TEST_WORKDIR}/shower_normal.log"

if [[ ! -f "${TEST_WORKDIR}/output_normal.hepmc" ]]; then
    msg_error "shower_normal failed to produce output"
    exit 1
fi

NORMAL_SIZE=$(stat -c%s "${TEST_WORKDIR}/output_normal.hepmc")
msg_ok "shower_normal output: ${NORMAL_SIZE} bytes"

# ============================================================================
# Test 7: Run shower_phi
# ============================================================================
msg_step "Test 7: Run shower_phi"

"${SHOWER_DIR}/shower_phi" \
    "${LHE_FILE}" \
    "${TEST_WORKDIR}/output_phi.hepmc" \
    -1 0.0 2.5 2.4 100 2>&1 | tee "${TEST_WORKDIR}/shower_phi.log"

if [[ ! -f "${TEST_WORKDIR}/output_phi.hepmc" ]]; then
    msg_error "shower_phi failed to produce output"
    exit 1
fi

PHI_SIZE=$(stat -c%s "${TEST_WORKDIR}/output_phi.hepmc")
msg_ok "shower_phi output: ${PHI_SIZE} bytes"

# ============================================================================
# Test 8: Run shower_sps
# ============================================================================
msg_step "Test 8: Run shower_sps"

"${SHOWER_DIR}/shower_sps" \
    "${LHE_FILE}" \
    "${TEST_WORKDIR}/output_sps.hepmc" \
    -1 0.0 2.5 2.4 100 2>&1 | tee "${TEST_WORKDIR}/shower_sps.log"

if [[ ! -f "${TEST_WORKDIR}/output_sps.hepmc" ]]; then
    msg_error "shower_sps failed to produce output"
    exit 1
fi

SPS_SIZE=$(stat -c%s "${TEST_WORKDIR}/output_sps.hepmc")
msg_ok "shower_sps output: ${SPS_SIZE} bytes"

# ============================================================================
# Test 9: Run event mixer (single source)
# ============================================================================
msg_step "Test 9: Run event mixer (single source)"

"${SHOWER_DIR}/event_mixer_multisource" \
    "${TEST_WORKDIR}/mixed_single.hepmc" \
    "${TEST_WORKDIR}/output_normal.hepmc" 2>&1 | tee "${TEST_WORKDIR}/mixer_single.log"

if [[ ! -f "${TEST_WORKDIR}/mixed_single.hepmc" ]]; then
    msg_error "Event mixer (single) failed"
    exit 1
fi
msg_ok "Event mixer (single source) successful"

# ============================================================================
# Test 10: Run event mixer (two sources)
# ============================================================================
msg_step "Test 10: Run event mixer (two sources)"

"${SHOWER_DIR}/event_mixer_multisource" \
    "${TEST_WORKDIR}/mixed_dual.hepmc" \
    "${TEST_WORKDIR}/output_normal.hepmc" \
    "${TEST_WORKDIR}/output_phi.hepmc" 2>&1 | tee "${TEST_WORKDIR}/mixer_dual.log"

if [[ ! -f "${TEST_WORKDIR}/mixed_dual.hepmc" ]]; then
    msg_error "Event mixer (dual) failed"
    exit 1
fi
msg_ok "Event mixer (two sources) successful"

# ============================================================================
# Test 11: Run event mixer with shuffle
# ============================================================================
msg_step "Test 11: Run event mixer with shuffle (two sources)"

"${SHOWER_DIR}/event_mixer_multisource" \
    "${TEST_WORKDIR}/mixed_shuffled.hepmc" \
    "${TEST_WORKDIR}/output_normal.hepmc" \
    "${TEST_WORKDIR}/output_phi.hepmc" \
    --shuffle-sources 2>&1 | tee "${TEST_WORKDIR}/mixer_shuffled.log"

if [[ ! -f "${TEST_WORKDIR}/mixed_shuffled.hepmc" ]]; then
    msg_error "Event mixer (shuffle) failed"
    exit 1
fi
msg_ok "Event mixer (shuffled) successful"

# ============================================================================
# Test 12: Verify shuffle determinism (same seed -> same output)
# ============================================================================
msg_step "Test 12: Verify shuffle determinism with fixed seed"

# Run twice with the same seed base — outputs must be identical.
"${SHOWER_DIR}/event_mixer_multisource" \
    "${TEST_WORKDIR}/mixed_shuffled_seeded_a.hepmc" \
    "${TEST_WORKDIR}/output_normal.hepmc" \
    "${TEST_WORKDIR}/output_phi.hepmc" \
    --shuffle-sources --shuffle-seed-base 42 2>&1 | tee "${TEST_WORKDIR}/mixer_seeded_a.log"

"${SHOWER_DIR}/event_mixer_multisource" \
    "${TEST_WORKDIR}/mixed_shuffled_seeded_b.hepmc" \
    "${TEST_WORKDIR}/output_normal.hepmc" \
    "${TEST_WORKDIR}/output_phi.hepmc" \
    --shuffle-sources --shuffle-seed-base 42 2>&1 | tee "${TEST_WORKDIR}/mixer_seeded_b.log"

if ! cmp -s "${TEST_WORKDIR}/mixed_shuffled_seeded_a.hepmc" \
            "${TEST_WORKDIR}/mixed_shuffled_seeded_b.hepmc"; then
    msg_error "Shuffle output is NOT deterministic (seed=42 runs differ)"
    exit 1
fi
msg_ok "Shuffle determinism verified (identical output with same seed)"

# ============================================================================
# Summary
# ============================================================================
msg_step "Test Summary"

echo ""
echo "=============================================="
echo "  Shower Chain Test Results"
echo "=============================================="
echo ""
msg_ok "All shower tests passed!"
echo ""
echo "Output files:"
echo "  - output_normal.hepmc: ${NORMAL_SIZE} bytes"
echo "  - output_phi.hepmc:    ${PHI_SIZE} bytes"  
echo "  - output_sps.hepmc:    ${SPS_SIZE} bytes"
echo "  - mixed_single.hepmc"
echo "  - mixed_dual.hepmc"
echo ""
echo "Log files in: ${TEST_WORKDIR}"
echo ""
msg_info "Workdir preserved. Remove with: rm -rf ${TEST_WORKDIR}"
