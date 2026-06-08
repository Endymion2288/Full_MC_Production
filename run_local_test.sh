#!/bin/bash
# ==============================================================================
# run_local_test.sh - Generate and optionally submit a local HTCondor smoke DAG.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="${SCRIPT_DIR}"

JOBS=1
MAX_EVENTS=5
CAMPAIGNS=("JJP_DPS2_CS" "JUP_DPS1")
SUBMIT=0
WAIT=0
ENABLE_NTUPLE=0
OUTPUT_DIR="${BASE_DIR}/tests/generated/local_test_$(date +%Y%m%d_%H%M%S)"
LOCAL_OUTPUT_BASE=""

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

msg_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
msg_ok() { echo -e "${GREEN}[OK]${NC} $1"; }
msg_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
msg_error() { echo -e "${RED}[ERROR]${NC} $1"; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --jobs)
            JOBS="$2"
            shift 2
            ;;
        --max-events)
            MAX_EVENTS="$2"
            shift 2
            ;;
        --campaign)
            CAMPAIGNS=("$2")
            shift 2
            ;;
        --submit)
            SUBMIT=1
            shift
            ;;
        --wait)
            WAIT=1
            shift
            ;;
        --enable-ntuple)
            ENABLE_NTUPLE=1
            shift
            ;;
        --disable-ntuple)
            ENABLE_NTUPLE=0
            shift
            ;;
        --output-dir)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --local-output-base)
            LOCAL_OUTPUT_BASE="$2"
            shift 2
            ;;
        -h|--help)
            cat <<EOF
Usage: $0 [options]

Options:
  --jobs N                  Jobs per campaign (default: 1)
  --max-events N            Max events per job (default: 5)
  --campaign NAME           Campaign to test (default: JJP_DPS2_CS JUP_DPS1)
  --submit                  Submit to HTCondor
  --wait                    Wait for DAG completion after submit
  --enable-ntuple           Enable ntuple production
  --disable-ntuple          Disable ntuple production (default)
  --output-dir DIR          Output directory for DAG and bundles
  --local-output-base DIR   Local storage base (default: OUTPUT_DIR/output)

Examples:
  $0 --submit --wait
  $0 --campaign JJP_DPS1 --jobs 2 --max-events 10
  $0 --submit --enable-ntuple
EOF
            exit 0
            ;;
        *)
            msg_error "Unknown option: $1"
            exit 1
            ;;
    esac
done

if [[ "${OUTPUT_DIR}" != /* ]]; then
    OUTPUT_DIR="${BASE_DIR}/${OUTPUT_DIR}"
fi
if [[ -n "${LOCAL_OUTPUT_BASE}" && "${LOCAL_OUTPUT_BASE}" != /* ]]; then
    LOCAL_OUTPUT_BASE="${BASE_DIR}/${LOCAL_OUTPUT_BASE}"
fi
if [[ -z "${LOCAL_OUTPUT_BASE}" ]]; then
    LOCAL_OUTPUT_BASE="${OUTPUT_DIR}/output"
fi

LOCAL_LOG_DIR="${OUTPUT_DIR}/log"

msg_info "Local HTCondor test configuration"
msg_info "Campaigns: ${CAMPAIGNS[*]}"
msg_info "Jobs per campaign: ${JOBS}"
msg_info "Max events: ${MAX_EVENTS}"
msg_info "Enable ntuple: ${ENABLE_NTUPLE}"
msg_info "Output directory: ${OUTPUT_DIR}"
msg_info "Local output base: ${LOCAL_OUTPUT_BASE}"

msg_info "Checking VOMS proxy..."
if ! command -v voms-proxy-info >/dev/null 2>&1; then
    msg_error "voms-proxy-info is not available; initialize a valid VOMS proxy first."
    exit 1
fi
if ! voms-proxy-info --exists >/dev/null 2>&1; then
    msg_error "No valid VOMS proxy found; run voms-proxy-init before submitting."
    exit 1
fi
msg_ok "VOMS proxy is available"

msg_info "Checking required runtime packages..."
REQUIRED_PACKAGES=("common/packages/helac_package.tar.gz")
if [[ ${ENABLE_NTUPLE} -eq 1 ]]; then
    if [[ ! -f "${BASE_DIR}/common/packages/cmssw15_tpsonia2mumu_runtime.tar.gz" \
        && ! -d "${BASE_DIR}/external/TPS-Onia2MuMu" ]]; then
        msg_error "Missing ntuple runtime tarball and TPS-Onia2MuMu source fallback."
        exit 1
    fi
fi

for pkg in "${REQUIRED_PACKAGES[@]}"; do
    if [[ ! -f "${BASE_DIR}/${pkg}" ]]; then
        msg_error "Missing required package: ${pkg}"
        exit 1
    fi
    msg_ok "Found: ${pkg}"
done

mkdir -p "${LOCAL_LOG_DIR}" "${LOCAL_OUTPUT_BASE}"

CMD=(
    python3 "${BASE_DIR}/dag_generator.py" generate-test
    --machine-env hepthu
    --output-dir "${OUTPUT_DIR}"
    --output "local_test.dag"
    --jobs "${JOBS}"
    --max-events "${MAX_EVENTS}"
    --no-scan-existing
    --local-log-dir "${LOCAL_LOG_DIR}"
    --local-output-base "${LOCAL_OUTPUT_BASE}"
)

if [[ ${ENABLE_NTUPLE} -eq 1 ]]; then
    CMD+=(--enable-ntuple)
else
    CMD+=(--disable-ntuple)
fi

for campaign in "${CAMPAIGNS[@]}"; do
    CMD+=(--campaign "${campaign}")
done

msg_info "Generating DAG..."
"${CMD[@]}"

if [[ ! -f "${OUTPUT_DIR}/local_test.dag" ]]; then
    msg_error "DAG generation failed"
    exit 1
fi
msg_ok "DAG generated: ${OUTPUT_DIR}/local_test.dag"

if [[ ${SUBMIT} -eq 1 ]]; then
    msg_info "Submitting to local HTCondor..."
    cd "${OUTPUT_DIR}"
    condor_submit_dag -maxjobs 200 local_test.dag

    if [[ ${WAIT} -eq 1 ]]; then
        msg_info "Waiting for DAG completion..."
        condor_wait local_test.dag.dagman.log
        msg_ok "DAG completed"
    fi
else
    msg_info "DAG generated but not submitted. Submit with:"
    msg_info "  cd ${OUTPUT_DIR} && condor_submit_dag local_test.dag"
fi
