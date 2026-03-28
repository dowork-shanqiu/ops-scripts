#!/usr/bin/env bash
# ============================================================
# Caddy 安装与管理模块
# - 通过官方 APT 源安装 Caddy
# - 配置文件放于 /etc/caddy.d 目录
# - 安装后不允许重复安装
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

CADDY_MARKER="/etc/ops-scripts/.caddy_installed"
CADDY_CONF_DIR="/etc/caddy.d"

# ============================================================
# 安装 Caddy
# ============================================================
caddy_install() {
    print_separator
    echo -e "${BOLD}  Caddy 安装${NC}"
    print_separator
    echo ""

    # 检查是否已安装
    if [ -f "$CADDY_MARKER" ]; then
        log_warn "Caddy 已通过本脚本安装，无需再次执行"
        log_info "如需管理 Caddy，请使用其他菜单选项"
        return 0
    fi

    if command -v caddy &>/dev/null; then
        log_warn "检测到系统中已安装 Caddy: $(caddy version 2>/dev/null)"
        if ! confirm "是否跳过安装并标记为已完成?"; then
            return 0
        fi
        # 标记为已安装并设置配置目录
        _caddy_setup_conf_dir
        ensure_marker_dir
        touch "$CADDY_MARKER"
        log_info "已标记 Caddy 安装完成"
        return 0
    fi

    log_step "准备通过官方 APT 源安装 Caddy..."

    if ! confirm "确认安装 Caddy?"; then
        log_info "已取消安装"
        return 0
    fi

    # 安装依赖
    log_step "安装必要依赖..."
    apt install -y debian-keyring debian-archive-keyring apt-transport-https curl

    # 添加官方 GPG 密钥
    log_step "添加 Caddy 官方 GPG 密钥..."
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg

    # 添加官方 APT 源
    log_step "添加 Caddy 官方 APT 源..."
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list

    # 更新并安装
    log_step "更新 APT 缓存并安装 Caddy..."
    apt update
    apt install -y caddy

    if ! command -v caddy &>/dev/null; then
        log_error "Caddy 安装失败，请检查网络连接或手动安装"
        return 1
    fi

    log_info "Caddy 安装成功: $(caddy version 2>/dev/null)"

    # 创建配置目录
    _caddy_setup_conf_dir

    # 配置 Caddyfile 引入 /etc/caddy.d 目录
    _caddy_setup_main_config

    # 启动并启用服务
    log_step "启动 Caddy 服务..."
    systemctl enable caddy
    systemctl restart caddy

    if systemctl is-active --quiet caddy; then
        log_info "Caddy 服务已启动"
    else
        log_warn "Caddy 服务启动可能有问题，请检查: systemctl status caddy"
    fi

    # 标记安装完成
    ensure_marker_dir
    touch "$CADDY_MARKER"

    echo ""
    log_info "Caddy 安装与配置完成"
    log_info "配置文件目录: ${CADDY_CONF_DIR}"
    log_info "主配置文件: /etc/caddy/Caddyfile"
    log_info "请将站点配置文件放入 ${CADDY_CONF_DIR} 目录中"
}

# ---------- 创建配置目录 ----------
_caddy_setup_conf_dir() {
    if [ ! -d "$CADDY_CONF_DIR" ]; then
        mkdir -p "$CADDY_CONF_DIR"
        log_info "已创建配置目录: ${CADDY_CONF_DIR}"
    fi

    # 创建示例配置
    if [ ! -f "${CADDY_CONF_DIR}/example.conf.disabled" ]; then
        cat > "${CADDY_CONF_DIR}/example.conf.disabled" << 'EOF'
# 示例站点配置
# 将此文件重命名为 .conf 后缀即可启用
# 例如: mv example.conf.disabled mysite.conf

# example.com {
#     root * /var/www/example.com
#     file_server
#
#     # 反向代理示例
#     # reverse_proxy localhost:8080
#
#     # 日志配置
#     log {
#         output file /var/log/caddy/example.log
#     }
# }
EOF
        log_info "已创建示例配置文件: ${CADDY_CONF_DIR}/example.conf.disabled"
    fi
}

# ---------- 配置主 Caddyfile ----------
_caddy_setup_main_config() {
    local caddyfile="/etc/caddy/Caddyfile"

    # 备份原始配置
    if [ -f "$caddyfile" ]; then
        cp "$caddyfile" "${caddyfile}.bak.$(date +%Y%m%d%H%M%S)"
        log_info "已备份原始 Caddyfile"
    fi

    # 写入新的主配置，引入 /etc/caddy.d 目录
    cat > "$caddyfile" << EOF
# Caddyfile - 由 ops-scripts 自动生成
# 生成时间: $(date '+%Y-%m-%d %H:%M:%S')
#
# 站点配置文件请放入 ${CADDY_CONF_DIR} 目录
# 文件后缀为 .conf 的将被自动加载

# 全局配置
{
    # 管理端点（默认关闭外部访问）
    admin off

    # 日志级别
    log {
        level INFO
    }
}

# 导入 /etc/caddy.d 目录下所有 .conf 文件
import ${CADDY_CONF_DIR}/*.conf
EOF

    log_info "Caddyfile 已配置为加载 ${CADDY_CONF_DIR}/*.conf"
}

# ============================================================
# Caddy 状态查看
# ============================================================
caddy_status() {
    print_separator
    echo -e "${BOLD}  Caddy 状态${NC}"
    print_separator
    echo ""

    if ! command -v caddy &>/dev/null; then
        log_warn "Caddy 未安装"
        return 0
    fi

    echo -e "  ${BOLD}版本:${NC}    $(caddy version 2>/dev/null)"
    echo ""

    log_step "服务状态:"
    systemctl status caddy --no-pager 2>/dev/null | head -15
    echo ""

    log_step "配置文件目录 (${CADDY_CONF_DIR}):"
    if [ -d "$CADDY_CONF_DIR" ]; then
        ls -la "$CADDY_CONF_DIR" 2>/dev/null
    else
        log_warn "配置目录不存在"
    fi
    echo ""

    log_step "验证配置:"
    caddy validate --config /etc/caddy/Caddyfile 2>&1 || true
}

# ============================================================
# Caddy 服务管理
# ============================================================
caddy_service() {
    print_separator
    echo -e "${BOLD}  Caddy 服务管理${NC}"
    print_separator
    echo ""

    if ! command -v caddy &>/dev/null; then
        log_warn "Caddy 未安装"
        return 0
    fi

    echo "  1) 启动 Caddy"
    echo "  2) 停止 Caddy"
    echo "  3) 重启 Caddy"
    echo "  4) 重载配置"
    echo "  5) 查看日志"
    echo "  0) 返回"
    echo ""
    select_option "请选择" 5 0

    case "$SELECTED_OPTION" in
        1) systemctl start caddy && log_info "Caddy 已启动" ;;
        2) systemctl stop caddy && log_info "Caddy 已停止" ;;
        3) systemctl restart caddy && log_info "Caddy 已重启" ;;
        4) systemctl reload caddy && log_info "Caddy 配置已重载" ;;
        5)
            echo "  1) 最近 50 行"
            echo "  2) 最近 100 行"
            echo "  3) 实时跟踪 (Ctrl+C 退出)"
            select_option "请选择" 3
            case "$SELECTED_OPTION" in
                1) journalctl -u caddy -n 50 --no-pager ;;
                2) journalctl -u caddy -n 100 --no-pager ;;
                3) journalctl -u caddy -f ;;
            esac
            ;;
        0) return 0 ;;
    esac
}

# ============================================================
# 入口函数
# ============================================================
run_caddy() {
    while true; do
        print_separator
        echo -e "${BOLD}  Caddy 管理${NC}"
        print_separator
        echo ""
        echo "  1) 安装 Caddy"
        echo "  2) 查看状态"
        echo "  3) 服务管理"
        echo "  0) 返回上级菜单"
        echo ""
        select_option "请选择" 3 0

        case "$SELECTED_OPTION" in
            1) caddy_install ;;
            2) caddy_status ;;
            3) caddy_service ;;
            0) return 0 ;;
        esac
        press_any_key
    done
}
