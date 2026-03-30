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

# 中国大陆使用 GitHub 镜像
MIRROR_PREFIX="https://ghproxy.cn/"

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

# ---------- 获取最新版本标签 ----------
get_latest_tag() {
    local tag
    tag=$(curl -fsSL --connect-timeout 10 --max-time 15 "$GITHUB_API" 2>/dev/null \
        | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
    if [ -z "$tag" ]; then
        return 1
    fi
    echo "$tag"
}

# ---------- 下载并安装指定标签版本 ----------
download_and_install() {
    local tag="$1"
    local use_mirror="$2"

    local tarball_url="https://github.com/${GITHUB_REPO}/archive/refs/tags/${tag}.tar.gz"
    if [ "$use_mirror" = true ]; then
        tarball_url="${MIRROR_PREFIX}${tarball_url}"
    fi

    local tmp_dir
    tmp_dir=$(mktemp -d)
    local tmp_file="${tmp_dir}/ops-scripts.tar.gz"

    log_info "正在下载版本 ${tag}..."
    if ! curl -fsSL --connect-timeout 10 --max-time 120 -o "$tmp_file" "$tarball_url"; then
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

    # 检测网络环境
    local use_mirror=false

    log_info "检测网络环境..."
    if is_china_network; then
        log_info "检测到中国大陆网络，使用镜像加速"
        use_mirror=true
    fi

    # 获取最新版本
    log_info "获取最新版本信息..."
    local latest_tag
    if ! latest_tag=$(get_latest_tag); then
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
    if ! download_and_install "$latest_tag" "$use_mirror"; then
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
