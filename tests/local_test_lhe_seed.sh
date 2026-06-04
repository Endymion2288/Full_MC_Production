#!/bin/bash
# ==============================================================================
# local_test_lhe_seed.sh - 本地并行测试 LHE seed 修复 (不用 HTCondor)
# ==============================================================================
# 用法:
#   ./local_test_lhe_seed.sh [N_seeds] [N_events] [N_proc_jobs]
#
#   默认: 5 seeds, 10 events, 0 proc jobs (只测LHE)
#   ./local_test_lhe_seed.sh 10          → 10 seeds, LHE only
#   ./local_test_lhe_seed.sh 5 20 2      → 5 seeds, 20 events, 2 full-chain jobs
# ==============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
LHE_DIR="${BASE_DIR}/lhe_generation"
COMMON_DIR="${BASE_DIR}/common"
PROCESSING_DIR="${BASE_DIR}/processing"

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
TEST_ROOT="/home/storage29/users/xingcheng/MC_Production_result/test_local_${TIMESTAMP}"
WORKDIR="${TEST_ROOT}/work"
LHE_OUT="${TEST_ROOT}/lhe_pools"
OUTPUT_BASE="${TEST_ROOT}/output"
LOGDIR="${TEST_ROOT}/logs"

NUM_SEEDS=${1:-5}
EVENTS=${2:-10}
PROC_JOBS=${3:-0}

export LOCAL_OUTPUT_BASE="${TEST_ROOT}"

source /cvmfs/cms.cern.ch/cmsset_default.sh 2>/dev/null || true

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
_ok()  { echo -e "${GREEN}[OK]${NC}   $(date +%H:%M:%S) $*"; }
_err() { echo -e "${RED}[ERR]${NC}  $(date +%H:%M:%S) $*"; }
_log() { echo -e "[LOG]  $(date +%H:%M:%S) $*"; }

echo ""
echo "══════════════════════════════════════════════════════════"
echo "  Local LHE Seed Test"
echo "  Seeds: ${NUM_SEEDS}   Events: ${EVENTS}   Proc jobs: ${PROC_JOBS}"
echo "  Root:  ${TEST_ROOT}"
echo "══════════════════════════════════════════════════════════"
echo ""

mkdir -p "${WORKDIR}" "${LOGDIR}" \
         "${LHE_OUT}/pool_jpsi_CSCO_g" "${LHE_OUT}/pool_upsilon_CSCO_g" \
         "${OUTPUT_BASE}/JUP_DPS2"

# =============================================================================
# Helper: generate one LHE file (runs in subprocess)
# =============================================================================
gen_one_lhe() {
    local seed=$1 pool=$2 outdir=$3
    local w="${WORKDIR}/lhe_${pool}_${seed}"
    local log="${LOGDIR}/lhe_${pool}_${seed}.log"
    local expected="${LOCAL_OUTPUT_BASE}/${outdir}/sample_${pool}_${seed}.lhe"

    if [[ -f "${expected}" ]] && [[ $(stat -c%s "${expected}" 2>/dev/null || echo 0) -gt 2000 ]]; then
        echo "  [${pool}/seed=${seed}] SKIP (already exists, $(stat -c%s "${expected}") bytes)"
        return 0
    fi

    echo "  [${pool}/seed=${seed}] START"
    rm -rf "${w}" && mkdir -p "${w}"

    (
        cd "${w}"
        cp "${BASE_DIR}/common/packages/helac_package.tar.gz" .
        cp -a "${LHE_DIR}/input_templates" . 2>/dev/null || true
        bash "${LHE_DIR}/run_helac.sh" \
            --pool "${pool}" --seed "${seed}" \
            --min-pt-conia 6.0 --min-pt-bonia 4.0 --min-pt-q 0.0 \
            --unwevt 100 --test-mode false --fast-test \
            --output-dir "${outdir}" \
            >> "${log}" 2>&1
    )
    local rc=$?
    if [[ $rc -eq 0 ]] && [[ -f "${expected}" ]]; then
        echo "  [${pool}/seed=${seed}] DONE ($(stat -c%s "${expected}") bytes)"
    else
        echo "  [${pool}/seed=${seed}] FAILED (rc=${rc})"
        tail -30 "${log}" 2>/dev/null | head -20
    fi
    return $rc
}

# =============================================================================
# Phase 1: Generate LHE for pool_jpsi_CSCO_g (CrystalBall pool - this was buggy)
# =============================================================================
echo "=== Phase 1: LHE generation for pool_jpsi_CSCO_g (${NUM_SEEDS} seeds) ==="
echo ""

LHE1_START=$(date +%s)
POOL_JPSI="pool_jpsi_CSCO_g"
OUT_JPSI="lhe_pools/${POOL_JPSI}"

pids=()
for s in $(seq 100 $((100 + NUM_SEEDS - 1))); do
    gen_one_lhe $s "${POOL_JPSI}" "${OUT_JPSI}" &
    pids+=($!)
done

_log "Launched ${#pids[@]} workers, waiting..."
for pid in "${pids[@]}"; do wait $pid || true; done
LHE1_END=$(date +%s)
_ok "pool_jpsi_CSCO_g done in $(( (LHE1_END-LHE1_START)/60 ))m $(( (LHE1_END-LHE1_START)%60 ))s"

# =============================================================================
# Phase 1b: Generate LHE for pool_upsilon_CSCO_g (also needed for JUP_DPS2)
# =============================================================================
echo ""
echo "=== Phase 1b: LHE generation for pool_upsilon_CSCO_g (${NUM_SEEDS} seeds) ==="
echo ""

LHE2_START=$(date +%s)
POOL_UPSI="pool_upsilon_CSCO_g"
OUT_UPSI="lhe_pools/${POOL_UPSI}"

pids=()
for s in $(seq 20100 $((20100 + NUM_SEEDS - 1))); do
    gen_one_lhe $s "${POOL_UPSI}" "${OUT_UPSI}" &
    pids+=($!)
done

for pid in "${pids[@]}"; do wait $pid || true; done
LHE2_END=$(date +%s)
_ok "pool_upsilon_CSCO_g done in $(( (LHE2_END-LHE2_START)/60 ))m $(( (LHE2_END-LHE2_START)%60 ))s"

# =============================================================================
# Phase 2: Verify LHE uniqueness
# =============================================================================
echo ""
echo "=== Phase 2: LHE Uniqueness Check ==="
echo ""

check_pool() {
    local pool=$1 dir=$2 label=$3
    echo "--- ${label} ---"

    local first_md5="" first_seed="" all_ok=1
    declare -A _m

    for f in "${dir}"/sample_${pool}_*.lhe; do
        [[ -f "$f" ]] || continue
        local s=$(basename "$f" .lhe | sed "s/sample_${pool}_//")
        local md5=$(md5sum "$f" | awk '{print $1}')
        local evts=$(grep -c "<event>" "$f" 2>/dev/null || echo 0)
        local sz=$(stat -c%s "$f")
        _m["$s"]="$md5"

        if [[ -z "$first_md5" ]]; then
            first_md5="$md5"; first_seed="$s"
        fi

        if [[ "$md5" == "$first_md5" ]] && [[ "$s" != "$first_seed" ]]; then
            _err "  seed=${s}  IDENTICAL to seed=${first_seed}  md5=${md5:0:20}..."
            all_ok=0
        else
            _ok "  seed=${s}  events=${evts}  size=${sz}  md5=${md5:0:20}..."
        fi
    done

    local uniq=$(printf '%s\n' "${_m[@]}" | sort -u | wc -l)
    local total=${#_m[@]}
    echo ""
    if [[ $uniq -eq $total ]]; then
        _ok "${label}: ALL ${total}/${total} files UNIQUE"
    else
        _err "${label}: BUG! Only ${uniq}/${total} unique files"
    fi
    echo ""
    return $all_ok
}

check_pool "pool_jpsi_CSCO_g" "${LHE_OUT}/pool_jpsi_CSCO_g" "pool_jpsi_CSCO_g"
check_pool "pool_upsilon_CSCO_g" "${LHE_OUT}/pool_upsilon_CSCO_g" "pool_upsilon_CSCO_g"

# =============================================================================
# Phase 3: Processing chain (shower+mix) for JUP_DPS2
# =============================================================================
if [[ $PROC_JOBS -gt 0 ]]; then
    echo "=== Phase 3: Shower+Mix for ${PROC_JOBS} JUP_DPS2 jobs ==="
    echo ""

    proc_job() {
        local j=$1
        local sj=$((100 + j)) su=$((20100 + j))
        local w="${WORKDIR}/proc_${j}"
        local out="${OUTPUT_BASE}/JUP_DPS2/${j}"
        local log="${LOGDIR}/proc_${j}.log"
        mkdir -p "${w}" "${out}"

        (
            cd "${w}"
            mkdir -p runtime/processing runtime/common

            # Minimal runtime from source
            cp -a "${PROCESSING_DIR}/run_chain.sh" runtime/processing/
            cp -a "${PROCESSING_DIR}/pythia_shower" runtime/processing/
            cp -a "${COMMON_DIR}/octet_pdg.py" runtime/common/
            cp -a "${COMMON_DIR}/cmssw_configs" runtime/common/ 2>/dev/null || true

            # Symlink/copy LHE files
            cp "${LHE_OUT}/pool_jpsi_CSCO_g/sample_pool_jpsi_CSCO_g_${sj}.lhe" input0.lhe
            cp "${LHE_OUT}/pool_upsilon_CSCO_g/sample_pool_upsilon_CSCO_g_${su}.lhe" input1.lhe

            cd runtime/processing
            bash run_chain.sh \
                --inputs "file:${w}/input0.lhe,file:${w}/input1.lhe" \
                --modes "normal,phi_mpi_off" \
                --analysis JUP --campaign JUP_DPS2 --job-id "${j}" \
                --max-events "${EVENTS}" --enable-ntuple false --cleanup false \
                --skip-to shower --stop-at mix \
                --step-input "" --step-output-dir "${out}" \
                >> "${log}" 2>&1 || true

            if [[ -f "${out}/mixed.hepmc" ]]; then
                local md5=$(md5sum "${out}/mixed.hepmc" | awk '{print $1}')
                _ok "  job=${j}  mixed.hepmc  md5=${md5:0:20}...  $(stat -c%s "${out}/mixed.hepmc") bytes"
            else
                _log "  job=${j}  mixed.hepmc not found (check ${log})"
            fi
        )
    }

    for ((j=0; j<PROC_JOBS; j++)); do
        proc_job $j &
    done
    wait
    _ok "Processing chain done"
fi

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "══════════════════════════════════════════════════════════"
echo "  Test Complete"
echo "  Results: ${TEST_ROOT}"
echo "  LHE files:  ls ${LHE_OUT}/pool_jpsi_CSCO_g/"
echo "  Output:     ls ${OUTPUT_BASE}/JUP_DPS2/"
echo "  Logs:       ls ${LOGDIR}/"
echo "══════════════════════════════════════════════════════════"
