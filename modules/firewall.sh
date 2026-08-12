#!/usr/bin/env bash
# ============================================================
# 防火墙管理模块 (nftables)
# - 防火墙初始化
# - 规则增删改查
# ============================================================

FIREWALL_MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${FIREWALL_MODULE_DIR}/common.sh"

NFTABLES_DIR="/etc/nftables.d"
NFTABLES_BASE_CONF="${NFTABLES_DIR}/base.conf"
NFTABLES_MAIN_CONF="/etc/nftables.conf"
IP_FORWARD_CONF="/etc/sysctl.d/99-ops-scripts-forward.conf"

_fw_validate_port() {
    local value="$1" start end
    if [[ "$value" =~ ^([0-9]{1,5})(-([0-9]{1,5}))?$ ]]; then
        start="${BASH_REMATCH[1]}"
        end="${BASH_REMATCH[3]:-${BASH_REMATCH[1]}}"
        [ "$start" -ge 1 ] && [ "$start" -le 65535 ] \
            && [ "$end" -ge 1 ] && [ "$end" -le 65535 ] \
            && [ "$start" -le "$end" ]
        return
    fi
    return 1
}

_fw_validate_single_port() {
    _fw_validate_port "$1" && [[ "$1" != *-* ]]
}

_fw_validate_ipv4() {
    local address="${1%%/*}" prefix="" octet
    local -a octets
    if [[ "$1" == */* ]]; then
        prefix="${1##*/}"
        [[ "$prefix" =~ ^[0-9]{1,2}$ ]] && [ "$prefix" -le 32 ] || return 1
    fi
    IFS='.' read -r -a octets <<< "$address"
    [ "${#octets[@]}" -eq 4 ] || return 1
    for octet in "${octets[@]}"; do
        [[ "$octet" =~ ^[0-9]{1,3}$ ]] && [ "$((10#$octet))" -le 255 ] || return 1
    done
}

_fw_validate_ip_cidr() {
    local value="$1" address prefix rest piece compressed=false groups=0
    local -a pieces
    if [[ "$value" == *:* ]]; then
        [[ "$value" =~ ^[0-9A-Fa-f:]+(/[0-9]{1,3})?$ ]] || return 1
        address="${value%%/*}"
        [[ "$address" == *:* ]] && [[ "$address" != *:::* ]] || return 1
        if [[ "$address" == *::* ]]; then
            compressed=true
            rest="${address#*::}"
            [[ "$rest" != *::* ]] || return 1
        fi
        IFS=':' read -r -a pieces <<< "${address//::/:x:}"
        for piece in "${pieces[@]}"; do
            [ -z "$piece" ] && continue
            if [ "$piece" = x ]; then
                continue
            fi
            [[ "$piece" =~ ^[0-9A-Fa-f]{1,4}$ ]] || return 1
            groups=$((groups + 1))
        done
        if [ "$compressed" = true ]; then
            [ "$groups" -lt 8 ] || return 1
        else
            [ "$groups" -eq 8 ] || return 1
        fi
        if [[ "$value" == */* ]]; then
            prefix="${value##*/}"
            [ "$((10#$prefix))" -le 128 ] || return 1
        fi
        return 0
    fi
    _fw_validate_ipv4 "$value"
}

_fw_address_family_keyword() {
    if [[ "$1" == *:* ]]; then
        printf 'ip6'
    else
        printf 'ip'
    fi
}

_fw_validate_rate() {
    [[ "$1" =~ ^([1-9][0-9]{0,6})/(second|minute|hour)$ ]]
}

_fw_write_base_conf() {
    local output="$1" ssh_port="$2" enable_web="${3:-false}"
    {
        printf '%s\n' '#!/usr/sbin/nft -f'
        printf '%s\n' '# OPS-SCRIPTS FIREWALL BASE v2'
        printf '%s\n' '# 自定义规则使用普通链，所有最终判定均在同一个 input base chain 中完成。'
        printf '%s\n' 'table inet ops_filter {'
        printf '%s\n' '    chain ops_blacklist { }'
        printf '%s\n' '    chain ops_whitelist { }'
        printf '%s\n' '    chain ops_rate_limit { }'
        printf '%s\n' '    chain ops_ports { }'
        printf '%s\n' '    chain ops_forward { }'
        printf '%s\n' '    chain input {'
        printf '%s\n' '        type filter hook input priority 0; policy drop;'
        printf '%s\n' '        iifname "lo" accept'
        printf '%s\n' '        ct state established,related accept'
        printf '%s\n' '        ct state invalid drop'
        printf '%s\n' '        jump ops_blacklist'
        printf '%s\n' '        jump ops_whitelist'
        printf '%s\n' '        ip protocol icmp limit rate 10/second accept'
        printf '%s\n' '        ip6 nexthdr icmpv6 limit rate 10/second accept'
        printf '%s\n' '        jump ops_rate_limit'
        printf '%s\n' '        jump ops_ports'
        printf '        tcp dport %s accept\n' "$ssh_port"
        if [ "$enable_web" = true ]; then
            printf '%s\n' '        tcp dport { 80, 443 } accept'
        fi
        printf '%s\n' '        limit rate 5/minute log prefix "nftables-drop: " level warn'
        printf '%s\n' '    }'
        printf '%s\n' '    chain forward {'
        printf '%s\n' '        type filter hook forward priority 0; policy drop;'
        printf '%s\n' '        ct state established,related accept'
        printf '%s\n' '        jump ops_forward'
        printf '%s\n' '    }'
        printf '%s\n' '    chain output {'
        printf '%s\n' '        type filter hook output priority 0; policy accept;'
        printf '%s\n' '    }'
        printf '%s\n' '}'
        printf '%s\n' 'table ip ops_nat {'
        printf '%s\n' '    chain prerouting {'
        printf '%s\n' '        type nat hook prerouting priority dstnat; policy accept;'
        printf '%s\n' '    }'
        printf '%s\n' '    chain postrouting {'
        printf '%s\n' '        type nat hook postrouting priority srcnat; policy accept;'
        printf '%s\n' '    }'
        printf '%s\n' '}'
    } > "$output"
}

_fw_write_main_conf() {
    local output="$1"
    {
        printf '%s\n' '#!/usr/sbin/nft -f' '' 'flush ruleset'
        printf '%s\n' 'include "/etc/nftables.d/base.conf"'
        printf '%s\n' 'include "/etc/nftables.d/custom_ports.conf"'
        printf '%s\n' 'include "/etc/nftables.d/ip_whitelist.conf"'
        printf '%s\n' 'include "/etc/nftables.d/temp_whitelist.conf"'
        printf '%s\n' 'include "/etc/nftables.d/ip_blacklist.conf"'
        printf '%s\n' 'include "/etc/nftables.d/rate_limit.conf"'
        printf '%s\n' 'include "/etc/nftables.d/port_forward.conf"'
    } > "$output"
}

_fw_empty_rule_file() {
    local output="$1" description="$2"
    printf '#!/usr/sbin/nft -f\n# %s - 由 ops-scripts 管理\n' "$description" > "$output"
}

_fw_build_validation_bundle() {
    local output="$1" candidate="${2:-}" target="${3:-}" file
    printf 'flush ruleset\n' > "$output"

    if [ "$target" = "$NFTABLES_BASE_CONF" ]; then
        cat "$candidate" >> "$output"
    elif [ -f "$NFTABLES_BASE_CONF" ]; then
        cat "$NFTABLES_BASE_CONF" >> "$output"
    else
        return 1
    fi

    local -a managed_files=(
        "${NFTABLES_DIR}/custom_ports.conf"
        "${NFTABLES_DIR}/ip_whitelist.conf"
        "${NFTABLES_DIR}/temp_whitelist.conf"
        "${NFTABLES_DIR}/ip_blacklist.conf"
        "${NFTABLES_DIR}/rate_limit.conf"
        "${NFTABLES_DIR}/port_forward.conf"
    )
    for file in "${managed_files[@]}"; do
        if [ "$file" = "$target" ]; then
            cat "$candidate" >> "$output"
        elif [ -f "$file" ]; then
            cat "$file" >> "$output"
        fi
    done
}

_fw_validate_bundle() {
    local candidate="${1:-}" target="${2:-}" bundle
    bundle=$(mktemp "${NFTABLES_DIR}/.validate.XXXXXX") || return 1
    if ! _fw_build_validation_bundle "$bundle" "$candidate" "$target"; then
        rm -f "$bundle"
        return 1
    fi
    if nft -c -f "$bundle" 2>/dev/null; then
        rm -f "$bundle"
        return 0
    fi
    log_error "规则验证失败:"
    nft -c -f "$bundle" || true
    rm -f "$bundle"
    return 1
}

_fw_apply_candidate() {
    local candidate="$1" target="$2" backup existed=false
    [ -f "$candidate" ] || return 1
    if ! _fw_validate_bundle "$candidate" "$target"; then
        return 1
    fi

    backup=$(mktemp "${NFTABLES_DIR}/.backup.XXXXXX") || return 1
    if [ -f "$target" ]; then
        cp -p -- "$target" "$backup"
        existed=true
    fi
    chmod 0644 "$candidate"
    if ! mv -f -- "$candidate" "$target"; then
        rm -f "$backup"
        return 1
    fi

    if systemctl restart nftables; then
        rm -f "$backup"
        return 0
    fi

    log_error "防火墙重载失败，正在恢复上一份规则"
    if [ "$existed" = true ]; then
        mv -f -- "$backup" "$target"
    else
        rm -f -- "$target" "$backup"
    fi
    if ! systemctl restart nftables; then
        log_error "旧规则恢复后仍无法重载，请保持当前连接并立即人工检查 nftables"
    fi
    return 1
}

_fw_new_candidate() {
    local target="$1" description="$2" candidate
    candidate=$(mktemp "${NFTABLES_DIR}/.candidate.XXXXXX") || return 1
    if [ -f "$target" ]; then
        cp -p -- "$target" "$candidate"
    else
        _fw_empty_rule_file "$candidate" "$description"
    fi
    printf '%s' "$candidate"
}

_fw_append_rule() {
    local target="$1" description="$2" rule="$3" candidate
    candidate=$(_fw_new_candidate "$target" "$description") || return 1
    printf '%s\n' "$rule" >> "$candidate"
    if _fw_apply_candidate "$candidate" "$target"; then
        return 0
    fi
    rm -f "$candidate"
    return 1
}

_fw_delete_rule_by_line() {
    local target="$1" line_num="$2" expected_pattern="$3" candidate selected
    [[ "$line_num" =~ ^[0-9]+$ ]] || return 1
    selected=$(sed -n "${line_num}p" "$target")
    if ! [[ "$selected" =~ $expected_pattern ]]; then
        log_error "指定行不是此功能管理的规则，拒绝删除"
        return 1
    fi
    candidate=$(_fw_new_candidate "$target" "防火墙规则") || return 1
    sed -i "${line_num}d" "$candidate"
    if _fw_apply_candidate "$candidate" "$target"; then
        return 0
    fi
    rm -f "$candidate"
    return 1
}

_fw_rollback_forward_rule() {
    local conf_file="$1" rule_id="$2" candidate
    candidate=$(_fw_new_candidate "$conf_file" "端口转发规则") || return 1
    sed -i "/# ops-forward:${rule_id}$/d" "$candidate"
    if _fw_apply_candidate "$candidate" "$conf_file"; then
        return 0
    fi
    rm -f "$candidate"
    return 1
}

_fw_restore_ip_forward_conf() {
    local backup="$1" existed="$2"
    if [ "$existed" = true ]; then
        mv -f -- "$backup" "$IP_FORWARD_CONF"
    else
        rm -f -- "$IP_FORWARD_CONF" "$backup"
    fi
}

_fw_restore_ip_forward_runtime() {
    local old_value="$1"
    if [[ "$old_value" =~ ^[01]$ ]]; then
        sysctl -w "net.ipv4.ip_forward=${old_value}" >/dev/null 2>&1 || true
    fi
}

_fw_install_layout() {
    local ssh_port="$1" enable_web="$2" base_candidate main_candidate
    local base_backup main_backup base_existed=false main_existed=false
    local -a created_rule_files=()
    base_candidate=$(mktemp "${NFTABLES_DIR}/.base.XXXXXX") || return 1
    main_candidate=$(mktemp "$(dirname "$NFTABLES_MAIN_CONF")/.nft-main.XXXXXX") || {
        rm -f "$base_candidate"
        return 1
    }
    _fw_write_base_conf "$base_candidate" "$ssh_port" "$enable_web"
    _fw_write_main_conf "$main_candidate"
    if ! _fw_validate_bundle "$base_candidate" "$NFTABLES_BASE_CONF"; then
        rm -f "$base_candidate" "$main_candidate"
        return 1
    fi

    base_backup=$(mktemp "${NFTABLES_DIR}/.base-backup.XXXXXX") || return 1
    main_backup=$(mktemp "$(dirname "$NFTABLES_MAIN_CONF")/.main-backup.XXXXXX") || return 1
    if [ -f "$NFTABLES_BASE_CONF" ]; then
        cp -p -- "$NFTABLES_BASE_CONF" "$base_backup"
        base_existed=true
    fi
    if [ -f "$NFTABLES_MAIN_CONF" ]; then
        cp -p -- "$NFTABLES_MAIN_CONF" "$main_backup"
        main_existed=true
    fi
    chmod 0644 "$base_candidate" "$main_candidate"
    mv -f -- "$base_candidate" "$NFTABLES_BASE_CONF"
    mv -f -- "$main_candidate" "$NFTABLES_MAIN_CONF"
    local name file
    for name in custom_ports.conf ip_whitelist.conf temp_whitelist.conf ip_blacklist.conf rate_limit.conf port_forward.conf; do
        file="${NFTABLES_DIR}/${name}"
        if [ ! -f "$file" ]; then
            _fw_empty_rule_file "$file" "防火墙规则"
            chmod 0644 "$file"
            created_rule_files+=("$file")
        fi
    done
    if systemctl restart nftables; then
        rm -f "$base_backup" "$main_backup"
        return 0
    fi

    log_error "新防火墙规则加载失败，正在回滚"
    if [ "$base_existed" = true ]; then mv -f -- "$base_backup" "$NFTABLES_BASE_CONF"; else rm -f "$NFTABLES_BASE_CONF" "$base_backup"; fi
    if [ "$main_existed" = true ]; then mv -f -- "$main_backup" "$NFTABLES_MAIN_CONF"; else rm -f "$NFTABLES_MAIN_CONF" "$main_backup"; fi
    for file in "${created_rule_files[@]}"; do rm -f -- "$file"; done
    systemctl restart nftables || log_error "旧规则恢复后仍无法重载，请立即人工检查"
    return 1
}

_fw_replace_managed_rules() {
    local base_source="$1" staging backup file staged_file
    local -a managed_names=(base.conf custom_ports.conf ip_whitelist.conf temp_whitelist.conf ip_blacklist.conf rate_limit.conf port_forward.conf)
    staging=$(mktemp -d "${NFTABLES_DIR}/.replace.XXXXXX") || return 1
    backup=$(mktemp -d "${NFTABLES_DIR}/.replace-backup.XXXXXX") || { rm -rf "$staging"; return 1; }

    if grep -Eq '(^|[[:space:]])flush[[:space:]]+ruleset([[:space:]]|$)|(^|[[:space:]])include[[:space:]]' "$base_source"; then
        log_error "导入规则不得包含 flush ruleset 或 include；请提供单个自包含 ruleset"
        rm -rf "$staging" "$backup"
        return 1
    fi
    cp -- "$base_source" "${staging}/base.conf"
    local name
    for name in "${managed_names[@]:1}"; do
        _fw_empty_rule_file "${staging}/${name}" "防火墙规则"
    done

    local bundle
    bundle=$(mktemp "${NFTABLES_DIR}/.replace-validate.XXXXXX") || { rm -rf "$staging" "$backup"; return 1; }
    printf 'flush ruleset\n' > "$bundle"
    for name in "${managed_names[@]}"; do cat "${staging}/${name}" >> "$bundle"; done
    if ! nft -c -f "$bundle" 2>/dev/null; then
        log_error "候选规则未通过 nft 验证"
        nft -c -f "$bundle" || true
        rm -f "$bundle"
        rm -rf "$staging" "$backup"
        return 1
    fi
    rm -f "$bundle"

    for name in "${managed_names[@]}"; do
        file="${NFTABLES_DIR}/${name}"
        if [ -f "$file" ]; then cp -p -- "$file" "${backup}/${name}"; fi
        chmod 0644 "${staging}/${name}"
        mv -f -- "${staging}/${name}" "$file"
    done
    if systemctl restart nftables; then
        rm -rf "$staging" "$backup"
        return 0
    fi

    log_error "候选规则加载失败，正在恢复全部受管规则"
    for name in "${managed_names[@]}"; do
        file="${NFTABLES_DIR}/${name}"
        if [ -f "${backup}/${name}" ]; then
            mv -f -- "${backup}/${name}" "$file"
        else
            rm -f -- "$file"
        fi
    done
    systemctl restart nftables || log_error "旧规则恢复后仍无法重载，请立即人工检查"
    rm -rf "$staging" "$backup"
    return 1
}

_fw_migrate_legacy_layout() {
    if grep -q '^# OPS-SCRIPTS FIREWALL BASE v2$' "$NFTABLES_BASE_CONF" 2>/dev/null; then
        return 0
    fi

    log_warn "检测到旧版 nftables 规则布局，将在完整验证后原子迁移"
    local staging backup name line trimmed ssh_port web=false family address proto ports rate target target_port source_port rule_id
    local -a names=(base.conf custom_ports.conf ip_whitelist.conf temp_whitelist.conf ip_blacklist.conf rate_limit.conf port_forward.conf)
    staging=$(mktemp -d "${NFTABLES_DIR}/.migrate.XXXXXX") || return 1
    backup=$(mktemp -d "${NFTABLES_DIR}/.migrate-backup.XXXXXX") || { rm -rf "$staging"; return 1; }
    ssh_port=$(get_ssh_port)
    _fw_validate_single_port "$ssh_port" || { log_error "SSH 端口无效，无法安全迁移"; rm -rf "$staging" "$backup"; return 1; }
    if grep -q 'tcp dport { 80, 443 } accept' "$NFTABLES_BASE_CONF" 2>/dev/null; then web=true; fi
    _fw_write_base_conf "${staging}/base.conf" "$ssh_port" "$web"
    for name in "${names[@]:1}"; do _fw_empty_rule_file "${staging}/${name}" "防火墙规则"; done

    if [ -f "${NFTABLES_DIR}/custom_ports.conf" ]; then
        while IFS= read -r line; do
            trimmed="${line#"${line%%[![:space:]]*}"}"
            if [[ "$trimmed" =~ ^((ip6?|ip)[[:space:]]+saddr[[:space:]]+([^[:space:]]+)[[:space:]]+)?(tcp|udp)[[:space:]]+dport[[:space:]]+([0-9]+(-[0-9]+)?)[[:space:]]+accept ]]; then
                family="${BASH_REMATCH[2]}"; address="${BASH_REMATCH[3]}"; proto="${BASH_REMATCH[4]}"; ports="${BASH_REMATCH[5]}"
                if [ -n "$family" ]; then
                    printf 'add rule inet ops_filter ops_ports %s saddr %s %s dport %s accept # ops-port\n' "$family" "$address" "$proto" "$ports" >> "${staging}/custom_ports.conf"
                else
                    printf 'add rule inet ops_filter ops_ports %s dport %s accept # ops-port\n' "$proto" "$ports" >> "${staging}/custom_ports.conf"
                fi
            fi
        done < "${NFTABLES_DIR}/custom_ports.conf"
    fi

    for name in ip_whitelist ip_blacklist; do
        if [ -f "${NFTABLES_DIR}/${name}.conf" ]; then
            while IFS= read -r line; do
                trimmed="${line#"${line%%[![:space:]]*}"}"
                if [[ "$trimmed" =~ ^(ip6?|ip)[[:space:]]+saddr[[:space:]]+([^[:space:]]+)[[:space:]]+(accept|drop) ]]; then
                    family="${BASH_REMATCH[1]}"; address="${BASH_REMATCH[2]}"
                    if [ "$name" = ip_whitelist ]; then
                        printf 'add rule inet ops_filter ops_whitelist %s saddr %s accept # ops-whitelist\n' "$family" "$address" >> "${staging}/${name}.conf"
                    else
                        printf 'add rule inet ops_filter ops_blacklist %s saddr %s drop # ops-blacklist\n' "$family" "$address" >> "${staging}/${name}.conf"
                    fi
                fi
            done < "${NFTABLES_DIR}/${name}.conf"
        fi
    done

    if [ -f "${NFTABLES_DIR}/rate_limit.conf" ]; then
        while IFS= read -r line; do
            trimmed="${line#"${line%%[![:space:]]*}"}"
            if [[ "$trimmed" =~ ^tcp[[:space:]]+dport[[:space:]]+([0-9]+)[[:space:]]+limit[[:space:]]+rate[[:space:]]+([^[:space:]]+)[[:space:]]+accept ]]; then
                ports="${BASH_REMATCH[1]}"; rate="${BASH_REMATCH[2]}"; rule_id="migrated-${ports}-${RANDOM}"
                printf 'add rule inet ops_filter ops_rate_limit tcp dport %s limit rate %s accept # ops-rate:%s\n' "$ports" "$rate" "$rule_id" >> "${staging}/rate_limit.conf"
                printf 'add rule inet ops_filter ops_rate_limit tcp dport %s drop # ops-rate:%s\n' "$ports" "$rule_id" >> "${staging}/rate_limit.conf"
            fi
        done < "${NFTABLES_DIR}/rate_limit.conf"
    fi

    if [ -f "${NFTABLES_DIR}/port_forward.conf" ]; then
        while IFS= read -r line; do
            trimmed="${line#"${line%%[![:space:]]*}"}"
            if [[ "$trimmed" =~ ^(tcp|udp)[[:space:]]+dport[[:space:]]+([0-9]+)[[:space:]]+dnat[[:space:]]+to[[:space:]]+([0-9.]+):([0-9]+) ]]; then
                proto="${BASH_REMATCH[1]}"; source_port="${BASH_REMATCH[2]}"; target="${BASH_REMATCH[3]}"; target_port="${BASH_REMATCH[4]}"; rule_id="migrated-${source_port}-${RANDOM}"
                printf 'add rule ip ops_nat prerouting %s dport %s dnat to %s:%s # ops-forward:%s\n' "$proto" "$source_port" "$target" "$target_port" "$rule_id" >> "${staging}/port_forward.conf"
                printf 'add rule inet ops_filter ops_forward ip daddr %s %s dport %s accept # ops-forward:%s\n' "$target" "$proto" "$target_port" "$rule_id" >> "${staging}/port_forward.conf"
                printf 'add rule ip ops_nat postrouting ip daddr %s %s dport %s masquerade # ops-forward:%s\n' "$target" "$proto" "$target_port" "$rule_id" >> "${staging}/port_forward.conf"
            fi
        done < "${NFTABLES_DIR}/port_forward.conf"
    fi

    if [ -f "$TEMP_WHITELIST_DATA" ]; then
        _render_temp_whitelist_conf "$TEMP_WHITELIST_DATA" "${staging}/temp_whitelist.conf" || { rm -rf "$staging" "$backup"; return 1; }
    fi

    local bundle main_candidate main_backup main_existed=false file
    bundle=$(mktemp "${NFTABLES_DIR}/.migrate-validate.XXXXXX") || return 1
    printf 'flush ruleset\n' > "$bundle"
    for name in "${names[@]}"; do cat "${staging}/${name}" >> "$bundle"; done
    if ! nft -c -f "$bundle" 2>/dev/null; then
        log_error "旧规则迁移结果未通过验证，未修改现有配置"
        nft -c -f "$bundle" || true
        rm -f "$bundle"; rm -rf "$staging" "$backup"; return 1
    fi
    rm -f "$bundle"
    main_candidate=$(mktemp "$(dirname "$NFTABLES_MAIN_CONF")/.migrate-main.XXXXXX") || return 1
    _fw_write_main_conf "$main_candidate"
    main_backup=$(mktemp "$(dirname "$NFTABLES_MAIN_CONF")/.migrate-main-backup.XXXXXX") || return 1
    if [ -f "$NFTABLES_MAIN_CONF" ]; then cp -p -- "$NFTABLES_MAIN_CONF" "$main_backup"; main_existed=true; fi
    for name in "${names[@]}"; do
        file="${NFTABLES_DIR}/${name}"
        [ -f "$file" ] && cp -p -- "$file" "${backup}/${name}"
        chmod 0644 "${staging}/${name}"
        mv -f -- "${staging}/${name}" "$file"
    done
    chmod 0644 "$main_candidate"; mv -f -- "$main_candidate" "$NFTABLES_MAIN_CONF"
    if systemctl restart nftables; then
        rm -rf "$staging" "$backup"; rm -f "$main_backup"
        log_info "旧版防火墙规则已迁移到安全链路"
        return 0
    fi
    log_error "迁移规则加载失败，正在恢复旧配置"
    for name in "${names[@]}"; do
        file="${NFTABLES_DIR}/${name}"
        if [ -f "${backup}/${name}" ]; then mv -f -- "${backup}/${name}" "$file"; else rm -f -- "$file"; fi
    done
    if [ "$main_existed" = true ]; then mv -f -- "$main_backup" "$NFTABLES_MAIN_CONF"; else rm -f "$NFTABLES_MAIN_CONF" "$main_backup"; fi
    systemctl restart nftables || log_error "旧配置恢复后仍无法重载，请立即人工检查"
    rm -rf "$staging" "$backup"
    return 1
}

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

    # 确保 nftables 已安装
    if ! command -v nft &>/dev/null; then
        log_step "正在安装 nftables..."
        if ! apt install -y nftables; then
            log_error "nftables 安装失败"
            return 1
        fi
    fi

    if ! systemctl enable nftables; then
        log_error "无法启用 nftables 服务"
        return 1
    fi
    log_info "nftables 服务已启用"

    # 创建规则目录
    mkdir -p "$NFTABLES_DIR"

    # 获取当前 SSH 端口
    local ssh_port
    ssh_port=$(get_ssh_port)
    if ! _fw_validate_single_port "$ssh_port"; then
        log_error "检测到无效 SSH 端口: ${ssh_port}"
        return 1
    fi
    log_info "当前 SSH 端口: ${ssh_port}"

    # 询问是否开放 Web 端口
    local enable_web=false
    if confirm "是否开放 Web 端口 (80 和 443)?"; then
        enable_web=true
    fi

    if [ -f "$NFTABLES_BASE_CONF" ] \
        && ! grep -q '^# OPS-SCRIPTS FIREWALL BASE v2$' "$NFTABLES_BASE_CONF"; then
        if ! _fw_migrate_legacy_layout; then
            log_error "已有旧版规则无法安全迁移，防火墙初始化已取消"
            return 1
        fi
    fi

    # 先生成并验证候选规则，再处理可能与 nftables 冲突的 ufw。
    log_step "正在生成并预检基础防火墙规则..."
    local preflight_candidate
    preflight_candidate=$(mktemp "${NFTABLES_DIR}/.base-preflight.XXXXXX") || return 1
    _fw_write_base_conf "$preflight_candidate" "$ssh_port" "$enable_web"
    if ! _fw_validate_bundle "$preflight_candidate" "$NFTABLES_BASE_CONF"; then
        rm -f "$preflight_candidate"
        log_error "候选防火墙规则未通过验证，现有防火墙未变更"
        return 1
    fi
    rm -f "$preflight_candidate"

    local ufw_was_active=false
    if [ "$OS_ID" = "ubuntu" ] && command -v ufw &>/dev/null; then
        if systemctl is-active ufw >/dev/null 2>&1; then ufw_was_active=true; fi
        log_step "检测到 Ubuntu，正在停用可能冲突的 ufw..."
        if ! ufw disable >/dev/null 2>&1; then
            log_error "无法停用 ufw，拒绝加载第二套防火墙以避免规则冲突"
            return 1
        fi
        systemctl disable --now ufw >/dev/null 2>&1 || log_warn "ufw 已停用，但无法禁用其 systemd 单元"
    fi

    if ! _fw_install_layout "$ssh_port" "$enable_web"; then
        log_error "防火墙规则安装失败，原配置已保留或恢复"
        if [ "$ufw_was_active" = true ]; then
            log_warn "正在尝试恢复此前启用的 ufw"
            ufw --force enable >/dev/null 2>&1 || log_error "ufw 恢复失败，请保持当前连接并立即人工检查"
        fi
        return 1
    fi
    log_info "防火墙规则已验证并应用"

    # 显示当前规则
    echo ""
    log_info "当前防火墙规则:"
    print_thin_separator
    nft list ruleset || log_warn "无法读取当前 nftables 规则"
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
    nft list ruleset || log_error "无法读取当前 nftables 规则"
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
    if ! _fw_validate_port "$port"; then
        log_error "端口必须在 1-65535，且范围起始值不得大于结束值"
        return 1
    fi

    if ! _fw_migrate_legacy_layout; then
        log_error "旧版防火墙规则迁移失败，已保留原配置；拒绝继续修改"
        return 1
    fi

    echo ""
    echo "来源限制:"
    echo "  1) 任意来源"
    echo "  2) 指定 IP 或网段"
    select_option "选择" 2
    local src_filter="" family
    if [ "$SELECTED_OPTION" -eq 2 ]; then
        local src_ip
        read_nonempty "请输入源 IP 或网段 (如: 192.168.1.0/24)" src_ip
        if ! _fw_validate_ip_cidr "$src_ip"; then
            log_error "无效的 IP 地址或 CIDR"
            return 1
        fi
        family=$(_fw_address_family_keyword "$src_ip")
        src_filter="${family} saddr ${src_ip} "
    fi

    local conf_file="${NFTABLES_DIR}/custom_ports.conf"
    local candidate
    candidate=$(_fw_new_candidate "$conf_file" "自定义端口放行规则") || return 1
    case "$proto_choice" in
        1) printf 'add rule inet ops_filter ops_ports %stcp dport %s accept # ops-port\n' "$src_filter" "$port" >> "$candidate" ;;
        2) printf 'add rule inet ops_filter ops_ports %sudp dport %s accept # ops-port\n' "$src_filter" "$port" >> "$candidate" ;;
        3)
            printf 'add rule inet ops_filter ops_ports %stcp dport %s accept # ops-port\n' "$src_filter" "$port" >> "$candidate"
            printf 'add rule inet ops_filter ops_ports %sudp dport %s accept # ops-port\n' "$src_filter" "$port" >> "$candidate"
            ;;
    esac
    if _fw_apply_candidate "$candidate" "$conf_file"; then
        log_info "端口放行规则已添加: ${port}"
    else
        rm -f "$candidate"
        log_error "规则添加失败，原规则已保留或恢复"
        return 1
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
    grep -n '# ops-port$' "$conf_file" || true
    print_thin_separator

    local line_num
    read_nonempty "请输入要删除的规则行号" line_num

    if ! [[ "$line_num" =~ ^[0-9]+$ ]]; then
        log_error "无效的行号"
        return 1
    fi
    if _fw_delete_rule_by_line "$conf_file" "$line_num" '# ops-port$'; then
        log_info "规则已删除"
    else
        log_error "规则删除失败，原规则已保留或恢复"
        return 1
    fi
}

# ---------- 添加 IP 白名单 ----------
fw_add_ip_whitelist() {
    log_step "添加 IP 白名单"
    echo ""

    local ip
    read_nonempty "请输入要放行的 IP 地址或网段 (如: 10.0.0.1 或 192.168.0.0/24)" ip
    if ! _fw_validate_ip_cidr "$ip"; then
        log_error "无效的 IP 地址或 CIDR"
        return 1
    fi

    local conf_file="${NFTABLES_DIR}/ip_whitelist.conf"
    local family
    family=$(_fw_address_family_keyword "$ip")
    if _fw_append_rule "$conf_file" "IP 白名单规则" \
        "add rule inet ops_filter ops_whitelist ${family} saddr ${ip} accept # ops-whitelist"; then
        log_info "IP 白名单已添加: ${ip}"
    else
        log_error "添加失败，原规则已保留或恢复"
        return 1
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
    grep -n '# ops-whitelist$' "$conf_file" || true
    print_thin_separator

    local line_num
    read_nonempty "请输入要删除的规则行号" line_num
    if ! [[ "$line_num" =~ ^[0-9]+$ ]]; then
        log_error "无效的行号"
        return 1
    fi
    if _fw_delete_rule_by_line "$conf_file" "$line_num" '# ops-whitelist$'; then
        log_info "IP 白名单规则已删除"
    else
        log_error "删除失败，原规则已保留或恢复"
        return 1
    fi
}

# ---------- 添加 IP 黑名单 ----------
fw_add_ip_blacklist() {
    log_step "添加 IP 黑名单（封禁）"
    echo ""

    local ip
    read_nonempty "请输入要封禁的 IP 地址或网段" ip
    if ! _fw_validate_ip_cidr "$ip"; then
        log_error "无效的 IP 地址或 CIDR"
        return 1
    fi

    local conf_file="${NFTABLES_DIR}/ip_blacklist.conf"
    local family
    family=$(_fw_address_family_keyword "$ip")
    if _fw_append_rule "$conf_file" "IP 黑名单规则" \
        "add rule inet ops_filter ops_blacklist ${family} saddr ${ip} drop # ops-blacklist"; then
        log_info "IP 已封禁: ${ip}"
    else
        log_error "封禁失败，原规则已保留或恢复"
        return 1
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
    grep -n '# ops-blacklist$' "$conf_file" || true
    print_thin_separator

    local line_num
    read_nonempty "请输入要删除的规则行号" line_num
    if ! [[ "$line_num" =~ ^[0-9]+$ ]]; then
        log_error "无效的行号"
        return 1
    fi
    if _fw_delete_rule_by_line "$conf_file" "$line_num" '# ops-blacklist$'; then
        log_info "IP 黑名单规则已删除"
    else
        log_error "删除失败，原规则已保留或恢复"
        return 1
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
    if [ "$SELECTED_OPTION" -eq 1 ]; then proto="tcp"; else proto="udp"; fi

    local src_port dest_ip dest_port
    read_nonempty "请输入源端口" src_port
    read_nonempty "请输入目标 IP" dest_ip
    read_nonempty "请输入目标端口" dest_port
    if ! _fw_validate_single_port "$src_port" || ! _fw_validate_single_port "$dest_port"; then
        log_error "源端口和目标端口必须为 1-65535 的单个端口"
        return 1
    fi
    if ! _fw_validate_ipv4 "$dest_ip" || [[ "$dest_ip" == */* ]]; then
        log_error "端口转发目标必须为单个 IPv4 地址"
        return 1
    fi

    local conf_file="${NFTABLES_DIR}/port_forward.conf"
    local rule_id candidate
    rule_id="$(date +%s)-${RANDOM}"
    candidate=$(_fw_new_candidate "$conf_file" "端口转发规则") || return 1
    printf 'add rule ip ops_nat prerouting %s dport %s dnat to %s:%s # ops-forward:%s\n' \
        "$proto" "$src_port" "$dest_ip" "$dest_port" "$rule_id" >> "$candidate"
    printf 'add rule inet ops_filter ops_forward ip daddr %s %s dport %s accept # ops-forward:%s\n' \
        "$dest_ip" "$proto" "$dest_port" "$rule_id" >> "$candidate"
    printf 'add rule ip ops_nat postrouting ip daddr %s %s dport %s masquerade # ops-forward:%s\n' \
        "$dest_ip" "$proto" "$dest_port" "$rule_id" >> "$candidate"

    if _fw_apply_candidate "$candidate" "$conf_file"; then
        local sysctl_candidate sysctl_backup ip_forward_existed=false previous_ip_forward
        previous_ip_forward=$(sysctl -n net.ipv4.ip_forward 2>/dev/null || true)
        sysctl_candidate=$(mktemp "$(dirname "$IP_FORWARD_CONF")/.ip-forward.XXXXXX") || {
            log_error "无法创建 IP 转发配置候选，正在撤回防火墙规则"
            _fw_rollback_forward_rule "$conf_file" "$rule_id" || log_error "自动撤回规则失败，请立即人工检查"
            return 1
        }
        sysctl_backup=$(mktemp "$(dirname "$IP_FORWARD_CONF")/.ip-forward-backup.XXXXXX") || {
            rm -f "$sysctl_candidate"
            log_error "无法创建 IP 转发配置备份，正在撤回防火墙规则"
            _fw_rollback_forward_rule "$conf_file" "$rule_id" || log_error "自动撤回规则失败，请立即人工检查"
            return 1
        }
        if [ -f "$IP_FORWARD_CONF" ]; then
            if ! cp -p -- "$IP_FORWARD_CONF" "$sysctl_backup"; then
                rm -f "$sysctl_candidate" "$sysctl_backup"
                log_error "无法备份原 IP 转发配置，正在撤回防火墙规则"
                _fw_rollback_forward_rule "$conf_file" "$rule_id" || log_error "自动撤回规则失败，请立即人工检查"
                return 1
            fi
            ip_forward_existed=true
        fi
        printf 'net.ipv4.ip_forward = 1\n' > "$sysctl_candidate"
        chmod 0644 "$sysctl_candidate"
        if ! mv -f -- "$sysctl_candidate" "$IP_FORWARD_CONF"; then
            rm -f "$sysctl_candidate"
            _fw_restore_ip_forward_conf "$sysctl_backup" "$ip_forward_existed"
            log_error "无法安装 IP 转发配置，正在撤回防火墙规则"
            _fw_rollback_forward_rule "$conf_file" "$rule_id" || log_error "自动撤回规则失败，请立即人工检查"
            return 1
        fi
        if ! sysctl -w net.ipv4.ip_forward=1 >/dev/null; then
            log_error "无法启用 IPv4 转发，正在恢复配置并撤回防火墙规则"
            _fw_restore_ip_forward_conf "$sysctl_backup" "$ip_forward_existed"
            _fw_restore_ip_forward_runtime "$previous_ip_forward"
            _fw_rollback_forward_rule "$conf_file" "$rule_id" || log_error "自动撤回规则失败，请立即人工检查"
            return 1
        fi
        rm -f "$sysctl_backup"
        log_info "端口转发规则已添加: ${src_port} -> ${dest_ip}:${dest_port}"
    else
        rm -f "$candidate"
        log_error "添加失败，原规则已保留或恢复"
        return 1
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
    grep -n 'ops-forward:' "$conf_file" | grep 'dnat to' || true
    print_thin_separator

    local line_num selected rule_id candidate
    read_nonempty "请输入要删除的规则行号" line_num
    if ! [[ "$line_num" =~ ^[0-9]+$ ]]; then
        log_error "无效的行号"
        return 1
    fi
    selected=$(sed -n "${line_num}p" "$conf_file")
    if [[ "$selected" =~ ops-forward:([A-Za-z0-9-]+)$ ]]; then
        rule_id="${BASH_REMATCH[1]}"
    else
        log_error "指定行不是本工具管理的端口转发规则"
        return 1
    fi
    candidate=$(_fw_new_candidate "$conf_file" "端口转发规则") || return 1
    sed -i "/# ops-forward:${rule_id}$/d" "$candidate"
    if _fw_apply_candidate "$candidate" "$conf_file"; then
        log_info "端口转发规则及其限定的转发/masquerade 规则已删除"
    else
        rm -f "$candidate"
        log_error "删除失败，原规则已保留或恢复"
        return 1
    fi
}

# ---------- 添加速率限制规则 ----------
fw_add_rate_limit() {
    log_step "添加速率限制规则"
    echo ""

    local port rate
    read_nonempty "请输入要限制的端口号" port
    if ! _fw_validate_single_port "$port"; then
        log_error "端口必须为 1-65535 的单个端口"
        return 1
    fi
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
    if ! _fw_validate_rate "$rate"; then
        log_error "速率格式无效，应为正整数/second、/minute 或 /hour"
        return 1
    fi

    local conf_file="${NFTABLES_DIR}/rate_limit.conf"
    local rule_id candidate
    rule_id="$(date +%s)-${RANDOM}"
    candidate=$(_fw_new_candidate "$conf_file" "速率限制规则") || return 1
    printf 'add rule inet ops_filter ops_rate_limit tcp dport %s limit rate %s accept # ops-rate:%s\n' "$port" "$rate" "$rule_id" >> "$candidate"
    printf 'add rule inet ops_filter ops_rate_limit tcp dport %s drop # ops-rate:%s\n' "$port" "$rule_id" >> "$candidate"
    if _fw_apply_candidate "$candidate" "$conf_file"; then
        log_info "速率限制已设置: 端口 ${port} 限制 ${rate}"
    else
        rm -f "$candidate"
        log_error "添加失败，原规则已保留或恢复"
        return 1
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
    grep -n 'limit rate.*# ops-rate:' "$conf_file" || true
    print_thin_separator

    local line_num selected rule_id candidate
    read_nonempty "请输入要删除的规则行号" line_num
    if ! [[ "$line_num" =~ ^[0-9]+$ ]]; then
        log_error "无效的行号"
        return 1
    fi
    selected=$(sed -n "${line_num}p" "$conf_file")
    if [[ "$selected" =~ ops-rate:([A-Za-z0-9-]+)$ ]]; then
        rule_id="${BASH_REMATCH[1]}"
    else
        log_error "指定行不是本工具管理的速率限制规则"
        return 1
    fi
    candidate=$(_fw_new_candidate "$conf_file" "速率限制规则") || return 1
    sed -i "/# ops-rate:${rule_id}$/d" "$candidate"
    if _fw_apply_candidate "$candidate" "$conf_file"; then
        log_info "速率限制规则（accept/drop 配对）已删除"
    else
        rm -f "$candidate"
        log_error "删除失败，原规则已保留或恢复"
        return 1
    fi
}

# ---------- 重载防火墙 ----------
fw_reload() {
    log_step "正在重载防火墙规则..."
    if ! _fw_validate_bundle; then
        log_error "规则验证失败，未重载"
        return 1
    fi
    if systemctl restart nftables; then
        log_info "防火墙规则已重载"
    else
        log_error "防火墙重载失败"
        return 1
    fi
}

# ---------- 导出规则 ----------
fw_export() {
    local export_file
    read_optional "导出文件路径" export_file "/root/nftables_backup_$(date +%Y%m%d%H%M%S).conf"
    local export_dir
    export_dir=$(dirname "$export_file")
    if [ ! -d "$export_dir" ]; then
        log_error "导出目录不存在: ${export_dir}"
        return 1
    fi
    if ! nft list ruleset > "$export_file"; then
        log_error "规则导出失败"
        return 1
    fi
    chmod 0600 "$export_file"
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

    if grep -Eq '(^|[[:space:]])flush[[:space:]]+ruleset([[:space:]]|$)|(^|[[:space:]])include[[:space:]]' "$import_file"; then
        log_error "导入文件不得包含 flush ruleset 或 include；请提供单个自包含 ruleset"
        return 1
    fi
    if ! nft -c -f "$import_file" 2>/dev/null; then
        log_error "导入文件未通过 nft 语法验证"
        nft -c -f "$import_file" || true
        return 1
    fi
    if confirm "导入将替换本工具当前的基础及自定义规则，确认继续?"; then
        if _fw_replace_managed_rules "$import_file"; then
            log_info "规则导入成功"
        else
            log_error "导入失败，原规则已恢复"
            return 1
        fi
    fi
}

# ---------- 恢复默认规则 ----------
fw_reset() {
    if confirm "确认恢复默认防火墙规则? 这将删除所有自定义规则"; then
        local ssh_port web=false base_candidate
        ssh_port=$(get_ssh_port)
        if ! _fw_validate_single_port "$ssh_port"; then
            log_error "SSH 端口无效，拒绝重置"
            return 1
        fi
        if grep -q 'tcp dport { 80, 443 } accept' "$NFTABLES_BASE_CONF" 2>/dev/null; then web=true; fi
        base_candidate=$(mktemp "${NFTABLES_DIR}/.reset-base.XXXXXX") || return 1
        _fw_write_base_conf "$base_candidate" "$ssh_port" "$web"
        if _fw_replace_managed_rules "$base_candidate"; then
            rm -f "$base_candidate"
            log_info "防火墙已恢复为默认规则"
        else
            rm -f "$base_candidate"
            log_error "恢复失败，原规则已恢复"
            return 1
        fi
    fi
}

# ---------- 验证并重载 ----------
_fw_validate_and_reload() {
    fw_reload
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
    jails=$(_f2b_get_jail_list || true)
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
    jails=$(_f2b_get_jail_list || true)
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
    fail2ban-client status "$selected_jail" 2>/dev/null || log_error "无法读取 Jail 状态"
    print_thin_separator
}

# ---------- 手动封禁 IP ----------
f2b_ban_ip() {
    _f2b_check_installed || return 1
    _f2b_check_running || return 1

    log_step "手动封禁 IP"
    echo ""

    local jails
    jails=$(_f2b_get_jail_list || true)
    if [ -z "$jails" ]; then
        log_warn "没有活跃的 Jail"
        return 0
    fi

    local ip
    read_nonempty "请输入要封禁的 IP 地址" ip
    if ! _fw_validate_ip_cidr "$ip" || [[ "$ip" == */* ]]; then
        log_error "请输入单个有效的 IPv4 或 IPv6 地址"
        return 1
    fi

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
    jails=$(_f2b_get_jail_list || true)
    if [ -z "$jails" ]; then
        log_warn "没有活跃的 Jail"
        return 0
    fi

    local ip
    read_nonempty "请输入要解封的 IP 地址" ip
    if ! _fw_validate_ip_cidr "$ip" || [[ "$ip" == */* ]]; then
        log_error "请输入单个有效的 IPv4 或 IPv6 地址"
        return 1
    fi

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
        cur_bantime=$(grep -E "^bantime[[:space:]]*=" "$jail_conf" 2>/dev/null | head -1 | awk -F= '{print $2}' | tr -d ' ' || true)
        cur_findtime=$(grep -E "^findtime[[:space:]]*=" "$jail_conf" 2>/dev/null | head -1 | awk -F= '{print $2}' | tr -d ' ' || true)
        cur_maxretry=$(grep -E "^maxretry[[:space:]]*=" "$jail_conf" 2>/dev/null | head -1 | awk -F= '{print $2}' | tr -d ' ' || true)

        if [ -f "$FAIL2BAN_JAIL_LOCAL" ]; then
            local lb lf lm li
            lb=$(grep -E "^bantime[[:space:]]*=" "$FAIL2BAN_JAIL_LOCAL" 2>/dev/null | head -1 | awk -F= '{print $2}' | tr -d ' ' || true)
            lf=$(grep -E "^findtime[[:space:]]*=" "$FAIL2BAN_JAIL_LOCAL" 2>/dev/null | head -1 | awk -F= '{print $2}' | tr -d ' ' || true)
            lm=$(grep -E "^maxretry[[:space:]]*=" "$FAIL2BAN_JAIL_LOCAL" 2>/dev/null | head -1 | awk -F= '{print $2}' | tr -d ' ' || true)
            li=$(grep -E "^ignoreip[[:space:]]*=" "$FAIL2BAN_JAIL_LOCAL" 2>/dev/null | head -1 | awk -F= '{$1=""; print}' | sed 's/^[[:space:]]*//' || true)
            if [ -n "$lb" ]; then cur_bantime="$lb"; fi
            if [ -n "$lf" ]; then cur_findtime="$lf"; fi
            if [ -n "$lm" ]; then cur_maxretry="$lm"; fi
            if [ -n "$li" ]; then cur_ignoreip="$li"; fi
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
        if systemctl is-active fail2ban &>/dev/null; then status="运行中 ✓"; fi
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

    if ! _fw_migrate_legacy_layout; then
        log_error "旧版防火墙规则迁移失败，已保留原配置；拒绝继续修改"
        return 1
    fi

    local ip
    read_nonempty "请输入要拉黑的恶意 IP 地址或网段 (如: 1.2.3.4 或 1.2.3.0/24)" ip
    if ! _fw_validate_ip_cidr "$ip"; then
        log_error "无效的 IP 地址或 CIDR"
        return 1
    fi

    echo ""
    echo "拉黑方式:"
    echo "  1) nftables 直接封禁 (永久，直到手动删除)"
    echo "  2) fail2ban 封禁 (按 bantime 配置自动到期)"
    echo "  3) 同时使用两种方式"
    select_option "请选择" 3

    local nft_ok=false f2b_ok=false

    # 提取 nftables 和 fail2ban 操作的内联函数
    _do_nft_blacklist() {
        local conf_file="${NFTABLES_DIR}/ip_blacklist.conf" family
        family=$(_fw_address_family_keyword "$ip")
        if _fw_append_rule "$conf_file" "IP 黑名单规则" \
            "add rule inet ops_filter ops_blacklist ${family} saddr ${ip} drop # ops-blacklist"; then
            log_info "nftables 已封禁: ${ip}"
            nft_ok=true
        else
            log_error "nftables 封禁失败，原规则已保留或恢复"
        fi
    }

    _do_f2b_blacklist() {
        if command -v fail2ban-client &>/dev/null && systemctl is-active fail2ban &>/dev/null; then
            local jails
            jails=$(_f2b_get_jail_list || true)
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

_render_temp_whitelist_conf() {
    local data_file="$1" output="$2" now ip expiry desc family
    now=$(date +%s)
    {
        printf '%s\n' '#!/usr/sbin/nft -f' '# 临时 IP 白名单规则 - 由 ops-scripts 自动管理'
        if [ -f "$data_file" ]; then
            while IFS=' ' read -r ip expiry desc || [ -n "$ip" ]; do
                [ -z "$ip" ] && continue
                [[ "$ip" =~ ^# ]] && continue
                if ! _fw_validate_ip_cidr "$ip" || ! [[ "$expiry" =~ ^[0-9]+$ ]]; then
                    log_error "临时白名单数据存在无效记录: ${ip} ${expiry}"
                    return 1
                fi
                if [ "$expiry" -gt "$now" ]; then
                    family=$(_fw_address_family_keyword "$ip")
                    printf 'add rule inet ops_filter ops_whitelist %s saddr %s accept # ops-temp-whitelist\n' "$family" "$ip"
                fi
            done < "$data_file"
        fi
    } > "$output"
}

_apply_temp_whitelist_data() (
    local data_candidate="$1" conf_candidate data_backup conf_backup
    local data_existed=false conf_existed=false
    cleanup_temp_whitelist_transaction() {
        rm -f -- "$data_candidate" "${conf_candidate:-}" "${data_backup:-}" "${conf_backup:-}"
    }
    trap cleanup_temp_whitelist_transaction EXIT HUP INT TERM
    conf_candidate=$(mktemp "${NFTABLES_DIR}/.temp-white.XXXXXX") || return 1
    if ! _render_temp_whitelist_conf "$data_candidate" "$conf_candidate"; then
        rm -f "$conf_candidate"
        return 1
    fi
    if ! _fw_validate_bundle "$conf_candidate" "$TEMP_WHITELIST_CONF"; then
        rm -f "$conf_candidate"
        return 1
    fi
    data_backup=$(mktemp "$(dirname "$TEMP_WHITELIST_DATA")/.tw-data-backup.XXXXXX") || return 1
    conf_backup=$(mktemp "${NFTABLES_DIR}/.tw-conf-backup.XXXXXX") || return 1
    if [ -f "$TEMP_WHITELIST_DATA" ]; then cp -p -- "$TEMP_WHITELIST_DATA" "$data_backup"; data_existed=true; fi
    if [ -f "$TEMP_WHITELIST_CONF" ]; then cp -p -- "$TEMP_WHITELIST_CONF" "$conf_backup"; conf_existed=true; fi
    chmod 0600 "$data_candidate"
    chmod 0644 "$conf_candidate"
    mv -f -- "$data_candidate" "$TEMP_WHITELIST_DATA"
    mv -f -- "$conf_candidate" "$TEMP_WHITELIST_CONF"
    if systemctl restart nftables; then
        rm -f "$data_backup" "$conf_backup"
        return 0
    fi
    log_error "临时白名单重载失败，正在同时恢复数据与规则文件"
    if [ "$data_existed" = true ]; then mv -f -- "$data_backup" "$TEMP_WHITELIST_DATA"; else rm -f "$TEMP_WHITELIST_DATA" "$data_backup"; fi
    if [ "$conf_existed" = true ]; then mv -f -- "$conf_backup" "$TEMP_WHITELIST_CONF"; else rm -f "$TEMP_WHITELIST_CONF" "$conf_backup"; fi
    systemctl restart nftables || log_error "旧临时白名单恢复后仍无法重载，请立即人工检查"
    return 1
)

_rebuild_temp_whitelist_conf() {
    local candidate
    ensure_marker_dir
    candidate=$(mktemp "$(dirname "$TEMP_WHITELIST_DATA")/.tw-data.XXXXXX") || return 1
    if [ -f "$TEMP_WHITELIST_DATA" ]; then cp -p -- "$TEMP_WHITELIST_DATA" "$candidate"; fi
    _apply_temp_whitelist_data "$candidate"
}

_clean_expired_temp_whitelist() {
    if [ ! -f "$TEMP_WHITELIST_DATA" ]; then
        return 0
    fi

    local now
    now=$(date +%s)
    local tmpfile
    tmpfile=$(mktemp "$(dirname "$TEMP_WHITELIST_DATA")/.tw-clean.XXXXXX") || return 1
    local changed=false

    while IFS=' ' read -r ip expiry desc || [ -n "$ip" ]; do
        [ -z "$ip" ] && continue
        [[ "$ip" =~ ^# ]] && continue
        if ! [[ "$expiry" =~ ^[0-9]+$ ]] || ! _fw_validate_ip_cidr "$ip"; then
            rm -f "$tmpfile"
            log_error "临时白名单数据损坏，拒绝清理: ${ip} ${expiry}"
            return 1
        elif [ "$expiry" -gt "$now" ]; then
            printf '%s %s %s\n' "$ip" "$expiry" "$desc" >> "$tmpfile"
        else
            changed=true
            local expire_str
            expire_str=$(date -d "@${expiry}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "未知")
            log_info "已移除过期白名单: ${ip} (过期于 ${expire_str})"
        fi
    done < "$TEMP_WHITELIST_DATA"

    if [ "$changed" = true ]; then
        if _apply_temp_whitelist_data "$tmpfile"; then
            log_info "✓ 防火墙规则已重载"
        else
            rm -f "$tmpfile"
            log_error "清理失败，原数据与规则已恢复"
            return 1
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
    if ! _fw_validate_ip_cidr "$ip"; then
        log_error "无效的 IP 地址或 CIDR"
        return 1
    fi

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
            if ! [[ "$hours" =~ ^[0-9]+$ ]] || [ "$hours" -lt 1 ] || [ "$hours" -gt 8760 ]; then
                log_error "无效的小时数"
                return 1
            fi
            ;;
    esac

    local desc
    read_optional "备注信息" desc "手动添加"
    desc="${desc//$'\n'/ }"
    desc="${desc//$'\r'/ }"

    local expiry
    expiry=$(( $(date +%s) + hours * 3600 ))
    local expire_str
    expire_str=$(date -d "@${expiry}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "未知")

    ensure_marker_dir
    local data_candidate
    data_candidate=$(mktemp "$(dirname "$TEMP_WHITELIST_DATA")/.tw-add.XXXXXX") || return 1
    if [ -f "$TEMP_WHITELIST_DATA" ]; then cp -p -- "$TEMP_WHITELIST_DATA" "$data_candidate"; fi
    printf '%s %s %s\n' "$ip" "$expiry" "${desc:-手动添加}" >> "$data_candidate"

    if _apply_temp_whitelist_data "$data_candidate"; then
        log_info "✓ 临时白名单已添加: ${ip}"
        log_info "  过期时间: ${expire_str} (${hours} 小时后)"
    else
        rm -f "$data_candidate"
        log_error "添加失败，原数据与规则已恢复"
        return 1
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
    total=$(awk 'NF && $1 !~ /^#/ {count++} END {print count+0}' "$TEMP_WHITELIST_DATA")
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
    line_to_delete=$(awk 'NF && $1 !~ /^#/' "$TEMP_WHITELIST_DATA" | sed -n "${idx}p")
    local ip_to_delete expiry_to_delete
    ip_to_delete=$(echo "$line_to_delete" | awk '{print $1}')
    expiry_to_delete=$(echo "$line_to_delete" | awk '{print $2}')

    local tmpfile
    tmpfile=$(mktemp "$(dirname "$TEMP_WHITELIST_DATA")/.tw-delete.XXXXXX") || return 1
    awk -v ip="$ip_to_delete" -v expiry="$expiry_to_delete" \
        '!($1 == ip && $2 == expiry)' "$TEMP_WHITELIST_DATA" > "$tmpfile"
    if _apply_temp_whitelist_data "$tmpfile"; then
        log_info "✓ 已删除临时白名单: ${ip_to_delete}"
    else
        rm -f "$tmpfile"
        log_error "删除失败，原数据与规则已恢复"
        return 1
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

    _generate_temp_whitelist_cleanup_script || return 1

    local cron_candidate
    cron_candidate=$(mktemp "$(dirname "$cron_file")/.ops-temp-whitelist.XXXXXX") || return 1
    printf '%s root %s >> /var/log/ops-temp-whitelist.log 2>&1\n' \
        "$cron_schedule" "$TEMP_WHITELIST_CLEANUP" > "$cron_candidate"
    chmod 0644 "$cron_candidate"
    mv -f -- "$cron_candidate" "$cron_file"

    log_info "✓ 自动清理任务已设置: ${cron_schedule}"
    log_info "  日志文件: /var/log/ops-temp-whitelist.log"
}

_generate_temp_whitelist_cleanup_script() {
    ensure_marker_dir
    local script_candidate
    script_candidate=$(mktemp "$(dirname "$TEMP_WHITELIST_CLEANUP")/.tw-cleanup.XXXXXX") || return 1
    cat > "$script_candidate" << 'CLEANUP_EOF'
#!/usr/bin/env bash
# 临时 IP 白名单自动清理脚本 - 由 ops-scripts 自动生成，请勿手动编辑
set -euo pipefail

TEMP_WHITELIST_DATA="/etc/ops-scripts/temp_whitelist.dat"
NFTABLES_DIR="/etc/nftables.d"
TEMP_WHITELIST_CONF="${NFTABLES_DIR}/temp_whitelist.conf"

[ ! -f "$TEMP_WHITELIST_DATA" ] && exit 0

NOW=$(date +%s)
DATA_CANDIDATE=$(mktemp "$(dirname "$TEMP_WHITELIST_DATA")/.tw-cron-data.XXXXXX")
CONF_CANDIDATE=$(mktemp "${NFTABLES_DIR}/.tw-cron-conf.XXXXXX")
BUNDLE=$(mktemp "${NFTABLES_DIR}/.tw-cron-bundle.XXXXXX")
DATA_BACKUP=$(mktemp "$(dirname "$TEMP_WHITELIST_DATA")/.tw-cron-data-backup.XXXXXX")
CONF_BACKUP=$(mktemp "${NFTABLES_DIR}/.tw-cron-conf-backup.XXXXXX")
cleanup() {
    rm -f "$DATA_CANDIDATE" "$CONF_CANDIDATE" "$BUNDLE" "$DATA_BACKUP" "$CONF_BACKUP"
}
trap cleanup EXIT HUP INT TERM
CHANGED=false

while IFS=' ' read -r ip expiry desc || [ -n "$ip" ]; do
    [ -z "$ip" ] && continue
    [[ "$ip" =~ ^# ]] && continue
    if ! [[ "$expiry" =~ ^[0-9]+$ ]]; then
        echo "临时白名单数据损坏: $ip $expiry" >&2
        exit 1
    elif [ "$expiry" -gt "$NOW" ]; then
        printf '%s %s %s\n' "$ip" "$expiry" "$desc" >> "$DATA_CANDIDATE"
    else
        CHANGED=true
        expire_str=$(date -d "@${expiry}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "unknown")
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] 移除过期白名单: $ip (过期于 ${expire_str})"
    fi
done < "$TEMP_WHITELIST_DATA"

if [ "$CHANGED" = true ]; then
    {
        printf '%s\n' '#!/usr/sbin/nft -f' '# 临时 IP 白名单规则 - 由 ops-scripts 自动管理'
        if [ -s "$DATA_CANDIDATE" ]; then
            while IFS=' ' read -r ip expiry desc || [ -n "$ip" ]; do
                [ -z "$ip" ] && continue
                [[ "$ip" =~ ^# ]] && continue
                if [ "$expiry" -gt "$NOW" ]; then
                    if [[ "$ip" == *:* ]]; then
                        printf 'add rule inet ops_filter ops_whitelist ip6 saddr %s accept # ops-temp-whitelist\n' "$ip"
                    else
                        printf 'add rule inet ops_filter ops_whitelist ip saddr %s accept # ops-temp-whitelist\n' "$ip"
                    fi
                fi
            done < "$DATA_CANDIDATE"
        fi
    } > "$CONF_CANDIDATE"

    printf 'flush ruleset\n' > "$BUNDLE"
    cat "${NFTABLES_DIR}/base.conf" >> "$BUNDLE"
    for file in custom_ports.conf ip_whitelist.conf ip_blacklist.conf rate_limit.conf port_forward.conf; do
        [ -f "${NFTABLES_DIR}/${file}" ] && cat "${NFTABLES_DIR}/${file}" >> "$BUNDLE"
    done
    cat "$CONF_CANDIDATE" >> "$BUNDLE"
    nft -c -f "$BUNDLE"

    cp -p "$TEMP_WHITELIST_DATA" "$DATA_BACKUP"
    CONF_EXISTED=false
    if [ -f "$TEMP_WHITELIST_CONF" ]; then
        cp -p "$TEMP_WHITELIST_CONF" "$CONF_BACKUP"
        CONF_EXISTED=true
    fi
    chmod 0600 "$DATA_CANDIDATE"
    chmod 0644 "$CONF_CANDIDATE"
    mv -f "$DATA_CANDIDATE" "$TEMP_WHITELIST_DATA"
    mv -f "$CONF_CANDIDATE" "$TEMP_WHITELIST_CONF"

    if systemctl restart nftables; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] 防火墙规则已重载"
    else
        mv -f "$DATA_BACKUP" "$TEMP_WHITELIST_DATA"
        if [ "$CONF_EXISTED" = true ]; then
            mv -f "$CONF_BACKUP" "$TEMP_WHITELIST_CONF"
        else
            rm -f "$TEMP_WHITELIST_CONF"
        fi
        systemctl restart nftables || echo "旧规则恢复后仍无法重载，请立即人工检查" >&2
        exit 1
    fi
fi
CLEANUP_EOF

    chmod 0755 "$script_candidate"
    mv -f -- "$script_candidate" "$TEMP_WHITELIST_CLEANUP"
    log_info "清理脚本已生成: ${TEMP_WHITELIST_CLEANUP}"
}

# ---------- 临时 IP 白名单资源池主菜单 ----------
temp_whitelist_manage() {
    if ! _fw_migrate_legacy_layout; then
        log_error "旧版防火墙规则迁移失败，已保留原配置；拒绝继续修改"
        return 1
    fi
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
