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
        echo "  0) 返回上级菜单"
        echo ""
        select_option "请选择" 2 0

        case "$SELECTED_OPTION" in
            1) firewall_init ;;
            2) firewall_modify ;;
            0) return 0 ;;
        esac
        press_any_key
    done
}
