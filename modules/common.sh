#!/usr/bin/env bash
# ============================================================
# 通用工具函数模块
# ============================================================

# ---------- 颜色定义 ----------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# ---------- 初始化标记文件 ----------
INIT_MARKER="/etc/ops-scripts/.initialized"
FIREWALL_MARKER="/etc/ops-scripts/.firewall_initialized"

# ---------- 日志函数 ----------
log_info() {
    echo -e "${GREEN}[INFO]${NC} $*"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*"
}

log_step() {
    echo -e "${BLUE}[STEP]${NC} ${BOLD}$*${NC}"
}

# ---------- 分隔线 ----------
print_separator() {
    echo -e "${CYAN}============================================================${NC}"
}

print_thin_separator() {
    echo -e "${CYAN}------------------------------------------------------------${NC}"
}

# ---------- 确认函数 ----------
# 用法: confirm "提示信息" && 操作
confirm() {
    local prompt="${1:-确认操作?}"
    while true; do
        read -r -p "$(echo -e "${YELLOW}${prompt} [y/n]: ${NC}")" yn
        case "$yn" in
            [Yy]|[Yy][Ee][Ss]) return 0 ;;
            [Nn]|[Nn][Oo]) return 1 ;;
            *) echo "请输入 y 或 n" ;;
        esac
    done
}

# ---------- 数字选择函数 ----------
# 用法: select_option "提示信息" 最大值
# 返回值保存在 SELECTED_OPTION 变量中
select_option() {
    local prompt="$1"
    local max="$2"
    local min="${3:-1}"
    while true; do
        read -r -p "$(echo -e "${CYAN}${prompt} [${min}-${max}]: ${NC}")" choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge "$min" ] && [ "$choice" -le "$max" ]; then
            SELECTED_OPTION="$choice"
            return 0
        fi
        log_warn "请输入 ${min} 到 ${max} 之间的数字"
    done
}

# ---------- 读取非空输入 ----------
read_nonempty() {
    local prompt="$1"
    local varname="$2"
    while true; do
        read -r -p "$(echo -e "${CYAN}${prompt}: ${NC}")" input
        if [ -n "$input" ]; then
            printf -v "$varname" '%s' "$input"
            return 0
        fi
        log_warn "输入不能为空，请重新输入"
    done
}

# ---------- 读取可选输入（允许空） ----------
read_optional() {
    local prompt="$1"
    local varname="$2"
    local default="$3"
    read -r -p "$(echo -e "${CYAN}${prompt} [默认: ${default}]: ${NC}")" input
    if [ -z "$input" ]; then
        printf -v "$varname" '%s' "$default"
    else
        printf -v "$varname" '%s' "$input"
    fi
}

# ---------- 按任意键继续 ----------
press_any_key() {
    echo ""
    read -r -n 1 -s -p "$(echo -e "${YELLOW}按任意键继续...${NC}")"
    echo ""
}

# ---------- 检测操作系统 ----------
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_ID="$ID"
        OS_VERSION="$VERSION_ID"
        OS_NAME="$PRETTY_NAME"
    else
        OS_ID="unknown"
        OS_VERSION=""
        OS_NAME="Unknown"
    fi
}

# ---------- 检测是否为中国大陆网络 ----------
is_china_network() {
    # 方式1: 通过 Cloudflare CDN trace 接口检测地理位置（快速且可靠）
    local api_list=(
        "https://blog.cloudflare.com/cdn-cgi/trace"
        "https://dash.cloudflare.com/cdn-cgi/trace"
        "https://developers.cloudflare.com/cdn-cgi/trace"
    )
    local ua="Mozilla/5.0 (X11; Linux x86_64; rv:60.0) Gecko/20100101 Firefox/81.0"
    for api_url in "${api_list[@]}"; do
        local text
        text="$(curl -A "$ua" -m 5 -s "$api_url" 2>/dev/null)" || continue
        local localize
        localize="$(echo "$text" | sed -n 's/^loc=\([A-Z]*\).*/\1/p')"
        if [ "$localize" = "CN" ]; then
            return 0
        fi
        # 如果成功获取到地理位置但不是 CN，则不再继续尝试
        if [ -n "$localize" ]; then
            return 1
        fi
    done

    # 方式2: 通过 ipapi.co 查询 IP 归属地（备用）
    local country
    country=$(curl -s --connect-timeout 5 --max-time 8 "https://ipapi.co/country/" 2>/dev/null)
    if [ "$country" = "CN" ]; then
        return 0
    fi

    return 1
}

# ---------- 确保标记目录存在 ----------
ensure_marker_dir() {
    mkdir -p /etc/ops-scripts
}

# ---------- 获取当前 SSH 端口 ----------
get_ssh_port() {
    local port
    port=$(grep -E "^Port " /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}')
    if [ -z "$port" ]; then
        port=22
    fi
    echo "$port"
}

# ---------- 检测 SSH 服务名 ----------
get_ssh_service_name() {
    detect_os
    if [ "$OS_ID" = "ubuntu" ]; then
        # Ubuntu 使用 ssh 作为服务名
        echo "ssh"
    else
        # Debian 及其他使用 sshd
        echo "sshd"
    fi
}

# ---------- 验证 SSH 公钥格式 ----------
validate_ssh_pubkey() {
    local pubkey="$1"
    # 基本格式检查
    if ! echo "$pubkey" | grep -qE '^(ssh-rsa|ssh-ed25519|ssh-dss|ecdsa-sha2-nistp[0-9]+) [A-Za-z0-9+/=]+'; then
        return 1
    fi
    # 使用 ssh-keygen 进行验证（如果可用）
    local tmpfile
    tmpfile=$(mktemp)
    echo "$pubkey" > "$tmpfile"
    if ssh-keygen -l -f "$tmpfile" > /dev/null 2>&1; then
        rm -f "$tmpfile"
        return 0
    fi
    rm -f "$tmpfile"
    return 1
}

# ---------- 检测系统中可用的 shell ----------
list_available_shells() {
    if [ -f /etc/shells ]; then
        grep -v '^#' /etc/shells | grep -v '^$'
    else
        echo "/bin/bash"
        echo "/bin/sh"
    fi
}

# ---------- 获取脚本所在目录 ----------
get_script_dir() {
    local dir
    dir="$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)"
    echo "$dir"
}
