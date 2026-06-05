#!/bin/bash
# ==============================================================================
# local_full_chain_test.sh - 本地完整 pipeline 测试（重用已有 LHE）
# ==============================================================================
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
PROCESSING_DIR="${BASE_DIR}/processing"
COMMON_DIR="${BASE_DIR}/common"

LHE_BASE="/home/storage29/users/xingcheng/MC_Production_result/test_local_20260605_020105/lhe_pools"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
TEST_ROOT="/home/storage29/users/xingcheng/MC_Production_result/test_fullchain_${TIMESTAMP}"
OUTPUT_BASE="${TEST_ROOT}/output"
LOGDIR="${TEST_ROOT}/logs"

NUM_JOBS=${1:-2}
MAX_EVENTS=${2:-10}
ENABLE_NTUPLE=${3:-1}  # default: enable ntuple

export LOCAL_OUTPUT_BASE="${TEST_ROOT}"
source /cvmfs/cms.cern.ch/cmsset_default.sh 2>/dev/null || true

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
_ok()  { echo -e "${GREEN}[OK]${NC}   $(date +%H:%M:%S) $*"; }
_err() { echo -e "${RED}[ERR]${NC}  $(date +%H:%M:%S) $*"; }
_log() { echo -e "[LOG]  $(date +%H:%M:%S) $*"; }

mkdir -p "${OUTPUT_BASE}/JUP_DPS2" "${LOGDIR}" "${TEST_ROOT}/work"

echo ""
echo "══════════════════════════════════════════════════════════"
echo "  Full Chain Test (reusing LHE from local test)"
echo "  Jobs: ${NUM_JOBS}  Events: ${MAX_EVENTS}  Ntuple: ${ENABLE_NTUPLE}"
echo "══════════════════════════════════════════════════════════"
echo ""

# =============================================================================
# Run full chain for one job
# =============================================================================
run_job() {
    local j=$1
    local sj=$((100 + j)) su=$((20100 + j))
    local w="${TEST_ROOT}/work/job_${j}"
    local out="${OUTPUT_BASE}/JUP_DPS2/${j}"
    local log="${LOGDIR}/job_${j}.log"
    local jpsi_lhe="${LHE_BASE}/pool_jpsi_CSCO_g/sample_pool_jpsi_CSCO_g_${sj}.lhe"
    local upsi_lhe="${LHE_BASE}/pool_upsilon_CSCO_g/sample_pool_upsilon_CSCO_g_${su}.lhe"

    rm -rf "${w}" && mkdir -p "${w}" "${out}"

    _log "Job ${j}: seed_jpsi=${sj} seed_upsi=${su}"

    if [[ ! -f "${jpsi_lhe}" ]] || [[ ! -f "${upsi_lhe}" ]]; then
        _err "Job ${j}: LHE files missing!"
        return 1
    fi

    (
        cd "${w}"

        # Setup runtime from processing dir
        mkdir -p runtime/processing runtime/common runtime/lhe_generation
        cp -a "${PROCESSING_DIR}/run_chain.sh" runtime/processing/
        cp -a "${PROCESSING_DIR}/pythia_shower" runtime/processing/
        cp -a "${COMMON_DIR}/octet_pdg.py" runtime/common/
        cp -a "${COMMON_DIR}/cmssw_configs" runtime/common/ 2>/dev/null || true

        cp "${jpsi_lhe}" input0.lhe
        cp "${upsi_lhe}" input1.lhe

        local ntuple_flag="false"
        [[ ${ENABLE_NTUPLE} -eq 1 ]] && ntuple_flag="true"

        cd runtime/processing

        local t0=$(date +%s)

        bash run_chain.sh \
            --inputs "file:${w}/input0.lhe,file:${w}/input1.lhe" \
            --modes "normal,phi_mpi_off" \
            --analysis JUP --campaign JUP_DPS2 --job-id "${j}" \
            --max-events "${MAX_EVENTS}" \
            --enable-ntuple "${ntuple_flag}" \
            --cleanup false \
            --skip-to shower \
            --stop-at "" \
            --step-input "" --step-output-dir "${out}" \
            >> "${log}" 2>&1

        local rc=$?
        local t1=$(date +%s)
        local dt=$((t1 - t0))

        if [[ $rc -eq 0 ]]; then
            echo "--- Job ${j} output ---" >> "${log}"
            for f in mixed.hepmc GENSIM.root RAW.root RECO.root MINIAOD.root ntuple.root; do
                if [[ -f "${out}/${f}" ]]; then
                    local sz=$(stat -c%s "${out}/${f}" 2>/dev/null || echo 0)
                    local md5=$(md5sum "${out}/${f}" 2>/dev/null | awk '{print $1}')
                    echo "  ${f}: md5=${md5:0:20}... size=${sz}" >> "${log}"
                fi
            done
            _ok "Job ${j}: done in ${dt}s"
        else
            _err "Job ${j}: FAILED (rc=${rc}, ${dt}s)"
        fi
    )
}

# =============================================================================
# Run jobs sequentially (RAW step is heavy, parallel may overwhelm)
# =============================================================================
_log "Running ${NUM_JOBS} full-chain jobs sequentially..."

TOTAL_START=$(date +%s)
for ((j=0; j<NUM_JOBS; j++)); do
    run_job $j
done
TOTAL_END=$(date +%s)
_ok "All jobs done in $(( (TOTAL_END-TOTAL_START)/60 ))m $(( (TOTAL_END-TOTAL_START)%60 ))s"

# =============================================================================
# Compare outputs
# =============================================================================
echo ""
echo "=== Output Comparison ==="
echo ""

for f in mixed.hepmc GENSIM.root RAW.root RECO.root MINIAOD.root ntuple.root; do
    echo "--- ${f} ---"
    for ((j=0; j<NUM_JOBS; j++)); do
        local fp="${OUTPUT_BASE}/JUP_DPS2/${j}/${f}"
        if [[ -f "${fp}" ]]; then
            local sz=$(stat -c%s "${fp}" 2>/dev/null || echo 0)
            local md5=$(md5sum "${fp}" 2>/dev/null | awk '{print $1}')
            echo "  job=${j}: size=${sz}  md5=${md5:0:24}..."
        else
            echo "  job=${j}: NOT FOUND"
        fi
    done
    echo ""
done

echo "Results: ${TEST_ROOT}"
