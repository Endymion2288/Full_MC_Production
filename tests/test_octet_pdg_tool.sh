#!/bin/bash
# ==============================================================================
# test_octet_pdg_tool.sh - 八重态 PDG 映射规则自检
# ==============================================================================
# 用途：
# 1. 验证 HELAC 旧编码到 Pythia8 `99nqnsnrnLnJ` 编码的映射是否完整。
# 2. 覆盖 J/psi 与 Upsilon 的 3S1(8)、1S0(8)、3PJ(8) 三类八重态。
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TOOL="${BASE_DIR}/common/octet_pdg.py"

if [[ ! -f "${TOOL}" ]]; then
    echo "[ERROR] 找不到工具脚本: ${TOOL}" >&2
    exit 1
fi

check_case() {
    local raw="$1"
    local expected="$2"
    local actual=""

    actual=$(python3 "${TOOL}" convert-pdg "${raw}")
    if [[ "${actual}" != "${expected}" ]]; then
        echo "[ERROR] 映射错误: ${raw} -> ${actual}, 期望 ${expected}" >&2
        exit 1
    fi
    echo "[OK] ${raw} -> ${actual}"
}

check_case 9900443 9940003
check_case 9900441 9941003
check_case 9910441 9942003
check_case 9900553 9950003
check_case 9900551 9951003
check_case 9910551 9952003

echo "[INFO] 八重态 PDG 映射测试通过"
