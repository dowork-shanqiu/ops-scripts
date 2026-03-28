#!/usr/bin/env bash
# ============================================================
# 定时任务管理模块 (cron)
# - 查看定时任务
# - 添加定时任务
# - 删除定时任务
# - 编辑定时任务
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# ============================================================
# 查看定时任务
# ============================================================
cron_list() {
    print_separator
    echo -e "${BOLD}  定时任务列表${NC}"
    print_separator
    echo ""

    echo "请选择查看范围:"
    echo "  1) 当前用户 (root) 的定时任务"
    echo "  2) 指定用户的定时任务"
    echo "  3) 系统级定时任务 (/etc/crontab)"
    echo "  4) 所有定时任务"
    select_option "请选择" 4

    echo ""

    case "$SELECTED_OPTION" in
        1)
            log_step "root 用户的定时任务:"
            print_thin_separator
            crontab -l 2>/dev/null || echo "  没有定时任务"
            print_thin_separator
            ;;
        2)
            local username
            read_nonempty "请输入用户名" username
            log_step "${username} 的定时任务:"
            print_thin_separator
            crontab -u "$username" -l 2>/dev/null || echo "  没有定时任务"
            print_thin_separator
            ;;
        3)
            log_step "系统级定时任务:"
            print_thin_separator
            cat /etc/crontab 2>/dev/null
            print_thin_separator
            echo ""
            log_step "/etc/cron.d/ 目录:"
            ls -la /etc/cron.d/ 2>/dev/null
            ;;
        4)
            log_step "root 用户定时任务:"
            print_thin_separator
            crontab -l 2>/dev/null || echo "  没有定时任务"
            print_thin_separator
            echo ""
            log_step "系统级定时任务 (/etc/crontab):"
            print_thin_separator
            cat /etc/crontab 2>/dev/null
            print_thin_separator
            echo ""
            log_step "/etc/cron.d/ 目录:"
            ls -la /etc/cron.d/ 2>/dev/null
            echo ""
            log_step "各周期目录:"
            for dir in /etc/cron.hourly /etc/cron.daily /etc/cron.weekly /etc/cron.monthly; do
                if [ -d "$dir" ]; then
                    echo "  ${dir}:"
                    ls "$dir" 2>/dev/null | sed 's/^/    /'
                fi
            done
            ;;
    esac
}

# ============================================================
# 添加定时任务
# ============================================================
cron_add() {
    print_separator
    echo -e "${BOLD}  添加定时任务${NC}"
    print_separator
    echo ""

    echo "请选择添加方式:"
    echo "  1) 使用预设模板"
    echo "  2) 手动输入 cron 表达式"
    select_option "请选择" 2

    local cron_expr=""

    if [ "$SELECTED_OPTION" -eq 1 ]; then
        echo ""
        echo "预设模板:"
        echo "  1) 每分钟执行"
        echo "  2) 每 5 分钟执行"
        echo "  3) 每 10 分钟执行"
        echo "  4) 每 30 分钟执行"
        echo "  5) 每小时执行"
        echo "  6) 每天凌晨执行"
        echo "  7) 每天指定时间执行"
        echo "  8) 每周一执行"
        echo "  9) 每月 1 号执行"
        echo " 10) 每周日凌晨执行"
        select_option "请选择" 10

        case "$SELECTED_OPTION" in
            1)  cron_expr="* * * * *" ;;
            2)  cron_expr="*/5 * * * *" ;;
            3)  cron_expr="*/10 * * * *" ;;
            4)  cron_expr="*/30 * * * *" ;;
            5)  cron_expr="0 * * * *" ;;
            6)  cron_expr="0 0 * * *" ;;
            7)
                local hour minute
                read_nonempty "请输入小时 (0-23)" hour
                read_nonempty "请输入分钟 (0-59)" minute
                cron_expr="${minute} ${hour} * * *"
                ;;
            8)  cron_expr="0 0 * * 1" ;;
            9)  cron_expr="0 0 1 * *" ;;
            10) cron_expr="0 0 * * 0" ;;
        esac
    else
        echo ""
        log_info "Cron 表达式格式: 分 时 日 月 周"
        log_info "示例: */5 * * * * (每5分钟)"
        read_nonempty "请输入 cron 表达式" cron_expr
    fi

    # 输入要执行的命令
    echo ""
    local cron_cmd
    read_nonempty "请输入要执行的命令" cron_cmd

    # 是否添加输出重定向
    echo ""
    echo "输出处理:"
    echo "  1) 丢弃所有输出"
    echo "  2) 输出到指定日志文件"
    echo "  3) 不处理（默认邮件通知）"
    select_option "请选择" 3

    case "$SELECTED_OPTION" in
        1) cron_cmd="${cron_cmd} > /dev/null 2>&1" ;;
        2)
            local logfile
            read_nonempty "请输入日志文件路径" logfile
            cron_cmd="${cron_cmd} >> ${logfile} 2>&1"
            ;;
        3) ;;
    esac

    # 可选添加注释
    local comment=""
    read_optional "添加注释说明" comment ""

    # 选择用户
    echo ""
    local target_user="root"
    if confirm "是否为其他用户添加? (默认 root)"; then
        read_nonempty "请输入用户名" target_user
    fi

    # 确认并添加
    local full_entry="${cron_expr} ${cron_cmd}"
    echo ""
    print_thin_separator
    if [ -n "$comment" ]; then
        log_info "注释: ${comment}"
    fi
    log_info "定时任务: ${full_entry}"
    log_info "用户: ${target_user}"
    print_thin_separator

    if confirm "确认添加此定时任务?"; then
        local tmpfile
        tmpfile=$(mktemp)
        crontab -u "$target_user" -l 2>/dev/null > "$tmpfile"
        if [ -n "$comment" ]; then
            echo "# ${comment}" >> "$tmpfile"
        fi
        echo "$full_entry" >> "$tmpfile"
        crontab -u "$target_user" "$tmpfile"
        rm -f "$tmpfile"

        if [ $? -eq 0 ]; then
            log_info "定时任务添加成功"
        else
            log_error "定时任务添加失败"
        fi
    else
        log_info "已取消添加"
    fi
}

# ============================================================
# 删除定时任务
# ============================================================
cron_delete() {
    print_separator
    echo -e "${BOLD}  删除定时任务${NC}"
    print_separator
    echo ""

    local target_user="root"
    if confirm "是否操作其他用户的定时任务? (默认 root)"; then
        read_nonempty "请输入用户名" target_user
    fi

    local current_cron
    current_cron=$(crontab -u "$target_user" -l 2>/dev/null)

    if [ -z "$current_cron" ]; then
        log_warn "用户 '${target_user}' 没有定时任务"
        return 0
    fi

    echo ""
    log_info "当前定时任务:"
    print_thin_separator
    echo "$current_cron" | cat -n
    print_thin_separator

    echo ""
    echo "请选择操作:"
    echo "  1) 删除指定行"
    echo "  2) 清空所有定时任务"
    echo "  0) 取消"
    select_option "请选择" 2 0

    case "$SELECTED_OPTION" in
        1)
            local line_num
            read_nonempty "请输入要删除的行号" line_num
            if [[ "$line_num" =~ ^[0-9]+$ ]]; then
                local tmpfile
                tmpfile=$(mktemp)
                echo "$current_cron" | sed "${line_num}d" > "$tmpfile"
                crontab -u "$target_user" "$tmpfile"
                rm -f "$tmpfile"
                log_info "定时任务已删除"
            else
                log_error "无效的行号"
            fi
            ;;
        2)
            if confirm "确认清空用户 '${target_user}' 的所有定时任务?"; then
                crontab -u "$target_user" -r
                log_info "所有定时任务已清空"
            fi
            ;;
        0)
            log_info "已取消"
            ;;
    esac
}

# ============================================================
# 编辑定时任务
# ============================================================
cron_edit() {
    local target_user="root"
    if confirm "是否编辑其他用户的定时任务? (默认 root)"; then
        read_nonempty "请输入用户名" target_user
    fi

    log_info "正在打开编辑器..."
    EDITOR="${EDITOR:-vim}" crontab -u "$target_user" -e
}

# ============================================================
# 入口函数
# ============================================================
run_cron_mgmt() {
    while true; do
        print_separator
        echo -e "${BOLD}  定时任务管理${NC}"
        print_separator
        echo ""
        echo "  1) 查看定时任务"
        echo "  2) 添加定时任务"
        echo "  3) 删除定时任务"
        echo "  4) 编辑定时任务 (打开编辑器)"
        echo "  0) 返回上级菜单"
        echo ""
        select_option "请选择" 4 0

        case "$SELECTED_OPTION" in
            1) cron_list ;;
            2) cron_add ;;
            3) cron_delete ;;
            4) cron_edit ;;
            0) return 0 ;;
        esac
        press_any_key
    done
}
