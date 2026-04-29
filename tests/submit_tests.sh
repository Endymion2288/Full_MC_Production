#!/bin/bash
# ==============================================================================
# submit_tests.sh - 生成并提交 workbook_v2 小批量测试 DAG
# ==============================================================================
# 默认覆盖：
#   - JJP_DPS2_CS
#   - JJP_DPS2_G
#   - JUP_DPS1
# 验收口径：
#   - 代码保留全链路能力
#   - 本轮测试默认禁用 ntuple，实际跑到 MiniAOD 后 transfer
# ==============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
LOG_DIR="${SCRIPT_DIR}/log"

mkdir -p "${LOG_DIR}"

msg_info() { printf '[INFO] %s\n' "$1"; }
msg_warn() { printf '[WARN] %s\n' "$1"; }
msg_error() { printf '[ERROR] %s\n' "$1"; }

CAMPAIGNS=()
JOBS=1
MAX_EVENTS=5
OUTPUT_DIR=""
OUTPUT_NAME="mc_test.dag"
DO_SUBMIT=0
DO_WAIT=0
ENABLE_NTUPLE=0
FORCE_GENERATE=0
SCAN_EXISTING=1

while [[ $# -gt 0 ]]; do
    case "$1" in
        --campaign)
            CAMPAIGNS+=("$2")
            shift 2
            ;;
        --jobs)
            JOBS="$2"
            shift 2
            ;;
        --max-events)
            MAX_EVENTS="$2"
            shift 2
            ;;
        --output-dir)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --output)
            OUTPUT_NAME="$2"
            shift 2
            ;;
        --submit)
            DO_SUBMIT=1
            shift
            ;;
        --wait)
            DO_WAIT=1
            shift
            ;;
        --enable-ntuple)
            ENABLE_NTUPLE=1
            shift
            ;;
        --force-generate-lhe)
            FORCE_GENERATE=1
            shift
            ;;
        --no-scan-existing)
            SCAN_EXISTING=0
            shift
            ;;
        -h|--help)
            cat << EOF
用法: $0 [选项]

选项:
  --campaign NAME        可重复指定，默认 JJP_DPS2_CS、JJP_DPS2_G 和 JUP_DPS1
  --jobs N               每个 campaign 的测试 job 数，默认 1
  --max-events N         processing 节点 max-events，默认 5
  --output-dir DIR       DAG 输出目录，默认 tests/generated/<时间戳>
  --output NAME          DAG 文件名，默认 mc_test.dag
  --submit               生成后立即 condor_submit_dag
  --wait                 提交后调用 condor_wait 等待 DAGMan 结束
  --enable-ntuple        测试时也执行 ntuple
  --force-generate-lhe   不复用远端 pool，强制重生 LHE
  --no-scan-existing     不扫描远端已有 pool
EOF
            exit 0
            ;;
        *)
            msg_error "未知参数: $1"
            exit 1
            ;;
    esac
done

if [[ ${#CAMPAIGNS[@]} -eq 0 ]]; then
    CAMPAIGNS=("JJP_DPS2_CS" "JJP_DPS2_G" "JUP_DPS1")
fi

if [[ -z "${OUTPUT_DIR}" ]]; then
    OUTPUT_DIR="${BASE_DIR}/tests/generated/$(date +%Y%m%d_%H%M%S)"
fi

VALIDATE_CMD=(python3 "${BASE_DIR}/dag_generator.py" validate --campaign "$(IFS=,; echo "${CAMPAIGNS[*]}")")
if [[ ${SCAN_EXISTING} -eq 1 ]]; then
    VALIDATE_CMD+=(--scan-existing)
fi
msg_info "运行环境校验: ${VALIDATE_CMD[*]}"
"${VALIDATE_CMD[@]}"

GEN_CMD=(
    python3 "${BASE_DIR}/dag_generator.py" generate-test
    --output-dir "${OUTPUT_DIR}"
    --output "${OUTPUT_NAME}"
    --jobs "${JOBS}"
    --max-events "${MAX_EVENTS}"
)

for campaign in "${CAMPAIGNS[@]}"; do
    GEN_CMD+=(--campaign "${campaign}")
done

if [[ ${ENABLE_NTUPLE} -eq 1 ]]; then
    GEN_CMD+=(--enable-ntuple)
else
    GEN_CMD+=(--disable-ntuple)
fi

if [[ ${FORCE_GENERATE} -eq 1 ]]; then
    GEN_CMD+=(--force-generate-lhe)
fi

if [[ ${SCAN_EXISTING} -eq 0 ]]; then
    GEN_CMD+=(--no-scan-existing)
fi

msg_info "生成测试 DAG: ${GEN_CMD[*]}"
"${GEN_CMD[@]}"

DAG_PATH="${OUTPUT_DIR}/${OUTPUT_NAME}"
METADATA_PATH="${OUTPUT_DIR}/metadata.json"
msg_info "DAG 已生成: ${DAG_PATH}"
msg_info "元数据: ${METADATA_PATH}"

if [[ ${DO_SUBMIT} -eq 0 ]]; then
    msg_warn "当前为仅生成模式；如需真正提交，请加 --submit"
    exit 0
fi

SUBMIT_LOG="${LOG_DIR}/submit_$(date +%Y%m%d_%H%M%S).log"
msg_info "提交 DAG 到 HTCondor ..."
condor_submit_dag "${DAG_PATH}" | tee "${SUBMIT_LOG}"
msg_info "提交日志: ${SUBMIT_LOG}"

if [[ ${DO_WAIT} -eq 1 ]]; then
    if ! command -v condor_wait >/dev/null 2>&1; then
        msg_error "找不到 condor_wait，无法等待 DAG 完成"
        exit 1
    fi

    DAGMAN_LOG="${DAG_PATH}.dagman.log"
    if [[ ! -f "${DAGMAN_LOG}" ]]; then
        msg_warn "未找到 ${DAGMAN_LOG}，跳过等待"
        exit 0
    fi

    msg_info "等待 DAG 结束: ${DAGMAN_LOG}"
    condor_wait "${DAGMAN_LOG}"
fi
