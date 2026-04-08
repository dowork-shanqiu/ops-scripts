#!/usr/bin/env bash
# ============================================================
# 日志空间清理模块
# - 日志空间分析
# - journald 日志清理
# - 旧日志文件清理
# - APT 缓存清理
# - 自定义目录清理
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# ============================================================
# 日志空间分析
# ============================================================
log_show_usage() {
    print_separator
    echo -e "${BOLD}  日志空间分析${NC}"
    print_separator
    echo ""

    log_step "系统磁盘使用概况:"
    df -h / | tail -1 | awk '{printf "  根分区: 总 %s，已用 %s，可用 %s (%s)\n", $2, $3, $4, $5}'
    echo ""

    log_step "/var/log 目录总大小:"
    du -sh /var/log 2>/dev/null | awk '{print "  " $0}' || echo "  无法获取"
    echo ""

    log_step "/var/log 中占用最大的文件/目录 (Top 10):"
    print_thin_separator
    du -sh /var/log/* 2>/dev/null | sort -rh | head -10 | awk '{printf "  %-10s  %s\n", $1, $2}'
    print_thin_separator
    echo ""

    log_step "journald 日志大小:"
    journalctl --disk-usage 2>/dev/null | awk '{print "  " $0}' || echo "  无法获取 journald 信息"
    echo ""

    log_step "APT 缓存大小:"
    du -sh /var/cache/apt 2>/dev/null | awk '{print "  " $0}' || echo "  无法获取"
    echo ""

    log_step "旧日志文件统计:"
    local gz_count old_count
    gz_count=$(find /var/log -name "*.gz" 2>/dev/null | wc -l)
    old_count=$(find /var/log -name "*.[0-9]" 2>/dev/null | wc -l)
    echo "  压缩日志 (*.gz):         ${gz_count} 个"
    echo "  轮转日志 (*.[0-9]):      ${old_count} 个"
}

# ============================================================
# journald 日志清理
# ============================================================
log_clean_journal() {
    while true; do
        print_separator
        echo -e "${BOLD}  journald 日志清理${NC}"
        print_separator
        echo ""

        log_info "当前 journald 日志使用量:"
        journalctl --disk-usage 2>/dev/null | awk '{print "  " $0}' || echo "  无法获取"
        echo ""

        echo "  1) 按时间清理 (保留近期日志)"
        echo "  2) 按大小清理 (限制最大占用)"
        echo "  3) 清理所有日志 (⚠️  不可恢复)"
        echo "  0) 返回"
        echo ""
        select_option "请选择" 3 0

        case "$SELECTED_OPTION" in
            1)
                echo ""
                echo "保留最近时间范围:"
                echo "  1) 1 天"
                echo "  2) 3 天"
                echo "  3) 7 天"
                echo "  4) 14 天"
                echo "  5) 30 天"
                echo "  6) 自定义"
                select_option "请选择" 6

                local vacuum_time
                case "$SELECTED_OPTION" in
                    1) vacuum_time="1d" ;;
                    2) vacuum_time="3d" ;;
                    3) vacuum_time="7d" ;;
                    4) vacuum_time="14d" ;;
                    5) vacuum_time="30d" ;;
                    6) read_nonempty "请输入保留时间 (如: 7d / 24h / 2weeks)" vacuum_time ;;
                esac

                if confirm "确认清理超过 ${vacuum_time} 的 journald 日志?"; then
                    journalctl --vacuum-time="$vacuum_time"
                    echo ""
                    log_info "✓ journald 日志清理完成"
                    log_info "清理后使用量:"
                    journalctl --disk-usage 2>/dev/null | awk '{print "  " $0}'
                fi
                ;;
            2)
                echo ""
                echo "保留最大大小:"
                echo "  1) 100M"
                echo "  2) 200M"
                echo "  3) 500M"
                echo "  4) 1G"
                echo "  5) 自定义"
                select_option "请选择" 5

                local vacuum_size
                case "$SELECTED_OPTION" in
                    1) vacuum_size="100M" ;;
                    2) vacuum_size="200M" ;;
                    3) vacuum_size="500M" ;;
                    4) vacuum_size="1G" ;;
                    5) read_nonempty "请输入大小限制 (如: 500M / 1G)" vacuum_size ;;
                esac

                if confirm "确认将 journald 日志限制在 ${vacuum_size} 以内?"; then
                    journalctl --vacuum-size="$vacuum_size"
                    echo ""
                    log_info "✓ journald 日志清理完成"
                    log_info "清理后使用量:"
                    journalctl --disk-usage 2>/dev/null | awk '{print "  " $0}'
                fi
                ;;
            3)
                if confirm "⚠️  确认清理所有 journald 日志? 此操作不可恢复!"; then
                    journalctl --vacuum-time=1s
                    echo ""
                    log_info "✓ journald 日志已全部清理"
                fi
                ;;
            0) return 0 ;;
        esac
        press_any_key
    done
}

# ============================================================
# 旧日志文件清理
# ============================================================
log_clean_old_logs() {
    while true; do
        print_separator
        echo -e "${BOLD}  旧日志文件清理${NC}"
        print_separator
        echo ""

        local gz_count gz_size old_count old_size
        gz_count=$(find /var/log -name "*.gz" 2>/dev/null | wc -l)
        gz_size=$(find /var/log -name "*.gz" 2>/dev/null -exec du -ch {} + 2>/dev/null | tail -1 | cut -f1)
        old_count=$(find /var/log -name "*.[0-9]" 2>/dev/null | wc -l)
        old_size=$(find /var/log -name "*.[0-9]" 2>/dev/null -exec du -ch {} + 2>/dev/null | tail -1 | cut -f1)

        log_info "可清理的旧日志文件:"
        echo "  压缩日志 (*.gz):    ${gz_count} 个，共 ${gz_size:-0}"
        echo "  轮转日志 (*.[0-9]): ${old_count} 个，共 ${old_size:-0}"
        echo ""
        echo "  1) 清理所有压缩日志 (*.gz)"
        echo "  2) 清理所有轮转日志 (*.[0-9])"
        echo "  3) 清理所有旧日志 (以上两类)"
        echo "  4) 按天数清理 (/var/log 中超过 N 天未修改的日志)"
        echo "  0) 返回"
        echo ""
        select_option "请选择" 4 0

        case "$SELECTED_OPTION" in
            1)
                if [ "$gz_count" -eq 0 ]; then
                    log_info "没有压缩日志文件"
                elif confirm "确认删除 ${gz_count} 个压缩日志文件?"; then
                    find /var/log -name "*.gz" -delete 2>/dev/null
                    log_info "✓ 已删除 ${gz_count} 个压缩日志文件"
                fi
                ;;
            2)
                if [ "$old_count" -eq 0 ]; then
                    log_info "没有轮转日志文件"
                elif confirm "确认删除 ${old_count} 个轮转日志文件?"; then
                    find /var/log -name "*.[0-9]" -delete 2>/dev/null
                    log_info "✓ 已删除 ${old_count} 个轮转日志文件"
                fi
                ;;
            3)
                local total_count=$(( gz_count + old_count ))
                if [ "$total_count" -eq 0 ]; then
                    log_info "没有旧日志文件需要清理"
                elif confirm "确认删除全部 ${total_count} 个旧日志文件?"; then
                    find /var/log -name "*.gz" -delete 2>/dev/null
                    find /var/log -name "*.[0-9]" -delete 2>/dev/null
                    log_info "✓ 已删除 ${total_count} 个旧日志文件"
                fi
                ;;
            4)
                local days
                read_nonempty "请输入天数 (清理 /var/log 中超过 N 天未修改的日志文件)" days
                if ! [[ "$days" =~ ^[0-9]+$ ]] || [ "$days" -lt 1 ]; then
                    log_error "无效的天数"
                else
                    local count
                    count=$(find /var/log \( -name "*.log" -o -name "*.gz" \) -mtime +"$days" 2>/dev/null | wc -l)
                    if [ "$count" -eq 0 ]; then
                        log_info "没有超过 ${days} 天的日志文件"
                    elif confirm "确认删除 ${count} 个超过 ${days} 天的日志文件?"; then
                        find /var/log \( -name "*.log" -o -name "*.gz" \) -mtime +"$days" -delete 2>/dev/null
                        log_info "✓ 已清理超过 ${days} 天的日志文件"
                    fi
                fi
                ;;
            0) return 0 ;;
        esac
        press_any_key
    done
}

# ============================================================
# APT 缓存清理
# ============================================================
log_clean_apt_cache() {
    while true; do
        print_separator
        echo -e "${BOLD}  APT 缓存清理${NC}"
        print_separator
        echo ""

        log_info "APT 缓存使用量:"
        du -sh /var/cache/apt 2>/dev/null | awk '{print "  " $0}' || echo "  无法获取"
        echo ""
        echo "  1) 清理过期软件包缓存 (apt autoclean)"
        echo "  2) 清理所有软件包缓存 (apt clean)"
        echo "  3) 删除不再需要的依赖包 (apt autoremove)"
        echo "  4) 全面清理 (以上全部)"
        echo "  0) 返回"
        echo ""
        select_option "请选择" 4 0

        case "$SELECTED_OPTION" in
            1)
                apt autoclean -y
                log_info "✓ APT 过期缓存已清理"
                ;;
            2)
                local cache_size
                cache_size=$(du -sh /var/cache/apt/archives 2>/dev/null | cut -f1)
                if confirm "确认清理所有 APT 缓存 (${cache_size:-未知大小})?"; then
                    apt clean
                    log_info "✓ APT 缓存已全部清理"
                fi
                ;;
            3)
                log_info "不再需要的依赖包预览:"
                apt-get autoremove --dry-run 2>/dev/null | grep "^Remv" | head -20 | awk '{print "  " $0}'
                if confirm "确认删除以上不再需要的依赖包?"; then
                    apt autoremove -y
                    log_info "✓ 不再需要的依赖包已删除"
                fi
                ;;
            4)
                if confirm "确认执行全面 APT 缓存清理?"; then
                    apt autoclean -y
                    apt clean
                    apt autoremove -y
                    log_info "✓ APT 缓存全面清理完成"
                fi
                ;;
            0) return 0 ;;
        esac
        echo ""
        log_info "清理后 APT 缓存:"
        du -sh /var/cache/apt 2>/dev/null | awk '{print "  " $0}'
        press_any_key
    done
}

# ============================================================
# 自定义目录清理
# ============================================================
log_clean_custom() {
    print_separator
    echo -e "${BOLD}  自定义目录清理${NC}"
    print_separator
    echo ""

    local target_dir
    read_nonempty "请输入要清理的目录路径 (如: /var/log/nginx)" target_dir

    if [ ! -d "$target_dir" ]; then
        log_error "目录不存在: ${target_dir}"
        return 1
    fi

    log_info "目录大小: $(du -sh "$target_dir" 2>/dev/null | cut -f1)"
    echo ""
    echo "  1) 清理压缩日志 (*.gz)"
    echo "  2) 清理轮转日志 (*.[0-9])"
    echo "  3) 清理超过 N 天未修改的文件"
    echo "  4) 清理所有旧日志 (保留 *.log 当前文件)"
    echo "  0) 返回"
    select_option "请选择" 4 0

    case "$SELECTED_OPTION" in
        1)
            local count
            count=$(find "$target_dir" -name "*.gz" 2>/dev/null | wc -l)
            if [ "$count" -eq 0 ]; then
                log_info "没有压缩日志文件"
            elif confirm "确认删除 ${target_dir} 中 ${count} 个压缩日志文件?"; then
                find "$target_dir" -name "*.gz" -delete 2>/dev/null
                log_info "✓ 已清理压缩日志"
            fi
            ;;
        2)
            local count
            count=$(find "$target_dir" -name "*.[0-9]" 2>/dev/null | wc -l)
            if [ "$count" -eq 0 ]; then
                log_info "没有轮转日志文件"
            elif confirm "确认删除 ${target_dir} 中 ${count} 个轮转日志文件?"; then
                find "$target_dir" -name "*.[0-9]" -delete 2>/dev/null
                log_info "✓ 已清理轮转日志"
            fi
            ;;
        3)
            local days
            read_nonempty "请输入天数" days
            if ! [[ "$days" =~ ^[0-9]+$ ]] || [ "$days" -lt 1 ]; then
                log_error "无效的天数"
                return 1
            fi
            local count
            count=$(find "$target_dir" -mtime +"$days" -type f 2>/dev/null | wc -l)
            if [ "$count" -eq 0 ]; then
                log_info "没有超过 ${days} 天未修改的文件"
            elif confirm "确认删除 ${target_dir} 中超过 ${days} 天的 ${count} 个文件?"; then
                find "$target_dir" -mtime +"$days" -type f -delete 2>/dev/null
                log_info "✓ 已清理超过 ${days} 天的文件"
            fi
            ;;
        4)
            log_warn "将删除 ${target_dir} 下所有 *.gz 和 *.[0-9] 旧日志，保留当前 *.log 文件"
            if confirm "确认执行?"; then
                find "$target_dir" -name "*.gz" -delete 2>/dev/null
                find "$target_dir" -name "*.[0-9]" -delete 2>/dev/null
                log_info "✓ 旧日志文件已清理"
            fi
            ;;
        0) return 0 ;;
    esac

    echo ""
    log_info "清理后目录大小: $(du -sh "$target_dir" 2>/dev/null | cut -f1)"
}

# ============================================================
# 入口函数
# ============================================================
run_log_clean() {
    while true; do
        print_separator
        echo -e "${BOLD}  日志空间清理${NC}"
        print_separator
        echo ""
        echo "  1) 日志空间分析"
        echo "  2) journald 日志清理"
        echo "  3) 旧日志文件清理 (*.gz / *.1 等)"
        echo "  4) APT 缓存清理"
        echo "  5) 自定义目录清理"
        echo "  0) 返回上级菜单"
        echo ""
        select_option "请选择" 5 0

        case "$SELECTED_OPTION" in
            1) log_show_usage ;;
            2) log_clean_journal ;;
            3) log_clean_old_logs ;;
            4) log_clean_apt_cache ;;
            5) log_clean_custom ;;
            0) return 0 ;;
        esac
        press_any_key
    done
}
