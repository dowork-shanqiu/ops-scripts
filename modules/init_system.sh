#!/usr/bin/env bash
# ============================================================
# 系统初始化模块
# - 检测网络环境，替换 APT 源（中国大陆）
# - 系统更新
# - 安装基础工具
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# ---------- APT 源配置 ----------
setup_apt_sources() {
    log_step "检测网络环境..."

    if is_china_network; then
        log_info "检测到当前服务器处于中国大陆网络环境"
        log_info "建议替换 APT 源以加速软件安装"
        echo ""
        echo "请选择 APT 镜像源："
        echo "  1) 阿里云镜像 (mirrors.aliyun.com)"
        echo "  2) 腾讯云镜像 (mirrors.tencent.com)"
        echo "  3) 清华大学镜像 (mirrors.tuna.tsinghua.edu.cn)"
        echo "  4) 中科大镜像 (mirrors.ustc.edu.cn)"
        echo "  5) 华为云镜像 (repo.huaweicloud.com)"
        echo "  6) 不替换，使用默认源"
        echo ""
        select_option "请选择" 6

        local mirror_url=""
        case "$SELECTED_OPTION" in
            1) mirror_url="mirrors.aliyun.com" ;;
            2) mirror_url="mirrors.tencent.com" ;;
            3) mirror_url="mirrors.tuna.tsinghua.edu.cn" ;;
            4) mirror_url="mirrors.ustc.edu.cn" ;;
            5) mirror_url="repo.huaweicloud.com" ;;
            6) log_info "保持默认源"; mirror_url="" ;;
        esac

        if [ -n "$mirror_url" ]; then
            log_step "备份当前 APT 源配置..."
            cp /etc/apt/sources.list "/etc/apt/sources.list.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null

            log_step "替换 APT 源为: ${mirror_url}"
            detect_os
            local codename
            codename=$(lsb_release -cs 2>/dev/null || echo "")

            if [ -z "$codename" ]; then
                # 从 os-release 获取
                codename=$(grep VERSION_CODENAME /etc/os-release 2>/dev/null | cut -d= -f2)
            fi

            if [ -z "$codename" ]; then
                log_error "无法检测系统版本代号，跳过源替换"
                return
            fi

            # 检查是否使用 DEB822 格式（Ubuntu 24.04+ 使用 .sources 文件）
            if [ -f /etc/apt/sources.list.d/ubuntu.sources ]; then
                log_info "检测到 DEB822 格式源配置"
                cp /etc/apt/sources.list.d/ubuntu.sources "/etc/apt/sources.list.d/ubuntu.sources.bak.$(date +%Y%m%d%H%M%S)"
                sed -i "s|http://archive.ubuntu.com|https://${mirror_url}|g" /etc/apt/sources.list.d/ubuntu.sources
                sed -i "s|http://security.ubuntu.com|https://${mirror_url}|g" /etc/apt/sources.list.d/ubuntu.sources
                sed -i "s|https://archive.ubuntu.com|https://${mirror_url}|g" /etc/apt/sources.list.d/ubuntu.sources
                sed -i "s|https://security.ubuntu.com|https://${mirror_url}|g" /etc/apt/sources.list.d/ubuntu.sources
            elif [ "$OS_ID" = "ubuntu" ]; then
                cat > /etc/apt/sources.list << EOF
deb https://${mirror_url}/ubuntu/ ${codename} main restricted universe multiverse
deb https://${mirror_url}/ubuntu/ ${codename}-updates main restricted universe multiverse
deb https://${mirror_url}/ubuntu/ ${codename}-backports main restricted universe multiverse
deb https://${mirror_url}/ubuntu/ ${codename}-security main restricted universe multiverse
EOF
            elif [ "$OS_ID" = "debian" ]; then
                cat > /etc/apt/sources.list << EOF
deb https://${mirror_url}/debian/ ${codename} main contrib non-free non-free-firmware
deb https://${mirror_url}/debian/ ${codename}-updates main contrib non-free non-free-firmware
deb https://${mirror_url}/debian/ ${codename}-backports main contrib non-free non-free-firmware
deb https://${mirror_url}/debian-security/ ${codename}-security main contrib non-free non-free-firmware
EOF
            fi
            log_info "APT 源替换完成"
        fi
    else
        log_info "当前网络环境为非中国大陆，使用默认源"
    fi
}

# ---------- 系统更新 ----------
update_system() {
    log_step "正在更新系统..."
    apt update && apt upgrade -y
    if [ $? -eq 0 ]; then
        log_info "系统更新完成"
    else
        log_error "系统更新过程中出现错误，请检查网络连接"
        return 1
    fi
}

# ---------- 安装基础工具 ----------
install_base_packages() {
    log_step "正在安装基础工具包..."

    local packages=(
        # 基础工具
        curl
        wget
        vim
        git
        rsync
        jq
        unzip
        tar

        # 网络工具
        net-tools
        iproute2
        dnsutils
        nftables

        # 系统监控
        htop
        lsof

        # 编译与开发
        build-essential
        apt-transport-https
        ca-certificates
        gnupg
        lsb-release

        # 安全工具
        fail2ban

        # 其他
        tmux
        cron
        logrotate
        bash-completion
        sudo
    )

    # software-properties-common 仅在 Ubuntu 上可用（提供 add-apt-repository）
    # Debian 13+ 的仓库中不包含此包
    # detect_os 已在 setup_apt_sources 中调用，OS_ID 此时已设置
    if [ -z "${OS_ID:-}" ]; then
        detect_os
    fi
    if [ "$OS_ID" = "ubuntu" ]; then
        packages+=(software-properties-common)
    fi

    apt install -y "${packages[@]}"

    if [ $? -eq 0 ]; then
        log_info "基础工具包安装完成"
    else
        log_warn "部分工具包安装可能失败，请检查日志"
    fi
}

# ---------- 入口函数 ----------
run_init_system() {
    print_separator
    echo -e "${BOLD}  系统初始化 - 环境配置${NC}"
    print_separator
    echo ""

    setup_apt_sources
    echo ""
    update_system
    echo ""
    install_base_packages
    echo ""

    log_info "系统环境配置完成"
}
