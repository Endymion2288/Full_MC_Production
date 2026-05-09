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
MIN_PT_Q=0.0
WORKDIR=$(pwd)
OUTPUT_DIR=""
# workbook_v2 / 用户补充要求：
# 1. 优先使用 gener = 0 (PHEGAS)
# 2. gener = 0 时推荐 nopt = nmc/10, nopt_step = nmc/10, noptlim = nmc
# 3. preunw 推荐取 nmc/10
# 4. 当 unwevt 较小时，nmc 仍需设置一个下限，避免只得到 header-only LHE
GENER=0
UNWEVT=10000000
NMC=100000
PREUNW=10000
NOPT=10000
NOPT_STEP=10000
NOPT_LIM=100000
FAST_TEST=0
TEST_MODE="false"
UNWEVT_OVERRIDE=0
# Build locations (populated after unpacking helac_package.tar.gz)
HEPMC_SRC_TGZ=""
HELAC_SRC_TAR=""
HEPMC_PREFIX="${WORKDIR}/HepMC/HepMC-2.06.11"
JOB_LOG_DIR="${WORKDIR}/command_logs"
COMMAND_LOG_INDEX=0
LAST_STDOUT_LOG=""
LAST_STDERR_LOG=""
LOG_STAGEOUT_ATTEMPTED=0

# T2_CN_Beijing XRootD storage paths
EOS_HOST="cceos.ihep.ac.cn"
EOS_XRDFS_TARGET="root://${EOS_HOST}"
EOS_PATH_BASE="/eos/ihep/cms/store/user/xcheng/MC_Production_v3"

# ----------------------------------------------------------------------------
# Helper functions
# ----------------------------------------------------------------------------

msg_info() { echo "[INFO] $1"; }
msg_warn() { echo "[WARN] $1"; }
msg_error() { echo "[ERROR] $1" >&2; }

sanitize_log_label() {
    local raw_label="$1"
    printf '%s' "${raw_label}" | sed 's/[^A-Za-z0-9._-]/_/g'
}

ensure_job_log_dir() {
    mkdir -p "${JOB_LOG_DIR}"
}

show_log_tail() {
    local label="$1"
    local file_path="$2"
    local max_lines="$3"
    if [[ -s "${file_path}" ]]; then
        msg_warn "${label} 摘要 (${file_path}, tail -n ${max_lines})"
        tail -n "${max_lines}" "${file_path}"
    fi
}

run_logged() {
    local label="$1"
    shift

    ensure_job_log_dir

    COMMAND_LOG_INDEX=$((COMMAND_LOG_INDEX + 1))
    local safe_label=""
    safe_label=$(sanitize_log_label "${label}")
    local log_prefix=""
    printf -v log_prefix "%s/%03d_%s" "${JOB_LOG_DIR}" "${COMMAND_LOG_INDEX}" "${safe_label}"
    local stdout_log="${log_prefix}.stdout"
    local stderr_log="${log_prefix}.stderr"
    local rc=0
    local stdout_size=0
    local stderr_size=0

    LAST_STDOUT_LOG="${stdout_log}"
    LAST_STDERR_LOG="${stderr_log}"

    msg_info "执行 ${label}，完整日志写入 ${log_prefix}.[stdout|stderr]"
    if "$@" >"${stdout_log}" 2>"${stderr_log}"; then
        stdout_size=$(wc -c < "${stdout_log}" 2>/dev/null || echo 0)
        stderr_size=$(wc -c < "${stderr_log}" 2>/dev/null || echo 0)
        msg_info "${label} 完成 (stdout=${stdout_size} B, stderr=${stderr_size} B)"
        return 0
    fi

    rc=$?
    msg_error "${label} 失败 (rc=${rc})"
    show_log_tail "${label} stderr" "${stderr_log}" 80 >&2
    show_log_tail "${label} stdout" "${stdout_log}" 40
    return "${rc}"
}

run_logged_bash() {
    local label="$1"
    local command_str="$2"
    run_logged "${label}" bash -lc "${command_str}"
}

make_remote_dir() {
    local remote_subpath="$1"
    xrdfs "${EOS_XRDFS_TARGET}" mkdir -p "${EOS_PATH_BASE}/${remote_subpath}" >/dev/null 2>&1 || {
        msg_warn "远端目录创建失败或已存在: ${EOS_PATH_BASE}/${remote_subpath}"
        return 1
    }
    return 0
}

stage_out_worker_logs() {
    if [[ "${LOG_STAGEOUT_ATTEMPTED}" -eq 1 ]]; then
        return 0
    fi
    LOG_STAGEOUT_ATTEMPTED=1

    if [[ "${SKIP_STAGEOUT:-0}" -eq 1 ]]; then
        msg_info "SKIP_STAGEOUT=1, skip log stageout"
        return 0
    fi

    ensure_job_log_dir

    local remote_log_dir="${OUTPUT_DIR}/logs"
    local bundle_name="logs_${POOL_NAME}_${MY_SEED}.tar.gz"
    local bundle_path="${WORKDIR}/${bundle_name}"
    local manifest_path="${WORKDIR}/log_manifest_${POOL_NAME}_${MY_SEED}.txt"

    {
        echo "pool=${POOL_NAME}"
        echo "seed=${MY_SEED}"
        echo "process=${PROCESS_STRING}"
        echo "min_pt_conia=${MIN_PT_CONIA}"
        echo "min_pt_bonia=${MIN_PT_BONIA}"
        echo "min_pt_q=${MIN_PT_Q}"
        echo "unwevt=${UNWEVT}"
        echo "nmc=${NMC}"
        echo "preunw=${PREUNW}"
    } > "${manifest_path}"

    (
        cd "${WORKDIR}" && \
        tar -czf "${bundle_path}" \
            command_logs \
            log_manifest_"${POOL_NAME}"_"${MY_SEED}".txt \
            py8_onia_user.inp \
            sample_"${POOL_NAME}"_"${MY_SEED}"_converted.lhe \
            helac_run.log \
            HELAC-Onia-2.7.6/run_config.ho \
            HELAC-Onia-2.7.6/input/user.inp \
            HELAC-Onia-2.7.6/PROC_HO_0/results/results.out \
            HELAC-Onia-2.7.6/PROC_HO_0/results/results.lhe \
            >/dev/null 2>&1 || true
    )

    if [[ ! -f "${bundle_path}" ]]; then
        msg_warn "未生成日志 bundle，跳过远端日志传输"
        return 0
    fi

    make_remote_dir "${remote_log_dir}" || true
    local remote_url="root://${EOS_HOST}/${EOS_PATH_BASE}/${remote_log_dir}/${bundle_name}"
    msg_info "上传完整日志到: ${remote_url}"
    if xrdcp --nopbar --force "${bundle_path}" "${remote_url}" >/dev/null 2>&1; then
        msg_info "完整日志已上传: ${remote_url}"
    else
        msg_warn "完整日志上传失败: ${remote_url}"
    fi
}

upload_logs_on_exit() {
    local exit_code=$?
    set +e
    stage_out_worker_logs
    exit "${exit_code}"
}

trap upload_logs_on_exit EXIT

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

    msg_info "Building HepMC from ${HEPMC_SRC_TGZ}..."
    mkdir -p "${WORKDIR}/HepMC"
    run_logged "untar_hepmc" tar -xzf "${HEPMC_SRC_TGZ}" -C "${WORKDIR}/HepMC"
    cd "${HEPMC_PREFIX}"
    mkdir -p build install
    cd build
    run_logged "configure_hepmc" "${HEPMC_PREFIX}/configure" --prefix="${HEPMC_PREFIX}/install" --with-momentum=GEV --with-length=MM
    run_logged "make_hepmc" make -j 2
    run_logged "check_hepmc" make check
    run_logged "install_hepmc" make install
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

    msg_info "Unpacking HELAC-Onia from ${HELAC_SRC_TAR}..."
    run_logged "untar_helac" tar -xzf "${HELAC_SRC_TAR}" -C "${WORKDIR}"

    cd "${WORKDIR}/HELAC-Onia-2.7.6"

    # Keep HepMC optional on worker nodes (avoid linking HepMC2Plot)
    sed -i -r -e 's|^[[:space:]]*hepmc_path[[:space:]]*=.*|# hepmc_path is left unset for condor runs|' input/ho_configuration.txt

    # Fix heptoptagger interface to compile with newer gcc
    sed -i 's/HEPTopTagger::HEPTopTagger /HEPTopTagger /g' analysis/heptoptagger/heptoptagger_fjcore_interface.cc

    msg_info "Configuring HELAC-Onia..."
    run_logged "config_helac" ./config
    cd "${WORKDIR}"
}

write_py8_onia_config() {
    local pool_name="$1"
    local output_file="$2"

    case "$pool_name" in
        "pool_2jpsi_cs"|"pool_2jpsi_g")
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

    msg_info "Building lhe_pythia6_pythia8 converter..."
    run_logged "build_lhe_converter" gfortran "${build_flags[@]}" -o "${WORKDIR}/lhe_pythia6_pythia8" "${WORKDIR}/lhe_pythia6_pythia8.f"
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

count_lhe_events() {
    local lhe_file="$1"
    local event_count="0"
    if [[ ! -f "${lhe_file}" ]]; then
        echo "0"
        return 0
    fi
    event_count=$(grep -c '^[[:space:]]*<event>' "${lhe_file}" 2>/dev/null || true)
    if [[ -z "${event_count}" ]]; then
        event_count="0"
    fi
    echo "${event_count}"
}

prepare_runtime_user_inp() {
    local helac_dir="$1"
    local runtime_user_inp="${helac_dir}/input/user.inp"
    local template_user_inp="../input_templates/user.inp"

    if [[ -f "${template_user_inp}" ]]; then
        cp "${template_user_inp}" "${runtime_user_inp}"
    elif [[ ! -f "${runtime_user_inp}" ]]; then
        echo "[ERROR] 找不到可用的 user.inp 模板"
        return 1
    fi

    # worker 上显式重写 Monte Carlo 相关参数，避免旧模板把 run_config.ho 中的
    # 积分设置重新覆盖掉。
    sed -i -E \
        -e "s|^(minptq)[[:space:]].*$|\\1 ${MIN_PT_Q}d0|" \
        -e "s|^(minptconia)[[:space:]].*$|\\1 ${MIN_PT_CONIA}d0|" \
        -e "s|^(minptbonia)[[:space:]].*$|\\1 ${MIN_PT_BONIA}d0|" \
        -e "s|^(preunw)[[:space:]].*$|\\1 ${PREUNW}|" \
        -e "s|^(unwevt)[[:space:]].*$|\\1 ${UNWEVT}|" \
        -e "s|^(nmc)[[:space:]].*$|\\1 ${NMC}|" \
        -e "s|^(nopt)[[:space:]].*$|\\1 ${NOPT}|" \
        -e "s|^(nopt_step)[[:space:]].*$|\\1 ${NOPT_STEP}|" \
        -e "s|^(noptlim)[[:space:]].*$|\\1 ${NOPT_LIM}|" \
        -e "s|^(gener)[[:space:]].*$|\\1 ${GENER}|" \
        -e "s|^(ranhel)[[:space:]].*$|\\1 4|" \
        "${runtime_user_inp}"

    echo "[INFO] 运行时 user.inp 中的关键积分参数:"
    grep -E '^(minptq|minptconia|minptbonia|preunw|unwevt|nmc|nopt|nopt_step|noptlim|gener|ranhel)[[:space:]]' "${runtime_user_inp}"
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
            UNWEVT_OVERRIDE=1
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
        "pool_2jpsi_cs")
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
            echo "  - pool_gg, pool_2jpsi_cs, pool_2jpsi_g"
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

# 正式生产统一使用固定的 HELAC 积分参数；测试模式单独收缩。
if [ "$FAST_TEST" -eq 1 ]; then
    if [ "$UNWEVT_OVERRIDE" -eq 0 ]; then
        UNWEVT=100
    fi
    GENER=0
    if ! [[ "$UNWEVT" =~ ^[0-9]+$ ]] || [ "$UNWEVT" -le 0 ]; then
        echo "Error: --unwevt must be a positive integer"
        exit 1
    fi
    if [ "$UNWEVT" -ge 100000 ]; then
        NMC="$UNWEVT"
    else
        NMC=100000
    fi
    PREUNW=$(( NMC / 10 ))
    NOPT=$(( NMC / 10 ))
    NOPT_STEP=$(( NMC / 10 ))
    NOPT_LIM=$(( NMC ))
else
    GENER=0
    UNWEVT=100000
    PREUNW=500000
    NMC=5000000
    NOPT=500000
    NOPT_STEP=500000
    NOPT_LIM=5000000
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
echo "Generator:      PHEGAS (gener=${GENER})"
echo "preunw:         $PREUNW"
echo "nmc:            $NMC"
echo "nopt:           $NOPT"
echo "nopt_step:      $NOPT_STEP"
echo "noptlim:        $NOPT_LIM"
if [ "$FAST_TEST" -eq 1 ]; then
    echo "Mode:           FAST TEST"
fi
echo "Output dir:     $OUTPUT_DIR"
echo "=============================================="

ensure_job_log_dir

# Check for HELAC package
if [ ! -f "helac_package.tar.gz" ]; then
    echo "Error: helac_package.tar.gz not found"
    exit 1
fi

# Prepare build environment and unpack archives
setup_build_env
run_logged "untar_helac_package" tar -xzf helac_package.tar.gz

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
set gener = ${GENER}
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

# 强制同步 runtime user.inp，避免静态模板中的旧积分参数覆盖掉当前作业设置。
prepare_runtime_user_inp "$(pwd)"

msg_info "Running HELAC-Onia..."
run_logged_bash "helac_ho_cluster" "cd '$(pwd)' && ./ho_cluster < run_config.ho"
HELAC_RUN_LOG="${LAST_STDOUT_LOG}"
cp "${HELAC_RUN_LOG}" ../helac_run.log

# Find output LHE file
RUN_DIR=$(grep "INFO: Results are collected in" "${HELAC_RUN_LOG}" | \
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

RAW_EVENT_COUNT=$(count_lhe_events "${LHE_FILE}")
echo "[INFO] 原始 LHE 事件数: ${RAW_EVENT_COUNT}"
if (( RAW_EVENT_COUNT <= 0 )); then
    echo "[ERROR] HELAC 生成的原始 LHE 不包含任何 <event>，终止上传空文件"
    exit 1
fi

# workbook_v2 要求在 LHE 生成后单独调用 converter 完成 PDG 转换。
FINAL_LHE_FILE="${LHE_FILE}"
PY8_ONIA_CONFIG="${WORKDIR}/py8_onia_user.inp"
CONVERTED_LHE_FILE="${WORKDIR}/sample_${POOL_NAME}_${MY_SEED}_converted.lhe"

if write_py8_onia_config "${POOL_NAME}" "${PY8_ONIA_CONFIG}" && build_lhe_converter_if_needed; then
    echo "[INFO] Running lhe_pythia6_pythia8 converter..."
    if run_logged "lhe_pythia6_pythia8" "${WORKDIR}/lhe_pythia6_pythia8" "${LHE_FILE}" "${PY8_ONIA_CONFIG}" "${CONVERTED_LHE_FILE}"; then
        if [[ -f "${CONVERTED_LHE_FILE}" ]]; then
            CONVERTED_EVENT_COUNT=$(count_lhe_events "${CONVERTED_LHE_FILE}")
            echo "[INFO] 转换后 LHE 事件数: ${CONVERTED_EVENT_COUNT}"
            if (( CONVERTED_EVENT_COUNT > 0 )); then
                FINAL_LHE_FILE="${CONVERTED_LHE_FILE}"
                echo "[INFO] Converted LHE ready: ${FINAL_LHE_FILE}"
            else
                echo "[WARN] 转换后 LHE 不包含任何 <event>，回退到原始 LHE"
            fi
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

FINAL_EVENT_COUNT=$(count_lhe_events "${FINAL_LHE_FILE}")
echo "[INFO] 最终待上传 LHE 事件数: ${FINAL_EVENT_COUNT}"
if (( FINAL_EVENT_COUNT <= 0 )); then
    echo "[ERROR] 最终 LHE 不包含任何 <event>，拒绝上传空文件"
    exit 1
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
    xrdfs "${EOS_XRDFS_TARGET}" mkdir -p "${EOS_PATH_BASE}/${OUTPUT_DIR}" >/dev/null 2>&1 || {
        echo "Warning: mkdir failed (directory may already exist)"
    }

    OUTPUT_FILE="root://${EOS_HOST}/${EOS_PATH_BASE}/${OUTPUT_DIR}/sample_${POOL_NAME}_${MY_SEED}.lhe"
    echo "Staging out LHE file to: ${OUTPUT_FILE}"
    run_logged "xrdcp_lhe_stageout" xrdcp --nopbar --force "${FINAL_LHE_FILE}" "${OUTPUT_FILE}" || {
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
