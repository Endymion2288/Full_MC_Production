#!/bin/bash
# ==============================================================================
# check_proxy.sh - VOMS 代理检查与远端写权限测试
# ==============================================================================
# 主要服务于 workbook_v2 版本的 T2_CN_Beijing 工作流。
# ==============================================================================

set -e

# Configuration
PROXY_SRC="/tmp/x509up_u$(id -u)"
PROXY_DST="/afs/cern.ch/user/x/xcheng/x509up_u$(id -u)"
EOS_HOST="cceos.ihep.ac.cn"
EOS_XRDFS_TARGET="root://${EOS_HOST}"
EOS_PATH_BASE="/eos/ihep/cms/store/user/xcheng/MC_Production_v2"
MIN_HOURS_LEFT=12

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

resolve_proxy_path() {
    if [[ -n "${X509_USER_PROXY:-}" && -f "${X509_USER_PROXY}" ]]; then
        echo "${X509_USER_PROXY}"
        return 0
    fi
    if [[ -f "${PROXY_DST}" ]]; then
        echo "${PROXY_DST}"
        return 0
    fi
    if [[ -f "${PROXY_SRC}" ]]; then
        echo "${PROXY_SRC}"
        return 0
    fi
    return 1
}

activate_proxy_env() {
    local proxy_path=""
    proxy_path=$(resolve_proxy_path) || return 1
    export X509_USER_PROXY="${proxy_path}"
    return 0
}

check_proxy() {
    msg_info "Checking VOMS proxy status..."
    
    if ! command -v voms-proxy-info &>/dev/null; then
        msg_error "voms-proxy-info not found. Please setup CMS environment first."
        return 1
    fi
    
    if ! activate_proxy_env; then
        msg_error "No proxy file found in X509_USER_PROXY, ${PROXY_DST} or ${PROXY_SRC}."
        return 1
    fi

    if ! voms-proxy-info -file "${X509_USER_PROXY}" --exists &>/dev/null; then
        msg_error "No valid proxy found."
        return 1
    fi
    
    # Check time left
    local timeleft=$(voms-proxy-info -file "${X509_USER_PROXY}" --timeleft 2>/dev/null || echo "0")
    local hours_left=$((timeleft / 3600))
    
    if [[ $hours_left -lt $MIN_HOURS_LEFT ]]; then
        msg_warn "Proxy has only ${hours_left}h left (minimum: ${MIN_HOURS_LEFT}h)"
        return 1
    fi
    
    # Check CMS VO
    local vo=$(voms-proxy-info -file "${X509_USER_PROXY}" --vo 2>/dev/null || echo "")
    if [[ "$vo" != "cms" ]]; then
        msg_error "Proxy is not for CMS VO (found: $vo)"
        return 1
    fi
    
    msg_ok "Valid CMS proxy found (${hours_left}h remaining)"
    return 0
}

init_proxy() {
    msg_info "Initializing new CMS VOMS proxy..."
    
    # Request 7-day proxy
    voms-proxy-init -voms cms -valid 192:00
    
    if [[ $? -eq 0 ]]; then
        msg_ok "New proxy initialized successfully"
        return 0
    else
        msg_error "Failed to initialize proxy"
        return 1
    fi
}

copy_proxy() {
    msg_info "Copying proxy to persistent location..."
    
    local source_proxy=""
    source_proxy=$(resolve_proxy_path) || true

    if [[ -z "${source_proxy}" || ! -f "${source_proxy}" ]]; then
        msg_error "Source proxy not found in X509_USER_PROXY, ${PROXY_DST} or ${PROXY_SRC}"
        return 1
    fi

    if [[ "${source_proxy}" == "${PROXY_DST}" ]]; then
        chmod 600 "$PROXY_DST"
        msg_ok "Persistent proxy already available: $PROXY_DST"
        return 0
    fi

    cp "${source_proxy}" "$PROXY_DST"
    chmod 600 "$PROXY_DST"
    
    msg_ok "Proxy copied to: $PROXY_DST"
}

test_xrootd() {
    msg_info "Testing XRootD access to T2_CN_Beijing..."

    if ! activate_proxy_env; then
        msg_error "No valid proxy file available for XRootD test"
        return 1
    fi
    
    # Test listing
    msg_info "Testing xrdfs ls..."
    if xrdfs "$EOS_XRDFS_TARGET" ls "$EOS_PATH_BASE" &>/dev/null; then
        msg_ok "Can list $EOS_PATH_BASE"
    else
        msg_warn "Cannot list $EOS_PATH_BASE (may not exist yet)"
    fi
    
    # Test directory creation
    local test_dir="$EOS_PATH_BASE/test_access_$(date +%s)"
    msg_info "Testing xrdfs mkdir..."
    if xrdfs "$EOS_XRDFS_TARGET" mkdir -p "$test_dir" 2>/dev/null; then
        msg_ok "Can create directories"
        xrdfs "$EOS_XRDFS_TARGET" rmdir "$test_dir" 2>/dev/null || true
    else
        msg_error "Cannot create directories - check permissions"
        return 1
    fi
    
    msg_ok "XRootD access to T2_CN_Beijing verified"
}

ensure_directories() {
    msg_info "Ensuring base directories exist on T2_CN_Beijing..."
    
    local dirs=("lhe_pools" "output" "lhe_pools/pool_jpsi_CSCO_g" "lhe_pools/pool_upsilon_CSCO_g" \
                "lhe_pools/pool_jpsi_upsilon_CSCO" "lhe_pools/pool_2jpsi" "lhe_pools/pool_2jpsi_cs" "lhe_pools/pool_2jpsi_g" \
                "lhe_pools/pool_gg")
    
    for subdir in "${dirs[@]}"; do
        if xrdfs "$EOS_XRDFS_TARGET" mkdir -p "$EOS_PATH_BASE/$subdir" 2>/dev/null; then
            msg_ok "Created: $EOS_PATH_BASE/$subdir"
        else
            msg_warn "Could not create $subdir (may already exist)"
        fi
    done
}

show_status() {
    activate_proxy_env || true
    echo ""
    echo "=============================================="
    echo "VOMS Proxy Status"
    echo "=============================================="
    if [[ -n "${X509_USER_PROXY:-}" && -f "${X509_USER_PROXY}" ]]; then
        voms-proxy-info -file "${X509_USER_PROXY}" --all 2>/dev/null || echo "No valid proxy"
    else
        echo "No valid proxy"
    fi
    echo ""
    echo "Persistent proxy location: $PROXY_DST"
    if [[ -f "$PROXY_DST" ]]; then
        echo "  Last updated: $(stat -c '%y' "$PROXY_DST")"
    else
        echo "  NOT FOUND - run: $0 --init"
    fi
    echo ""
    echo "T2_CN_Beijing storage:"
    echo "  Host: $EOS_HOST"
    echo "  Path: $EOS_PATH_BASE"
    echo "=============================================="
}

# Main
case "${1:-}" in
    --init)
        init_proxy && copy_proxy && test_xrootd && ensure_directories
        ;;
    --test)
        test_xrootd
        ;;
    --ensure-dirs)
        ensure_directories
        ;;
    --status)
        show_status
        ;;
    *)
        if check_proxy; then
            copy_proxy
            show_status
        else
            msg_error "No valid proxy. Run: $0 --init"
            exit 1
        fi
        ;;
esac
