#!/usr/bin/env bash
# ============================================================
# 主机名与时区管理模块
# - 主机名设置
# - 时区设置
# - NTP 时间同步
# - Swap 管理
# ============================================================

HOST_MGMT_MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${HOST_MGMT_MODULE_DIR}/common.sh"

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

    log_info "当前时区: $(timedatectl 2>/dev/null | awk '/Time zone/ {print $3; exit}' || true)"
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
    timedatectl 2>/dev/null | grep -E 'NTP|synchronized' || true
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

            if [[ ! "$swap_size" =~ ^[1-9][0-9]*[MmGg]$ ]]; then
                log_error "不支持的大小格式，请使用正整数加 G 或 M（如: 2G, 512M）"
                return 1
            fi
            if [[ "$swap_file" != /* || "$swap_file" =~ [[:space:]\\#] ]] || [ -e "$swap_file" ]; then
                log_error "Swap 路径必须是尚不存在、且不含空白、反斜杠或 # 的绝对路径"
                return 1
            fi
            if [ ! -d "$(dirname "$swap_file")" ]; then
                log_error "Swap 文件的父目录不存在"
                return 1
            fi

            if ! confirm "确认创建并启用 Swap 文件 ${swap_file} (${swap_size})?"; then
                return 0
            fi

            log_step "正在创建 Swap 文件 (${swap_size})..."
            if ! fallocate -l "$swap_size" "$swap_file" 2>/dev/null; then
                # fallocate 失败时使用 dd，支持 G 和 M 单位
                local dd_count
                if echo "$swap_size" | grep -qiE '^[0-9]+G$'; then
                    dd_count=$(echo "$swap_size" | sed 's/[Gg]//' | awk '{print $1 * 1024}')
                elif echo "$swap_size" | grep -qiE '^[0-9]+M$'; then
                    dd_count=$(echo "$swap_size" | sed 's/[Mm]//')
                fi
                if ! dd if=/dev/zero of="$swap_file" bs=1M count="$dd_count" status=progress; then
                    rm -f -- "$swap_file"
                    log_error "Swap 文件创建失败"
                    return 1
                fi
            fi
            if ! chmod 600 "$swap_file" || ! mkswap "$swap_file" || ! swapon "$swap_file"; then
                swapoff "$swap_file" 2>/dev/null || true
                rm -f -- "$swap_file"
                log_error "Swap 初始化或启用失败，已清理本次创建的文件"
                return 1
            fi

            # 添加到 fstab
            if ! awk -v target="$swap_file" '$1 == target { found=1 } END { exit !found }' /etc/fstab; then
                local fstab_create_tmp
                fstab_create_tmp=$(mktemp /etc/.fstab.ops.XXXXXX) || {
                    swapoff "$swap_file" 2>/dev/null || true
                    rm -f -- "$swap_file"
                    return 1
                }
                if ! cp -p /etc/fstab "$fstab_create_tmp" ||
                   ! printf '%s none swap sw 0 0\n' "$swap_file" >> "$fstab_create_tmp" ||
                   ! mv -f "$fstab_create_tmp" /etc/fstab; then
                    rm -f "$fstab_create_tmp"
                    swapoff "$swap_file" 2>/dev/null || true
                    rm -f -- "$swap_file"
                    log_error "写入 /etc/fstab 失败，已回滚本次创建"
                    return 1
                fi
                log_info "已添加到 /etc/fstab"
            fi

            log_info "Swap 创建完成"
            free -h | grep Swap || true
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
            if ! validate_nonnegative_integer "$new_val" || [ "$new_val" -gt 100 ]; then
                log_error "swappiness 必须是 0-100 的整数"
                return 1
            fi
            local sysctl_backup sysctl_candidate
            sysctl_backup=$(mktemp /etc/.sysctl.conf.ops-backup.XXXXXX) || return 1
            sysctl_candidate=$(mktemp /etc/.sysctl.conf.ops.XXXXXX) || {
                rm -f "$sysctl_backup"
                return 1
            }
            if ! cp -p /etc/sysctl.conf "$sysctl_backup" ||
               ! cp -p /etc/sysctl.conf "$sysctl_candidate"; then
                rm -f "$sysctl_backup" "$sysctl_candidate"
                log_error "无法准备 sysctl 配置候选文件"
                return 1
            fi
            if grep -qE '^[[:space:]]*vm\.swappiness[[:space:]]*=' "$sysctl_candidate"; then
                sed -i -E "s|^[[:space:]]*vm\.swappiness[[:space:]]*=.*|vm.swappiness=${new_val}|" "$sysctl_candidate"
            else
                printf 'vm.swappiness=%s\n' "$new_val" >> "$sysctl_candidate"
            fi
            if ! mv -f "$sysctl_candidate" /etc/sysctl.conf; then
                rm -f "$sysctl_backup" "$sysctl_candidate"
                log_error "持久化 swappiness 配置失败，原配置已保留"
                return 1
            fi
            if ! sysctl vm.swappiness="$new_val"; then
                mv -f "$sysctl_backup" /etc/sysctl.conf || log_error "恢复 /etc/sysctl.conf 失败"
                sysctl vm.swappiness="$current_swappiness" >/dev/null 2>&1 || true
                log_error "swappiness 应用失败，已尝试恢复配置和运行时值"
                return 1
            fi
            rm -f "$sysctl_backup"
            log_info "swappiness 已设置为: ${new_val}"
            ;;
        4)
            local del_file
            read_nonempty "请输入要删除的 Swap 文件路径" del_file
            if [[ "$del_file" != /* || "$del_file" =~ [[:space:]\\#] ]] || [ ! -f "$del_file" ] || [ -L "$del_file" ]; then
                log_error "文件不存在: ${del_file}"
                return 1
            fi
            if ! swapon --show=NAME --noheadings --raw 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -Fxq -- "$del_file"; then
                log_error "拒绝删除：该文件不是当前活动的 Swap"
                return 1
            fi
            log_warn "即将关闭并永久删除活动 Swap 文件: ${del_file}"
            if ! confirm "确认删除此 Swap 文件?"; then
                return 0
            fi
            if ! swapoff "$del_file"; then
                log_error "关闭 Swap 失败，未删除文件"
                return 1
            fi
            local fstab_tmp
            local fstab_backup
            fstab_tmp=$(mktemp /etc/.fstab.ops.XXXXXX) || {
                swapon "$del_file" 2>/dev/null || true
                return 1
            }
            fstab_backup=$(mktemp /etc/.fstab.ops-backup.XXXXXX) || {
                rm -f "$fstab_tmp"
                swapon "$del_file" 2>/dev/null || true
                return 1
            }
            if ! cp -p /etc/fstab "$fstab_backup" ||
               ! awk -v target="$del_file" '$1 != target' /etc/fstab > "$fstab_tmp" ||
               ! chmod --reference=/etc/fstab "$fstab_tmp" ||
               ! chown --reference=/etc/fstab "$fstab_tmp" ||
               ! mv -f "$fstab_tmp" /etc/fstab; then
                rm -f "$fstab_tmp" "$fstab_backup"
                swapon "$del_file" 2>/dev/null || true
                log_error "更新 /etc/fstab 失败，已尝试重新启用 Swap"
                return 1
            fi
            if ! rm -f -- "$del_file"; then
                mv -f "$fstab_backup" /etc/fstab || log_error "恢复 /etc/fstab 失败"
                swapon "$del_file" 2>/dev/null || true
                log_error "Swap 文件删除失败，已恢复持久化配置并尝试重新启用"
                return 1
            fi
            rm -f "$fstab_backup"
            log_info "Swap 文件已删除: ${del_file}"
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
