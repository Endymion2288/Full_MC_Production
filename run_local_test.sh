#!/bin/bash
# ==============================================================================
# run_local_test.sh - 本地 HTCondor 测试脚本
# ==============================================================================
# 使用本地 nd-29.hepthu.com HTCondor 集群进行小批量测试
# ==============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Default test settings
JOBS=1
MAX_EVENTS=5
CAMPAIGNS=("JJP_DPS2_CS" "JUP_DPS1")
SUBMIT=0
WAIT=0
ENABLE_NTUPLE=0
OUTPUT_DIR="${BASE_DIR}/tests/generated/local_test_$(date +%Y%m%d_%H%M%S)"

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

# Parse arguments
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
        --output-dir)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        -h|--help)
            cat << EOF
Usage: $0 [options]

Options:
  --jobs N              Jobs per campaign (default: 1)
  --max-events N        Max events per job (default: 5)
  --campaign NAME        Campaign to test (default: JJP_DPS2_CS JUP_DPS1)
  --submit              Submit to HTCondor
  --wait               Wait for DAG to complete
  --enable-ntuple      Enable ntuple production (default: false)
  --output-dir DIR       Output directory for DAG and bundles

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

msg_info "本地 HTCondor 测试配置"
msg_info "Campaigns: ${CAMPAIGNS[*]}"
msg_info "Jobs per campaign: ${JOBS}"
msg_info "Max events: ${MAX_EVENTS}"
msg_info "Enable ntuple: ${ENABLE_NTUPLE}"
msg_info "Output directory: ${OUTPUT_DIR}"

# Check proxy
msg_info "检查 VOMS 代理..."
if ! ./check_proxy.sh --status > /dev/null 2>&1; then
    msg_error "代理检查失败，请运行: ./check_proxy.sh --init"
    exit 1
fi
msg_ok "代理检查通过"

# Check packages
msg_info "检查必需的包..."
REQUIRED_PACKAGES=("common/packages/helac_package.tar.gz")
if [[ ${ENABLE_NTUPLE} -eq 1 ]]; then
    REQUIRED_PACKAGES+=("common/packages/jjp_code.tar.gz" "common/packages/jup_code.tar.gz")
fi

for pkg in "${REQUIRED_PACKAGES[@]}"; do
    if [[ ! -f "${BASE_DIR}/${pkg}" ]]; then
        msg_error "缺少必需的包: ${pkg}"
        exit 1
    fi
    msg_ok "找到: ${pkg}"
done

# Create local log directory
LOCAL_LOG_DIR="${OUTPUT_DIR}/log"
mkdir -p "${LOCAL_LOG_DIR}"

# Build command arguments
CMD=(
    python3 dag_generator.py generate-test
    --output-dir "${OUTPUT_DIR}"
    --output "local_test.dag"
    --jobs "${JOBS}"
    --max-events "${MAX_EVENTS}"
    --no-scan-existing
)

if [[ ${ENABLE_NTUPLE} -eq 1 ]]; then
    CMD+=(--enable-ntuple)
else
    CMD+=(--disable-ntuple)
fi

for campaign in "${CAMPAIGNS[@]}"; do
    CMD+=(--campaign "${campaign}")
done

# Generate DAG
msg_info "生成 DAG..."
"${CMD[@]}"

if [[ ! -f "${OUTPUT_DIR}/local_test.dag" ]]; then
    msg_error "DAG 生成失败"
    exit 1
fi
msg_ok "DAG 生成成功: ${OUTPUT_DIR}/local_test.dag"

# Submit if requested
if [[ ${SUBMIT} -eq 1 ]]; then
    msg_info "提交到本地 HTCondor 集群..."
    cd "${OUTPUT_DIR}"
    condor_submit_dag -maxjobs 200 local_test.dag

    if [[ ${WAIT} -eq 1 ]]; then
        msg_info "等待 DAG 完成..."
        condor_wait local_test.dag
        msg_ok "DAG 完成"
    fi
else
    msg_info "DAG 已生成但未提交。使用以下命令提交:"
    msg_info "  cd ${OUTPUT_DIR} && condor_submit_dag local_test.dag"
fi