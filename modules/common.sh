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

# ============================================================
# 镜像代理配置
# ============================================================

MIRROR_CONF_FILE="/etc/ops-scripts/mirror.conf"
MIRROR_URL=""
MIRROR_HEADERS=()
MIRROR_CURL_ARGS=()

# 加载镜像配置（从文件读取到全局变量）
load_mirror_config() {
    MIRROR_URL=""
    MIRROR_HEADERS=()
    MIRROR_CURL_ARGS=()
    [ -f "$MIRROR_CONF_FILE" ] || return 0

    local raw
    raw=$(grep "^MIRROR_URL=" "$MIRROR_CONF_FILE" 2>/dev/null | head -1 | cut -d= -f2-) || true
    MIRROR_URL="${raw:-}"

    local count=0
    raw=$(grep "^HEADER_COUNT=" "$MIRROR_CONF_FILE" 2>/dev/null | head -1 | cut -d= -f2-) || true
    count="${raw:-0}"

    local i=0
    while [ "$i" -lt "${count}" ]; do
        raw=$(grep "^HEADER_${i}=" "$MIRROR_CONF_FILE" 2>/dev/null | head -1 | cut -d= -f2-) || true
        if [ -n "${raw:-}" ]; then
            MIRROR_HEADERS+=("$raw")
            MIRROR_CURL_ARGS+=(-H "$raw")
        fi
        (( i++ )) || true
    done
}

# 保存镜像配置到文件
save_mirror_config() {
    ensure_marker_dir
    {
        printf 'MIRROR_URL=%s\n' "${MIRROR_URL}"
        printf 'HEADER_COUNT=%d\n' "${#MIRROR_HEADERS[@]}"
        local i=0
        for h in "${MIRROR_HEADERS[@]+"${MIRROR_HEADERS[@]}"}"; do
            printf 'HEADER_%d=%s\n' "$i" "$h"
            (( i++ )) || true
        done
    } > "$MIRROR_CONF_FILE"
}

# 构建带镜像前缀的完整 URL
build_mirror_url() {
    local url="$1"
    if [ -n "${MIRROR_URL:-}" ]; then
        echo "${MIRROR_URL%/}/${url}"
    else
        echo "$url"
    fi
}

# 显示当前镜像配置状态
show_mirror_status() {
    if [ -z "${MIRROR_URL:-}" ]; then
        log_info "当前未配置镜像代理"
    else
        log_info "镜像地址: ${MIRROR_URL}"
        if [ ${#MIRROR_HEADERS[@]} -eq 0 ]; then
            log_info "认证请求头: 未配置"
        else
            log_info "认证请求头 (共 ${#MIRROR_HEADERS[@]} 个):"
            for h in "${MIRROR_HEADERS[@]}"; do
                local hname="${h%%:*}"
                echo "    ${hname}: ****"
            done
        fi
    fi
}

# 内部函数：交互配置认证请求头
_configure_mirror_headers() {
    MIRROR_HEADERS=()
    MIRROR_CURL_ARGS=()
    echo ""
    log_info "配置认证请求头 (可配置多个，输入空行结束)"
    log_info "格式示例: X-XN-Token: xxxxxx"
    echo ""
    local idx=0
    while true; do
        local h
        read -r -p "$(echo -e "${CYAN}  第 $((idx + 1)) 个请求头 (直接回车结束): ${NC}")" h
        if [ -z "$h" ]; then
            break
        fi
        if ! echo "$h" | grep -q ": "; then
            log_warn "格式不正确，请使用 'Header-Name: value' 格式"
            continue
        fi
        MIRROR_HEADERS+=("$h")
        MIRROR_CURL_ARGS+=(-H "$h")
        local hname="${h%%:*}"
        log_info "  ✓ 已添加: ${hname}: ****"
        (( idx++ )) || true
    done
    if [ ${#MIRROR_HEADERS[@]} -gt 0 ]; then
        log_info "共添加 ${#MIRROR_HEADERS[@]} 个认证请求头"
    else
        log_info "未配置认证请求头"
    fi
}

# 交互配置/管理镜像代理（供菜单调用）
configure_mirror_interactive() {
    while true; do
        print_separator
        echo -e "  ${BOLD}镜像代理配置${NC}"
        print_separator
        echo ""
        show_mirror_status
        echo ""
        echo "  1) 配置/重新配置镜像代理"
        echo "  2) 清除镜像代理配置"
        echo "  0) 返回"
        echo ""
        select_option "请选择" 2 0

        case "$SELECTED_OPTION" in
            1)
                echo ""
                local new_url
                read_nonempty "请输入镜像地址 (如: https://gh-proxy.example.com)" new_url
                if ! echo "$new_url" | grep -qE '^https?://[a-zA-Z0-9]'; then
                    log_error "地址格式不正确，请以 http:// 或 https:// 开头并包含有效域名"
                    press_any_key
                    continue
                fi
                MIRROR_URL="${new_url%/}"
                echo ""
                if confirm "是否配置认证请求头?"; then
                    _configure_mirror_headers
                else
                    MIRROR_HEADERS=()
                    MIRROR_CURL_ARGS=()
                fi
                save_mirror_config
                echo ""
                log_info "✓ 镜像代理配置已保存"
                show_mirror_status
                press_any_key
                ;;
            2)
                if confirm "确认清除镜像代理配置?"; then
                    MIRROR_URL=""
                    MIRROR_HEADERS=()
                    MIRROR_CURL_ARGS=()
                    rm -f "$MIRROR_CONF_FILE"
                    log_info "✓ 镜像代理配置已清除"
                fi
                press_any_key
                ;;
            0) return 0 ;;
        esac
    done
}

# ============================================================
# 依赖检查与安装
# ============================================================

# 检查并提示安装缺失依赖
# 用法: check_and_install_deps "功能名称" "cmd1:pkg1" "cmd2:pkg2" ...
# 返回 0 表示所有依赖已满足，1 表示用户拒绝安装或安装失败
check_and_install_deps() {
    local feature="$1"
    shift
    local missing_pkgs=()
    local missing_descs=()

    for dep in "$@"; do
        local cmd="${dep%%:*}"
        local pkg="${dep#*:}"
        if ! command -v "$cmd" &>/dev/null; then
            missing_pkgs+=("$pkg")
            missing_descs+=("$cmd (软件包: $pkg)")
        fi
    done

    if [ ${#missing_pkgs[@]} -eq 0 ]; then
        return 0
    fi

    echo ""
    log_warn "「${feature}」需要以下依赖，当前尚未安装:"
    for desc in "${missing_descs[@]}"; do
        echo "  - ${desc}"
    done
    echo ""

    if confirm "是否立即安装所需依赖?"; then
        log_info "正在安装依赖..."
        apt update -qq && apt install -y "${missing_pkgs[@]}"
        echo ""
        log_info "✓ 依赖安装完成"
        return 0
    else
        log_warn "未安装依赖，返回上级菜单"
        press_any_key
        return 1
    fi
}
