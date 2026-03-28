#!/usr/bin/env bash
# ============================================================
# SSH 安全配置模块
# - 端口修改
# - 安全加固（禁用密码登录、禁止匿名登录等）
# - 公钥配置
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# ---------- SSH 配置文件 ----------
SSHD_CONFIG="/etc/ssh/sshd_config"

# ---------- 备份 SSH 配置 ----------
backup_sshd_config() {
    local backup_file
    backup_file="${SSHD_CONFIG}.bak.$(date +%Y%m%d%H%M%S)"
    cp "$SSHD_CONFIG" "$backup_file"
    log_info "已备份 SSH 配置到: ${backup_file}"
}

# ---------- 设置 SSH 配置项 ----------
set_sshd_option() {
    local key="$1"
    local value="$2"
    if grep -qE "^#?${key}\s" "$SSHD_CONFIG"; then
        sed -i "s|^#*${key}\s.*|${key} ${value}|" "$SSHD_CONFIG"
    else
        echo "${key} ${value}" >> "$SSHD_CONFIG"
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
        set_sshd_option "Port" "$new_port"
        log_info "SSH 端口已设置为: ${new_port}"
    else
        log_info "保持当前 SSH 端口: ${current_port}"
    fi
}

# ---------- SSH 安全加固 ----------
harden_ssh() {
    log_step "正在进行 SSH 安全加固..."

    # 禁止 root 密码登录（仅允许公钥）
    set_sshd_option "PermitRootLogin" "prohibit-password"
    log_info "已设置: 禁止 root 密码登录（仅允许公钥认证）"

    # 禁用密码认证
    set_sshd_option "PasswordAuthentication" "no"
    log_info "已设置: 禁用密码认证"

    # 禁用空密码登录
    set_sshd_option "PermitEmptyPasswords" "no"
    log_info "已设置: 禁止空密码登录"

    # 禁用基于主机的认证
    set_sshd_option "HostbasedAuthentication" "no"
    log_info "已设置: 禁用基于主机的认证"

    # 启用公钥认证
    set_sshd_option "PubkeyAuthentication" "yes"
    log_info "已设置: 启用公钥认证"

    # 禁用 X11 转发
    set_sshd_option "X11Forwarding" "no"
    log_info "已设置: 禁用 X11 转发"

    # 设置最大认证尝试次数
    set_sshd_option "MaxAuthTries" "3"
    log_info "已设置: 最大认证尝试次数为 3"

    # 设置登录超时时间
    set_sshd_option "LoginGraceTime" "60"
    log_info "已设置: 登录超时时间 60 秒"

    # 禁用 DNS 反向解析
    set_sshd_option "UseDNS" "no"
    log_info "已设置: 禁用 DNS 反向解析"

    # 禁用 GSSAPI 认证
    set_sshd_option "GSSAPIAuthentication" "no"
    log_info "已设置: 禁用 GSSAPI 认证"

    # 设置客户端存活间隔
    set_sshd_option "ClientAliveInterval" "300"
    set_sshd_option "ClientAliveCountMax" "2"
    log_info "已设置: 客户端存活检测（300秒间隔，最多2次）"

    # 禁用 TCP 转发（可选，根据需求）
    if confirm "是否禁用 TCP 转发? (如果不使用 SSH 隧道可以禁用)"; then
        set_sshd_option "AllowTcpForwarding" "no"
        log_info "已设置: 禁用 TCP 转发"
    fi

    # 设置日志级别
    set_sshd_option "LogLevel" "VERBOSE"
    log_info "已设置: 日志级别为 VERBOSE"

    # 仅使用 SSH 协议 2
    set_sshd_option "Protocol" "2"
    log_info "已设置: 仅使用 SSH 协议 2"
}

# ---------- 配置 root 公钥 ----------
setup_root_pubkey() {
    log_step "配置 root 用户 SSH 公钥..."

    mkdir -p /root/.ssh
    chmod 700 /root/.ssh

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

    echo "$pubkey" >> /root/.ssh/authorized_keys
    chmod 600 /root/.ssh/authorized_keys
    log_info "公钥已添加到 root 用户"
}

# ---------- 重启 SSH 服务 ----------
restart_ssh_service() {
    local service_name
    service_name=$(get_ssh_service_name)
    log_step "正在重启 SSH 服务 (${service_name})..."

    systemctl restart "$service_name"
    if [ $? -eq 0 ]; then
        log_info "SSH 服务重启成功"
    else
        log_error "SSH 服务重启失败，请检查配置"
        log_info "可以使用以下命令检查配置: sshd -t"
        sshd -t
    fi
}

# ---------- 入口函数 ----------
run_init_ssh() {
    print_separator
    echo -e "${BOLD}  系统初始化 - SSH 安全配置${NC}"
    print_separator
    echo ""

    backup_sshd_config
    echo ""
    setup_ssh_port
    echo ""
    harden_ssh
    echo ""
    setup_root_pubkey
    echo ""

    # 验证配置
    log_step "验证 SSH 配置..."
    if sshd -t 2>/dev/null; then
        log_info "SSH 配置验证通过"
        restart_ssh_service
    else
        log_error "SSH 配置验证失败:"
        sshd -t
        log_warn "请手动修复配置后重启 SSH 服务"
    fi

    echo ""
    log_info "SSH 安全配置完成"
    log_warn "重要提示: 请确保在断开当前连接之前，使用新配置测试 SSH 连接！"

    local current_port
    current_port=$(get_ssh_port)
    log_info "当前 SSH 端口: ${current_port}"
}
