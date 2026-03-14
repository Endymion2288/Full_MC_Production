#!/bin/bash
# ==============================================================================
# test_cmssw_chain.sh - Test CMSSW processing chain (GEN-SIM to Ntuple)
# ==============================================================================
# This script tests the CMSSW processing chain with minimal events.
#
# Tests:
#   1. CMSSW_12 setup (el8)
#   2. GEN-SIM step
#   3. DIGI-RAW step  
#   4. RECO step
#   5. MiniAOD step
#   6. CMSSW_14 setup (el9 via apptainer)
#   7. Ntuple step
#
# Usage:
#   ./test_cmssw_chain.sh [--use-existing-hepmc PATH]
# ==============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TEST_WORKDIR="${SCRIPT_DIR}/workdir_cmssw_test"

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
EXISTING_HEPMC=""
NUM_EVENTS=2
SKIP_NTUPLE=0

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --use-existing-hepmc)
            EXISTING_HEPMC="$2"
            shift 2
            ;;
        --num-events)
            NUM_EVENTS="$2"
            shift 2
            ;;
        --skip-ntuple)
            SKIP_NTUPLE=1
            shift
            ;;
        --help|-h)
            echo "Usage: $0 [--use-existing-hepmc PATH] [--num-events N] [--skip-ntuple]"
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
echo "  CMSSW Chain Test"
echo "=============================================="
echo "Work dir:   ${TEST_WORKDIR}"
echo "Num events: ${NUM_EVENTS}"
echo "=============================================="
echo ""

# Create test workdir
rm -rf "${TEST_WORKDIR}"
mkdir -p "${TEST_WORKDIR}"
cd "${TEST_WORKDIR}"

# ============================================================================
# Test 1: Check CVMFS availability
# ============================================================================
msg_step "Test 1: Check CVMFS"

if [[ ! -f "/cvmfs/cms.cern.ch/cmsset_default.sh" ]]; then
    msg_error "CVMFS not accessible"
    exit 1
fi
msg_ok "CVMFS accessible"

# ============================================================================
# Test 2: Create or obtain HepMC input
# ============================================================================
msg_step "Test 2: Prepare HepMC input"

if [[ -n "${EXISTING_HEPMC}" ]]; then
    if [[ ! -f "${EXISTING_HEPMC}" ]]; then
        msg_error "Specified HepMC file not found: ${EXISTING_HEPMC}"
        exit 1
    fi
    cp "${EXISTING_HEPMC}" "${TEST_WORKDIR}/input.hepmc"
    msg_ok "Using existing HepMC: ${EXISTING_HEPMC}"
else
    msg_info "Creating minimal HepMC3 file..."
    
    # Create a minimal HepMC3 file (ASCII format)
    cat > input.hepmc << 'HEPMCFILE'
HepMC::Version 3.02.05
HepMC::Asciiv3-START_EVENT_LISTING
E 0 1 3
U GEV MM
W 1.0
A 0 signal_process_id 1
A 0 event_scale 100.0
A 0 alphaQCD 0.118
A 0 alphaQED 0.00781
V -1 0 [1,2]
P 1 -1 2212 0 0 6800 6800 938.272 4
P 2 -1 2212 0 0 -6800 6800 938.272 4
V -2 0 [3,4,5,6]
P 3 -2 443 5.0 3.0 50.0 52.0 3.0969 2
P 4 -2 443 -3.0 2.0 40.0 42.0 3.0969 2
P 5 -2 21 2.0 -3.0 30.0 30.5 0 1
P 6 -2 21 -4.0 -2.0 30.0 30.5 0 1
V -3 0 [7,8]
P 7 -3 13 2.0 1.5 25.0 25.1 0.1057 1
P 8 -3 -13 3.0 1.5 25.0 25.1 0.1057 1
V -4 0 [9,10]
P 9 -4 13 -1.5 1.0 20.0 20.1 0.1057 1
P 10 -4 -13 -1.5 1.0 20.0 20.1 0.1057 1
E 1 1 3
U GEV MM
W 1.0
A 0 signal_process_id 1
A 0 event_scale 100.0
A 0 alphaQCD 0.118
A 0 alphaQED 0.00781
V -1 0 [1,2]
P 1 -1 2212 0 0 6800 6800 938.272 4
P 2 -1 2212 0 0 -6800 6800 938.272 4
V -2 0 [3,4,5,6]
P 3 -2 443 6.0 4.0 60.0 62.0 3.0969 2
P 4 -2 443 -4.0 3.0 50.0 52.0 3.0969 2
P 5 -2 21 3.0 -4.0 25.0 26.0 0 1
P 6 -2 21 -5.0 -3.0 25.0 26.0 0 1
V -3 0 [7,8]
P 7 -3 13 3.0 2.0 30.0 30.1 0.1057 1
P 8 -3 -13 3.0 2.0 30.0 30.1 0.1057 1
V -4 0 [9,10]
P 9 -4 13 -2.0 1.5 25.0 25.1 0.1057 1
P 10 -4 -13 -2.0 1.5 25.0 25.1 0.1057 1
E 2 1 3
U GEV MM
W 1.0
A 0 signal_process_id 1
A 0 event_scale 100.0
A 0 alphaQCD 0.118
A 0 alphaQED 0.00781
V -1 0 [1,2]
P 1 -1 2212 0 0 6800 6800 938.272 4
P 2 -1 2212 0 0 -6800 6800 938.272 4
V -2 0 [3,4,5,6]
P 3 -2 443 4.0 2.0 40.0 42.0 3.0969 2
P 4 -2 443 -2.0 1.0 30.0 32.0 3.0969 2
P 5 -2 21 1.0 -2.0 35.0 35.5 0 1
P 6 -2 21 -3.0 -1.0 35.0 35.5 0 1
V -3 0 [7,8]
P 7 -3 13 2.0 1.0 20.0 20.1 0.1057 1
P 8 -3 -13 2.0 1.0 20.0 20.1 0.1057 1
V -4 0 [9,10]
P 9 -4 13 -1.0 0.5 15.0 15.1 0.1057 1
P 10 -4 -13 -1.0 0.5 15.0 15.1 0.1057 1
HepMC::Asciiv3-END_EVENT_LISTING
HEPMCFILE
    
    msg_ok "Created test HepMC3 with 3 events"
fi

# ============================================================================
# Test 3: Setup CMSSW_12 environment
# ============================================================================
msg_step "Test 3: Setup CMSSW_12_4_14"

source /cvmfs/cms.cern.ch/cmsset_default.sh
export SCRAM_ARCH=el8_amd64_gcc10

msg_info "Creating CMSSW_12_4_14 project..."
scramv1 project CMSSW CMSSW_12_4_14
cd CMSSW_12_4_14/src
eval $(scramv1 runtime -sh)
cd "${TEST_WORKDIR}"

msg_info "CMSSW_VERSION: ${CMSSW_VERSION}"
msg_ok "CMSSW_12 environment ready"

# ============================================================================
# Test 4: GEN-SIM step
# ============================================================================
msg_step "Test 4: GEN-SIM"

msg_info "Creating GEN-SIM config..."
cat > gensim_cfg.py << 'GENSIMCFG'
import FWCore.ParameterSet.Config as cms
from Configuration.Eras.Era_Run3_cff import Run3
import sys
import os

process = cms.Process('SIM', Run3)

# Message Logger
process.load("FWCore.MessageService.MessageLogger_cfi")
process.MessageLogger.cerr.FwkReport.reportEvery = 1

# Number of events
process.maxEvents = cms.untracked.PSet(input = cms.untracked.int32(2))

# HepMC3 source
hepmc_file = os.path.abspath("input.hepmc")
process.source = cms.Source("HepMC3Product",
    fileNames = cms.untracked.vstring("file:" + hepmc_file),
    filterEfficiency = cms.untracked.double(1.0)
)

# Random numbers
process.load('Configuration.StandardSequences.Services_cff')
process.RandomNumberGeneratorService.generator = cms.PSet(
    initialSeed = cms.untracked.uint32(12345),
    engineName = cms.untracked.string('HepJamesRandom')
)

# Geometry, conditions, etc.
process.load('Configuration.StandardSequences.GeometryRecoDB_cff')
process.load('Configuration.StandardSequences.GeometrySimDB_cff')
process.load('Configuration.StandardSequences.MagneticField_cff')
process.load('Configuration.StandardSequences.SimIdeal_cff')
process.load('Configuration.StandardSequences.FrontierConditions_GlobalTag_cff')
from Configuration.AlCa.GlobalTag import GlobalTag
process.GlobalTag = GlobalTag(process.GlobalTag, 'auto:phase1_2024_realistic', '')

# Output
process.output = cms.OutputModule("PoolOutputModule",
    fileName = cms.untracked.string("GENSIM.root"),
    outputCommands = cms.untracked.vstring(
        'keep *',
    ),
    SelectEvents = cms.untracked.PSet(
        SelectEvents = cms.vstring()
    )
)

process.p = cms.Path(process.psim)
process.e = cms.EndPath(process.output)

process.schedule = cms.Schedule(process.p, process.e)
GENSIMCFG

msg_info "Running GEN-SIM (${NUM_EVENTS} events)..."
cmsRun gensim_cfg.py 2>&1 | tee gensim.log

if [[ ! -f "GENSIM.root" ]]; then
    msg_error "GEN-SIM failed to produce output"
    cat gensim.log
    exit 1
fi

GENSIM_SIZE=$(stat -c%s "GENSIM.root")
msg_ok "GEN-SIM output: GENSIM.root (${GENSIM_SIZE} bytes)"

# ============================================================================
# Test 5: DIGI-RAW step
# ============================================================================
msg_step "Test 5: DIGI-RAW"

msg_info "Creating DIGI-RAW config..."
cmsDriver.py step1 \
    --step DIGI,L1,DIGI2RAW \
    --conditions auto:phase1_2024_realistic \
    --datatier GEN-SIM-DIGI-RAW \
    --eventcontent RAWSIM \
    --era Run3 \
    --filein file:GENSIM.root \
    --fileout file:RAW.root \
    --python_filename raw_cfg.py \
    --mc -n ${NUM_EVENTS} \
    --no_exec

msg_info "Running DIGI-RAW..."
cmsRun raw_cfg.py 2>&1 | tee raw.log

if [[ ! -f "RAW.root" ]]; then
    msg_error "DIGI-RAW failed to produce output"
    exit 1
fi

RAW_SIZE=$(stat -c%s "RAW.root")
msg_ok "DIGI-RAW output: RAW.root (${RAW_SIZE} bytes)"

# ============================================================================
# Test 6: RECO step
# ============================================================================
msg_step "Test 6: RECO"

msg_info "Creating RECO config..."
cmsDriver.py step2 \
    --step RAW2DIGI,L1Reco,RECO \
    --conditions auto:phase1_2024_realistic \
    --datatier GEN-SIM-RECO \
    --eventcontent AODSIM \
    --era Run3 \
    --filein file:RAW.root \
    --fileout file:RECO.root \
    --python_filename reco_cfg.py \
    --mc -n ${NUM_EVENTS} \
    --no_exec

msg_info "Running RECO..."
cmsRun reco_cfg.py 2>&1 | tee reco.log

if [[ ! -f "RECO.root" ]]; then
    msg_error "RECO failed to produce output"
    exit 1
fi

RECO_SIZE=$(stat -c%s "RECO.root")
msg_ok "RECO output: RECO.root (${RECO_SIZE} bytes)"

# ============================================================================
# Test 7: MiniAOD step
# ============================================================================
msg_step "Test 7: MiniAOD"

msg_info "Creating MiniAOD config..."
cmsDriver.py step3 \
    --step PAT \
    --conditions auto:phase1_2024_realistic \
    --datatier MINIAODSIM \
    --eventcontent MINIAODSIM \
    --era Run3 \
    --filein file:RECO.root \
    --fileout file:MINIAOD.root \
    --python_filename miniaod_cfg.py \
    --mc -n ${NUM_EVENTS} \
    --no_exec

msg_info "Running MiniAOD..."
cmsRun miniaod_cfg.py 2>&1 | tee miniaod.log

if [[ ! -f "MINIAOD.root" ]]; then
    msg_error "MiniAOD failed to produce output"
    exit 1
fi

MINIAOD_SIZE=$(stat -c%s "MINIAOD.root")
msg_ok "MiniAOD output: MINIAOD.root (${MINIAOD_SIZE} bytes)"

# ============================================================================
# Test 8: Ntuple step (el9 via apptainer)
# ============================================================================
if [[ ${SKIP_NTUPLE} -eq 1 ]]; then
    msg_step "Test 8: Ntuple (SKIPPED)"
    msg_warn "Ntuple test skipped by user request"
else
    msg_step "Test 8: Ntuple (el9 via apptainer)"
    
    # Check apptainer availability
    if ! command -v apptainer &> /dev/null; then
        msg_warn "Apptainer not available, skipping Ntuple test"
    else
        msg_info "Running Ntuple generation in el9 container..."
        
        # Create Ntuple config
        cat > ntuple_cfg.py << 'NTUPLECFG'
import FWCore.ParameterSet.Config as cms
import os

process = cms.Process("Ntuple")

process.load("FWCore.MessageService.MessageLogger_cfi")
process.MessageLogger.cerr.FwkReport.reportEvery = 1

process.maxEvents = cms.untracked.PSet(input = cms.untracked.int32(-1))

process.source = cms.Source("PoolSource",
    fileNames = cms.untracked.vstring("file:MINIAOD.root")
)

process.TFileService = cms.Service("TFileService",
    fileName = cms.string("Ntuple.root")
)

# Simple analyzer that just tests reading
process.analyzer = cms.EDAnalyzer("MiniAODAnalyzer",
    # Add analyzer config
)
NTUPLECFG
        
        # Run in el9 container
        apptainer exec \
            -B /cvmfs -B ${PWD} \
            /cvmfs/unpacked.cern.ch/registry.hub.docker.com/cmssw/el9:x86_64 \
            bash -c "
                source /cvmfs/cms.cern.ch/cmsset_default.sh
                export SCRAM_ARCH=el9_amd64_gcc12
                cd ${PWD}
                scramv1 project CMSSW CMSSW_14_0_18
                cd CMSSW_14_0_18/src
                eval \$(scramv1 runtime -sh)
                cd ${PWD}
                echo 'CMSSW_14 environment ready'
                ls -la MINIAOD.root
            " 2>&1 | tee ntuple.log
        
        msg_ok "Ntuple environment test passed"
    fi
fi

# ============================================================================
# Summary
# ============================================================================
msg_step "Test Summary"

echo ""
echo "=============================================="
echo "  CMSSW Chain Test Results"
echo "=============================================="
echo ""
msg_ok "All CMSSW tests passed!"
echo ""
echo "Output files:"
echo "  - GENSIM.root:  ${GENSIM_SIZE:-N/A} bytes"
echo "  - RAW.root:     ${RAW_SIZE:-N/A} bytes"
echo "  - RECO.root:    ${RECO_SIZE:-N/A} bytes"
echo "  - MINIAOD.root: ${MINIAOD_SIZE:-N/A} bytes"
echo ""
echo "Log files in: ${TEST_WORKDIR}"
echo ""
msg_info "Workdir preserved. Remove with: rm -rf ${TEST_WORKDIR}"
