#!/usr/bin/env bash
# ============================================================
# 主机名与时区管理模块
# - 主机名设置
# - 时区设置
# - NTP 时间同步
# - Swap 管理
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# ============================================================
# 主机名设置
# ============================================================
hostname_setup() {
    print_separator
    echo -e "${BOLD}  主机名设置${NC}"
    print_separator
    echo ""

    log_info "当前主机名: $(hostname)"
    echo ""

    if confirm "是否修改主机名?"; then
        local new_hostname
        read_nonempty "请输入新的主机名" new_hostname
        hostnamectl set-hostname "$new_hostname"
        log_info "主机名已修改为: ${new_hostname}"
        log_warn "注意: 部分服务可能需要重启才能识别新主机名"
    fi
}

# ============================================================
# 时区设置
# ============================================================
timezone_setup() {
    print_separator
    echo -e "${BOLD}  时区设置${NC}"
    print_separator
    echo ""

    log_info "当前时区: $(timedatectl 2>/dev/null | grep 'Time zone' | awk '{print $3}')"
    log_info "当前时间: $(date '+%Y-%m-%d %H:%M:%S %Z')"
    echo ""

    if confirm "是否修改时区?"; then
        echo ""
        echo "常用时区:"
        echo "  1) Asia/Shanghai (中国-上海)"
        echo "  2) Asia/Hong_Kong (中国-香港)"
        echo "  3) Asia/Tokyo (日本-东京)"
        echo "  4) Asia/Singapore (新加坡)"
        echo "  5) America/New_York (美东)"
        echo "  6) America/Los_Angeles (美西)"
        echo "  7) Europe/London (英国-伦敦)"
        echo "  8) Europe/Berlin (德国-柏林)"
        echo "  9) UTC"
        echo " 10) 手动输入"
        select_option "请选择" 10

        local tz=""
        case "$SELECTED_OPTION" in
            1) tz="Asia/Shanghai" ;;
            2) tz="Asia/Hong_Kong" ;;
            3) tz="Asia/Tokyo" ;;
            4) tz="Asia/Singapore" ;;
            5) tz="America/New_York" ;;
            6) tz="America/Los_Angeles" ;;
            7) tz="Europe/London" ;;
            8) tz="Europe/Berlin" ;;
            9) tz="UTC" ;;
            10) read_nonempty "请输入时区 (如: Asia/Shanghai)" tz ;;
        esac

        timedatectl set-timezone "$tz"
        log_info "时区已设置为: ${tz}"
        log_info "当前时间: $(date '+%Y-%m-%d %H:%M:%S %Z')"
    fi
}

# ============================================================
# NTP 时间同步
# ============================================================
ntp_setup() {
    print_separator
    echo -e "${BOLD}  NTP 时间同步${NC}"
    print_separator
    echo ""

    log_info "当前 NTP 状态:"
    timedatectl 2>/dev/null | grep -E 'NTP|synchronized'
    echo ""

    echo "  1) 启用 NTP 自动同步"
    echo "  2) 禁用 NTP 自动同步"
    echo "  3) 立即同步时间"
    echo "  4) 查看详细时间信息"
    echo "  0) 返回"
    select_option "请选择" 4 0

    case "$SELECTED_OPTION" in
        1)
            timedatectl set-ntp true
            log_info "NTP 自动同步已启用"
            ;;
        2)
            timedatectl set-ntp false
            log_info "NTP 自动同步已禁用"
            ;;
        3)
            # 尝试多种同步方式
            if command -v chronyd &>/dev/null; then
                chronyc makestep
            elif command -v ntpdate &>/dev/null; then
                ntpdate pool.ntp.org
            else
                timedatectl set-ntp false
                timedatectl set-ntp true
            fi
            log_info "时间同步完成"
            log_info "当前时间: $(date '+%Y-%m-%d %H:%M:%S %Z')"
            ;;
        4)
            timedatectl 2>/dev/null
            ;;
        0) return 0 ;;
    esac
}

# ============================================================
# Swap 管理
# ============================================================
swap_manage() {
    print_separator
    echo -e "${BOLD}  Swap 管理${NC}"
    print_separator
    echo ""

    log_info "当前 Swap 状态:"
    free -h | grep -E 'Mem|Swap'
    echo ""
    swapon --show 2>/dev/null
    echo ""

    echo "  1) 创建 Swap 文件"
    echo "  2) 关闭 Swap"
    echo "  3) 修改 Swappiness 参数"
    echo "  4) 删除 Swap 文件"
    echo "  0) 返回"
    select_option "请选择" 4 0

    case "$SELECTED_OPTION" in
        1)
            # 检查是否已有 swap
            if swapon --show 2>/dev/null | grep -q "/"; then
                log_warn "已存在 Swap，建议先关闭现有 Swap"
                if ! confirm "是否继续?"; then
                    return
                fi
            fi

            echo ""
            echo "请选择 Swap 大小:"
            echo "  1) 1G"
            echo "  2) 2G"
            echo "  3) 4G"
            echo "  4) 8G"
            echo "  5) 自定义"
            select_option "请选择" 5

            local swap_size=""
            case "$SELECTED_OPTION" in
                1) swap_size="1G" ;;
                2) swap_size="2G" ;;
                3) swap_size="4G" ;;
                4) swap_size="8G" ;;
                5) read_nonempty "请输入大小 (如: 2G)" swap_size ;;
            esac

            local swap_file="/swapfile"
            read_optional "Swap 文件路径" swap_file "/swapfile"

            log_step "正在创建 Swap 文件 (${swap_size})..."
            fallocate -l "$swap_size" "$swap_file" 2>/dev/null || dd if=/dev/zero of="$swap_file" bs=1M count="$(echo "$swap_size" | sed 's/G//' | awk '{print $1 * 1024}')" status=progress
            chmod 600 "$swap_file"
            mkswap "$swap_file"
            swapon "$swap_file"

            # 添加到 fstab
            if ! grep -q "$swap_file" /etc/fstab; then
                echo "${swap_file} none swap sw 0 0" >> /etc/fstab
                log_info "已添加到 /etc/fstab"
            fi

            log_info "Swap 创建完成"
            free -h | grep Swap
            ;;
        2)
            if confirm "确认关闭所有 Swap?"; then
                swapoff -a
                log_info "Swap 已关闭"
            fi
            ;;
        3)
            local current_swappiness
            current_swappiness=$(cat /proc/sys/vm/swappiness)
            log_info "当前 swappiness: ${current_swappiness}"
            echo ""
            echo "推荐值: 服务器建议 10-30，桌面建议 60"
            local new_val
            read_nonempty "请输入新的 swappiness 值 (0-100)" new_val
            sysctl vm.swappiness="$new_val"
            if ! grep -q "vm.swappiness" /etc/sysctl.conf; then
                echo "vm.swappiness=${new_val}" >> /etc/sysctl.conf
            else
                sed -i "s/vm.swappiness=.*/vm.swappiness=${new_val}/" /etc/sysctl.conf
            fi
            log_info "swappiness 已设置为: ${new_val}"
            ;;
        4)
            local del_file
            read_nonempty "请输入要删除的 Swap 文件路径" del_file
            if [ -f "$del_file" ]; then
                swapoff "$del_file" 2>/dev/null
                rm -f "$del_file"
                sed -i "\|${del_file}|d" /etc/fstab
                log_info "Swap 文件已删除: ${del_file}"
            else
                log_error "文件不存在: ${del_file}"
            fi
            ;;
        0) return 0 ;;
    esac
}

# ============================================================
# 入口函数
# ============================================================
run_host_mgmt() {
    while true; do
        print_separator
        echo -e "${BOLD}  主机设置${NC}"
        print_separator
        echo ""
        echo "  1) 主机名设置"
        echo "  2) 时区设置"
        echo "  3) NTP 时间同步"
        echo "  4) Swap 管理"
        echo "  0) 返回上级菜单"
        echo ""
        select_option "请选择" 4 0

        case "$SELECTED_OPTION" in
            1) hostname_setup ;;
            2) timezone_setup ;;
            3) ntp_setup ;;
            4) swap_manage ;;
            0) return 0 ;;
        esac
        press_any_key
    done
}
