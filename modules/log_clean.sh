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
# 日志清理入口函数（作为日志管理的二级菜单）
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

# ============================================================
# 日志轮转管理
# ============================================================

# ---------- 查看轮转状态 ----------
logrotate_show_status() {
    print_separator
    echo -e "${BOLD}  日志轮转状态${NC}"
    print_separator
    echo ""

    log_step "logrotate 主配置文件 (/etc/logrotate.conf):"
    if [ -f /etc/logrotate.conf ]; then
        grep -v '^#' /etc/logrotate.conf | grep -v '^$' | head -20 | awk '{print "  " $0}'
    else
        log_warn "未找到 /etc/logrotate.conf"
    fi
    echo ""

    log_step "/etc/logrotate.d/ 中的服务配置 (共 $(ls /etc/logrotate.d/ 2>/dev/null | wc -l) 个):"
    print_thin_separator
    if [ -d /etc/logrotate.d ]; then
        ls -1 /etc/logrotate.d/ 2>/dev/null | awk '{print "  " $0}'
    fi
    print_thin_separator
    echo ""

    log_step "上次轮转记录 (/var/lib/logrotate/status):"
    if [ -f /var/lib/logrotate/status ]; then
        local total
        total=$(wc -l < /var/lib/logrotate/status)
        echo "  (共 $((total - 1)) 条记录，显示最近 20 条)"
        print_thin_separator
        tail -20 /var/lib/logrotate/status | awk '{print "  " $0}'
    else
        log_warn "状态文件不存在: /var/lib/logrotate/status"
    fi
    echo ""
}

# ---------- 立即执行日志轮转 ----------
logrotate_run_now() {
    while true; do
        print_separator
        echo -e "${BOLD}  立即执行日志轮转${NC}"
        print_separator
        echo ""
        echo "  1) 执行所有轮转规则 (按时间条件)"
        echo "  2) 强制执行所有轮转规则 (忽略时间条件)"
        echo "  3) 对指定配置文件执行轮转"
        echo "  4) 模拟运行 (不实际执行，仅查看效果)"
        echo "  0) 返回"
        echo ""
        select_option "请选择" 4 0

        case "$SELECTED_OPTION" in
            1)
                if confirm "确认执行所有日志轮转?"; then
                    log_info "正在执行日志轮转..."
                    logrotate /etc/logrotate.conf 2>&1 | awk '{print "  " $0}'
                    echo ""
                    log_info "✓ 日志轮转执行完成"
                fi
                ;;
            2)
                log_warn "强制执行将忽略时间条件，对所有日志立即进行轮转"
                if confirm "确认强制执行所有日志轮转?"; then
                    log_info "正在强制执行日志轮转..."
                    logrotate -f /etc/logrotate.conf 2>&1 | awk '{print "  " $0}'
                    echo ""
                    log_info "✓ 强制日志轮转执行完成"
                fi
                ;;
            3)
                echo ""
                echo "  可用配置文件:"
                ls -1 /etc/logrotate.d/ 2>/dev/null | nl -ba | awk '{print "  " $0}'
                echo ""
                local conf_name
                read_nonempty "请输入配置文件名称 (位于 /etc/logrotate.d/)" conf_name
                local conf_path="/etc/logrotate.d/${conf_name}"
                if [ ! -f "$conf_path" ]; then
                    log_error "配置文件不存在: ${conf_path}"
                else
                    echo ""
                    echo "  1) 正常执行"
                    echo "  2) 强制执行"
                    select_option "请选择" 2
                    if [ "$SELECTED_OPTION" -eq 1 ]; then
                        logrotate "$conf_path" 2>&1 | awk '{print "  " $0}'
                    else
                        logrotate -f "$conf_path" 2>&1 | awk '{print "  " $0}'
                    fi
                    echo ""
                    log_info "✓ 执行完成"
                fi
                ;;
            4)
                log_info "模拟运行所有轮转规则 (dry-run):"
                echo ""
                logrotate -d /etc/logrotate.conf 2>&1 | awk '{print "  " $0}'
                ;;
            0) return 0 ;;
        esac
        press_any_key
    done
}

# ---------- 查看轮转配置文件内容 ----------
logrotate_view_config() {
    while true; do
        print_separator
        echo -e "${BOLD}  查看轮转配置${NC}"
        print_separator
        echo ""
        echo "  1) 查看主配置 (/etc/logrotate.conf)"
        echo "  2) 查看 /etc/logrotate.d/ 中的配置文件"
        echo "  0) 返回"
        echo ""
        select_option "请选择" 2 0

        case "$SELECTED_OPTION" in
            1)
                print_separator
                echo -e "${BOLD}  /etc/logrotate.conf${NC}"
                print_separator
                echo ""
                cat /etc/logrotate.conf 2>/dev/null | awk '{print "  " $0}' || log_warn "文件不存在"
                ;;
            2)
                echo ""
                echo "  /etc/logrotate.d/ 中的配置文件:"
                print_thin_separator
                local files=()
                while IFS= read -r f; do
                    files+=("$f")
                done < <(ls -1 /etc/logrotate.d/ 2>/dev/null)

                if [ ${#files[@]} -eq 0 ]; then
                    log_warn "目录为空"
                    press_any_key
                    continue
                fi

                local idx=1
                for f in "${files[@]}"; do
                    printf "  %3d) %s\n" "$idx" "$f"
                    (( idx++ )) || true
                done
                print_thin_separator
                echo ""
                local choice
                read -r -p "$(echo -e "${CYAN}请输入文件序号 [1-${#files[@]}] (回车返回): ${NC}")" choice
                if [ -z "$choice" ]; then
                    continue
                fi
                if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#files[@]}" ]; then
                    local selected="${files[$((choice - 1))]}"
                    echo ""
                    print_thin_separator
                    echo -e "  ${BOLD}/etc/logrotate.d/${selected}${NC}"
                    print_thin_separator
                    cat "/etc/logrotate.d/${selected}" 2>/dev/null | awk '{print "  " $0}'
                else
                    log_warn "无效的序号"
                fi
                ;;
            0) return 0 ;;
        esac
        press_any_key
    done
}

# ---------- 添加自定义轮转配置 ----------
logrotate_add_config() {
    print_separator
    echo -e "${BOLD}  添加自定义日志轮转配置${NC}"
    print_separator
    echo ""

    local conf_name
    read_nonempty "请输入配置名称 (将保存为 /etc/logrotate.d/<名称>)" conf_name
    # Sanitize name: must start with alphanumeric, only allow alphanumeric, dash, underscore
    if ! echo "$conf_name" | grep -qE '^[a-zA-Z0-9][a-zA-Z0-9_-]*$'; then
        log_error "名称必须以字母或数字开头，且只能包含字母、数字、连字符和下划线"
        return 1
    fi

    local conf_path="/etc/logrotate.d/${conf_name}"
    if [ -f "$conf_path" ]; then
        log_warn "配置文件已存在: ${conf_path}"
        if ! confirm "是否覆盖?"; then
            return 0
        fi
    fi

    echo ""
    local log_path
    read_nonempty "请输入要轮转的日志文件路径 (支持通配符，如 /var/log/myapp/*.log)" log_path

    echo ""
    echo "  轮转周期:"
    echo "  1) daily   (每天)"
    echo "  2) weekly  (每周)"
    echo "  3) monthly (每月)"
    select_option "请选择" 3
    local rotate_cycle
    case "$SELECTED_OPTION" in
        1) rotate_cycle="daily" ;;
        2) rotate_cycle="weekly" ;;
        3) rotate_cycle="monthly" ;;
    esac

    local rotate_count
    read_optional "保留轮转文件数量" rotate_count "7"
    if ! [[ "$rotate_count" =~ ^[0-9]+$ ]] || [ "$rotate_count" -lt 1 ]; then
        rotate_count=7
    fi

    echo ""
    echo "  压缩选项:"
    echo "  1) 压缩轮转后的日志 (compress)"
    echo "  2) 不压缩"
    select_option "请选择" 2
    local compress_opt=""
    if [ "$SELECTED_OPTION" -eq 1 ]; then
        compress_opt="    compress
    delaycompress"
    fi

    echo ""
    echo "  缺失日志处理:"
    echo "  1) 忽略缺失的日志文件 (missingok)"
    echo "  2) 日志不存在时报错"
    select_option "请选择" 2
    local missingok_opt=""
    [ "$SELECTED_OPTION" -eq 1 ] && missingok_opt="    missingok"

    echo ""
    echo "  空文件处理:"
    echo "  1) 跳过空文件 (notifempty)"
    echo "  2) 对空文件也执行轮转"
    select_option "请选择" 2
    local notifempty_opt=""
    [ "$SELECTED_OPTION" -eq 1 ] && notifempty_opt="    notifempty"

    echo ""
    local postrotate_cmd
    read -r -p "$(echo -e "${CYAN}轮转后执行的命令 (可选，如重载服务，直接回车跳过): ${NC}")" postrotate_cmd

    # Write config file
    {
        echo "${log_path} {"
        echo "    ${rotate_cycle}"
        echo "    rotate ${rotate_count}"
        [ -n "$compress_opt" ] && echo "$compress_opt"
        [ -n "$missingok_opt" ] && echo "$missingok_opt"
        [ -n "$notifempty_opt" ] && echo "$notifempty_opt"
        if [ -n "$postrotate_cmd" ]; then
            echo "    postrotate"
            echo "        ${postrotate_cmd}"
            echo "    endscript"
        fi
        echo "}"
    } > "$conf_path"

    echo ""
    log_info "✓ 轮转配置已写入: ${conf_path}"
    echo ""
    log_step "配置内容预览:"
    awk '{print "  " $0}' "$conf_path"
    echo ""

    if confirm "是否立即测试此配置 (dry-run)?"; then
        echo ""
        logrotate -d "$conf_path" 2>&1 | awk '{print "  " $0}'
    fi
}

# ---------- 删除自定义轮转配置 ----------
logrotate_delete_config() {
    print_separator
    echo -e "${BOLD}  删除自定义日志轮转配置${NC}"
    print_separator
    echo ""

    local files=()
    while IFS= read -r f; do
        files+=("$f")
    done < <(ls -1 /etc/logrotate.d/ 2>/dev/null)

    if [ ${#files[@]} -eq 0 ]; then
        log_info "没有可删除的配置文件"
        return 0
    fi

    echo "  /etc/logrotate.d/ 中的配置文件:"
    print_thin_separator
    local idx=1
    for f in "${files[@]}"; do
        printf "  %3d) %s\n" "$idx" "$f"
        (( idx++ )) || true
    done
    print_thin_separator
    echo ""

    local choice
    read -r -p "$(echo -e "${CYAN}请输入要删除的文件序号 [1-${#files[@]}] (回车取消): ${NC}")" choice
    if [ -z "$choice" ]; then
        log_info "已取消"
        return 0
    fi

    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#files[@]}" ]; then
        local selected="${files[$((choice - 1))]}"
        log_warn "即将删除配置文件: /etc/logrotate.d/${selected}"
        if confirm "确认删除?"; then
            rm -f "/etc/logrotate.d/${selected}"
            log_info "✓ 已删除: /etc/logrotate.d/${selected}"
        fi
    else
        log_warn "无效的序号"
    fi
}

# ---------- 日志轮转管理入口 ----------
run_logrotate_mgmt() {
    # 检查 logrotate 依赖
    check_and_install_deps "日志轮转管理" "logrotate:logrotate" || return 0

    while true; do
        print_separator
        echo -e "${BOLD}  日志轮转管理${NC}"
        print_separator
        echo ""
        echo "  1) 查看轮转状态与配置"
        echo "  2) 查看轮转配置文件内容"
        echo "  3) 立即执行日志轮转"
        echo "  4) 添加自定义轮转配置"
        echo "  5) 删除自定义轮转配置"
        echo "  0) 返回上级菜单"
        echo ""
        select_option "请选择" 5 0

        case "$SELECTED_OPTION" in
            1) logrotate_show_status; press_any_key ;;
            2) logrotate_view_config ;;
            3) logrotate_run_now ;;
            4) logrotate_add_config; press_any_key ;;
            5) logrotate_delete_config; press_any_key ;;
            0) return 0 ;;
        esac
    done
}

# ============================================================
# 日志管理顶层入口函数
# ============================================================
run_log_mgmt() {
    while true; do
        print_separator
        echo -e "${BOLD}  日志管理${NC}"
        print_separator
        echo ""
        echo "  1) 日志空间清理"
        echo "  2) 日志轮转管理"
        echo "  0) 返回上级菜单"
        echo ""
        select_option "请选择" 2 0

        case "$SELECTED_OPTION" in
            1) run_log_clean ;;
            2) run_logrotate_mgmt ;;
            0) return 0 ;;
        esac
    done
}
