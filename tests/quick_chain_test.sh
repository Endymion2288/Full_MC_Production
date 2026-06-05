#!/bin/bash
# Quick shower→mix→gensim chain test using existing LHE files
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
PROCESSING_DIR="${BASE_DIR}/processing"
COMMON_DIR="${BASE_DIR}/common"

LHE_BASE="/home/storage29/users/xingcheng/MC_Production_result/test_local_20260605_020105/lhe_pools"
TSTAMP=$(date +%Y%m%d_%H%M%S)
OUT="/home/storage29/users/xingcheng/MC_Production_result/test_quickchain_${TSTAMP}"
LOG="${OUT}/log"
mkdir -p "${OUT}/out0" "${OUT}/out1" "${OUT}/w0" "${OUT}/w1" "${LOG}"

export LOCAL_OUTPUT_BASE="${OUT}"
source /cvmfs/cms.cern.ch/cmsset_default.sh 2>/dev/null || true

run_one() {
    local j=$1 seed_j=$2 seed_u=$3 w="${OUT}/w${j}" o="${OUT}/out${j}"
    mkdir -p runtime/processing runtime/common
    cp -a "${PROCESSING_DIR}/run_chain.sh" runtime/processing/
    cp -a "${PROCESSING_DIR}/pythia_shower" runtime/processing/
    cp -a "${COMMON_DIR}/octet_pdg.py" runtime/common/
    cp -a "${COMMON_DIR}/cmssw_configs" runtime/common/ 2>/dev/null || true
    cp "${LHE_BASE}/pool_jpsi_CSCO_g/sample_pool_jpsi_CSCO_g_${seed_j}.lhe" "${w}/input0.lhe"
    cp "${LHE_BASE}/pool_upsilon_CSCO_g/sample_pool_upsilon_CSCO_g_${seed_u}.lhe" "${w}/input1.lhe"
    cd runtime/processing
    bash run_chain.sh \
        --inputs "file:${w}/input0.lhe,file:${w}/input1.lhe" \
        --modes "normal,phi_mpi_off" --analysis JUP --campaign JUP_DPS2 --job-id "${j}" \
        --max-events 10 --enable-ntuple false --cleanup false \
        --skip-to shower --stop-at gensim --step-input "" --step-output-dir "${o}" \
        > "${LOG}/job${j}.log" 2>&1
    echo "Job ${j}: rc=$?"
    for f in mixed.hepmc GENSIM.root; do
        [[ -f "${o}/${f}" ]] && echo "  ${f}: $(md5sum "${o}/${f}" | cut -c1-24)  $(stat -c%s "${o}/${f}") bytes"
    done
}

echo "=== Quick Chain Test: seed_jpsi=(100,101) seed_upsi=(20100,20101) ==="
echo "Step: shower → mix → gensim (no RAW, skip premix pileup)"
echo ""

T0=$(date +%s)

cd "${OUT}/w0" && run_one 0 100 20100 &
cd "${OUT}/w1" && run_one 1 101 20101 &
wait

T1=$(date +%s)
echo ""
echo "=== Comparison ==="
for f in mixed.hepmc GENSIM.root; do
    echo "--- ${f} ---"
    for j in 0 1; do
        fp="${OUT}/out${j}/${f}"
        [[ -f "${fp}" ]] && echo "job=${j}: md5=$(md5sum "${fp}"|cut -c1-24) $(stat -c%s "${fp}")b" || echo "job=${j}: MISSING"
    done
    echo ""
done

echo "Total: $(( (T1-T0)/60 ))m $(( (T1-T0)%60 ))s"
echo "Output: ${OUT}"
