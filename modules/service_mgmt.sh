#!/usr/bin/env bash
# ============================================================
# 系统服务管理模块
# - 查看服务状态
# - 启动/停止/重启服务
# - 启用/禁用服务开机自启
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# ============================================================
# 查看服务列表
# ============================================================
service_list() {
    print_separator
    echo -e "${BOLD}  服务列表${NC}"
    print_separator
    echo ""

    echo "请选择查看范围:"
    echo "  1) 运行中的服务"
    echo "  2) 所有服务"
    echo "  3) 已启用开机自启的服务"
    echo "  4) 失败的服务"
    select_option "请选择" 4

    echo ""
    print_thin_separator

    case "$SELECTED_OPTION" in
        1) systemctl list-units --type=service --state=running --no-pager ;;
        2) systemctl list-units --type=service --all --no-pager ;;
        3) systemctl list-unit-files --type=service --state=enabled --no-pager ;;
        4) systemctl list-units --type=service --state=failed --no-pager ;;
    esac

    print_thin_separator
}

# ============================================================
# 服务操作
# ============================================================
service_operate() {
    print_separator
    echo -e "${BOLD}  服务操作${NC}"
    print_separator
    echo ""

    local service_name
    read_nonempty "请输入服务名称" service_name

    # 检查服务是否存在
    if ! systemctl cat "$service_name" &>/dev/null; then
        log_error "服务 '${service_name}' 不存在"
        return 1
    fi

    # 显示当前状态
    echo ""
    log_info "服务 '${service_name}' 当前状态:"
    print_thin_separator
    systemctl status "$service_name" --no-pager 2>/dev/null
    print_thin_separator

    echo ""
    echo "请选择操作:"
    echo "  1) 启动服务"
    echo "  2) 停止服务"
    echo "  3) 重启服务"
    echo "  4) 重载配置"
    echo "  5) 启用开机自启"
    echo "  6) 禁用开机自启"
    echo "  7) 查看服务日志"
    echo "  0) 返回"
    select_option "请选择" 7 0

    case "$SELECTED_OPTION" in
        1)
            systemctl start "$service_name"
            log_info "服务已启动"
            ;;
        2)
            if confirm "确认停止服务 '${service_name}'?"; then
                systemctl stop "$service_name"
                log_info "服务已停止"
            fi
            ;;
        3)
            systemctl restart "$service_name"
            log_info "服务已重启"
            ;;
        4)
            systemctl reload "$service_name" 2>/dev/null
            if [ $? -eq 0 ]; then
                log_info "配置已重载"
            else
                log_warn "此服务不支持 reload，尝试重启..."
                systemctl restart "$service_name"
            fi
            ;;
        5)
            systemctl enable "$service_name"
            log_info "已启用开机自启"
            ;;
        6)
            systemctl disable "$service_name"
            log_info "已禁用开机自启"
            ;;
        7)
            echo ""
            echo "日志范围:"
            echo "  1) 最近 50 行"
            echo "  2) 最近 100 行"
            echo "  3) 今天的日志"
            echo "  4) 实时跟踪 (Ctrl+C 退出)"
            select_option "请选择" 4
            case "$SELECTED_OPTION" in
                1) journalctl -u "$service_name" -n 50 --no-pager ;;
                2) journalctl -u "$service_name" -n 100 --no-pager ;;
                3) journalctl -u "$service_name" --since today --no-pager ;;
                4) journalctl -u "$service_name" -f ;;
            esac
            ;;
        0) return 0 ;;
    esac

    # 显示操作后状态
    echo ""
    systemctl status "$service_name" --no-pager 2>/dev/null | head -5
}

# ============================================================
# 入口函数
# ============================================================
run_service_mgmt() {
    while true; do
        print_separator
        echo -e "${BOLD}  系统服务管理${NC}"
        print_separator
        echo ""
        echo "  1) 查看服务列表"
        echo "  2) 服务操作 (启动/停止/重启...)"
        echo "  0) 返回上级菜单"
        echo ""
        select_option "请选择" 2 0

        case "$SELECTED_OPTION" in
            1) service_list ;;
            2) service_operate ;;
            0) return 0 ;;
        esac
        press_any_key
    done
}
