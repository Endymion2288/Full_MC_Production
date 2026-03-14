#!/bin/bash
# ==============================================================================
# run_helac.sh - HELAC-Onia LHE 生成脚本
# ==============================================================================
# 主要约束：
# 1. 运行于 HTCondor worker 节点，依赖打包传入的 helac_package.tar.gz。
# 2. 物理配置以 workbook_v2.md 为准，默认使用更新后的 LDME 参数。
# 3. 支持 test-mode，把积分与非加权事件数压到小批量验证可接受的范围。
# ==============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
OCTET_PDG_TOOL="${BASE_DIR}/common/octet_pdg.py"

# Default values
POOL_NAME=""
MY_SEED=100
PROCESS_STRING=""
MIN_PT_CONIA=6.0
MIN_PT_BONIA=4.0
MIN_PT_Q=4.0
WORKDIR=$(pwd)
OUTPUT_DIR=""
# Integration and event-generation controls (can be overridden for fast tests)
# PREUNW=3000000
# UNWEVT=1000000000
# NMC=200000000
# NOPT=20000000
# NOPT_STEP=20000000
# NOPT_LIM=200000000
PREUNW=300000
UNWEVT=10000000
NMC=2000000
NOPT=2000000
NOPT_STEP=2000000
NOPT_LIM=20000000
FAST_TEST=0
TEST_MODE="false"
# Build locations (populated after unpacking helac_package.tar.gz)
HEPMC_SRC_TGZ=""
HELAC_SRC_TAR=""
HEPMC_PREFIX="${WORKDIR}/HepMC/HepMC-2.06.11"

# T2_CN_Beijing XRootD storage paths
EOS_HOST="cceos.ihep.ac.cn"
EOS_XRDFS_TARGET="root://${EOS_HOST}"
EOS_PATH_BASE="/eos/ihep/cms/store/user/xcheng/MC_Production_v2"

# ----------------------------------------------------------------------------
# Helper functions
# ----------------------------------------------------------------------------

setup_build_env() {
    # Minimal environment for building HepMC/HELAC inside the worker node
    if ! command -v python >/dev/null 2>&1; then
        if command -v python3 >/dev/null 2>&1; then
            mkdir -p "${WORKDIR}/.local/bin"
            cat > "${WORKDIR}/.local/bin/python" << 'PYWRAP'
#!/bin/bash
exec python3 "$@"
PYWRAP
            chmod +x "${WORKDIR}/.local/bin/python"
            export PATH="${WORKDIR}/.local/bin:$PATH"
        elif [ -x "/cvmfs/sft.cern.ch/lcg/releases/Python/2.7.13-597a5/x86_64-centos7-gcc62-opt/bin/python" ]; then
            export PATH="/cvmfs/sft.cern.ch/lcg/releases/Python/2.7.13-597a5/x86_64-centos7-gcc62-opt/bin:$PATH"
        fi
    fi
    source /cvmfs/cms.cern.ch/cmsset_default.sh
    source /cvmfs/sft.cern.ch/lcg/views/LCG_88b/x86_64-centos7-gcc62-opt/setup.sh
    export LD_LIBRARY_PATH=/cvmfs/sft.cern.ch/lcg/releases/LCG_88b/Boost/1.62.0/x86_64-centos7-gcc62-opt/lib:$LD_LIBRARY_PATH
    export LD_LIBRARY_PATH=/cvmfs/sft.cern.ch/lcg/contrib/gcc/6.2.0/x86_64-centos7-gcc62-opt/lib64:/opt/rh/gcc-toolset-12/root/usr/lib64:$LD_LIBRARY_PATH
    export LD_LIBRARY_PATH=/cvmfs/sft.cern.ch/lcg/releases/LCG_88b/Boost/1.62.0/x86_64-centos7-gcc62-opt/lib:$LD_LIBRARY_PATH
    export PATH=/cvmfs/sft.cern.ch/lcg/contrib/gcc/6.2.0/x86_64-centos7-gcc62-opt/bin:/opt/rh/gcc-toolset-12/root/usr/bin:$PATH
    # 某些 el7 worker 不提供 C.UTF-8 locale，统一退回 C，避免构建阶段刷屏警告。
    export LANG=${LANG:-C}
    export LC_ALL=${LC_ALL:-C}
    unset PYTHONHOME PYTHONPATH
}

ensure_hepmc() {
    if [ -d "${HEPMC_PREFIX}/install" ]; then
        echo "[INFO] Reusing existing HepMC build at ${HEPMC_PREFIX}"
        return 0
    fi

    if [ -z "${HEPMC_SRC_TGZ}" ] || [ ! -f "${HEPMC_SRC_TGZ}" ]; then
        echo "Error: HepMC source tarball not found"
        return 1
    fi

    echo "[INFO] Building HepMC from ${HEPMC_SRC_TGZ}..."
    mkdir -p "${WORKDIR}/HepMC"
    tar -xzf "${HEPMC_SRC_TGZ}" -C "${WORKDIR}/HepMC"
    cd "${HEPMC_PREFIX}"
    mkdir -p build install
    cd build
    "${HEPMC_PREFIX}/configure" --prefix="${HEPMC_PREFIX}/install" --with-momentum=GEV --with-length=MM
    make -j 2
    make check
    make install
    cd "${WORKDIR}"
}

ensure_helac() {
    if [ -d "${WORKDIR}/HELAC-Onia-2.7.6" ] && [ -x "${WORKDIR}/HELAC-Onia-2.7.6/ho_cluster" ]; then
        echo "[INFO] Reusing existing HELAC-Onia build"
        return 0
    fi

    if [ -z "${HELAC_SRC_TAR}" ] || [ ! -f "${HELAC_SRC_TAR}" ]; then
        echo "Error: HELAC-Onia source tarball not found"
        return 1
    fi

    echo "[INFO] Unpacking HELAC-Onia from ${HELAC_SRC_TAR}..."
    tar -xzf "${HELAC_SRC_TAR}" -C "${WORKDIR}"

    cd "${WORKDIR}/HELAC-Onia-2.7.6"

    # Keep HepMC optional on worker nodes (avoid linking HepMC2Plot)
    sed -i -r -e 's|^[[:space:]]*hepmc_path[[:space:]]*=.*|# hepmc_path is left unset for condor runs|' input/ho_configuration.txt

    # Fix heptoptagger interface to compile with newer gcc
    sed -i 's/HEPTopTagger::HEPTopTagger /HEPTopTagger /g' analysis/heptoptagger/heptoptagger_fjcore_interface.cc

    echo "[INFO] Configuring HELAC-Onia..."
    ./config
    cd "${WORKDIR}"
}

write_py8_onia_config() {
    local pool_name="$1"
    local output_file="$2"

    case "$pool_name" in
        "pool_2jpsi"|"pool_2jpsi_cs"|"pool_2jpsi_g")
            cat > "${output_file}" << 'EOF'
2
443 443
EOF
            ;;
        "pool_jpsi_CSCO_g")
            cat > "${output_file}" << 'EOF'
1
443
EOF
            ;;
        "pool_upsilon_CSCO_g")
            cat > "${output_file}" << 'EOF'
1
553
EOF
            ;;
        "pool_jpsi_upsilon_CSCO")
            cat > "${output_file}" << 'EOF'
2
443 553
EOF
            ;;
        "pool_gg")
            cat > "${output_file}" << 'EOF'
0
EOF
            ;;
        *)
            return 1
            ;;
    esac
}

compiler_supports_flag() {
    local flag="$1"
    local test_src="${WORKDIR}/.gfortran_flag_check.f"
    local test_obj="${WORKDIR}/.gfortran_flag_check.o"

    cat > "${test_src}" << 'EOF'
      end
EOF

    if gfortran "${flag}" -c "${test_src}" -o "${test_obj}" >/dev/null 2>&1; then
        rm -f "${test_src}" "${test_obj}"
        return 0
    fi

    rm -f "${test_src}" "${test_obj}"
    return 1
}

build_lhe_converter_if_needed() {
    if [[ -x "${WORKDIR}/lhe_pythia6_pythia8" ]]; then
        return 0
    fi
    if [[ ! -f "${WORKDIR}/lhe_pythia6_pythia8.f" ]]; then
        return 1
    fi

    local build_flags=("-O2")
    if compiler_supports_flag "-fallow-argument-mismatch"; then
        build_flags+=("-fallow-argument-mismatch")
    else
        echo "[WARN] 当前 gfortran 不支持 -fallow-argument-mismatch，改用兼容编译参数"
    fi

    echo "[INFO] Building lhe_pythia6_pythia8 converter..."
    gfortran "${build_flags[@]}" -o "${WORKDIR}/lhe_pythia6_pythia8" "${WORKDIR}/lhe_pythia6_pythia8.f"
}

verify_lhe_octet_codes() {
    local lhe_file="$1"
    if [[ ! -f "${lhe_file}" ]]; then
        echo "[ERROR] LHE file not found for octet verification: ${lhe_file}"
        return 1
    fi
    if [[ ! -f "${OCTET_PDG_TOOL}" ]]; then
        echo "[ERROR] Octet PDG tool not found: ${OCTET_PDG_TOOL}"
        return 1
    fi

    PYTHONIOENCODING=UTF-8 python3 "${OCTET_PDG_TOOL}" scan "${lhe_file}" --fail-on-legacy
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --pool)
            POOL_NAME="$2"
            shift 2
            ;;
        --seed|-s)
            MY_SEED="$2"
            shift 2
            ;;
        --process)
            PROCESS_STRING="$2"
            shift 2
            ;;
        --min-pt-conia)
            MIN_PT_CONIA="$2"
            shift 2
            ;;
        --min-pt-bonia)
            MIN_PT_BONIA="$2"
            shift 2
            ;;
        --min-pt-q)
            MIN_PT_Q="$2"
            shift 2
            ;;
        --output-dir)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --unwevt)
            UNWEVT="$2"
            shift 2
            ;;
        --fast-test)
            FAST_TEST=1
            shift 1
            ;;
        --test-mode)
            TEST_MODE="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Validate required arguments
if [ -z "$POOL_NAME" ]; then
    echo "Error: --pool is required"
    exit 1
fi

# Set default process string based on pool name if not specified
if [ -z "$PROCESS_STRING" ]; then
    case "$POOL_NAME" in
        # =====================================================================
        # CSCO Pools (Color Singlet + Color Octet combined using define)
        # These are the PRIMARY pools recommended by workbook.md
        # =====================================================================
        "pool_jpsi_CSCO_g")
            # J/psi (CS+CO) + g using define syntax
            PROCESS_STRING="define jpsi_all = cc~(3S11) cc~(3S18) cc~(1S08) cc~(3PJ8)
generate g g > jpsi_all g"
            ;;
        "pool_upsilon_CSCO_g")
            # Upsilon (CS+CO) + g using define syntax
            PROCESS_STRING="define upsilon_all = bb~(3S11) bb~(3S18) bb~(1S08) bb~(3PJ8)
generate g g > upsilon_all g"
            ;;
        "pool_jpsi_upsilon_CSCO")
            # J/psi + Upsilon (CS only for now, as per workbook)
            PROCESS_STRING="generate g g > jpsi y(1s)"
            ;;
            
        # =====================================================================
        # Basic Single/Double Onia Pools (Color Singlet only)
        # =====================================================================
        "pool_gg")
            PROCESS_STRING="generate g g > g g"
            ;;
        "pool_2jpsi"|"pool_2jpsi_cs")
            PROCESS_STRING="generate g g > cc~(3S11) cc~(3S11)"
            ;;
        "pool_2jpsi_g")
            PROCESS_STRING="generate g g > cc~(3S11) cc~(3S11) g"
            ;;
            
        *)
            echo "Error: Unknown pool name and no process string specified"
            echo "Available pools (CSCO - recommended):"
            echo "  - pool_jpsi_CSCO_g, pool_upsilon_CSCO_g, pool_jpsi_upsilon_CSCO"
            echo "Available pools (basic):"
            echo "  - pool_gg, pool_2jpsi, pool_2jpsi_cs, pool_2jpsi_g"
            exit 1
            ;;
    esac
fi

# Set default output directory (XRootD path for T2_CN_Beijing)
if [ -z "$OUTPUT_DIR" ]; then
    OUTPUT_DIR="lhe_pools/${POOL_NAME}"
fi

# Validate seed
if ! [[ "$MY_SEED" =~ ^[0-9]+$ ]]; then
    echo "Error: Seed must be a valid integer"
    exit 1
fi

if [ "$MY_SEED" -le 10 ] || [ "$MY_SEED" -ge 100000 ]; then
    echo "Error: Seed must be between 11 and 99999"
    exit 1
fi

# Apply fast-test presets (drastically fewer integration/event counts)
if [ "$TEST_MODE" = "true" ]; then
    FAST_TEST=1
fi

if [ "$FAST_TEST" -eq 1 ]; then
    PREUNW=3000
    UNWEVT=100
    NMC=20000
    NOPT=2000
    NOPT_STEP=2000
    NOPT_LIM=20000
fi

# Validate unweighted event target
if ! [[ "$UNWEVT" =~ ^[0-9]+$ ]] || [ "$UNWEVT" -le 0 ]; then
    echo "Error: --unwevt must be a positive integer"
    exit 1
fi

echo "=============================================="
echo "HELAC-Onia LHE Generation"
echo "=============================================="
echo "Pool:           $POOL_NAME"
echo "Process:        $PROCESS_STRING"
echo "Seed:           $MY_SEED"
echo "Min pT (conia): $MIN_PT_CONIA GeV"
echo "Min pT (bonia): $MIN_PT_BONIA GeV"
echo "Min pT (q):     $MIN_PT_Q GeV"
echo "Unw. events:    $UNWEVT"
if [ "$FAST_TEST" -eq 1 ]; then
    echo "Mode:           FAST TEST (integration cuts reduced)"
fi
echo "Output dir:     $OUTPUT_DIR"
echo "=============================================="

# Check for HELAC package
if [ ! -f "helac_package.tar.gz" ]; then
    echo "Error: helac_package.tar.gz not found"
    exit 1
fi

# Prepare build environment and unpack archives
setup_build_env
echo "Unpacking helac_package.tar.gz..."
tar -xzf helac_package.tar.gz

# Locate source tarballs (either freshly unpacked or already present)
[ -f "${WORKDIR}/hepmc2.06.11.tgz" ] && HEPMC_SRC_TGZ="${WORKDIR}/hepmc2.06.11.tgz"
[ -f "${WORKDIR}/HELAC-Onia-2.7.6.tar.gz" ] && HELAC_SRC_TAR="${WORKDIR}/HELAC-Onia-2.7.6.tar.gz"

# Build dependencies from packaged sources
ensure_hepmc

# Setup HepMC paths after build
if [ -d "${HEPMC_PREFIX}/install" ]; then
    export PATH=${HEPMC_PREFIX}/install/bin:$PATH
    export LD_LIBRARY_PATH=${HEPMC_PREFIX}/install/lib:$LD_LIBRARY_PATH
fi

ensure_helac

# Enter HELAC directory
cd HELAC-Onia-2.7.6

# Create run configuration with LDME parameters
# LDME values from:
# - workbook_v2.md 中给出的 Helac-Onia 格式换算值
cat > run_config.ho << EOF
set cmass = 1.54845d0
set bmass = 4.73020d0
set LDMEcc1S08 = 0.0023125d0
set LDMEcc3S18 = 0.0003528845833333333d0
set LDMEcc3P08 = 0.0040024d0
set LDMEcc3P18 = 0.004002404166666667d0
set LDMEcc3P28 = 0.0040024d0
set LDMEcc3S11 = 0.06444444444444444d0
set LDMEbb1S08 = 0.000021266d0
set LDMEbb3S18 = 0.001239275d0
set LDMEbb3P08 = 0.10807425d0
set LDMEbb3P18 = 0.1080741666666667d0
set LDMEbb3P28 = 0.10807425d0
set LDMEbb3S11 = 0.5155555555555555d0
set preunw = ${PREUNW}
set unwevt = ${UNWEVT}
set nmc = ${NMC}
set nopt = ${NOPT}
set nopt_step = ${NOPT_STEP}
set noptlim = ${NOPT_LIM}
set seed = ${MY_SEED}
set minptconia = ${MIN_PT_CONIA}d0
set minptbonia = ${MIN_PT_BONIA}d0
set maxrapconia = 2.4
set minptq = ${MIN_PT_Q}
set ranhel = 4
${PROCESS_STRING}
launch
exit
EOF

# Copy user.inp if exists
if [ -f "../input_templates/user.inp" ]; then
    cp ../input_templates/user.inp input/user.inp
fi

echo "Running HELAC-Onia..."
./ho_cluster < run_config.ho | tee ../helac_run.log

# Find output LHE file
RUN_DIR=$(grep "INFO: Results are collected in" ../helac_run.log | \
          sed -r -e "s,^.*(PROC_HO_[0-9]+)\/.*$,\1,g" | head -1)

if [ -z "$RUN_DIR" ]; then
    echo "Error: Could not find run directory in log"
    exit 1
fi

# Find the LHE file from the latest run directory
if [[ -n "${RUN_DIR}" ]] && [[ -d "${RUN_DIR}/results" ]]; then
    RAW_LHE_FILE=$(find "${RUN_DIR}/results" -name "*.lhe" -type f ! -name "*_py8.lhe" | head -1)
    PY8_LHE_FILE=$(find "${RUN_DIR}/results" -name "*_py8.lhe" -type f | head -1)
else
    RAW_LHE_FILE=$(find . -path "./PROC_HO_*/results/*.lhe" -type f ! -name "*_py8.lhe" | sort | tail -1)
    PY8_LHE_FILE=$(find . -path "./PROC_HO_*/results/*_py8.lhe" -type f | sort | tail -1)
fi

if [[ -n "${RAW_LHE_FILE}" && -f "${RAW_LHE_FILE}" ]]; then
    LHE_FILE="${RAW_LHE_FILE}"
elif [[ -n "${PY8_LHE_FILE}" && -f "${PY8_LHE_FILE}" ]]; then
    LHE_FILE="${PY8_LHE_FILE}"
else
    echo "Error: LHE file not found"
    exit 1
fi

echo "Found LHE file: $LHE_FILE"

# workbook_v2 要求在 LHE 生成后单独调用 converter 完成 PDG 转换。
FINAL_LHE_FILE="${LHE_FILE}"
PY8_ONIA_CONFIG="${WORKDIR}/py8_onia_user.inp"
CONVERTED_LHE_FILE="${WORKDIR}/sample_${POOL_NAME}_${MY_SEED}_converted.lhe"

if write_py8_onia_config "${POOL_NAME}" "${PY8_ONIA_CONFIG}" && build_lhe_converter_if_needed; then
    echo "[INFO] Running lhe_pythia6_pythia8 converter..."
    if "${WORKDIR}/lhe_pythia6_pythia8" "${LHE_FILE}" "${PY8_ONIA_CONFIG}" "${CONVERTED_LHE_FILE}"; then
        if [[ -f "${CONVERTED_LHE_FILE}" ]]; then
            FINAL_LHE_FILE="${CONVERTED_LHE_FILE}"
            echo "[INFO] Converted LHE ready: ${FINAL_LHE_FILE}"
        fi
    else
        echo "[WARN] LHE converter failed, fallback to original LHE"
    fi
elif [[ -n "${PY8_LHE_FILE}" && -f "${PY8_LHE_FILE}" ]]; then
    FINAL_LHE_FILE="${PY8_LHE_FILE}"
    echo "[INFO] Reusing HELAC generated *_py8.lhe: ${FINAL_LHE_FILE}"
else
    echo "[WARN] No standalone converter available, fallback to original LHE"
fi

if [[ -f "${OCTET_PDG_TOOL}" ]] && grep -q "\<9900" "${FINAL_LHE_FILE}"; then
    echo "[INFO] Standalone converter 后仍检测到旧编码，使用统一工具补做转换..."
    PYTHONIOENCODING=UTF-8 python3 "${OCTET_PDG_TOOL}" convert-file "${FINAL_LHE_FILE}" --in-place >/dev/null
fi

verify_lhe_octet_codes "${FINAL_LHE_FILE}"

# Create remote directory and copy to T2_CN_Beijing storage via XRootD
if [ "${SKIP_STAGEOUT:-0}" -eq 1 ]; then
    echo "[INFO] SKIP_STAGEOUT=1, skip XRootD stageout"
else
    echo "Creating remote directory on T2_CN_Beijing..."
    xrdfs "${EOS_XRDFS_TARGET}" mkdir -p "${EOS_PATH_BASE}/${OUTPUT_DIR}" || {
        echo "Warning: mkdir failed (directory may already exist)"
    }

    OUTPUT_FILE="root://${EOS_HOST}/${EOS_PATH_BASE}/${OUTPUT_DIR}/sample_${POOL_NAME}_${MY_SEED}.lhe"
    echo "Staging out LHE file to: ${OUTPUT_FILE}"
    xrdcp --nopbar --force "${FINAL_LHE_FILE}" "${OUTPUT_FILE}" || {
        echo "Error: Failed to stage out LHE file"
        exit 1
    }
    echo "LHE generation complete!"
    echo "Output: $OUTPUT_FILE"
fi
echo "=============================================="

# Return to work directory
cd "$WORKDIR"

# Cleanup (optional, saves disk space on worker)
# rm -rf HELAC-Onia-2.7.6 HepMC
