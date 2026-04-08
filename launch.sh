#!/usr/bin/env bash
# ============================================================
#
#   ██████╗ ██████╗ ███████╗   ███████╗ ██████╗██████╗ ██╗██████╗ ████████╗███████╗
#  ██╔═══██╗██╔══██╗██╔════╝   ██╔════╝██╔════╝██╔══██╗██║██╔══██╗╚══██╔══╝██╔════╝
#  ██║   ██║██████╔╝███████╗   ███████╗██║     ██████╔╝██║██████╔╝   ██║   ███████╗
#  ██║   ██║██╔═══╝ ╚════██║   ╚════██║██║     ██╔══██╗██║██╔═══╝    ██║   ╚════██║
#  ╚██████╔╝██║     ███████║   ███████║╚██████╗██║  ██║██║██║        ██║   ███████║
#   ╚═════╝ ╚═╝     ╚══════╝   ╚══════╝ ╚═════╝╚═╝  ╚═╝╚═╝╚═╝        ╚═╝   ╚══════╝
#
#  服务器运维脚本集合
#  仅支持 Ubuntu / Debian 系统
#
# ============================================================

set -euo pipefail

# ---------- 获取脚本所在目录（解析软链接，确保通过 /usr/bin/ops-scripts 调用时路径正确）----------
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
MODULES_DIR="${SCRIPT_DIR}/modules"

# ---------- 加载公共模块 ----------
source "${MODULES_DIR}/common.sh"

# ---------- 加载镜像配置 ----------
load_mirror_config

# ============================================================
# 前置检查
# ============================================================
pre_check() {
    # 检查 root 权限
    if [ "$(id -u)" -ne 0 ]; then
        log_error "此脚本必须以 root 权限运行"
        log_info "请使用: sudo bash $0"
        exit 1
    fi

    # 检查操作系统
    detect_os
    if [ "$OS_ID" != "ubuntu" ] && [ "$OS_ID" != "debian" ]; then
        log_error "此脚本仅支持 Ubuntu 和 Debian 系统"
        log_error "当前系统: ${OS_NAME} (${OS_ID})"
        exit 1
    fi

    log_info "系统检测通过: ${OS_NAME}"
}

# ============================================================
# 系统初始化流程
# ============================================================
run_initialization() {
    print_separator
    echo -e "${BOLD}${CYAN}"
    echo "  欢迎使用服务器运维脚本集合"
    echo "  检测到系统尚未初始化，即将开始环境配置"
    echo -e "${NC}"
    print_separator
    echo ""

    if ! confirm "是否开始系统初始化?"; then
        log_info "已取消初始化，退出脚本"
        exit 0
    fi

    echo ""

    # 步骤 1: 系统环境配置 (APT 源 + 更新 + 安装基础包)
    source "${MODULES_DIR}/init_system.sh"
    run_init_system

    echo ""

    # 步骤 2: SSH 安全配置
    source "${MODULES_DIR}/init_ssh.sh"
    run_init_ssh

    echo ""

    # 标记初始化完成
    ensure_marker_dir
    touch "$INIT_MARKER"

    print_separator
    echo -e "${GREEN}${BOLD}"
    echo "  ✓ 系统初始化完成！"
    echo -e "${NC}"
    print_separator
    echo ""

    press_any_key
}

# ============================================================
# 脚本更新
# ============================================================
GITHUB_REPO="dowork-shanqiu/ops-scripts"
GITHUB_API="https://api.github.com/repos/${GITHUB_REPO}/releases/latest"
VERSION_FILE="${SCRIPT_DIR}/.version"
AUTO_MIRROR_PREFIX="https://ghproxy.cn/"

update_scripts() {
    print_separator
    echo -e "  ${BOLD}脚本更新${NC}"
    print_separator
    echo ""

    # 显示当前版本
    if [ -f "$VERSION_FILE" ]; then
        local current_version
        current_version=$(cat "$VERSION_FILE")
        log_info "当前版本: ${current_version}"
    else
        log_warn "未检测到版本信息"
    fi

    echo ""

    # 确定使用的下载前缀
    local mirror_prefix=""
    if [ -n "${MIRROR_URL:-}" ]; then
        log_info "使用已配置的镜像代理: ${MIRROR_URL}"
        mirror_prefix="${MIRROR_URL%/}/"
    else
        log_info "检测网络环境..."
        if is_china_network; then
            log_info "检测到中国大陆网络，使用默认镜像加速"
            mirror_prefix="${AUTO_MIRROR_PREFIX}"
        fi
    fi

    # 构建 API 地址
    local api_url
    if [ -n "$mirror_prefix" ]; then
        api_url="${mirror_prefix}${GITHUB_API}"
    else
        api_url="$GITHUB_API"
    fi

    # 获取最新版本
    log_info "获取最新版本信息..."
    local latest_tag
    latest_tag=$(curl -fsSL --connect-timeout 10 --max-time 15 \
        "${MIRROR_CURL_ARGS[@]+"${MIRROR_CURL_ARGS[@]}"}" "$api_url" 2>/dev/null \
        | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')

    if [ -z "$latest_tag" ]; then
        log_error "无法获取最新版本信息，请检查网络连接"
        press_any_key
        return
    fi

    log_info "最新版本: ${latest_tag}"

    # 检查是否已是最新版本
    if [ -f "$VERSION_FILE" ]; then
        if [ "${current_version:-}" = "$latest_tag" ]; then
            echo ""
            log_info "当前已是最新版本，无需更新"
            press_any_key
            return
        fi
    fi

    echo ""
    if ! confirm "是否更新到版本 ${latest_tag}?"; then
        return
    fi

    echo ""
    local tarball_url="https://github.com/${GITHUB_REPO}/archive/refs/tags/${latest_tag}.tar.gz"
    if [ -n "$mirror_prefix" ]; then
        tarball_url="${mirror_prefix}${tarball_url}"
    fi

    local tmp_dir
    tmp_dir=$(mktemp -d)
    local tmp_file="${tmp_dir}/ops-scripts.tar.gz"

    log_info "正在下载版本 ${latest_tag}..."
    if ! curl -fsSL --connect-timeout 10 --max-time 120 \
        "${MIRROR_CURL_ARGS[@]+"${MIRROR_CURL_ARGS[@]}"}" -o "$tmp_file" "$tarball_url"; then
        rm -rf "$tmp_dir"
        log_error "下载失败，请检查网络连接"
        press_any_key
        return
    fi

    log_info "正在安装更新..."
    # 解压到临时目录
    local extract_dir="${tmp_dir}/extract"
    mkdir -p "$extract_dir"
    if ! tar -xzf "$tmp_file" -C "$extract_dir" --strip-components=1; then
        rm -rf "$tmp_dir"
        log_error "解压失败"
        press_any_key
        return
    fi

    # 替换安装目录内容
    rm -rf "${SCRIPT_DIR}/modules"
    cp -af "$extract_dir"/. "$SCRIPT_DIR"/
    rm -rf "$tmp_dir"

    # 记录新版本
    echo "$latest_tag" > "$VERSION_FILE"
    chmod +x "${SCRIPT_DIR}/launch.sh"

    echo ""
    log_info "✓ 脚本已更新到版本 ${latest_tag}！"
    log_info "请重新运行脚本以使更新生效"
    press_any_key
}

# ============================================================
# 主功能菜单
# ============================================================
show_menu() {
    while true; do
        clear
        echo -e "${CYAN}"
        echo "  ============================================================"
        echo "    ███████╗███████╗██████╗ ██╗   ██╗███████╗██████╗ "
        echo "    ██╔════╝██╔════╝██╔══██╗██║   ██║██╔════╝██╔══██╗"
        echo "    ███████╗█████╗  ██████╔╝██║   ██║█████╗  ██████╔╝"
        echo "    ╚════██║██╔══╝  ██╔══██╗╚██╗ ██╔╝██╔══╝  ██╔══██╗"
        echo "    ███████║███████╗██║  ██║ ╚████╔╝ ███████╗██║  ██║"
        echo "    ╚══════╝╚══════╝╚═╝  ╚═╝  ╚═══╝  ╚══════╝╚═╝  ╚═╝"
        echo "    ██████╗ ██████╗ ███████╗                          "
        echo "    ██╔═══██╗██╔══██╗██╔════╝                          "
        echo "    ██║   ██║██████╔╝███████╗                          "
        echo "    ██║   ██║██╔═══╝ ╚════██║                          "
        echo "    ╚██████╔╝██║     ███████║                          "
        echo "     ╚═════╝ ╚═╝     ╚══════╝                          "
        echo "  ============================================================"
        echo -e "${NC}"
        echo -e "  ${BOLD}服务器运维工具集${NC}  |  系统: ${OS_NAME}"
        if [ -n "${MIRROR_URL:-}" ]; then
            echo -e "  ${YELLOW}镜像代理: ${MIRROR_URL}${NC}"
        fi
        echo ""
        print_separator
        echo ""
        echo -e "  ${BOLD}功能菜单:${NC}"
        echo ""
        echo "    1) 🔥 防火墙管理"
        echo "    2) 👤 用户管理"
        echo "    3) 👥 用户组管理"
        echo "    4) 📊 系统信息"
        echo "    5) ⏰ 定时任务管理"
        echo "    6) ⚙️  系统服务管理"
        echo "    7) 🖥️  主机设置 (主机名/时区/NTP/Swap)"
        echo "    8) 🌐 Caddy 管理"
        echo "    9) 🌐 Nginx 管理 (源码编译)"
        echo "   10) 🔑 Sudoer 管理"
        echo "   11) 📋 日志管理"
        echo ""
        echo "   12) 🔄 脚本更新"
        echo "   13) 🌐 镜像代理配置"
        echo ""
        echo "    0) 退出"
        echo ""
        print_separator
        select_option "请选择功能" 13 0

        case "$SELECTED_OPTION" in
            1)
                check_and_install_deps "防火墙管理" "nft:nftables" || continue
                source "${MODULES_DIR}/firewall.sh"
                run_firewall
                ;;
            2)
                source "${MODULES_DIR}/user_mgmt.sh"
                run_user_mgmt
                ;;
            3)
                source "${MODULES_DIR}/group_mgmt.sh"
                run_group_mgmt
                ;;
            4)
                source "${MODULES_DIR}/system_info.sh"
                run_system_info
                ;;
            5)
                check_and_install_deps "定时任务管理" "crontab:cron" || continue
                source "${MODULES_DIR}/cron_mgmt.sh"
                run_cron_mgmt
                ;;
            6)
                source "${MODULES_DIR}/service_mgmt.sh"
                run_service_mgmt
                ;;
            7)
                source "${MODULES_DIR}/host_mgmt.sh"
                run_host_mgmt
                ;;
            8)
                source "${MODULES_DIR}/caddy.sh"
                run_caddy
                ;;
            9)
                source "${MODULES_DIR}/nginx.sh"
                run_nginx
                ;;
            10)
                source "${MODULES_DIR}/sudoer_mgmt.sh"
                run_sudoer_mgmt
                ;;
            11)
                source "${MODULES_DIR}/log_clean.sh"
                run_log_mgmt
                ;;
            12)
                update_scripts
                ;;
            13)
                configure_mirror_interactive
                ;;
            0)
                echo ""
                log_info "感谢使用，再见！"
                echo ""
                exit 0
                ;;
        esac
    done
}

# ============================================================
# 主入口
# ============================================================
main() {
    pre_check

    # 检查是否已初始化
    if [ ! -f "$INIT_MARKER" ]; then
        run_initialization
    fi

    # 显示功能菜单
    show_menu
}

main "$@"
