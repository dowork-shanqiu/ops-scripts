#!/usr/bin/env bash
# ============================================================
# 防火墙管理模块 (nftables)
# - 防火墙初始化
# - 规则增删改查
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

NFTABLES_DIR="/etc/nftables.d"
NFTABLES_BASE_CONF="${NFTABLES_DIR}/base.conf"
NFTABLES_MAIN_CONF="/etc/nftables.conf"

# ============================================================
# 防火墙初始化
# ============================================================
firewall_init() {
    # 检查是否已初始化
    if [ -f "$FIREWALL_MARKER" ]; then
        log_warn "防火墙已完成初始化，无需再次执行"
        log_info "如需修改规则，请使用「防火墙修改」功能"
        return 0
    fi

    print_separator
    echo -e "${BOLD}  防火墙初始化 (nftables)${NC}"
    print_separator
    echo ""

    detect_os

    # 如果是 Ubuntu，关闭 ufw
    if [ "$OS_ID" = "ubuntu" ]; then
        log_step "检测到 Ubuntu 系统，正在关闭 ufw..."
        ufw disable 2>/dev/null
        systemctl stop ufw 2>/dev/null
        systemctl disable ufw 2>/dev/null
        log_info "ufw 已关闭并禁用"
    fi

    # 确保 nftables 已安装
    if ! command -v nft &>/dev/null; then
        log_step "正在安装 nftables..."
        apt install -y nftables
    fi

    # 启用 nftables
    systemctl enable nftables
    log_info "nftables 服务已启用"

    # 创建规则目录
    mkdir -p "$NFTABLES_DIR"

    # 获取当前 SSH 端口
    local ssh_port
    ssh_port=$(get_ssh_port)
    log_info "当前 SSH 端口: ${ssh_port}"

    # 询问是否开放 Web 端口
    local web_ports=""
    if confirm "是否开放 Web 端口 (80 和 443)?"; then
        web_ports="        tcp dport { 80, 443 } accept"
    fi

    # 生成基础规则文件
    log_step "正在生成基础防火墙规则..."
    cat > "$NFTABLES_BASE_CONF" << EOF
#!/usr/sbin/nft -f
# ============================================================
# 基础防火墙规则 - 由 ops-scripts 自动生成
# 生成时间: $(date '+%Y-%m-%d %H:%M:%S')
# ============================================================

table inet filter {
    chain input {
        type filter hook input priority 0; policy drop;

        # 允许本地回环
        iif "lo" accept

        # 允许已建立和相关连接
        ct state established,related accept

        # 丢弃无效连接
        ct state invalid drop

        # 允许 ICMP (ping)
        ip protocol icmp accept
        ip6 nexthdr icmpv6 accept

        # 允许 SSH 端口
        tcp dport ${ssh_port} accept

${web_ports}

        # 限制 ICMP 速率防止 flood
        ip protocol icmp limit rate 10/second accept

        # 记录被拒绝的连接（限制日志速率）
        limit rate 5/minute log prefix "nftables-drop: " level warn

        # 默认丢弃
        drop
    }

    chain forward {
        type filter hook forward priority 0; policy drop;

        # 允许已建立和相关连接的转发
        ct state established,related accept
    }

    chain output {
        type filter hook output priority 0; policy accept;
    }
}
EOF

    # 设置主配置文件
    cat > "$NFTABLES_MAIN_CONF" << 'EOF'
#!/usr/sbin/nft -f

# 清空所有规则
flush ruleset

# 加载所有规则文件
include "/etc/nftables.d/*.conf"
EOF

    # 验证规则
    log_step "验证防火墙规则..."
    if nft -c -f "$NFTABLES_MAIN_CONF" 2>/dev/null; then
        log_info "防火墙规则验证通过"
    else
        log_error "防火墙规则验证失败:"
        nft -c -f "$NFTABLES_MAIN_CONF"
        log_warn "请检查规则文件"
        return 1
    fi

    # 重启防火墙
    log_step "正在应用防火墙规则..."
    systemctl restart nftables
    if [ $? -eq 0 ]; then
        log_info "防火墙已启动并应用规则"
    else
        log_error "防火墙启动失败"
        return 1
    fi

    # 显示当前规则
    echo ""
    log_info "当前防火墙规则:"
    print_thin_separator
    nft list ruleset
    print_thin_separator

    # 标记已初始化
    ensure_marker_dir
    touch "$FIREWALL_MARKER"
    log_info "防火墙初始化完成"
}

# ============================================================
# 防火墙修改 - 主菜单
# ============================================================
firewall_modify() {
    if [ ! -f "$FIREWALL_MARKER" ]; then
        log_warn "防火墙尚未初始化，请先执行「防火墙初始化」"
        return 1
    fi

    while true; do
        print_separator
        echo -e "${BOLD}  防火墙规则管理${NC}"
        print_separator
        echo ""
        echo "  1) 查看当前规则"
        echo "  2) 添加端口放行规则"
        echo "  3) 删除端口放行规则"
        echo "  4) 添加 IP 白名单"
        echo "  5) 删除 IP 白名单"
        echo "  6) 添加 IP 黑名单（封禁）"
        echo "  7) 删除 IP 黑名单"
        echo "  8) 添加端口转发规则"
        echo "  9) 删除端口转发规则"
        echo " 10) 添加速率限制规则"
        echo " 11) 删除速率限制规则"
        echo " 12) 重载防火墙规则"
        echo " 13) 导出当前规则"
        echo " 14) 导入规则文件"
        echo " 15) 恢复默认规则"
        echo "  0) 返回上级菜单"
        echo ""
        select_option "请选择操作" 15 0

        case "$SELECTED_OPTION" in
            1) fw_show_rules ;;
            2) fw_add_port ;;
            3) fw_delete_port ;;
            4) fw_add_ip_whitelist ;;
            5) fw_delete_ip_whitelist ;;
            6) fw_add_ip_blacklist ;;
            7) fw_delete_ip_blacklist ;;
            8) fw_add_port_forward ;;
            9) fw_delete_port_forward ;;
            10) fw_add_rate_limit ;;
            11) fw_delete_rate_limit ;;
            12) fw_reload ;;
            13) fw_export ;;
            14) fw_import ;;
            15) fw_reset ;;
            0) return 0 ;;
        esac
        press_any_key
    done
}

# ---------- 查看当前规则 ----------
fw_show_rules() {
    log_step "当前防火墙规则:"
    print_thin_separator
    nft list ruleset
    print_thin_separator
}

# ---------- 添加端口放行规则 ----------
fw_add_port() {
    log_step "添加端口放行规则"
    echo ""

    echo "请选择协议类型:"
    echo "  1) TCP"
    echo "  2) UDP"
    echo "  3) TCP + UDP"
    select_option "协议" 3
    local proto_choice="$SELECTED_OPTION"

    local port
    read_nonempty "请输入端口号或端口范围 (如: 8080 或 8000-9000)" port

    # 验证端口格式
    if ! echo "$port" | grep -qE '^[0-9]+(-[0-9]+)?$'; then
        log_error "端口格式不正确"
        return 1
    fi

    echo ""
    echo "来源限制:"
    echo "  1) 任意来源"
    echo "  2) 指定 IP 或网段"
    select_option "选择" 2
    local src_filter=""
    if [ "$SELECTED_OPTION" -eq 2 ]; then
        local src_ip
        read_nonempty "请输入源 IP 或网段 (如: 192.168.1.0/24)" src_ip
        src_filter="ip saddr ${src_ip} "
    fi

    local conf_file="${NFTABLES_DIR}/custom_ports.conf"

    # 如果文件不存在，创建框架
    if [ ! -f "$conf_file" ]; then
        cat > "$conf_file" << 'EOF'
#!/usr/sbin/nft -f
# 自定义端口放行规则
table inet custom_ports {
    chain input {
        type filter hook input priority -1; policy accept;
    }
}
EOF
    fi

    local rules=""
    case "$proto_choice" in
        1)
            rules="        ${src_filter}tcp dport ${port} accept  # added $(date '+%Y-%m-%d %H:%M')"
            ;;
        2)
            rules="        ${src_filter}udp dport ${port} accept  # added $(date '+%Y-%m-%d %H:%M')"
            ;;
        3)
            rules="        ${src_filter}tcp dport ${port} accept  # added $(date '+%Y-%m-%d %H:%M')\n        ${src_filter}udp dport ${port} accept  # added $(date '+%Y-%m-%d %H:%M')"
            ;;
    esac

    # 在 chain input 的最后一个 } 前插入规则
    sed -i "/^    chain input {/,/^    }/ { /^    }/i\\
$(echo -e "$rules")
}" "$conf_file"

    if _fw_validate_and_reload; then
        log_info "端口放行规则已添加: ${port}"
    else
        log_error "规则添加失败，正在回滚..."
        rm -f "$conf_file"
        fw_reload
    fi
}

# ---------- 删除端口放行规则 ----------
fw_delete_port() {
    log_step "删除端口放行规则"
    echo ""

    local conf_file="${NFTABLES_DIR}/custom_ports.conf"
    if [ ! -f "$conf_file" ]; then
        log_warn "没有自定义端口放行规则"
        return 0
    fi

    log_info "当前自定义端口规则:"
    print_thin_separator
    grep -n "dport.*accept" "$conf_file" | while IFS= read -r line; do
        echo "  $line"
    done
    print_thin_separator

    local line_num
    read_nonempty "请输入要删除的规则行号" line_num

    if [[ "$line_num" =~ ^[0-9]+$ ]]; then
        sed -i "${line_num}d" "$conf_file"
        if _fw_validate_and_reload; then
            log_info "规则已删除"
        else
            log_error "删除规则后验证失败"
        fi
    else
        log_error "无效的行号"
    fi
}

# ---------- 添加 IP 白名单 ----------
fw_add_ip_whitelist() {
    log_step "添加 IP 白名单"
    echo ""

    local ip
    read_nonempty "请输入要放行的 IP 地址或网段 (如: 10.0.0.1 或 192.168.0.0/24)" ip

    local conf_file="${NFTABLES_DIR}/ip_whitelist.conf"
    if [ ! -f "$conf_file" ]; then
        cat > "$conf_file" << 'EOF'
#!/usr/sbin/nft -f
# IP 白名单规则
table inet ip_whitelist {
    chain input {
        type filter hook input priority -10; policy accept;
    }
}
EOF
    fi

    sed -i "/^    chain input {/,/^    }/ { /^    }/i\\
        ip saddr ${ip} accept  # whitelist $(date '+%Y-%m-%d %H:%M')
}" "$conf_file"

    if _fw_validate_and_reload; then
        log_info "IP 白名单已添加: ${ip}"
    fi
}

# ---------- 删除 IP 白名单 ----------
fw_delete_ip_whitelist() {
    log_step "删除 IP 白名单"
    echo ""

    local conf_file="${NFTABLES_DIR}/ip_whitelist.conf"
    if [ ! -f "$conf_file" ]; then
        log_warn "没有 IP 白名单规则"
        return 0
    fi

    log_info "当前 IP 白名单:"
    print_thin_separator
    grep -n "saddr.*accept.*whitelist" "$conf_file" | while IFS= read -r line; do
        echo "  $line"
    done
    print_thin_separator

    local line_num
    read_nonempty "请输入要删除的规则行号" line_num
    if [[ "$line_num" =~ ^[0-9]+$ ]]; then
        sed -i "${line_num}d" "$conf_file"
        if _fw_validate_and_reload; then
            log_info "IP 白名单规则已删除"
        fi
    else
        log_error "无效的行号"
    fi
}

# ---------- 添加 IP 黑名单 ----------
fw_add_ip_blacklist() {
    log_step "添加 IP 黑名单（封禁）"
    echo ""

    local ip
    read_nonempty "请输入要封禁的 IP 地址或网段" ip

    local conf_file="${NFTABLES_DIR}/ip_blacklist.conf"
    if [ ! -f "$conf_file" ]; then
        cat > "$conf_file" << 'EOF'
#!/usr/sbin/nft -f
# IP 黑名单规则
table inet ip_blacklist {
    chain input {
        type filter hook input priority -20; policy accept;
    }
}
EOF
    fi

    sed -i "/^    chain input {/,/^    }/ { /^    }/i\\
        ip saddr ${ip} drop  # blacklist $(date '+%Y-%m-%d %H:%M')
}" "$conf_file"

    if _fw_validate_and_reload; then
        log_info "IP 已封禁: ${ip}"
    fi
}

# ---------- 删除 IP 黑名单 ----------
fw_delete_ip_blacklist() {
    log_step "删除 IP 黑名单"
    echo ""

    local conf_file="${NFTABLES_DIR}/ip_blacklist.conf"
    if [ ! -f "$conf_file" ]; then
        log_warn "没有 IP 黑名单规则"
        return 0
    fi

    log_info "当前 IP 黑名单:"
    print_thin_separator
    grep -n "saddr.*drop.*blacklist" "$conf_file" | while IFS= read -r line; do
        echo "  $line"
    done
    print_thin_separator

    local line_num
    read_nonempty "请输入要删除的规则行号" line_num
    if [[ "$line_num" =~ ^[0-9]+$ ]]; then
        sed -i "${line_num}d" "$conf_file"
        if _fw_validate_and_reload; then
            log_info "IP 黑名单规则已删除"
        fi
    else
        log_error "无效的行号"
    fi
}

# ---------- 添加端口转发规则 ----------
fw_add_port_forward() {
    log_step "添加端口转发规则"
    echo ""

    echo "请选择协议类型:"
    echo "  1) TCP"
    echo "  2) UDP"
    select_option "协议" 2
    local proto
    [ "$SELECTED_OPTION" -eq 1 ] && proto="tcp" || proto="udp"

    local src_port dest_ip dest_port
    read_nonempty "请输入源端口" src_port
    read_nonempty "请输入目标 IP" dest_ip
    read_nonempty "请输入目标端口" dest_port

    local conf_file="${NFTABLES_DIR}/port_forward.conf"
    if [ ! -f "$conf_file" ]; then
        cat > "$conf_file" << 'EOF'
#!/usr/sbin/nft -f
# 端口转发规则
table inet port_forward {
    chain prerouting {
        type nat hook prerouting priority -100; policy accept;
    }

    chain postrouting {
        type nat hook postrouting priority 100; policy accept;
        masquerade
    }
}
EOF
    fi

    sed -i "/^    chain prerouting {/,/^    }/ { /^    }/i\\
        ${proto} dport ${src_port} dnat to ${dest_ip}:${dest_port}  # forward $(date '+%Y-%m-%d %H:%M')
}" "$conf_file"

    # 启用 IP 转发
    echo 1 > /proc/sys/net/ipv4/ip_forward
    if ! grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf; then
        echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
    fi

    if _fw_validate_and_reload; then
        log_info "端口转发规则已添加: ${src_port} -> ${dest_ip}:${dest_port}"
    fi
}

# ---------- 删除端口转发规则 ----------
fw_delete_port_forward() {
    log_step "删除端口转发规则"
    echo ""

    local conf_file="${NFTABLES_DIR}/port_forward.conf"
    if [ ! -f "$conf_file" ]; then
        log_warn "没有端口转发规则"
        return 0
    fi

    log_info "当前端口转发规则:"
    print_thin_separator
    grep -n "dnat to.*forward" "$conf_file" | while IFS= read -r line; do
        echo "  $line"
    done
    print_thin_separator

    local line_num
    read_nonempty "请输入要删除的规则行号" line_num
    if [[ "$line_num" =~ ^[0-9]+$ ]]; then
        sed -i "${line_num}d" "$conf_file"
        if _fw_validate_and_reload; then
            log_info "端口转发规则已删除"
        fi
    else
        log_error "无效的行号"
    fi
}

# ---------- 添加速率限制规则 ----------
fw_add_rate_limit() {
    log_step "添加速率限制规则"
    echo ""

    local port rate
    read_nonempty "请输入要限制的端口号" port
    echo ""
    echo "请选择限制速率:"
    echo "  1) 10/秒"
    echo "  2) 30/秒"
    echo "  3) 60/秒"
    echo "  4) 100/秒"
    echo "  5) 自定义"
    select_option "选择" 5
    case "$SELECTED_OPTION" in
        1) rate="10/second" ;;
        2) rate="30/second" ;;
        3) rate="60/second" ;;
        4) rate="100/second" ;;
        5) read_nonempty "请输入速率 (格式: 数量/second|minute|hour)" rate ;;
    esac

    local conf_file="${NFTABLES_DIR}/rate_limit.conf"
    if [ ! -f "$conf_file" ]; then
        cat > "$conf_file" << 'EOF'
#!/usr/sbin/nft -f
# 速率限制规则
table inet rate_limit {
    chain input {
        type filter hook input priority -5; policy accept;
    }
}
EOF
    fi

    sed -i "/^    chain input {/,/^    }/ { /^    }/i\\
        tcp dport ${port} limit rate ${rate} accept  # ratelimit $(date '+%Y-%m-%d %H:%M')\\n        tcp dport ${port} drop
}" "$conf_file"

    if _fw_validate_and_reload; then
        log_info "速率限制已设置: 端口 ${port} 限制 ${rate}"
    fi
}

# ---------- 删除速率限制规则 ----------
fw_delete_rate_limit() {
    log_step "删除速率限制规则"
    echo ""

    local conf_file="${NFTABLES_DIR}/rate_limit.conf"
    if [ ! -f "$conf_file" ]; then
        log_warn "没有速率限制规则"
        return 0
    fi

    log_info "当前速率限制规则:"
    print_thin_separator
    grep -n "limit rate\|dport.*drop" "$conf_file" | while IFS= read -r line; do
        echo "  $line"
    done
    print_thin_separator

    local line_num
    read_nonempty "请输入要删除的规则行号 (建议同时删除对应的 drop 规则)" line_num
    if [[ "$line_num" =~ ^[0-9]+$ ]]; then
        sed -i "${line_num}d" "$conf_file"
        if confirm "是否继续删除关联的 drop 规则?"; then
            read_nonempty "请输入 drop 规则行号" line_num
            sed -i "${line_num}d" "$conf_file"
        fi
        if _fw_validate_and_reload; then
            log_info "速率限制规则已删除"
        fi
    else
        log_error "无效的行号"
    fi
}

# ---------- 重载防火墙 ----------
fw_reload() {
    log_step "正在重载防火墙规则..."
    systemctl restart nftables
    if [ $? -eq 0 ]; then
        log_info "防火墙规则已重载"
    else
        log_error "防火墙重载失败"
    fi
}

# ---------- 导出规则 ----------
fw_export() {
    local export_file
    read_optional "导出文件路径" export_file "/root/nftables_backup_$(date +%Y%m%d%H%M%S).conf"
    nft list ruleset > "$export_file"
    log_info "规则已导出到: ${export_file}"
}

# ---------- 导入规则 ----------
fw_import() {
    local import_file
    read_nonempty "请输入要导入的规则文件路径" import_file

    if [ ! -f "$import_file" ]; then
        log_error "文件不存在: ${import_file}"
        return 1
    fi

    if confirm "导入将覆盖当前规则，确认继续?"; then
        # 备份当前规则
        fw_export
        cp "$import_file" "$NFTABLES_BASE_CONF"
        if _fw_validate_and_reload; then
            log_info "规则导入成功"
        else
            log_error "导入的规则验证失败"
        fi
    fi
}

# ---------- 恢复默认规则 ----------
fw_reset() {
    if confirm "确认恢复默认防火墙规则? 这将删除所有自定义规则"; then
        # 备份
        fw_export

        # 删除自定义规则文件
        find "$NFTABLES_DIR" -name "*.conf" ! -name "base.conf" -delete
        log_info "已删除所有自定义规则文件"

        fw_reload
        log_info "防火墙已恢复为默认规则"
    fi
}

# ---------- 验证并重载 ----------
_fw_validate_and_reload() {
    if nft -c -f "$NFTABLES_MAIN_CONF" 2>/dev/null; then
        systemctl restart nftables
        return $?
    else
        log_error "规则验证失败:"
        nft -c -f "$NFTABLES_MAIN_CONF"
        return 1
    fi
}

# ============================================================
# fail2ban 管理
# ============================================================
FAIL2BAN_JAIL_LOCAL="/etc/fail2ban/jail.local"

_f2b_check_installed() {
    if ! command -v fail2ban-client &>/dev/null; then
        log_error "fail2ban 未安装，请先运行系统初始化或手动安装: apt install -y fail2ban"
        return 1
    fi
    return 0
}

_f2b_check_running() {
    if ! systemctl is-active fail2ban &>/dev/null; then
        log_warn "fail2ban 服务未运行，请先启动服务"
        log_info "可使用「fail2ban 管理」→「服务控制」→「启动 fail2ban」"
        return 1
    fi
    return 0
}

_f2b_get_jail_list() {
    fail2ban-client status 2>/dev/null \
        | grep "Jail list:" \
        | sed 's/.*Jail list:[[:space:]]*//' \
        | tr ',' '\n' \
        | sed 's/^[[:space:]]*//' \
        | grep -v '^$'
}

# ---------- 查看服务状态与 Jail 概览 ----------
f2b_status() {
    print_separator
    echo -e "${BOLD}  fail2ban 服务状态${NC}"
    print_separator
    echo ""

    if systemctl is-active fail2ban &>/dev/null; then
        log_info "服务状态: 运行中 ✓"
    else
        log_warn "服务状态: 未运行 ✗"
        log_info "请使用「服务控制」菜单启动 fail2ban"
        return 0
    fi

    echo ""
    log_info "fail2ban 状态概览:"
    print_thin_separator
    fail2ban-client status 2>/dev/null
    print_thin_separator

    echo ""
    local jails
    jails=$(_f2b_get_jail_list)
    if [ -n "$jails" ]; then
        log_info "各 Jail 封禁摘要:"
        print_thin_separator
        while IFS= read -r jail; do
            [ -z "$jail" ] && continue
            local banned total_banned
            banned=$(fail2ban-client status "$jail" 2>/dev/null \
                | grep "Currently banned" | awk '{print $NF}')
            total_banned=$(fail2ban-client status "$jail" 2>/dev/null \
                | grep "Total banned" | awk '{print $NF}')
            echo "  ${jail}: 当前封禁 ${banned:-0} 个 IP，累计封禁 ${total_banned:-0} 个"
        done <<< "$jails"
        print_thin_separator
    fi
}

# ---------- 查看指定 Jail 详情 ----------
f2b_jail_detail() {
    _f2b_check_installed || return 1
    _f2b_check_running || return 1

    log_step "查看 Jail 详情"
    echo ""

    local jails
    jails=$(_f2b_get_jail_list)
    if [ -z "$jails" ]; then
        log_warn "没有活跃的 Jail，请检查 fail2ban 配置"
        return 0
    fi

    log_info "可用的 Jail 列表:"
    local i=1
    local jail_arr=()
    while IFS= read -r jail; do
        [ -z "$jail" ] && continue
        echo "  ${i}) ${jail}"
        jail_arr+=("$jail")
        i=$((i + 1))
    done <<< "$jails"
    echo ""

    select_option "请选择 Jail" "$((i - 1))"
    local selected_jail="${jail_arr[$((SELECTED_OPTION - 1))]}"

    echo ""
    log_info "Jail「${selected_jail}」的详细状态:"
    print_thin_separator
    fail2ban-client status "$selected_jail" 2>/dev/null
    print_thin_separator
}

# ---------- 手动封禁 IP ----------
f2b_ban_ip() {
    _f2b_check_installed || return 1
    _f2b_check_running || return 1

    log_step "手动封禁 IP"
    echo ""

    local jails
    jails=$(_f2b_get_jail_list)
    if [ -z "$jails" ]; then
        log_warn "没有活跃的 Jail"
        return 0
    fi

    local ip
    read_nonempty "请输入要封禁的 IP 地址" ip

    echo ""
    log_info "请选择封禁到哪个 Jail:"
    local i=1
    local jail_arr=()
    while IFS= read -r jail; do
        [ -z "$jail" ] && continue
        echo "  ${i}) ${jail}"
        jail_arr+=("$jail")
        i=$((i + 1))
    done <<< "$jails"

    select_option "请选择 Jail" "$((i - 1))"
    local selected_jail="${jail_arr[$((SELECTED_OPTION - 1))]}"

    if fail2ban-client set "$selected_jail" banip "$ip" 2>/dev/null; then
        log_info "✓ IP 已封禁: ${ip} (Jail: ${selected_jail})"
    else
        log_error "封禁失败，请检查 IP 格式或 fail2ban 服务状态"
    fi
}

# ---------- 手动解封 IP ----------
f2b_unban_ip() {
    _f2b_check_installed || return 1
    _f2b_check_running || return 1

    log_step "手动解封 IP"
    echo ""

    local jails
    jails=$(_f2b_get_jail_list)
    if [ -z "$jails" ]; then
        log_warn "没有活跃的 Jail"
        return 0
    fi

    local ip
    read_nonempty "请输入要解封的 IP 地址" ip

    echo ""
    log_info "请选择从哪个 Jail 解封:"
    echo "  0) 从所有 Jail 解封"
    local i=1
    local jail_arr=()
    while IFS= read -r jail; do
        [ -z "$jail" ] && continue
        echo "  ${i}) ${jail}"
        jail_arr+=("$jail")
        i=$((i + 1))
    done <<< "$jails"

    select_option "请选择 Jail" "$((i - 1))" 0

    if [ "$SELECTED_OPTION" -eq 0 ]; then
        local unbanned=false
        while IFS= read -r jail; do
            [ -z "$jail" ] && continue
            if fail2ban-client set "$jail" unbanip "$ip" 2>/dev/null; then
                log_info "✓ 已从 Jail「${jail}」解封: ${ip}"
                unbanned=true
            fi
        done <<< "$jails"
        if [ "$unbanned" = false ]; then
            log_warn "IP ${ip} 未在任何 Jail 的封禁列表中"
        fi
    else
        local selected_jail="${jail_arr[$((SELECTED_OPTION - 1))]}"
        if fail2ban-client set "$selected_jail" unbanip "$ip" 2>/dev/null; then
            log_info "✓ IP 已解封: ${ip} (Jail: ${selected_jail})"
        else
            log_error "解封失败，IP 可能不在该 Jail 的封禁列表中"
        fi
    fi
}

# ---------- 修改全局配置 ----------
f2b_edit_config() {
    _f2b_check_installed || return 1

    while true; do
        print_separator
        echo -e "${BOLD}  fail2ban 全局配置${NC}"
        print_separator
        echo ""

        # 读取当前配置值（优先读 jail.local，其次 jail.conf）
        local cur_bantime cur_findtime cur_maxretry cur_ignoreip
        local jail_conf="/etc/fail2ban/jail.conf"
        cur_bantime=$(grep -E "^bantime[[:space:]]*=" "$jail_conf" 2>/dev/null | head -1 | awk -F= '{print $2}' | tr -d ' ')
        cur_findtime=$(grep -E "^findtime[[:space:]]*=" "$jail_conf" 2>/dev/null | head -1 | awk -F= '{print $2}' | tr -d ' ')
        cur_maxretry=$(grep -E "^maxretry[[:space:]]*=" "$jail_conf" 2>/dev/null | head -1 | awk -F= '{print $2}' | tr -d ' ')

        if [ -f "$FAIL2BAN_JAIL_LOCAL" ]; then
            local lb lf lm
            lb=$(grep -E "^bantime[[:space:]]*=" "$FAIL2BAN_JAIL_LOCAL" 2>/dev/null | head -1 | awk -F= '{print $2}' | tr -d ' ')
            lf=$(grep -E "^findtime[[:space:]]*=" "$FAIL2BAN_JAIL_LOCAL" 2>/dev/null | head -1 | awk -F= '{print $2}' | tr -d ' ')
            lm=$(grep -E "^maxretry[[:space:]]*=" "$FAIL2BAN_JAIL_LOCAL" 2>/dev/null | head -1 | awk -F= '{print $2}' | tr -d ' ')
            li=$(grep -E "^ignoreip[[:space:]]*=" "$FAIL2BAN_JAIL_LOCAL" 2>/dev/null | head -1 | awk -F= '{$1=""; print}' | sed 's/^[[:space:]]*//')
            [ -n "$lb" ] && cur_bantime="$lb"
            [ -n "$lf" ] && cur_findtime="$lf"
            [ -n "$lm" ] && cur_maxretry="$lm"
            [ -n "$li" ] && cur_ignoreip="$li"
        fi

        log_info "当前 DEFAULT 区块配置:"
        echo "  bantime  (封禁时长):       ${cur_bantime:-10m}"
        echo "  findtime (统计时间窗):     ${cur_findtime:-10m}"
        echo "  maxretry (最大失败次数):   ${cur_maxretry:-5}"
        echo "  ignoreip (忽略 IP 列表):   ${cur_ignoreip:-127.0.0.1/8 ::1}"
        echo ""
        echo "  时间格式示例: 600 (秒) / 10m / 1h / 1d"
        echo ""
        echo "  1) 修改封禁时长 (bantime)"
        echo "  2) 修改统计时间窗 (findtime)"
        echo "  3) 修改最大失败次数 (maxretry)"
        echo "  4) 修改忽略 IP 列表 (ignoreip)"
        echo "  5) 查看完整 jail.local 文件"
        echo "  0) 返回"
        echo ""
        select_option "请选择" 5 0

        case "$SELECTED_OPTION" in
            1)
                local val
                read_nonempty "请输入新的封禁时长 (如: 1h 或 3600)" val
                _f2b_set_option "bantime" "$val"
                ;;
            2)
                local val
                read_nonempty "请输入新的统计时间窗 (如: 10m 或 600)" val
                _f2b_set_option "findtime" "$val"
                ;;
            3)
                local val
                read_nonempty "请输入新的最大失败次数 (如: 5)" val
                _f2b_set_option "maxretry" "$val"
                ;;
            4)
                local cur_ignore
                cur_ignore="${cur_ignoreip:-127.0.0.1/8 ::1}"
                log_info "当前忽略 IP 列表: ${cur_ignore}"
                log_info "多个 IP/CIDR 用空格分隔，如: 127.0.0.1/8 ::1 10.0.0.0/8"
                local val
                read_nonempty "请输入新的忽略 IP 列表" val
                _f2b_set_option "ignoreip" "$val"
                ;;
            5)
                if [ -f "$FAIL2BAN_JAIL_LOCAL" ]; then
                    log_info "jail.local 内容:"
                    print_thin_separator
                    cat "$FAIL2BAN_JAIL_LOCAL"
                    print_thin_separator
                else
                    log_warn "jail.local 不存在，当前使用 jail.conf 默认配置"
                fi
                ;;
            0) return 0 ;;
        esac
        echo ""
    done
}

_f2b_set_option() {
    local key="$1"
    local value="$2"

    # 确保 jail.local 存在并包含 [DEFAULT] 区块
    if [ ! -f "$FAIL2BAN_JAIL_LOCAL" ]; then
        printf '# fail2ban 本地配置文件 - 由 ops-scripts 管理\n# 此文件中的配置覆盖 jail.conf 中的默认值\n\n[DEFAULT]\n\n' > "$FAIL2BAN_JAIL_LOCAL"
    fi
    if ! grep -q "^\[DEFAULT\]" "$FAIL2BAN_JAIL_LOCAL"; then
        sed -i "1s/^/[DEFAULT]\n\n/" "$FAIL2BAN_JAIL_LOCAL"
    fi

    if grep -qE "^#?${key}[[:space:]]*=" "$FAIL2BAN_JAIL_LOCAL"; then
        sed -i "s|^#*${key}[[:space:]]*=.*|${key} = ${value}|" "$FAIL2BAN_JAIL_LOCAL"
    else
        sed -i "/^\[DEFAULT\]/a ${key} = ${value}" "$FAIL2BAN_JAIL_LOCAL"
    fi

    log_info "配置已更新: ${key} = ${value}"

    if confirm "是否立即重载 fail2ban 配置?"; then
        if fail2ban-client reload 2>/dev/null; then
            log_info "fail2ban 配置已重载"
        else
            log_error "重载失败，请检查 fail2ban 服务状态"
        fi
    fi
}

# ---------- 服务控制 ----------
f2b_service_control() {
    _f2b_check_installed || return 1

    while true; do
        print_separator
        echo -e "${BOLD}  fail2ban 服务控制${NC}"
        print_separator
        echo ""

        local status="未运行 ✗"
        systemctl is-active fail2ban &>/dev/null && status="运行中 ✓"
        log_info "当前状态: ${status}"
        echo ""
        echo "  1) 启动 fail2ban"
        echo "  2) 停止 fail2ban"
        echo "  3) 重启 fail2ban"
        echo "  4) 重载配置 (不中断封禁)"
        echo "  5) 查看最近日志 (50行)"
        echo "  0) 返回"
        echo ""
        select_option "请选择" 5 0

        case "$SELECTED_OPTION" in
            1)
                systemctl start fail2ban && log_info "fail2ban 已启动" || log_error "启动失败"
                ;;
            2)
                if confirm "确认停止 fail2ban? 停止后封禁规则将被清除"; then
                    systemctl stop fail2ban && log_info "fail2ban 已停止" || log_error "停止失败"
                fi
                ;;
            3)
                systemctl restart fail2ban && log_info "fail2ban 已重启" || log_error "重启失败"
                ;;
            4)
                fail2ban-client reload 2>/dev/null && log_info "fail2ban 配置已重载" || log_error "重载失败"
                ;;
            5)
                log_info "fail2ban 最近日志:"
                print_thin_separator
                journalctl -u fail2ban --no-pager -n 50 2>/dev/null \
                    || tail -50 /var/log/fail2ban.log 2>/dev/null \
                    || log_warn "无法读取 fail2ban 日志"
                print_thin_separator
                ;;
            0) return 0 ;;
        esac
        press_any_key
    done
}

# ---------- fail2ban 管理主菜单 ----------
fail2ban_manage() {
    _f2b_check_installed || { press_any_key; return 1; }

    while true; do
        print_separator
        echo -e "${BOLD}  fail2ban 管理${NC}"
        print_separator
        echo ""
        echo "  1) 查看服务状态与 Jail 概览"
        echo "  2) 查看指定 Jail 详情"
        echo "  3) 手动封禁 IP"
        echo "  4) 手动解封 IP"
        echo "  5) 修改全局配置 (bantime/findtime/maxretry/ignoreip)"
        echo "  6) 服务控制 (启动/停止/重启/重载/日志)"
        echo "  0) 返回上级菜单"
        echo ""
        select_option "请选择" 6 0

        case "$SELECTED_OPTION" in
            1) f2b_status ;;
            2) f2b_jail_detail ;;
            3) f2b_ban_ip ;;
            4) f2b_unban_ip ;;
            5) f2b_edit_config ;;
            6) f2b_service_control ;;
            0) return 0 ;;
        esac
        press_any_key
    done
}

# ============================================================
# 一键拉黑恶意 IP
# ============================================================
fw_quick_blacklist() {
    print_separator
    echo -e "${BOLD}  一键拉黑恶意 IP${NC}"
    print_separator
    echo ""

    local ip
    read_nonempty "请输入要拉黑的恶意 IP 地址或网段 (如: 1.2.3.4 或 1.2.3.0/24)" ip

    echo ""
    echo "拉黑方式:"
    echo "  1) nftables 直接封禁 (永久，直到手动删除)"
    echo "  2) fail2ban 封禁 (按 bantime 配置自动到期)"
    echo "  3) 同时使用两种方式"
    select_option "请选择" 3

    local nft_ok=false f2b_ok=false

    # 提取 nftables 和 fail2ban 操作的内联函数
    _do_nft_blacklist() {
        local conf_file="${NFTABLES_DIR}/ip_blacklist.conf"
        if [ ! -f "$conf_file" ]; then
            cat > "$conf_file" << 'NFTEOF'
#!/usr/sbin/nft -f
# IP 黑名单规则
table inet ip_blacklist {
    chain input {
        type filter hook input priority -20; policy accept;
    }
}
NFTEOF
        fi
        sed -i "/^    chain input {/,/^    }/ { /^    }/i\\
        ip saddr ${ip} drop  # blacklist $(date '+%Y-%m-%d %H:%M')
}" "$conf_file"
        if _fw_validate_and_reload; then
            log_info "nftables 已封禁: ${ip}"
            nft_ok=true
        else
            log_error "nftables 封禁失败，正在回滚..."
            sed -i "\|ip saddr ${ip} drop.*blacklist|d" "$conf_file"
        fi
    }

    _do_f2b_blacklist() {
        if command -v fail2ban-client &>/dev/null && systemctl is-active fail2ban &>/dev/null; then
            local jails
            jails=$(_f2b_get_jail_list)
            if [ -n "$jails" ]; then
                local first_jail
                first_jail=$(echo "$jails" | head -1)
                if fail2ban-client set "$first_jail" banip "$ip" 2>/dev/null; then
                    log_info "fail2ban 已封禁: ${ip} (Jail: ${first_jail})"
                    f2b_ok=true
                else
                    log_warn "fail2ban 封禁失败 (CIDR 网段可能不支持)"
                fi
            else
                log_warn "fail2ban 没有活跃的 Jail，跳过"
            fi
        else
            log_warn "fail2ban 未安装或未运行，跳过 fail2ban 封禁"
        fi
    }

    case "$SELECTED_OPTION" in
        1) _do_nft_blacklist ;;
        2) _do_f2b_blacklist ;;
        3) _do_nft_blacklist; _do_f2b_blacklist ;;
    esac

    echo ""
    if [ "$nft_ok" = true ] || [ "$f2b_ok" = true ]; then
        log_info "✓ IP 已成功拉黑: ${ip}"
    else
        log_error "拉黑操作未成功，请检查防火墙状态"
    fi
}

# ============================================================
# 临时 IP 白名单资源池
# ============================================================
TEMP_WHITELIST_DATA="/etc/ops-scripts/temp_whitelist.dat"
TEMP_WHITELIST_CONF="${NFTABLES_DIR}/temp_whitelist.conf"
TEMP_WHITELIST_CLEANUP="/etc/ops-scripts/temp_whitelist_cleanup.sh"

_rebuild_temp_whitelist_conf() {
    local now
    now=$(date +%s)

    {
        echo "#!/usr/sbin/nft -f"
        echo "# 临时 IP 白名单规则 - 由 ops-scripts 自动管理"
        echo "# 警告: 此文件由程序自动生成，请勿手动编辑"
        echo "table inet temp_whitelist {"
        echo "    chain input {"
        echo "        type filter hook input priority -15; policy accept;"

        if [ -f "$TEMP_WHITELIST_DATA" ]; then
            while IFS=' ' read -r ip expiry desc || [ -n "$ip" ]; do
                [ -z "$ip" ] && continue
                [[ "$ip" =~ ^# ]] && continue
                if [ "$expiry" -gt "$now" ]; then
                    local expire_str
                    expire_str=$(date -d "@${expiry}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "unknown")
                    if [[ "$ip" == *:* ]]; then
                        echo "        ip6 saddr ${ip} accept  # temp_whitelist expires ${expire_str}"
                    else
                        echo "        ip saddr ${ip} accept  # temp_whitelist expires ${expire_str}"
                    fi
                fi
            done < "$TEMP_WHITELIST_DATA"
        fi

        echo "    }"
        echo "}"
    } > "$TEMP_WHITELIST_CONF"
}

_clean_expired_temp_whitelist() {
    if [ ! -f "$TEMP_WHITELIST_DATA" ]; then
        return 0
    fi

    local now
    now=$(date +%s)
    local tmpfile
    tmpfile=$(mktemp)
    local changed=false

    while IFS=' ' read -r ip expiry desc || [ -n "$ip" ]; do
        [ -z "$ip" ] && continue
        [[ "$ip" =~ ^# ]] && continue
        if [ "$expiry" -gt "$now" ]; then
            echo "$ip $expiry $desc" >> "$tmpfile"
        else
            changed=true
            local expire_str
            expire_str=$(date -d "@${expiry}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "未知")
            log_info "已移除过期白名单: ${ip} (过期于 ${expire_str})"
        fi
    done < "$TEMP_WHITELIST_DATA"

    if [ "$changed" = true ]; then
        mv "$tmpfile" "$TEMP_WHITELIST_DATA"
        _rebuild_temp_whitelist_conf
        if _fw_validate_and_reload; then
            log_info "✓ 防火墙规则已重载"
        fi
    else
        rm -f "$tmpfile"
        log_info "没有过期条目需要清理"
    fi
}

temp_whitelist_list() {
    print_separator
    echo -e "${BOLD}  临时 IP 白名单列表${NC}"
    print_separator

    if [ ! -f "$TEMP_WHITELIST_DATA" ] || [ ! -s "$TEMP_WHITELIST_DATA" ]; then
        echo "  (当前没有临时白名单条目)"
        return 0
    fi

    local now
    now=$(date +%s)
    local idx=1
    echo ""
    printf "  %-4s %-20s %-22s %-16s %s\n" "序号" "IP 地址" "过期时间" "状态" "备注"
    print_thin_separator

    while IFS=' ' read -r ip expiry desc || [ -n "$ip" ]; do
        [ -z "$ip" ] && continue
        [[ "$ip" =~ ^# ]] && continue
        local expire_str status
        expire_str=$(date -d "@${expiry}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "未知")
        if [ "$expiry" -gt "$now" ]; then
            local remaining=$(( (expiry - now) / 60 ))
            status="有效(剩${remaining}分)"
        else
            status="已过期"
        fi
        printf "  %-4s %-20s %-22s %-16s %s\n" "$idx" "$ip" "$expire_str" "$status" "${desc:-}"
        idx=$((idx + 1))
    done < "$TEMP_WHITELIST_DATA"

    print_thin_separator
}

temp_whitelist_add() {
    log_step "添加临时 IP 白名单"
    echo ""

    if [ ! -f "$FIREWALL_MARKER" ]; then
        log_warn "防火墙尚未初始化，请先执行「防火墙初始化」"
        return 1
    fi

    local ip
    read_nonempty "请输入要加入白名单的 IP 地址或网段 (IPv4/IPv6/CIDR)" ip

    echo ""
    echo "请选择过期时间:"
    echo "  1) 1 小时"
    echo "  2) 6 小时"
    echo "  3) 24 小时 (1 天)"
    echo "  4) 72 小时 (3 天)"
    echo "  5) 168 小时 (7 天)"
    echo "  6) 自定义小时数"
    select_option "请选择" 6

    local hours
    case "$SELECTED_OPTION" in
        1) hours=1 ;;
        2) hours=6 ;;
        3) hours=24 ;;
        4) hours=72 ;;
        5) hours=168 ;;
        6)
            read_nonempty "请输入小时数" hours
            if ! [[ "$hours" =~ ^[0-9]+$ ]] || [ "$hours" -lt 1 ]; then
                log_error "无效的小时数"
                return 1
            fi
            ;;
    esac

    local desc
    read_optional "备注信息" desc "手动添加"

    local expiry
    expiry=$(( $(date +%s) + hours * 3600 ))
    local expire_str
    expire_str=$(date -d "@${expiry}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "未知")

    ensure_marker_dir
    echo "${ip} ${expiry} ${desc:-手动添加}" >> "$TEMP_WHITELIST_DATA"

    _rebuild_temp_whitelist_conf

    if _fw_validate_and_reload; then
        log_info "✓ 临时白名单已添加: ${ip}"
        log_info "  过期时间: ${expire_str} (${hours} 小时后)"
    else
        # 回滚
        awk -v ip="$ip" -v expiry="$expiry" '!($1 == ip && $2 == expiry)' \
            "$TEMP_WHITELIST_DATA" > /tmp/tw_rollback.tmp && mv /tmp/tw_rollback.tmp "$TEMP_WHITELIST_DATA"
        _rebuild_temp_whitelist_conf
        log_error "添加失败，已回滚"
    fi
}

temp_whitelist_delete() {
    log_step "删除临时 IP 白名单条目"
    echo ""

    if [ ! -f "$TEMP_WHITELIST_DATA" ] || [ ! -s "$TEMP_WHITELIST_DATA" ]; then
        log_warn "当前没有临时白名单条目"
        return 0
    fi

    temp_whitelist_list
    echo ""

    local total
    total=$(grep -c -v '^#' "$TEMP_WHITELIST_DATA" 2>/dev/null || echo 0)
    if [ "$total" -eq 0 ]; then
        log_warn "没有可删除的条目"
        return 0
    fi

    local idx
    read_nonempty "请输入要删除的序号" idx
    if ! [[ "$idx" =~ ^[0-9]+$ ]] || [ "$idx" -lt 1 ] || [ "$idx" -gt "$total" ]; then
        log_error "无效的序号"
        return 1
    fi

    local line_to_delete
    line_to_delete=$(grep -v '^#' "$TEMP_WHITELIST_DATA" | sed -n "${idx}p")
    local ip_to_delete expiry_to_delete
    ip_to_delete=$(echo "$line_to_delete" | awk '{print $1}')
    expiry_to_delete=$(echo "$line_to_delete" | awk '{print $2}')

    local tmpfile
    tmpfile=$(mktemp)
    awk -v ip="$ip_to_delete" -v expiry="$expiry_to_delete" \
        '!($1 == ip && $2 == expiry)' "$TEMP_WHITELIST_DATA" > "$tmpfile"
    mv "$tmpfile" "$TEMP_WHITELIST_DATA"

    _rebuild_temp_whitelist_conf

    if _fw_validate_and_reload; then
        log_info "✓ 已删除临时白名单: ${ip_to_delete}"
    else
        log_error "删除后规则重载失败"
    fi
}

temp_whitelist_setup_cron() {
    log_step "自动清理定时任务"
    echo ""

    local cron_file="/etc/cron.d/ops-temp-whitelist"

    if [ -f "$cron_file" ]; then
        log_info "当前已设置自动清理任务:"
        print_thin_separator
        cat "$cron_file"
        print_thin_separator
        echo ""
        echo "  1) 更新清理间隔"
        echo "  2) 删除自动清理任务"
        echo "  0) 返回"
        select_option "请选择" 2 0
        case "$SELECTED_OPTION" in
            2)
                rm -f "$cron_file"
                log_info "自动清理任务已删除"
                return 0
                ;;
            0) return 0 ;;
        esac
    fi

    echo "请选择自动清理间隔:"
    echo "  1) 每 5 分钟"
    echo "  2) 每 10 分钟"
    echo "  3) 每 30 分钟"
    echo "  4) 每小时"
    select_option "请选择" 4

    local cron_schedule
    case "$SELECTED_OPTION" in
        1) cron_schedule="*/5 * * * *" ;;
        2) cron_schedule="*/10 * * * *" ;;
        3) cron_schedule="*/30 * * * *" ;;
        4) cron_schedule="0 * * * *" ;;
    esac

    _generate_temp_whitelist_cleanup_script

    echo "${cron_schedule} root ${TEMP_WHITELIST_CLEANUP} >> /var/log/ops-temp-whitelist.log 2>&1" > "$cron_file"
    chmod 644 "$cron_file"

    log_info "✓ 自动清理任务已设置: ${cron_schedule}"
    log_info "  日志文件: /var/log/ops-temp-whitelist.log"
}

_generate_temp_whitelist_cleanup_script() {
    ensure_marker_dir

    cat > "$TEMP_WHITELIST_CLEANUP" << 'CLEANUP_EOF'
#!/usr/bin/env bash
# 临时 IP 白名单自动清理脚本 - 由 ops-scripts 自动生成，请勿手动编辑
set -euo pipefail

TEMP_WHITELIST_DATA="/etc/ops-scripts/temp_whitelist.dat"
NFTABLES_DIR="/etc/nftables.d"
TEMP_WHITELIST_CONF="${NFTABLES_DIR}/temp_whitelist.conf"

[ ! -f "$TEMP_WHITELIST_DATA" ] && exit 0

NOW=$(date +%s)
TMPFILE=$(mktemp)
CHANGED=false

while IFS=' ' read -r ip expiry desc || [ -n "$ip" ]; do
    [ -z "$ip" ] && continue
    [[ "$ip" =~ ^# ]] && continue
    if [ "$expiry" -gt "$NOW" ]; then
        echo "$ip $expiry $desc" >> "$TMPFILE"
    else
        CHANGED=true
        expire_str=$(date -d "@${expiry}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "unknown")
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] 移除过期白名单: $ip (过期于 ${expire_str})"
    fi
done < "$TEMP_WHITELIST_DATA"

if [ "$CHANGED" = true ]; then
    mv "$TMPFILE" "$TEMP_WHITELIST_DATA"

    {
        echo "#!/usr/sbin/nft -f"
        echo "# 临时 IP 白名单规则 - 由 ops-scripts 自动管理"
        echo "table inet temp_whitelist {"
        echo "    chain input {"
        echo "        type filter hook input priority -15; policy accept;"
        if [ -s "$TEMP_WHITELIST_DATA" ]; then
            while IFS=' ' read -r ip expiry desc || [ -n "$ip" ]; do
                [ -z "$ip" ] && continue
                [[ "$ip" =~ ^# ]] && continue
                if [ "$expiry" -gt "$NOW" ]; then
                    expire_str=$(date -d "@${expiry}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "unknown")
                    if [[ "$ip" == *:* ]]; then
                        echo "        ip6 saddr ${ip} accept  # temp_whitelist expires ${expire_str}"
                    else
                        echo "        ip saddr ${ip} accept  # temp_whitelist expires ${expire_str}"
                    fi
                fi
            done < "$TEMP_WHITELIST_DATA"
        fi
        echo "    }"
        echo "}"
    } > "$TEMP_WHITELIST_CONF"

    if nft -c -f /etc/nftables.conf 2>/dev/null; then
        systemctl restart nftables
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] 防火墙规则已重载"
    else
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] 警告: 防火墙规则验证失败，请手动检查"
    fi
else
    rm -f "$TMPFILE"
fi
CLEANUP_EOF

    chmod 755 "$TEMP_WHITELIST_CLEANUP"
    log_info "清理脚本已生成: ${TEMP_WHITELIST_CLEANUP}"
}

# ---------- 临时 IP 白名单资源池主菜单 ----------
temp_whitelist_manage() {
    while true; do
        print_separator
        echo -e "${BOLD}  临时 IP 白名单资源池${NC}"
        print_separator
        echo ""
        echo "  1) 查看当前临时白名单"
        echo "  2) 添加临时白名单 IP（含过期时间）"
        echo "  3) 删除临时白名单条目"
        echo "  4) 立即清理过期条目"
        echo "  5) 设置自动清理定时任务"
        echo "  0) 返回上级菜单"
        echo ""
        select_option "请选择" 5 0

        case "$SELECTED_OPTION" in
            1) temp_whitelist_list ;;
            2) temp_whitelist_add ;;
            3) temp_whitelist_delete ;;
            4) _clean_expired_temp_whitelist ;;
            5) temp_whitelist_setup_cron ;;
            0) return 0 ;;
        esac
        press_any_key
    done
}

# ============================================================
# 入口函数
# ============================================================
run_firewall() {
    while true; do
        print_separator
        echo -e "${BOLD}  防火墙管理${NC}"
        print_separator
        echo ""
        echo "  1) 防火墙初始化"
        echo "  2) 防火墙规则管理"
        echo "  3) 一键拉黑恶意 IP"
        echo "  4) fail2ban 管理"
        echo "  5) 临时 IP 白名单资源池"
        echo "  0) 返回上级菜单"
        echo ""
        select_option "请选择" 5 0

        case "$SELECTED_OPTION" in
            1) firewall_init ;;
            2) firewall_modify ;;
            3) fw_quick_blacklist ;;
            4) fail2ban_manage ;;
            5) temp_whitelist_manage ;;
            0) return 0 ;;
        esac
        press_any_key
    done
}
