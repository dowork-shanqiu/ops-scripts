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

# ---------- 获取脚本所在目录 ----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULES_DIR="${SCRIPT_DIR}/modules"

# ---------- 加载公共模块 ----------
source "${MODULES_DIR}/common.sh"

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
REPO_URL="https://github.com/dowork-shanqiu/ops-scripts.git"
MIRROR_REPO_URL="https://ghproxy.cn/https://github.com/dowork-shanqiu/ops-scripts.git"

update_scripts() {
    print_separator
    echo -e "  ${BOLD}脚本更新${NC}"
    print_separator
    echo ""

    # 检查是否通过 git 安装
    if [ ! -d "${SCRIPT_DIR}/.git" ]; then
        log_error "当前安装不支持更新（未检测到 Git 仓库）"
        log_info "请使用以下命令重新安装："
        echo ""
        echo "  curl -fsSL https://raw.githubusercontent.com/dowork-shanqiu/ops-scripts/main/install.sh | sudo bash"
        echo ""
        press_any_key
        return
    fi

    # 检查 git 命令
    if ! command -v git &>/dev/null; then
        log_error "未找到 git 命令，无法更新"
        press_any_key
        return
    fi

    if ! confirm "是否更新脚本到最新版本?"; then
        return
    fi

    echo ""
    log_info "检测网络环境..."
    local origin_url="$REPO_URL"
    if is_china_network; then
        log_info "检测到中国大陆网络，使用镜像加速"
        origin_url="$MIRROR_REPO_URL"
    fi

    log_info "正在更新..."
    cd "$SCRIPT_DIR"
    git remote set-url origin "$origin_url"
    if git fetch origin main && git reset --hard origin/main; then
        echo ""
        log_info "✓ 脚本更新完成！"
        log_info "部分更新可能需要重新运行脚本才能生效"
    else
        echo ""
        log_error "更新失败，请检查网络连接"
    fi

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
        echo ""
        echo "   11) 🔄 脚本更新"
        echo ""
        echo "    0) 退出"
        echo ""
        print_separator
        select_option "请选择功能" 11 0

        case "$SELECTED_OPTION" in
            1)
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
                update_scripts
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
