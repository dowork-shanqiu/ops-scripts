#!/usr/bin/env bash
# ============================================================
# OPS-Scripts 安装脚本
# 通过 curl 一键安装服务器运维脚本集合
#
# 用法:
#   curl -fsSL https://raw.githubusercontent.com/dowork-shanqiu/ops-scripts/main/install.sh | sudo bash
# ============================================================

set -euo pipefail

# ---------- 配置 ----------
GITHUB_REPO="dowork-shanqiu/ops-scripts"
GITHUB_API="https://api.github.com/repos/${GITHUB_REPO}/releases/latest"
INSTALL_DIR="/opt/ops-scripts"
BIN_LINK="/usr/bin/ops-scripts"
VERSION_FILE="${INSTALL_DIR}/.version"
MARKER_DIR="/etc/ops-scripts"
MIRROR_CONF_FILE="${MARKER_DIR}/mirror.conf"

# 中国大陆自动使用 GitHub 镜像
AUTO_MIRROR_PREFIX="https://ghproxy.cn/"

# 镜像配置（安装过程中填充）
MIRROR_URL=""
MIRROR_HEADERS=()
MIRROR_CURL_ARGS=()

# ---------- 颜色定义 ----------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

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

# ---------- 检测是否为中国大陆网络 ----------
is_china_network() {
    local api_list=(
        "https://blog.cloudflare.com/cdn-cgi/trace"
        "https://dash.cloudflare.com/cdn-cgi/trace"
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
        if [ -n "$localize" ]; then
            return 1
        fi
    done
    return 1
}

# ---------- 检查依赖 ----------
check_dependencies() {
    local missing=()
    for cmd in curl tar; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done

    if [ ${#missing[@]} -gt 0 ]; then
        log_warn "缺少依赖: ${missing[*]}"
        log_info "正在安装依赖..."
        if command -v apt &>/dev/null; then
            apt update -qq && apt install -y -qq "${missing[@]}"
        else
            log_error "无法自动安装依赖，请手动安装: ${missing[*]}"
            exit 1
        fi
    fi
}

# ---------- 镜像配置：从文件加载 ----------
_load_mirror_config() {
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

# ---------- 镜像配置：保存到文件 ----------
_save_mirror_config() {
    mkdir -p "$MARKER_DIR"
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

# ---------- 显示当前镜像状态 ----------
_show_mirror_status() {
    if [ -z "${MIRROR_URL:-}" ]; then
        log_info "当前未配置镜像代理"
    else
        log_info "镜像地址: ${MIRROR_URL}"
        if [ ${#MIRROR_HEADERS[@]} -eq 0 ]; then
            log_info "认证请求头: 未配置"
        else
            log_info "认证请求头: 共 ${#MIRROR_HEADERS[@]} 个"
            for h in "${MIRROR_HEADERS[@]}"; do
                local hname="${h%%:*}"
                echo "    ${hname}: ****"
            done
        fi
    fi
}

# ---------- 镜像配置：交互配置认证请求头 ----------
_configure_install_headers() {
    MIRROR_HEADERS=()
    MIRROR_CURL_ARGS=()
    echo ""
    log_info "配置认证请求头 (可配置多个，直接回车结束)"
    log_info "格式示例: X-XN-Token: xxxxxx"
    echo ""
    local idx=0
    while true; do
        local h
        read -r -p "$(echo -e "${CYAN}  第 $((idx + 1)) 个请求头 (直接回车结束): ${NC}")" h || true
        if [ -z "$h" ]; then
            break
        fi
        if ! echo "$h" | grep -q ": "; then
            echo -e "${YELLOW}[WARN]${NC} 格式不正确，请使用 'Header-Name: value' 格式"
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

# ---------- 镜像配置：交互配置入口 ----------
configure_install_mirror() {
    echo ""
    echo -e "${CYAN}============================================================${NC}"
    echo -e "  ${BOLD}镜像代理配置${NC}"
    echo -e "${CYAN}============================================================${NC}"
    echo ""

    # 加载已有配置
    _load_mirror_config

    if [ -n "${MIRROR_URL:-}" ]; then
        log_info "检测到已有镜像配置:"
        _show_mirror_status
        echo ""
        read -r -p "$(echo -e "${YELLOW}是否重新配置镜像? [y/n]: ${NC}")" yn
        case "$yn" in
            [Yy]|[Yy][Ee][Ss]) ;;  # continue to configure
            *)
                log_info "保留现有镜像配置"
                return 0
                ;;
        esac
        echo ""
    fi

    read -r -p "$(echo -e "${YELLOW}是否配置 GitHub 镜像代理? (建议在 GitHub 访问困难时配置) [y/n]: ${NC}")" yn
    case "$yn" in
        [Yy]|[Yy][Ee][Ss]) ;;
        *)
            MIRROR_URL=""
            MIRROR_HEADERS=()
            MIRROR_CURL_ARGS=()
            # Clear any existing config if user says no
            rm -f "$MIRROR_CONF_FILE"
            log_info "跳过镜像配置"
            return 0
            ;;
    esac

    echo ""
    while true; do
        read -r -p "$(echo -e "${CYAN}请输入镜像地址 (如: https://gh-proxy.example.com): ${NC}")" new_url
        if [ -z "$new_url" ]; then
            log_warn "地址不能为空，请重新输入"
            continue
        fi
        if ! echo "$new_url" | grep -qE '^https?://'; then
            log_warn "地址格式不正确，请以 http:// 或 https:// 开头"
            continue
        fi
        MIRROR_URL="${new_url%/}"
        break
    done

    log_info "镜像地址已设置: ${MIRROR_URL}"
    echo ""

    read -r -p "$(echo -e "${YELLOW}是否配置认证请求头? [y/n]: ${NC}")" yn
    case "$yn" in
        [Yy]|[Yy][Ee][Ss])
            _configure_install_headers
            ;;
        *)
            MIRROR_HEADERS=()
            MIRROR_CURL_ARGS=()
            log_info "未配置认证请求头"
            ;;
    esac

    # 保存配置
    mkdir -p "$MARKER_DIR"
    _save_mirror_config
    echo ""
    log_info "✓ 镜像代理配置已保存"
    _show_mirror_status
}

# ---------- 获取最新版本标签 ----------
get_latest_tag() {
    local mirror_prefix="${1:-}"
    local api_url="$GITHUB_API"
    if [ -n "$mirror_prefix" ]; then
        api_url="${mirror_prefix}${GITHUB_API}"
    fi

    local tag
    tag=$(curl -fsSL --connect-timeout 10 --max-time 15 \
        "${MIRROR_CURL_ARGS[@]+"${MIRROR_CURL_ARGS[@]}"}" "$api_url" 2>/dev/null \
        | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
    if [ -z "$tag" ]; then
        return 1
    fi
    echo "$tag"
}

# ---------- 下载并安装指定标签版本 ----------
download_and_install() {
    local tag="$1"
    local mirror_prefix="${2:-}"

    local tarball_url="https://github.com/${GITHUB_REPO}/archive/refs/tags/${tag}.tar.gz"
    if [ -n "$mirror_prefix" ]; then
        tarball_url="${mirror_prefix}${tarball_url}"
    fi

    local tmp_dir
    tmp_dir=$(mktemp -d)
    local tmp_file="${tmp_dir}/ops-scripts.tar.gz"

    log_info "正在下载版本 ${tag}..."
    if ! curl -fsSL --connect-timeout 10 --max-time 120 \
        "${MIRROR_CURL_ARGS[@]+"${MIRROR_CURL_ARGS[@]}"}" -o "$tmp_file" "$tarball_url"; then
        rm -rf "$tmp_dir"
        log_error "下载失败，请检查网络连接后重试"
        return 1
    fi

    # 清理旧安装目录
    if [ -d "$INSTALL_DIR" ]; then
        rm -rf "$INSTALL_DIR"
    fi
    mkdir -p "$INSTALL_DIR"

    # 解压到安装目录（tarball 内含一层目录，使用 --strip-components 去除）
    if ! tar -xzf "$tmp_file" -C "$INSTALL_DIR" --strip-components=1; then
        rm -rf "$tmp_dir"
        log_error "解压失败"
        return 1
    fi

    rm -rf "$tmp_dir"

    # 记录当前版本
    echo "$tag" > "$VERSION_FILE"

    log_info "版本 ${tag} 安装完成"
}

# ---------- 主安装流程 ----------
main() {
    echo -e "${CYAN}"
    echo "  ============================================================"
    echo "   OPS-Scripts 安装程序"
    echo "   服务器运维脚本集合 - 仅支持 Ubuntu / Debian"
    echo "  ============================================================"
    echo -e "${NC}"

    # 检查 root 权限
    if [ "$(id -u)" -ne 0 ]; then
        log_error "此脚本必须以 root 权限运行"
        log_info "请使用: curl -fsSL <URL> | sudo bash"
        exit 1
    fi

    # 检查操作系统
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        if [ "$ID" != "ubuntu" ] && [ "$ID" != "debian" ]; then
            log_error "此脚本仅支持 Ubuntu 和 Debian 系统"
            log_error "当前系统: ${PRETTY_NAME}"
            exit 1
        fi
    else
        log_error "无法检测操作系统"
        exit 1
    fi

    # 检查依赖
    check_dependencies

    # 交互配置镜像代理
    configure_install_mirror

    # 确定下载前缀
    local mirror_prefix=""
    if [ -n "${MIRROR_URL:-}" ]; then
        mirror_prefix="${MIRROR_URL%/}/"
    else
        # 未配置自定义镜像则自动检测网络环境
        log_info "检测网络环境..."
        if is_china_network; then
            log_info "检测到中国大陆网络，使用默认镜像加速"
            mirror_prefix="${AUTO_MIRROR_PREFIX}"
        fi
    fi

    # 获取最新版本
    log_info "获取最新版本信息..."
    local latest_tag
    if ! latest_tag=$(get_latest_tag "$mirror_prefix"); then
        log_error "无法获取最新版本信息，请检查网络连接"
        exit 1
    fi
    log_info "最新版本: ${latest_tag}"

    # 检查是否已安装相同版本
    if [ -f "$VERSION_FILE" ]; then
        local current_version
        current_version=$(cat "$VERSION_FILE")
        if [ "$current_version" = "$latest_tag" ]; then
            log_info "当前已是最新版本 (${current_version})"
            log_info "如需强制重新安装，请先删除 ${INSTALL_DIR} 目录"
            exit 0
        fi
        log_warn "检测到已安装版本: ${current_version}"
        log_info "正在更新到 ${latest_tag}..."
    fi

    # 下载并安装
    if ! download_and_install "$latest_tag" "$mirror_prefix"; then
        exit 1
    fi

    # 设置权限
    chmod +x "$INSTALL_DIR/launch.sh"

    # 创建 /usr/bin 软链接
    ln -sf "$INSTALL_DIR/launch.sh" "$BIN_LINK"
    log_info "已创建命令链接: ${BIN_LINK}"

    echo ""
    echo -e "${GREEN}${BOLD}"
    echo "  ✓ OPS-Scripts 安装完成！(版本: ${latest_tag})"
    echo -e "${NC}"
    echo -e "  运行方式："
    echo -e "    ${CYAN}sudo ops-scripts${NC}"
    echo ""
}

main "$@"
