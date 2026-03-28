#!/usr/bin/env bash
# ============================================================
# 系统信息模块
# - 系统概览
# - 资源使用情况
# - 网络信息
# - 磁盘信息
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# ============================================================
# 系统概览
# ============================================================
sys_overview() {
    print_separator
    echo -e "${BOLD}  系统概览${NC}"
    print_separator
    echo ""

    detect_os

    echo -e "  ${BOLD}操作系统:${NC}    ${OS_NAME}"
    echo -e "  ${BOLD}内核版本:${NC}    $(uname -r)"
    echo -e "  ${BOLD}主机名:${NC}      $(hostname)"
    echo -e "  ${BOLD}架构:${NC}        $(uname -m)"
    echo -e "  ${BOLD}运行时间:${NC}    $(uptime -p 2>/dev/null || uptime)"

    # CPU 信息
    local cpu_model
    cpu_model=$(grep "model name" /proc/cpuinfo 2>/dev/null | head -1 | cut -d: -f2 | sed 's/^ //')
    local cpu_cores
    cpu_cores=$(nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo)
    echo -e "  ${BOLD}CPU:${NC}         ${cpu_model} (${cpu_cores} 核)"

    # 内存信息
    local mem_total mem_used mem_free
    mem_total=$(free -h 2>/dev/null | awk '/^Mem:/ {print $2}')
    mem_used=$(free -h 2>/dev/null | awk '/^Mem:/ {print $3}')
    mem_free=$(free -h 2>/dev/null | awk '/^Mem:/ {print $4}')
    echo -e "  ${BOLD}内存:${NC}        总计 ${mem_total} / 已用 ${mem_used} / 空闲 ${mem_free}"

    # Swap 信息
    local swap_total
    swap_total=$(free -h 2>/dev/null | awk '/^Swap:/ {print $2}')
    echo -e "  ${BOLD}Swap:${NC}        ${swap_total}"

    # 负载
    echo -e "  ${BOLD}系统负载:${NC}    $(cat /proc/loadavg 2>/dev/null | awk '{print $1, $2, $3}')"

    # 登录用户数
    echo -e "  ${BOLD}在线用户:${NC}    $(who 2>/dev/null | wc -l)"

    # 进程数
    echo -e "  ${BOLD}进程总数:${NC}    $(ps aux 2>/dev/null | wc -l)"

    echo ""
}

# ============================================================
# 资源使用情况
# ============================================================
sys_resources() {
    print_separator
    echo -e "${BOLD}  资源使用情况${NC}"
    print_separator
    echo ""

    # CPU 使用率
    log_step "CPU 使用率 (Top 10 进程):"
    print_thin_separator
    ps aux --sort=-%cpu 2>/dev/null | head -11
    print_thin_separator

    echo ""

    # 内存使用率
    log_step "内存使用率 (Top 10 进程):"
    print_thin_separator
    ps aux --sort=-%mem 2>/dev/null | head -11
    print_thin_separator

    echo ""

    # 内存详情
    log_step "内存详情:"
    free -h 2>/dev/null

    echo ""
}

# ============================================================
# 网络信息
# ============================================================
sys_network() {
    print_separator
    echo -e "${BOLD}  网络信息${NC}"
    print_separator
    echo ""

    # 网络接口
    log_step "网络接口:"
    print_thin_separator
    ip -brief addr 2>/dev/null || ifconfig 2>/dev/null
    print_thin_separator

    echo ""

    # 默认路由
    log_step "默认路由:"
    ip route 2>/dev/null | head -5

    echo ""

    # DNS 配置
    log_step "DNS 配置:"
    cat /etc/resolv.conf 2>/dev/null | grep -v '^#' | grep -v '^$'

    echo ""

    # 监听端口
    log_step "监听端口:"
    print_thin_separator
    ss -tlnp 2>/dev/null || netstat -tlnp 2>/dev/null
    print_thin_separator

    echo ""

    # 公网 IP
    log_step "公网 IP:"
    local public_ip
    public_ip=$(curl -s --connect-timeout 5 https://ipinfo.io/ip 2>/dev/null)
    if [ -n "$public_ip" ]; then
        echo "  ${public_ip}"
    else
        echo "  无法获取公网 IP"
    fi

    echo ""
}

# ============================================================
# 磁盘信息
# ============================================================
sys_disk() {
    print_separator
    echo -e "${BOLD}  磁盘信息${NC}"
    print_separator
    echo ""

    # 磁盘使用
    log_step "磁盘使用情况:"
    print_thin_separator
    df -hT 2>/dev/null | grep -v tmpfs | grep -v devtmpfs
    print_thin_separator

    echo ""

    # inode 使用
    log_step "Inode 使用情况:"
    print_thin_separator
    df -i 2>/dev/null | grep -v tmpfs | grep -v devtmpfs
    print_thin_separator

    echo ""

    # 大目录
    log_step "最大的目录 (根分区 Top 10):"
    print_thin_separator
    du -sh /* 2>/dev/null | sort -rh | head -10
    print_thin_separator

    echo ""
}

# ============================================================
# 安全信息
# ============================================================
sys_security() {
    print_separator
    echo -e "${BOLD}  安全信息${NC}"
    print_separator
    echo ""

    # SSH 最近登录
    log_step "最近 SSH 登录 (最近 10 条):"
    print_thin_separator
    last -n 10 2>/dev/null
    print_thin_separator

    echo ""

    # SSH 失败登录
    log_step "最近失败的 SSH 登录尝试 (最近 10 条):"
    print_thin_separator
    lastb -n 10 2>/dev/null || echo "  无记录"
    print_thin_separator

    echo ""

    # 当前 SSH 配置摘要
    log_step "SSH 安全配置摘要:"
    local ssh_port
    ssh_port=$(get_ssh_port)
    echo "  端口: ${ssh_port}"
    echo "  密码登录: $(grep -E '^PasswordAuthentication' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}')"
    echo "  Root 登录: $(grep -E '^PermitRootLogin' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}')"
    echo "  公钥认证: $(grep -E '^PubkeyAuthentication' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}')"

    echo ""
}

# ============================================================
# 入口函数
# ============================================================
run_system_info() {
    while true; do
        print_separator
        echo -e "${BOLD}  系统信息${NC}"
        print_separator
        echo ""
        echo "  1) 系统概览"
        echo "  2) 资源使用情况"
        echo "  3) 网络信息"
        echo "  4) 磁盘信息"
        echo "  5) 安全信息"
        echo "  6) 显示全部"
        echo "  0) 返回上级菜单"
        echo ""
        select_option "请选择" 6 0

        case "$SELECTED_OPTION" in
            1) sys_overview ;;
            2) sys_resources ;;
            3) sys_network ;;
            4) sys_disk ;;
            5) sys_security ;;
            6)
                sys_overview
                sys_resources
                sys_network
                sys_disk
                sys_security
                ;;
            0) return 0 ;;
        esac
        press_any_key
    done
}
