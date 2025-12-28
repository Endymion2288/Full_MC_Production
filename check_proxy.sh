#!/bin/bash
# ==============================================================================
# check_proxy.sh - Check and setup VOMS proxy for T2_CN_Beijing jobs
# ==============================================================================
# This script checks if a valid CMS VOMS proxy exists and copies it to a 
# persistent location for HTCondor jobs to access.
#
# Usage:
#   ./check_proxy.sh           # Check and copy proxy
#   ./check_proxy.sh --init    # Initialize new proxy if needed
#   ./check_proxy.sh --test    # Test XRootD access to T2_CN_Beijing
# ==============================================================================

set -e

# Configuration
PROXY_SRC="/tmp/x509up_u$(id -u)"
PROXY_DST="/afs/cern.ch/user/x/xcheng/x509up_u$(id -u)"
EOS_HOST="cceos.ihep.ac.cn"
EOS_PATH_BASE="/eos/ihep/cms/store/user/xcheng/MC_Production"
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

check_proxy() {
    msg_info "Checking VOMS proxy status..."
    
    if ! command -v voms-proxy-info &>/dev/null; then
        msg_error "voms-proxy-info not found. Please setup CMS environment first."
        return 1
    fi
    
    if ! voms-proxy-info --exists &>/dev/null; then
        msg_error "No valid proxy found."
        return 1
    fi
    
    # Check time left
    local timeleft=$(voms-proxy-info --timeleft 2>/dev/null || echo "0")
    local hours_left=$((timeleft / 3600))
    
    if [[ $hours_left -lt $MIN_HOURS_LEFT ]]; then
        msg_warn "Proxy has only ${hours_left}h left (minimum: ${MIN_HOURS_LEFT}h)"
        return 1
    fi
    
    # Check CMS VO
    local vo=$(voms-proxy-info --vo 2>/dev/null || echo "")
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
    voms-proxy-init -voms cms -valid 168:00
    
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
    
    if [[ ! -f "$PROXY_SRC" ]]; then
        msg_error "Source proxy not found: $PROXY_SRC"
        return 1
    fi
    
    cp "$PROXY_SRC" "$PROXY_DST"
    chmod 600 "$PROXY_DST"
    
    msg_ok "Proxy copied to: $PROXY_DST"
}

test_xrootd() {
    msg_info "Testing XRootD access to T2_CN_Beijing..."
    
    # Test listing
    msg_info "Testing xrdfs ls..."
    if xrdfs "$EOS_HOST" ls "$EOS_PATH_BASE" &>/dev/null; then
        msg_ok "Can list $EOS_PATH_BASE"
    else
        msg_warn "Cannot list $EOS_PATH_BASE (may not exist yet)"
    fi
    
    # Test directory creation
    local test_dir="$EOS_PATH_BASE/test_access_$(date +%s)"
    msg_info "Testing xrdfs mkdir..."
    if xrdfs "$EOS_HOST" mkdir -p "$test_dir" 2>/dev/null; then
        msg_ok "Can create directories"
        xrdfs "$EOS_HOST" rmdir "$test_dir" 2>/dev/null || true
    else
        msg_error "Cannot create directories - check permissions"
        return 1
    fi
    
    msg_ok "XRootD access to T2_CN_Beijing verified"
}

ensure_directories() {
    msg_info "Ensuring base directories exist on T2_CN_Beijing..."
    
    local dirs=("lhe_pools" "output" "lhe_pools/pool_jpsi_g" "lhe_pools/pool_gg" 
                "lhe_pools/pool_2jpsi_g" "lhe_pools/pool_upsilon_g" "lhe_pools/pool_jpsi_upsilon_g")
    
    for subdir in "${dirs[@]}"; do
        if xrdfs "$EOS_HOST" mkdir -p "$EOS_PATH_BASE/$subdir" 2>/dev/null; then
            msg_ok "Created: $EOS_PATH_BASE/$subdir"
        else
            msg_warn "Could not create $subdir (may already exist)"
        fi
    done
}

show_status() {
    echo ""
    echo "=============================================="
    echo "VOMS Proxy Status"
    echo "=============================================="
    voms-proxy-info --all 2>/dev/null || echo "No valid proxy"
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
