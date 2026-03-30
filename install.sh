#!/usr/bin/env bash
# ============================================================
# OPS-Scripts 安装脚本
# 通过 curl 一键安装服务器运维脚本集合
#
# 用法:
#   curl -fsSL https://raw.githubusercontent.com/dowork-shanqiu/ops-scripts/main/install.sh | bash
# ============================================================

set -euo pipefail

# ---------- 配置 ----------
REPO_URL="https://github.com/dowork-shanqiu/ops-scripts.git"
INSTALL_DIR="/opt/ops-scripts"
BIN_LINK="/usr/bin/ops-scripts"

# 中国大陆使用 GitHub 镜像
MIRROR_REPO_URL="https://ghproxy.cn/https://github.com/dowork-shanqiu/ops-scripts.git"

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
    local api_list="https://blog.cloudflare.com/cdn-cgi/trace https://dash.cloudflare.com/cdn-cgi/trace"
    local ua="Mozilla/5.0 (X11; Linux x86_64; rv:60.0) Gecko/20100101 Firefox/81.0"
    for api_url in $api_list; do
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
    for cmd in curl git; do
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
    local repo_url="$REPO_URL"

    log_info "检测网络环境..."
    if is_china_network; then
        log_info "检测到中国大陆网络，使用镜像加速"
        use_mirror=true
        repo_url="$MIRROR_REPO_URL"
    fi

    # 如果已安装，提示更新
    if [ -d "$INSTALL_DIR/.git" ]; then
        log_warn "检测到已安装 OPS-Scripts"
        log_info "正在更新到最新版本..."
        cd "$INSTALL_DIR"

        local origin_url
        if [ "$use_mirror" = true ]; then
            origin_url="$MIRROR_REPO_URL"
        else
            origin_url="$REPO_URL"
        fi
        git remote set-url origin "$origin_url"
        git fetch origin main
        git reset --hard origin/main

        log_info "更新完成!"
    else
        # 全新安装
        log_info "正在下载 OPS-Scripts..."
        if [ -d "$INSTALL_DIR" ]; then
            rm -rf "$INSTALL_DIR"
        fi

        git clone --depth 1 "$repo_url" "$INSTALL_DIR"
        log_info "下载完成"
    fi

    # 设置权限
    chmod +x "$INSTALL_DIR/launch.sh"

    # 创建 /usr/bin 软链接
    ln -sf "$INSTALL_DIR/launch.sh" "$BIN_LINK"
    log_info "已创建命令链接: ${BIN_LINK}"

    echo ""
    echo -e "${GREEN}${BOLD}"
    echo "  ✓ OPS-Scripts 安装完成！"
    echo -e "${NC}"
    echo -e "  运行方式："
    echo -e "    ${CYAN}sudo ops-scripts${NC}"
    echo ""
}

main "$@"
