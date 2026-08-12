#!/usr/bin/env bash
# ============================================================
# SSH 安全配置模块
# - 端口修改
# - 安全加固（禁用密码登录、禁止匿名登录等）
# - 公钥配置
# ============================================================

INIT_SSH_MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${INIT_SSH_MODULE_DIR}/common.sh"

# ---------- SSH 配置文件 ----------
SSHD_CONFIG="/etc/ssh/sshd_config"
SSHD_BACKUP_FILE=""

# ---------- 备份 SSH 配置 ----------
backup_sshd_config() {
    SSHD_BACKUP_FILE=$(mktemp "${SSHD_CONFIG}.bak.$(date +%Y%m%d%H%M%S).XXXXXX") || return 1
    if ! cp -p "$SSHD_CONFIG" "$SSHD_BACKUP_FILE"; then
        rm -f "$SSHD_BACKUP_FILE"
        SSHD_BACKUP_FILE=""
        return 1
    fi
    log_info "已备份 SSH 配置到: ${SSHD_BACKUP_FILE}"
}

restore_sshd_config() {
    [ -n "$SSHD_BACKUP_FILE" ] && [ -f "$SSHD_BACKUP_FILE" ] || return 1
    cp -p "$SSHD_BACKUP_FILE" "$SSHD_CONFIG"
}

# ---------- 设置 SSH 配置项 ----------
set_sshd_option() {
    local key="$1"
    local value="$2"
    local tmpfile
    tmpfile=$(mktemp "${SSHD_CONFIG}.tmp.XXXXXX") || return 1

    # 全局选项必须位于第一个 Match 块之前；删除该作用域内的旧值并插入新值。
    if ! awk -v key="$key" -v value="$value" '
        BEGIN { in_global=1; print key " " value }
        /^[[:space:]]*Match([[:space:]]|$)/ && in_global { in_global=0 }
        in_global && $0 ~ "^[[:space:]]*#?[[:space:]]*" key "[[:space:]]" { next }
        { print }
    ' "$SSHD_CONFIG" > "$tmpfile"; then
        rm -f "$tmpfile"
        return 1
    fi
    chmod --reference="$SSHD_CONFIG" "$tmpfile" 2>/dev/null || chmod 600 "$tmpfile"
    chown --reference="$SSHD_CONFIG" "$tmpfile" 2>/dev/null || true
    if ! mv -f "$tmpfile" "$SSHD_CONFIG"; then
        rm -f "$tmpfile"
        return 1
    fi
}

# ---------- 配置 SSH 端口 ----------
setup_ssh_port() {
    local current_port
    current_port=$(get_ssh_port)
    log_info "当前 SSH 端口: ${current_port}"

    if confirm "是否修改 SSH 端口?"; then
        local new_port
        while true; do
            read_nonempty "请输入新的 SSH 端口号 (建议 1024-65535)" new_port
            if [[ "$new_port" =~ ^[0-9]+$ ]] && [ "$new_port" -ge 1 ] && [ "$new_port" -le 65535 ]; then
                break
            fi
            log_warn "端口号必须在 1-65535 之间"
        done
        if ! set_sshd_option "Port" "$new_port"; then
            log_error "写入 SSH 端口配置失败"
            return 1
        fi
        log_info "SSH 端口已设置为: ${new_port}"
    else
        log_info "保持当前 SSH 端口: ${current_port}"
    fi
}

# ---------- SSH 安全加固 ----------
harden_ssh() {
    log_step "正在进行 SSH 安全加固..."

    # 禁止 root 密码登录（仅允许公钥）
    set_sshd_option "PermitRootLogin" "prohibit-password" || return 1
    log_info "已设置: 禁止 root 密码登录（仅允许公钥认证）"

    # 禁用密码认证
    set_sshd_option "PasswordAuthentication" "no" || return 1
    log_info "已设置: 禁用密码认证"

    # 禁用空密码登录
    set_sshd_option "PermitEmptyPasswords" "no" || return 1
    log_info "已设置: 禁止空密码登录"

    # 禁用基于主机的认证
    set_sshd_option "HostbasedAuthentication" "no" || return 1
    log_info "已设置: 禁用基于主机的认证"

    # 启用公钥认证
    set_sshd_option "PubkeyAuthentication" "yes" || return 1
    log_info "已设置: 启用公钥认证"

    # 禁用 X11 转发
    set_sshd_option "X11Forwarding" "no" || return 1
    log_info "已设置: 禁用 X11 转发"

    # 设置最大认证尝试次数
    set_sshd_option "MaxAuthTries" "3" || return 1
    log_info "已设置: 最大认证尝试次数为 3"

    # 设置登录超时时间
    set_sshd_option "LoginGraceTime" "60" || return 1
    log_info "已设置: 登录超时时间 60 秒"

    # 禁用 DNS 反向解析
    set_sshd_option "UseDNS" "no" || return 1
    log_info "已设置: 禁用 DNS 反向解析"

    # 禁用 GSSAPI 认证
    set_sshd_option "GSSAPIAuthentication" "no" || return 1
    log_info "已设置: 禁用 GSSAPI 认证"

    # 设置客户端存活间隔
    set_sshd_option "ClientAliveInterval" "300" || return 1
    set_sshd_option "ClientAliveCountMax" "2" || return 1
    log_info "已设置: 客户端存活检测（300秒间隔，最多2次）"

    # 禁用 TCP 转发（可选，根据需求）
    if confirm "是否禁用 TCP 转发? (如果不使用 SSH 隧道可以禁用)"; then
        set_sshd_option "AllowTcpForwarding" "no" || return 1
        log_info "已设置: 禁用 TCP 转发"
    fi

    # 设置日志级别
    set_sshd_option "LogLevel" "VERBOSE" || return 1
    log_info "已设置: 日志级别为 VERBOSE"

    # 仅使用 SSH 协议 2
    set_sshd_option "Protocol" "2" || return 1
    log_info "已设置: 仅使用 SSH 协议 2"
}

# ---------- 配置 root 公钥 ----------
setup_root_pubkey() {
    log_step "配置 root 用户 SSH 公钥..."

    if ! mkdir -p /root/.ssh || ! chmod 700 /root/.ssh; then
        log_error "无法创建或设置 /root/.ssh 权限"
        return 1
    fi

    # 检查是否已有授权密钥
    if [ -f /root/.ssh/authorized_keys ] && [ -s /root/.ssh/authorized_keys ]; then
        log_info "当前已存在以下授权公钥："
        print_thin_separator
        cat /root/.ssh/authorized_keys
        print_thin_separator
        echo ""
        if ! confirm "是否添加新的公钥?"; then
            return
        fi
    fi

    echo ""
    log_info "请输入 SSH 公钥（通常以 ssh-rsa、ssh-ed25519 等开头）"
    log_info "输入完成后按 Enter 确认"
    echo ""

    local pubkey
    while true; do
        read_nonempty "SSH 公钥" pubkey
        # 验证公钥格式
        if validate_ssh_pubkey "$pubkey"; then
            break
        fi
        log_warn "公钥格式不正确，请输入有效的 SSH 公钥"
    done

    if ! printf '%s\n' "$pubkey" >> /root/.ssh/authorized_keys ||
       ! chmod 600 /root/.ssh/authorized_keys; then
        log_error "写入 root authorized_keys 失败"
        return 1
    fi
    log_info "公钥已添加到 root 用户"
}

# ---------- 重启 SSH 服务 ----------
restart_ssh_service() {
    local service_name
    service_name=$(get_ssh_service_name)
    log_step "正在重启 SSH 服务 (${service_name})..."

    if systemctl restart "$service_name"; then
        log_info "SSH 服务重启成功"
        return 0
    else
        log_error "SSH 服务重启失败，请检查配置"
        return 1
    fi
}

# ---------- 入口函数 ----------
run_init_ssh() {
    print_separator
    echo -e "${BOLD}  系统初始化 - SSH 安全配置${NC}"
    print_separator
    echo ""

    if ! backup_sshd_config; then
        log_error "无法备份 SSH 配置，已停止初始化"
        return 1
    fi
    echo ""
    if ! setup_ssh_port; then
        log_error "SSH 端口配置失败，正在恢复原配置"
        restore_sshd_config || log_error "自动恢复 SSH 配置失败，请立即人工检查"
        return 1
    fi
    echo ""
    if ! harden_ssh; then
        log_error "SSH 安全配置写入失败，正在恢复原配置"
        restore_sshd_config || log_error "自动恢复 SSH 配置失败，请立即人工检查"
        return 1
    fi
    echo ""
    if ! setup_root_pubkey; then
        log_error "root 公钥配置失败，正在恢复原 SSH 服务配置"
        restore_sshd_config || log_error "自动恢复 SSH 配置失败，请立即人工检查"
        return 1
    fi
    echo ""

    # 验证配置
    log_step "验证 SSH 配置..."
    if sshd -t 2>/dev/null; then
        log_info "SSH 配置验证通过"
        if ! restart_ssh_service; then
            log_warn "正在恢复原 SSH 配置并尝试重新启动服务..."
            if restore_sshd_config && restart_ssh_service; then
                log_info "原 SSH 配置已恢复"
            else
                log_error "恢复 SSH 配置或服务失败，请保持当前连接并立即人工检查"
            fi
            return 1
        fi
    else
        log_error "SSH 配置验证失败:"
        sshd -t 2>&1 || true
        if restore_sshd_config; then
            log_info "已恢复修改前的 SSH 配置"
        else
            log_error "自动恢复 SSH 配置失败，请立即人工检查"
        fi
        return 1
    fi

    echo ""
    log_info "SSH 安全配置完成"
    log_warn "重要提示: 请确保在断开当前连接之前，使用新配置测试 SSH 连接！"

    local current_port
    current_port=$(get_ssh_port)
    log_info "当前 SSH 端口: ${current_port}"
}
