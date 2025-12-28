#!/bin/bash
# ==============================================================================
# run_chain.sh - Universal MC Production Chain Wrapper
# ==============================================================================
# This script orchestrates the complete MC production chain:
#   LHE -> Shower -> Mix -> GEN-SIM -> RAW -> RECO -> MiniAOD -> Ntuple
#
# Designed to run on HTCondor worker nodes with proper environment setup.
#
# Usage:
#   ./run_chain.sh --inputs f1.lhe,f2.lhe --modes normal,phi --analysis JJP|JUP \
#                  --campaign CAMPAIGN_NAME --job-id JOB_ID [options]
#
# Examples:
#   # JJP DPS: Two J/psi sources mixed
#   ./run_chain.sh --inputs pool_jpsi_g:100,pool_jpsi_g:101 --modes normal,phi \
#                  --analysis JJP --campaign JJP_DPS1 --job-id 0
#
#   # JUP SPS: Single source with phi shower
#   ./run_chain.sh --inputs pool_jpsi_upsilon_g:50 --modes phi \
#                  --analysis JUP --campaign JUP_SPS --job-id 0
# ==============================================================================

set -e

# ==============================================================================
# Configuration
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
COMMON_DIR="${BASE_DIR}/common"
SHOWER_DIR="${SCRIPT_DIR}/pythia_shower"
CMSSW_CONFIGS_DIR="${COMMON_DIR}/cmssw_configs"
PACKAGES_DIR="${COMMON_DIR}/packages"

# Fallback when run from a transferred sandbox (run_chain.sh + sibling folders)
if [[ ! -d "${COMMON_DIR}" && -d "${SCRIPT_DIR}/common" ]]; then
    BASE_DIR="${SCRIPT_DIR}"
    COMMON_DIR="${BASE_DIR}/common"
    SHOWER_DIR="${BASE_DIR}/pythia_shower"
    CMSSW_CONFIGS_DIR="${COMMON_DIR}/cmssw_configs"
    PACKAGES_DIR="${COMMON_DIR}/packages"
fi

# CMSSW paths
CMSSW_12_BASE="${CMSSW_12_BASE:-/afs/cern.ch/user/x/xcheng/condor/CMSSW_12_4_14_patch3}"
CMSSW_14_BASE="${CMSSW_14_BASE:-/afs/cern.ch/user/x/xcheng/condor/CMSSW_14_0_18}"

# T2_CN_Beijing XRootD storage paths
EOS_HOST="cceos.ihep.ac.cn"
EOS_PATH_BASE="/eos/ihep/cms/store/user/xcheng/MC_Production"
EOS_BASE="root://${EOS_HOST}/${EOS_PATH_BASE}"
EOS_LHE_POOL="${EOS_BASE}/lhe_pools"
EOS_OUTPUT="${EOS_BASE}/output"

# Existing LHE pools (now on T2_CN_Beijing storage)
declare -A EXISTING_POOLS=(
    ["pool_jpsi_g"]="lhe_pools/pool_jpsi_g"
    ["pool_gg"]="lhe_pools/pool_gg"
)

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

if [[ ! -d "${COMMON_DIR}" ]]; then
    echo "[ERROR] Common directory not found at ${COMMON_DIR}. Ensure common/ is transferred alongside run_chain.sh."
    exit 1
fi

# ==============================================================================
# Utility Functions
# ==============================================================================

msg_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
msg_ok() { echo -e "${GREEN}[OK]${NC} $1"; }
msg_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
msg_error() { echo -e "${RED}[ERROR]${NC} $1"; }
msg_step() { echo -e "\n${YELLOW}========================================${NC}"; echo -e "${YELLOW}  $1${NC}"; echo -e "${YELLOW}========================================${NC}\n"; }

# Create remote directory via XRootD
make_remote_dir() {
    local remote_subpath="$1"
    msg_info "Creating remote directory: ${EOS_PATH_BASE}/${remote_subpath}"
    xrdfs "${EOS_HOST}" mkdir -p "${EOS_PATH_BASE}/${remote_subpath}" || {
        msg_error "Failed to create remote directory: ${EOS_PATH_BASE}/${remote_subpath}"
        return 1
    }
    msg_ok "Remote directory ready: ${EOS_PATH_BASE}/${remote_subpath}"
}

# Stage out files via XRootD
stage_out() {
    local local_file="$1"
    local remote_subpath="$2"
    
    if [[ ! -f "${local_file}" ]]; then
        msg_error "Local file not found: ${local_file}"
        return 1
    fi
    
    local remote_url="${EOS_BASE}/${remote_subpath}"
    msg_info "Staging out: ${local_file} -> ${remote_url}"
    
    xrdcp --nopbar --force "${local_file}" "${remote_url}" || {
        msg_error "Failed to stage out ${local_file} to ${remote_url}"
        return 1
    }
    msg_ok "Staged out: ${remote_url}"
}

get_lhe_file() {
    local pool_name="$1"
    local index="$2"
    local pool_subpath=""
    
    # Check for existing pool (use subpath from EXISTING_POOLS)
    if [[ -n "${EXISTING_POOLS[$pool_name]}" ]]; then
        pool_subpath="${EXISTING_POOLS[$pool_name]}"
    else
        pool_subpath="lhe_pools/${pool_name}"
    fi
    
    # List files via xrdfs
    local file_list
    file_list=$(xrdfs "${EOS_HOST}" ls "${EOS_PATH_BASE}/${pool_subpath}" 2>/dev/null | grep '\.lhe$' | sort)
    
    if [[ -z "${file_list}" ]]; then
        msg_error "No LHE files found in ${EOS_PATH_BASE}/${pool_subpath}"
        return 1
    fi
    
    # Convert to array
    local files=()
    while IFS= read -r line; do
        files+=("${line}")
    done <<< "${file_list}"
    
    local n_files=${#files[@]}
    
    if [[ $n_files -eq 0 ]]; then
        msg_error "No LHE files found in ${pool_subpath}"
        return 1
    fi
    
    # Wrap around if index exceeds available files
    local file_idx=$((index % n_files))
    local selected_path="${files[$file_idx]}"
    
    # Return full XRootD URL
    echo "root://${EOS_HOST}/${selected_path}"
}

setup_cmssw12() {
    msg_info "Setting up CMSSW_12_4_14_patch3..."
    source /cvmfs/cms.cern.ch/cmsset_default.sh
    # Force el8 architecture for CMSSW_12
    export SCRAM_ARCH=el8_amd64_gcc10
    cd "${CMSSW_12_BASE}/src"
    eval $(scramv1 runtime -sh)
    cd - > /dev/null
    msg_ok "CMSSW environment: ${CMSSW_VERSION}"
}

setup_cmssw14() {
    msg_info "Setting up CMSSW_14_0_18..."

    if [[ ! -d "${CMSSW_14_BASE}/src" ]]; then
        msg_error "CMSSW_14_0_18 not found at ${CMSSW_14_BASE}; ensure packages are unpacked and built"
        return 1
    fi

    # Note: CMSSW_14 is built in el9 container, setup happens in container too
    source /cvmfs/cms.cern.ch/cmsset_default.sh
    # Force el9 architecture for CMSSW_14
    export SCRAM_ARCH=el9_amd64_gcc12
    cd "${CMSSW_14_BASE}/src"
    eval $(scramv1 runtime -sh)
    cd - > /dev/null
    msg_ok "CMSSW environment: ${CMSSW_VERSION}"
}

# EL9 container path for CMSSW_14
EL9_CONTAINER="/cvmfs/unpacked.cern.ch/registry.hub.docker.com/cmssw/el9:x86_64"

# Run command inside el9 container using apptainer
run_in_el9_container() {
    local script_content="$1"
    local tmp_script=$(mktemp --suffix=_el9_cmd.sh)
    
    cat > "${tmp_script}" << 'SCRIPT_HEADER'
#!/bin/bash
set -e
source /cvmfs/cms.cern.ch/cmsset_default.sh
export SCRAM_ARCH=el9_amd64_gcc12
SCRIPT_HEADER
    
    echo "${script_content}" >> "${tmp_script}"
    chmod +x "${tmp_script}"
    
    # Run in el9 container with necessary bind mounts
    apptainer exec \
        --bind /cvmfs:/cvmfs \
        --bind /afs:/afs \
        --bind /eos:/eos \
        --bind /tmp:/tmp \
        --bind "${WORKDIR}:${WORKDIR}" \
        "${EL9_CONTAINER}" \
        /bin/bash "${tmp_script}"
    
    local rc=$?
    rm -f "${tmp_script}"
    return ${rc}
}

run_cmsrun_cmssw14() {
    local cfg="$1"
    shift
    
    msg_info "Running cmsRun in el9 container for CMSSW_14..."
    
    local script_content="
cd \"${CMSSW_14_BASE}/src\"
eval \$(scramv1 runtime -sh)
cmsRun \"${cfg}\" \"\$@\"
"
    
    # Build the full command with arguments
    local tmp_script=$(mktemp --suffix=_cmsrun.sh)
    cat > "${tmp_script}" << SCRIPT_EOF
#!/bin/bash
set -e
source /cvmfs/cms.cern.ch/cmsset_default.sh
export SCRAM_ARCH=el9_amd64_gcc12
cd "${CMSSW_14_BASE}/src"
eval \$(scramv1 runtime -sh)
cmsRun "${cfg}" $@
SCRIPT_EOF
    
    chmod +x "${tmp_script}"
    
    apptainer exec \
        --bind /cvmfs:/cvmfs \
        --bind /afs:/afs \
        --bind /eos:/eos \
        --bind /tmp:/tmp \
        --bind "${WORKDIR}:${WORKDIR}" \
        --env "X509_USER_PROXY=${X509_USER_PROXY:-}" \
        --env "HOME=${HOME}" \
        "${EL9_CONTAINER}" \
        /bin/bash "${tmp_script}"
    
    local rc=$?
    rm -f "${tmp_script}"
    return ${rc}
}

ensure_voms_proxy() {
    msg_info "Checking VOMS proxy for pileup access..."

    # Prefer user-provided proxy if already set
    if [[ -z "${X509_USER_PROXY:-}" ]] && [[ -f "/tmp/x509up_u$(id -u)" ]]; then
        export X509_USER_PROXY="/tmp/x509up_u$(id -u)"
        msg_info "Using default proxy path: ${X509_USER_PROXY}"
    fi

    if command -v voms-proxy-info >/dev/null 2>&1; then
        if voms-proxy-info --exists >/dev/null 2>&1; then
            local tl
            tl=$(voms-proxy-info --timeleft 2>/dev/null || true)
            msg_ok "VOMS proxy valid (timeleft: ${tl}s)"
            return 0
        fi
    else
        msg_warn "voms-proxy-info not found; skipping proxy validation"
        return 0
    fi

    msg_warn "No valid VOMS proxy detected. If DIGI premix download fails, run: voms-proxy-init -voms cms -valid 192:00"
}

prepare_cmssw14_from_package() {
    local analysis="$1"
    local pkg=""

    case "${analysis}" in
        "JJP") pkg="${PACKAGES_DIR}/jjp_code.tar.gz" ;;
        "JUP") pkg="${PACKAGES_DIR}/jup_code.tar.gz" ;;
        *) msg_error "Unknown analysis type for CMSSW_14 build: ${analysis}"; return 1 ;;
    esac

    if [[ ! -d "${PACKAGES_DIR}" ]]; then
        msg_error "Packages directory missing: ${PACKAGES_DIR}"
        return 1
    fi
    if [[ ! -f "${pkg}" ]]; then
        msg_error "Package not found: ${pkg} (ensure common/packages is transferred)"
        return 1
    fi

    local project_dir="${WORKDIR}/CMSSW_14_0_18"
    export CMSSW_14_BASE="${project_dir}"
    
    if [[ ! -d "${project_dir}/src" ]]; then
        msg_info "Creating CMSSW_14_0_18 project in el9 container at ${project_dir}..."
        
        local tmp_script=$(mktemp --suffix=_create_cmssw14.sh)
        cat > "${tmp_script}" << CREATEEOF
#!/bin/bash
set -e
source /cvmfs/cms.cern.ch/cmsset_default.sh
export SCRAM_ARCH=el9_amd64_gcc12
cd "${WORKDIR}"
scramv1 project CMSSW CMSSW_14_0_18
CREATEEOF
        chmod +x "${tmp_script}"
        
        apptainer exec \
            --bind /cvmfs:/cvmfs \
            --bind /afs:/afs \
            --bind /eos:/eos \
            --bind /tmp:/tmp \
            --bind "${WORKDIR}:${WORKDIR}" \
            "${EL9_CONTAINER}" \
            /bin/bash "${tmp_script}"
        rm -f "${tmp_script}"
    fi

    # Check for correct package structure based on analysis type
    local pkg_check_dir=""
    case "${analysis}" in
        "JJP") pkg_check_dir="${project_dir}/src/JJPNtupleMaker/TPS-Onia2MuMu" ;;
        "JUP") pkg_check_dir="${project_dir}/src/JUPNtupleMaker/TPS-Onia2MuMu" ;;
    esac
    
    if [[ ! -d "${pkg_check_dir}" ]]; then
        msg_info "Unpacking ${pkg} into CMSSW src..."
        tar -xzf "${pkg}" -C "${project_dir}/src"
    fi

    local stamp="${project_dir}/.built_${analysis,,}"
    if [[ ! -f "${stamp}" ]]; then
        msg_info "Compiling ntuple code for ${analysis} in el9 container..."
        
        local tmp_script=$(mktemp --suffix=_build_cmssw14.sh)
        cat > "${tmp_script}" << BUILDEOF
#!/bin/bash
set -e
source /cvmfs/cms.cern.ch/cmsset_default.sh
export SCRAM_ARCH=el9_amd64_gcc12
cd "${project_dir}/src"
eval \$(scramv1 runtime -sh)
scram b -j 4
BUILDEOF
        chmod +x "${tmp_script}"
        
        apptainer exec \
            --bind /cvmfs:/cvmfs \
            --bind /afs:/afs \
            --bind /eos:/eos \
            --bind /tmp:/tmp \
            --bind "${WORKDIR}:${WORKDIR}" \
            "${EL9_CONTAINER}" \
            /bin/bash "${tmp_script}"
        rm -f "${tmp_script}"
        
        touch "${stamp}"
    else
        msg_info "Reusing existing CMSSW_14_0_18 build for ${analysis}"
    fi
}

# ==============================================================================
# Processing Steps
# ==============================================================================

# Step 1: Shower LHE files
run_shower() {
    local lhe_files=("$@")
    local n_files=${#lhe_files[@]}
    local n_modes=${#SHOWER_MODES[@]}
    
    msg_step "Step 1: Pythia8 Shower"
    
    if [[ $n_files -ne $n_modes ]]; then
        msg_error "Number of LHE files ($n_files) doesn't match modes ($n_modes)"
        return 1
    fi
    
    HEPMC_FILES=()
    
    setup_cmssw12
    cd "${SHOWER_DIR}"
    
    # Build shower programs if needed
    if [[ ! -f "shower_normal" ]] || [[ ! -f "shower_phi" ]]; then
        msg_info "Building shower programs..."
        make shower
    fi
    
    for ((i=0; i<n_files; i++)); do
        local lhe_file="${lhe_files[$i]}"
        local mode="${SHOWER_MODES[$i]}"
        local hepmc_output="${WORKDIR}/shower_${i}.hepmc"
        
        msg_info "Processing source $((i+1))/${n_files}: ${lhe_file}"
        msg_info "Shower mode: ${mode}"
        
        if [[ "$mode" == "phi" ]]; then
            ./shower_phi "${lhe_file}" "${hepmc_output}" -1 0.0 2.5 2.4 1000
        else
            ./shower_normal "${lhe_file}" "${hepmc_output}" -1 2.5 2.4 1000
        fi
        
        if [[ ! -f "${hepmc_output}" ]]; then
            msg_error "Shower failed: ${hepmc_output} not created"
            return 1
        fi
        
        HEPMC_FILES+=("${hepmc_output}")
        msg_ok "Shower complete: ${hepmc_output}"
    done
    
    cd "${WORKDIR}"
}

# Step 2: Mix HepMC files
run_mix() {
    msg_step "Step 2: Event Mixing"
    
    local n_sources=${#HEPMC_FILES[@]}
    MIXED_HEPMC="${WORKDIR}/mixed.hepmc"
    
    cd "${SHOWER_DIR}"
    
    # Build mixer if needed
    if [[ ! -f "event_mixer_multisource" ]]; then
        msg_info "Building event mixer..."
        make mixer
    fi
    
    if [[ $n_sources -eq 1 ]]; then
        msg_info "Single source - converting to HepMC2 format..."
        ./event_mixer_multisource "${MIXED_HEPMC}" "${HEPMC_FILES[0]}"
    else
        msg_info "Mixing ${n_sources} sources..."
        ./event_mixer_multisource "${MIXED_HEPMC}" "${HEPMC_FILES[@]}"
    fi
    
    if [[ ! -f "${MIXED_HEPMC}" ]]; then
        msg_error "Mixing failed: ${MIXED_HEPMC} not created"
        return 1
    fi
    
    msg_ok "Mixing complete: ${MIXED_HEPMC}"
    cd "${WORKDIR}"
}

# Step 3: GEN-SIM
run_gensim() {
    msg_step "Step 3: GEN-SIM"
    
    GENSIM_OUTPUT="${WORKDIR}/output_GENSIM.root"

    # When resuming with --skip-to gensim, ensure MIXED_HEPMC points to the
    # expected mixed file in the workdir.
    MIXED_HEPMC="${MIXED_HEPMC:-${WORKDIR}/mixed.hepmc}"
    if [[ ! -f "${MIXED_HEPMC}" ]]; then
        msg_error "GEN-SIM input missing: ${MIXED_HEPMC}"
        return 1
    fi
    
    setup_cmssw12
    
    msg_info "Running HepMC -> GEN-SIM..."
    cmsRun "${CMSSW_CONFIGS_DIR}/hepmc_to_GENSIM.py" \
        inputFiles="file:${MIXED_HEPMC}" \
        outputFile="file:${GENSIM_OUTPUT}" \
        maxEvents=${MAX_EVENTS} \
        nThreads=4
    
    if [[ ! -f "${GENSIM_OUTPUT}" ]]; then
        msg_error "GEN-SIM failed: ${GENSIM_OUTPUT} not created"
        return 1
    fi
    
    msg_ok "GEN-SIM complete: ${GENSIM_OUTPUT}"
}

# Step 4: RAW (DIGI + HLT)
run_raw() {
    msg_step "Step 4: RAW (DIGI + HLT)"
    
    RAW_OUTPUT="${WORKDIR}/output_RAW.root"
    
    setup_cmssw12
    
    local cfg_file=$(mktemp --suffix=_raw_cfg.py)
    
    msg_info "Generating RAW config..."
    cmsDriver.py step2 \
        --mc --no_exec \
        --python_filename "${cfg_file}" \
        --eventcontent PREMIXRAW \
        --step DIGI,DATAMIX,L1,DIGI2RAW,HLT:2022v12 \
        --procModifiers premix_stage2,siPixelQualityRawToDigi \
        --datamix PreMix \
        --datatier GEN-SIM-RAW \
        --conditions 124X_mcRun3_2022_realistic_v12 \
        --beamspot Realistic25ns13p6TeVEarly2022Collision \
        --era Run3 \
        --geometry DB:Extended \
        -n "${MAX_EVENTS}" \
        --customise Configuration/DataProcessing/Utils.addMonitoring \
        --nThreads 4 --nStreams 4 \
        --pileup_input "filelist:/cvmfs/cms.cern.ch/offcomp-prod/premixPUlist/PREMIX-Run3Summer22DRPremix.txt" \
        --filein "file:${GENSIM_OUTPUT}" \
        --fileout "file:${RAW_OUTPUT}"
    
    msg_info "Running RAW step..."
    cmsRun "${cfg_file}"
    rm -f "${cfg_file}"
    
    if [[ ! -f "${RAW_OUTPUT}" ]]; then
        msg_error "RAW step failed: ${RAW_OUTPUT} not created"
        return 1
    fi
    
    msg_ok "RAW complete: ${RAW_OUTPUT}"
}

# Step 5: RECO
run_reco() {
    msg_step "Step 5: RECO"
    
    RECO_OUTPUT="${WORKDIR}/output_RECO.root"
    
    setup_cmssw12
    
    local cfg_file=$(mktemp --suffix=_reco_cfg.py)
    
    msg_info "Generating RECO config..."
    cmsDriver.py step3 \
        --mc --no_exec \
        --python_filename "${cfg_file}" \
        --eventcontent AODSIM \
        --step RAW2DIGI,L1Reco,RECO,RECOSIM \
        --procModifiers siPixelQualityRawToDigi \
        --datatier AODSIM \
        --conditions 124X_mcRun3_2022_realistic_v12 \
        --beamspot Realistic25ns13p6TeVEarly2022Collision \
        --era Run3 \
        --geometry DB:Extended \
        -n "${MAX_EVENTS}" \
        --customise Configuration/DataProcessing/Utils.addMonitoring \
        --nThreads 4 --nStreams 4 \
        --filein "file:${RAW_OUTPUT}" \
        --fileout "file:${RECO_OUTPUT}"
    
    msg_info "Running RECO step..."
    cmsRun "${cfg_file}"
    rm -f "${cfg_file}"
    
    if [[ ! -f "${RECO_OUTPUT}" ]]; then
        msg_error "RECO step failed: ${RECO_OUTPUT} not created"
        return 1
    fi
    
    msg_ok "RECO complete: ${RECO_OUTPUT}"
}

# Step 6: MiniAOD
run_miniaod() {
    msg_step "Step 6: MiniAOD"
    
    MINIAOD_OUTPUT="${WORKDIR}/output_MINIAOD.root"
    
    setup_cmssw12
    
    local cfg_file=$(mktemp --suffix=_miniaod_cfg.py)
    
    msg_info "Generating MiniAOD config..."
    cmsDriver.py step4 \
        --mc --no_exec \
        --python_filename "${cfg_file}" \
        --eventcontent MINIAODSIM \
        --step PAT \
        --datatier MINIAODSIM \
        --conditions 124X_mcRun3_2022_realistic_v12 \
        --era Run3 \
        --geometry DB:Extended \
        -n "${MAX_EVENTS}" \
        --customise Configuration/DataProcessing/Utils.addMonitoring \
        --nThreads 4 --nStreams 4 \
        --filein "file:${RECO_OUTPUT}" \
        --fileout "file:${MINIAOD_OUTPUT}"
    
    msg_info "Running MiniAOD step..."
    cmsRun "${cfg_file}"
    rm -f "${cfg_file}"
    
    if [[ ! -f "${MINIAOD_OUTPUT}" ]]; then
        msg_error "MiniAOD step failed: ${MINIAOD_OUTPUT} not created"
        return 1
    fi
    
    msg_ok "MiniAOD complete: ${MINIAOD_OUTPUT}"
}

# Step 7: Ntuple
run_ntuple() {
    msg_step "Step 7: Ntuple (${ANALYSIS_TYPE})"
    
    NTUPLE_OUTPUT="${WORKDIR}/output_ntuple.root"
    MINIAOD_OUTPUT="${MINIAOD_OUTPUT:-${WORKDIR}/output_MINIAOD.root}"

    if [[ ! -f "${MINIAOD_OUTPUT}" ]]; then
        msg_error "Ntuple input missing: ${MINIAOD_OUTPUT}"
        return 1
    fi

    prepare_cmssw14_from_package "${ANALYSIS_TYPE}" || return 1
    setup_cmssw14
    
    if [[ "${ANALYSIS_TYPE}" == "JJP" ]]; then
        msg_info "Running JJP Ntuple analysis..."
        run_cmsrun_cmssw14 "${CMSSW_CONFIGS_DIR}/ntuple_jjp_cfg.py" \
            inputFiles="file:${MINIAOD_OUTPUT}" \
            outputFile="${NTUPLE_OUTPUT}" \
            runOnMC=True \
            maxEvents=-1
    elif [[ "${ANALYSIS_TYPE}" == "JUP" ]]; then
        msg_info "Running JUP Ntuple analysis..."
        run_cmsrun_cmssw14 "${CMSSW_CONFIGS_DIR}/ntuple_jup_cfg.py" \
            inputFiles="file:${MINIAOD_OUTPUT}" \
            outputFile="${NTUPLE_OUTPUT}" \
            runOnMC=True \
            maxEvents=-1
    else
        msg_error "Unknown analysis type: ${ANALYSIS_TYPE}"
        return 1
    fi
    
    if [[ ! -f "${NTUPLE_OUTPUT}" ]]; then
        msg_error "Ntuple step failed: ${NTUPLE_OUTPUT} not created"
        return 1
    fi
    
    msg_ok "Ntuple complete: ${NTUPLE_OUTPUT}"
}

# Step 8: Transfer output
transfer_output() {
    msg_step "Step 8: Transfer to T2_CN_Beijing Storage"
    
    local output_subpath="output/${CAMPAIGN_NAME}/${JOB_ID}"
    
    # Create remote directory
    make_remote_dir "${output_subpath}" || return 1
    
    # Copy final outputs via XRootD
    if [[ -f "${MINIAOD_OUTPUT}" ]]; then
        local miniaod_basename=$(basename "${MINIAOD_OUTPUT}")
        stage_out "${MINIAOD_OUTPUT}" "${output_subpath}/${miniaod_basename}" || return 1
    fi
    
    if [[ -f "${NTUPLE_OUTPUT}" ]]; then
        local ntuple_basename=$(basename "${NTUPLE_OUTPUT}")
        stage_out "${NTUPLE_OUTPUT}" "${output_subpath}/${ntuple_basename}" || return 1
    fi
    
    # Cleanup intermediate files
    if [[ "${CLEANUP}" == "true" ]]; then
        msg_info "Cleaning up intermediate files..."
        rm -f "${WORKDIR}"/*.hepmc
        rm -f "${WORKDIR}"/output_GENSIM.root
        rm -f "${WORKDIR}"/output_RAW.root
        rm -f "${WORKDIR}"/output_RECO.root
        msg_ok "Cleanup complete"
    fi
    
    msg_ok "Transfer complete: ${EOS_BASE}/${output_subpath}/"
}

# ==============================================================================
# Main
# ==============================================================================

usage() {
    cat << EOF
Usage: $0 [options]

Required options:
  --inputs INPUTS       Comma-separated list of pool:index pairs
  --modes MODES         Comma-separated shower modes (normal|phi)
  --analysis TYPE       Analysis type: JJP or JUP
  --campaign NAME       Campaign name (e.g., JJP_DPS1)
  --job-id ID           Job identifier

Optional:
  --workdir DIR         Working directory (default: current dir)
  --no-cleanup          Keep intermediate files
  --skip-to STEP        Skip to specified step (shower|mix|gensim|raw|reco|miniaod|ntuple)
  --stop-at STEP        Stop after specified step
    --max-events N        Limit events for fast local test (default: -1 = all)
  -h, --help            Show this help

Examples:
  $0 --inputs pool_jpsi_g:0,pool_jpsi_g:1 --modes normal,phi \\
     --analysis JJP --campaign JJP_DPS1 --job-id 0

  $0 --inputs pool_2jpsi_g:0 --modes phi \\
     --analysis JJP --campaign JJP_SPS --job-id 0
EOF
    exit 1
}

# Parse arguments
INPUTS=""
MODES=""
ANALYSIS_TYPE=""
CAMPAIGN_NAME=""
JOB_ID=""
WORKDIR=$(pwd)
CLEANUP="true"
SKIP_TO=""
STOP_AT=""
MAX_EVENTS=-1

while [[ $# -gt 0 ]]; do
    case $1 in
        --inputs)
            INPUTS="$2"
            shift 2
            ;;
        --modes)
            MODES="$2"
            shift 2
            ;;
        --analysis)
            ANALYSIS_TYPE="$2"
            shift 2
            ;;
        --campaign)
            CAMPAIGN_NAME="$2"
            shift 2
            ;;
        --job-id)
            JOB_ID="$2"
            shift 2
            ;;
        --workdir)
            WORKDIR="$2"
            shift 2
            ;;
        --no-cleanup)
            CLEANUP="false"
            shift
            ;;
        --skip-to)
            SKIP_TO="$2"
            shift 2
            ;;
        --stop-at)
            STOP_AT="$2"
            shift 2
            ;;
        --max-events)
            MAX_EVENTS="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            msg_error "Unknown option: $1"
            usage
            ;;
    esac
done

# Validate required arguments
if [[ -z "$INPUTS" ]] || [[ -z "$MODES" ]] || [[ -z "$ANALYSIS_TYPE" ]] || [[ -z "$CAMPAIGN_NAME" ]] || [[ -z "$JOB_ID" ]]; then
    msg_error "Missing required arguments"
    usage
fi

# Parse inputs and modes
IFS=',' read -ra INPUT_SPECS <<< "$INPUTS"
IFS=',' read -ra SHOWER_MODES <<< "$MODES"

# Resolve LHE files from pool:index specs (supports GEN:pool:idx, EOS:pool:idx:usage, or pool:idx)
LHE_FILES=()
declare -a parts  # Declare array outside loop (no 'local' in main script)
for spec in "${INPUT_SPECS[@]}"; do
    if [[ "$spec" == GEN:* ]]; then
        # Format: GEN:pool_name:lhe_job_idx - generated LHE from DAG
        # The LHE file should be at EOS_LHE_POOL/pool_name/sample_pool_name_<seed>.lhe
        IFS=':' read -ra parts <<< "$spec"
        pool_name="${parts[1]}"
        lhe_job_idx="${parts[2]}"
        # For GEN: prefix, we look in the pool directory for any available file
        # Seed is typically 100 + job_idx for DAG jobs
        seed=$((100 + lhe_job_idx))
        lhe_file="${EOS_LHE_POOL}/${pool_name}/sample_${pool_name}_${seed}.lhe"
        if [[ ! -f "$lhe_file" ]]; then
            # Try to find any lhe file in the pool
            lhe_file=$(get_lhe_file "$pool_name" "$lhe_job_idx")
        fi
    elif [[ "$spec" == EOS:* ]]; then
        # Format: EOS:pool_name:job_id:usage_idx - existing LHE from EOS
        IFS=':' read -ra parts <<< "$spec"
        pool_name="${parts[1]}"
        job_id="${parts[2]}"
        lhe_file=$(get_lhe_file "$pool_name" "$job_id")
    else
        # Legacy format: pool_name:index
        pool_name="${spec%:*}"
        index="${spec#*:}"
        lhe_file=$(get_lhe_file "$pool_name" "$index")
    fi
    
    if [[ -z "$lhe_file" ]] || [[ ! -f "$lhe_file" ]]; then
        msg_error "Could not resolve LHE file for: $spec (tried: ${lhe_file:-<none>})"
        exit 1
    fi
    LHE_FILES+=("$lhe_file")
done

# Print configuration
echo ""
echo "=============================================="
echo "MC Production Chain"
echo "=============================================="
echo "Campaign:     ${CAMPAIGN_NAME}"
echo "Job ID:       ${JOB_ID}"
echo "Analysis:     ${ANALYSIS_TYPE}"
echo "Work dir:     ${WORKDIR}"
echo "N sources:    ${#LHE_FILES[@]}"
for ((i=0; i<${#LHE_FILES[@]}; i++)); do
    echo "  Source $((i+1)): ${LHE_FILES[$i]} (mode: ${SHOWER_MODES[$i]})"
done
echo "Max events:   ${MAX_EVENTS}"
echo "=============================================="
echo ""

# Create work directory
mkdir -p "${WORKDIR}"
cd "${WORKDIR}"

# Define step order
STEPS=("shower" "mix" "gensim" "raw" "reco" "miniaod" "ntuple" "transfer")

# Determine starting step
start_idx=0
if [[ -n "$SKIP_TO" ]]; then
    for ((i=0; i<${#STEPS[@]}; i++)); do
        if [[ "${STEPS[$i]}" == "$SKIP_TO" ]]; then
            start_idx=$i
            break
        fi
    done
fi

# Determine ending step
end_idx=$((${#STEPS[@]} - 1))
if [[ -n "$STOP_AT" ]]; then
    for ((i=0; i<${#STEPS[@]}; i++)); do
        if [[ "${STEPS[$i]}" == "$STOP_AT" ]]; then
            end_idx=$i
            break
        fi
    done
fi

# Summarize planned steps (helps debugging skip/stop logic)
SELECTED_STEPS=()
for ((i=start_idx; i<=end_idx; i++)); do
    SELECTED_STEPS+=("${STEPS[$i]}")
done
msg_info "Planned steps: ${SELECTED_STEPS[*]}"

# Validate VOMS proxy early to avoid pileup download failures
ensure_voms_proxy

# Run steps using the selected list (avoids index/loop drift)
for step in "${SELECTED_STEPS[@]}"; do
    case "$step" in
        shower)
            run_shower "${LHE_FILES[@]}"
            ;;
        mix)
            run_mix
            ;;
        gensim)
            run_gensim
            ;;
        raw)
            run_raw
            ;;
        reco)
            run_reco
            ;;
        miniaod)
            run_miniaod
            ;;
        ntuple)
            run_ntuple
            ;;
        transfer)
            transfer_output
            ;;
    esac
done

# If mix was requested but output not found, fail early so tests surface the issue.
# Skip this check when cleanup removed intermediates (CLEANUP=true) or after transfer.
if [[ " ${SELECTED_STEPS[*]} " == *" mix "* ]] && [[ " ${SELECTED_STEPS[*]} " != *" transfer "* ]] && [[ "${CLEANUP}" != "true" ]]; then
    if [[ ! -f "${MIXED_HEPMC:-}" ]]; then
        msg_error "Expected mixed HepMC at ${MIXED_HEPMC:-<unset>} but not found"
        exit 1
    fi
fi

msg_step "Production Complete!"
echo "Campaign:  ${CAMPAIGN_NAME}"
echo "Job ID:    ${JOB_ID}"
echo "Output:    ${EOS_OUTPUT}/${CAMPAIGN_NAME}/${JOB_ID}/"
echo ""
