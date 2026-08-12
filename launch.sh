#!/usr/bin/env bash
# ============================================================
#
#   ██████╗ ██████╗ ███████╗   ███████╗ ██████╗██████╗ ██╗██████╗ ████████╗███████╗
#  ██╔═══██╗██╔══██╗██╔════╝   ██╔════╝██╔════╝██╔══██╗██║██╔══██╗╚══██╔══╝██╔════╝
#  ██║   ██║██████╔╝███████╗   ███████╗██║     ██████╔╝██║██████╔╝   ██║   ███████╗
#  ██║   ██║██╔═══╝ ╚════██║   ╚════██║██║     ██╔══██╗██║██╔═══╝    ██║   ╚════██║
#  ╚██████╔╝██║     ███████║   ███████║╚██████╗██║  ██║██║██║        ██║   ███████║
#   ╚═════╝ ╚═╝     ╚══════╝   ╚══════╝ ╚═════╝╚═╝  ╚═╝╚═╝╚═╝        ╚═╝   ╚══════╝
#
#  服务器运维脚本集合
#  仅支持 Ubuntu / Debian 系统
#
# ============================================================

set -euo pipefail

# ---------- 获取入口所在目录（模块不得覆盖这些入口级变量）----------
readonly OPS_ROOT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
readonly OPS_MODULES_DIR="${OPS_ROOT_DIR}/modules"

# ---------- 加载公共模块 ----------
source "${OPS_MODULES_DIR}/common.sh"

# ---------- 加载镜像配置 ----------
load_mirror_config

# ============================================================
# 前置检查
# ============================================================
pre_check() {
    # 检查 root 权限
    if [ "$(id -u)" -ne 0 ]; then
        log_error "此脚本必须以 root 权限运行"
        log_info "请使用: sudo bash $0"
        exit 1
    fi

    # 检查操作系统
    detect_os
    if [ "$OS_ID" != "ubuntu" ] && [ "$OS_ID" != "debian" ]; then
        log_error "此脚本仅支持 Ubuntu 和 Debian 系统"
        log_error "当前系统: ${OS_NAME} (${OS_ID})"
        exit 1
    fi

    log_info "系统检测通过: ${OS_NAME}"
}

# ============================================================
# 系统初始化流程
# ============================================================
run_initialization() {
    print_separator
    echo -e "${BOLD}${CYAN}"
    echo "  欢迎使用服务器运维脚本集合"
    echo "  检测到系统尚未初始化，即将开始环境配置"
    echo -e "${NC}"
    print_separator
    echo ""

    if ! confirm "是否开始系统初始化?"; then
        log_info "已取消初始化，退出脚本"
        exit 0
    fi

    echo ""

    # 步骤 1: 系统环境配置 (APT 源 + 更新 + 安装基础包)
    source "${OPS_MODULES_DIR}/init_system.sh"
    run_init_system

    echo ""

    # 步骤 2: SSH 安全配置
    source "${OPS_MODULES_DIR}/init_ssh.sh"
    run_init_ssh

    echo ""

    # 标记初始化完成
    ensure_marker_dir
    touch "$INIT_MARKER"

    print_separator
    echo -e "${GREEN}${BOLD}"
    echo "  ✓ 系统初始化完成！"
    echo -e "${NC}"
    print_separator
    echo ""

    press_any_key
}

# ============================================================
# 脚本更新
# ============================================================
readonly OPS_GITHUB_REPO="uuuuupdate/ops-scripts"
readonly OPS_GITHUB_API="https://api.github.com/repos/${OPS_GITHUB_REPO}/releases/latest"
readonly OPS_GITHUB_TARBALL_API="https://api.github.com/repos/${OPS_GITHUB_REPO}/tarball"
readonly OPS_VERSION_FILE="${OPS_ROOT_DIR}/.version"
readonly OPS_AUTO_MIRROR_PREFIX="https://ghproxy.cn/"

UPDATE_TMP_DIR=""
UPDATE_STAGE_DIR=""
UPDATE_ROLLBACK_DIR=""
UPDATE_SWITCHING=0

_cleanup_update_state() {
    local status=$?
    if [ "$UPDATE_SWITCHING" -eq 1 ] && \
       [ ! -e "$OPS_ROOT_DIR" ] && [ ! -L "$OPS_ROOT_DIR" ] && \
       { [ -e "$UPDATE_ROLLBACK_DIR" ] || [ -L "$UPDATE_ROLLBACK_DIR" ]; }; then
        mv -- "$UPDATE_ROLLBACK_DIR" "$OPS_ROOT_DIR" || true
    fi
    if [ -n "$UPDATE_STAGE_DIR" ] && { [ -e "$UPDATE_STAGE_DIR" ] || [ -L "$UPDATE_STAGE_DIR" ]; }; then
        rm -rf -- "$UPDATE_STAGE_DIR"
    fi
    if [ -n "$UPDATE_TMP_DIR" ] && [ -d "$UPDATE_TMP_DIR" ]; then
        rm -rf -- "$UPDATE_TMP_DIR"
    fi
    return "$status"
}

_reset_update_state() {
    if [ -n "$UPDATE_TMP_DIR" ] && [ -d "$UPDATE_TMP_DIR" ]; then
        rm -rf -- "$UPDATE_TMP_DIR"
    fi
    UPDATE_TMP_DIR=""
    UPDATE_STAGE_DIR=""
    UPDATE_ROLLBACK_DIR=""
    UPDATE_SWITCHING=0
}

_validate_release_tag() {
    local tag="$1"
    [[ "$tag" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]{0,127}$ ]]
}

_mirror_release_url() {
    local url="$1"
    local mirror_prefix="$2"
    if [ -n "$mirror_prefix" ]; then
        printf '%s%s\n' "$mirror_prefix" "$url"
    else
        printf '%s\n' "$url"
    fi
}

_validate_release_archive() {
    local archive="$1"
    local entry=""
    local root=""
    local item_type=""

    tar -tzf "$archive" >/dev/null
    while IFS= read -r entry; do
        [ -n "$entry" ] || { log_error "更新归档包含空路径"; return 1; }
        case "$entry" in
            /*|*\\*) log_error "更新归档包含危险路径: ${entry}"; return 1 ;;
        esac
        case "/${entry}/" in
            */../*) log_error "更新归档包含路径穿越条目: ${entry}"; return 1 ;;
        esac
        if [ -z "$root" ]; then
            root="${entry%%/*}"
            [ -n "$root" ] && [ "$root" != "." ] && [ "$root" != ".." ] || return 1
        fi
        case "$entry" in
            "$root"|"$root"/*) ;;
            *) log_error "更新归档必须仅包含一个顶层目录"; return 1 ;;
        esac
    done < <(tar -tzf "$archive" --quoting-style=escape)
    [ -n "$root" ] || { log_error "更新归档为空"; return 1; }

    while IFS= read -r entry; do
        item_type="${entry:0:1}"
        case "$item_type" in
            -|d) ;;
            *) log_error "更新归档包含不允许的链接或设备条目"; return 1 ;;
        esac
    done < <(tar -tvzf "$archive" --quoting-style=escape)
}

_verify_release_tree() {
    local directory="$1"
    local required
    for required in launch.sh install.sh modules/common.sh; do
        if [ ! -f "${directory}/${required}" ] || [ -L "${directory}/${required}" ]; then
            log_error "更新内容缺少安全的必需文件: ${required}"
            return 1
        fi
    done

    local script
    while IFS= read -r -d '' script; do
        if ! bash -n "$script"; then
            log_error "更新内容语法检查失败: ${script#${directory}/}"
            return 1
        fi
    done < <(find "$directory" -type f -name '*.sh' -print0)
}

_stage_release_update() {
    local tag="$1"
    local mirror_prefix="$2"
    local install_parent
    local install_name
    local archive
    local extract_dir
    local tarball_url

    install_parent=$(dirname "$OPS_ROOT_DIR")
    install_name=$(basename "$OPS_ROOT_DIR")
    UPDATE_TMP_DIR=$(mktemp -d)
    archive="${UPDATE_TMP_DIR}/ops-scripts.tar.gz"
    extract_dir="${UPDATE_TMP_DIR}/extract"
    mkdir -p "$extract_dir"
    tarball_url=$(_mirror_release_url "${OPS_GITHUB_TARBALL_API}/${tag}" "$mirror_prefix")

    log_info "正在通过 GitHub API 下载版本 ${tag}..."
    log_warn "源码归档没有上游发布者提供的独立校验和；本次仅能依赖 HTTPS 传输和归档内容检查。"
    if ! curl --proto '=https' --proto-redir '=https' -fsSL \
        --connect-timeout 10 --max-time 120 \
        -H 'Accept: application/vnd.github+json' \
        -H 'X-GitHub-Api-Version: 2022-11-28' \
        "${MIRROR_CURL_ARGS[@]+"${MIRROR_CURL_ARGS[@]}"}" \
        -o "$archive" "$tarball_url"; then
        log_error "下载失败，请检查网络连接"
        return 1
    fi

    if ! _validate_release_archive "$archive"; then
        log_error "更新归档安全检查失败"
        return 1
    fi
    if ! tar -xzf "$archive" -C "$extract_dir" --strip-components=1 \
        --no-same-owner --no-same-permissions; then
        log_error "解压更新归档失败"
        return 1
    fi
    _verify_release_tree "$extract_dir" || return 1

    UPDATE_STAGE_DIR=$(mktemp -d "${install_parent}/.${install_name}.new.XXXXXX")
    cp -a "${extract_dir}/." "${UPDATE_STAGE_DIR}/"
    printf '%s\n' "$tag" > "${UPDATE_STAGE_DIR}/.version"
    chmod 0755 "${UPDATE_STAGE_DIR}/launch.sh" "${UPDATE_STAGE_DIR}/install.sh"
}

_activate_release_update() {
    local previous="${OPS_ROOT_DIR}.previous"

    if [ -e "$previous" ] || [ -L "$previous" ]; then
        rm -rf -- "$previous"
    fi
    UPDATE_ROLLBACK_DIR="$previous"
    UPDATE_SWITCHING=1
    if ! mv -- "$OPS_ROOT_DIR" "$UPDATE_ROLLBACK_DIR"; then
        UPDATE_SWITCHING=0
        log_error "无法保留当前版本，已取消更新"
        return 1
    fi
    if ! mv -- "$UPDATE_STAGE_DIR" "$OPS_ROOT_DIR"; then
        mv -- "$UPDATE_ROLLBACK_DIR" "$OPS_ROOT_DIR" || true
        UPDATE_SWITCHING=0
        log_error "切换新版本失败，已尝试恢复当前版本"
        return 1
    fi
    UPDATE_STAGE_DIR=""
    UPDATE_SWITCHING=0
}

update_scripts() {
    print_separator
    echo -e "  ${BOLD}脚本更新${NC}"
    print_separator
    echo ""

    # 显示当前版本
    if [ -f "$OPS_VERSION_FILE" ]; then
        local current_version
        current_version=$(head -n 1 "$OPS_VERSION_FILE") || true
        log_info "当前版本: ${current_version}"
    else
        log_warn "未检测到版本信息"
    fi

    echo ""

    # 确定使用的下载前缀
    local mirror_prefix=""
    if [ -n "${MIRROR_URL:-}" ]; then
        log_info "使用已配置的镜像代理: ${MIRROR_URL}"
        mirror_prefix="${MIRROR_URL%/}/"
    else
        log_info "检测网络环境..."
        if is_china_network; then
            log_info "检测到中国大陆网络，使用默认镜像加速"
            mirror_prefix="${OPS_AUTO_MIRROR_PREFIX}"
        fi
    fi

    # 构建 API 地址
    local api_url
    if [ -n "$mirror_prefix" ]; then
        api_url="${mirror_prefix}${OPS_GITHUB_API}"
    else
        api_url="$OPS_GITHUB_API"
    fi

    # 获取最新版本
    log_info "获取最新版本信息..."
    local latest_tag=""
    local api_response=""
    if ! api_response=$(curl --proto '=https' --proto-redir '=https' -fsSL \
        --connect-timeout 10 --max-time 20 \
        -H 'Accept: application/vnd.github+json' \
        -H 'X-GitHub-Api-Version: 2022-11-28' \
        "${MIRROR_CURL_ARGS[@]+"${MIRROR_CURL_ARGS[@]}"}" "$api_url" 2>/dev/null); then
        log_error "无法获取最新版本信息，请检查网络连接"
        press_any_key
        return
    fi
    latest_tag=$(sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' <<< "$api_response") || true
    if ! _validate_release_tag "$latest_tag"; then
        log_error "无法获取最新版本信息，请检查网络连接"
        press_any_key
        return
    fi

    log_info "最新版本: ${latest_tag}"

    # 检查是否已是最新版本
    if [ -f "$OPS_VERSION_FILE" ]; then
        if [ "${current_version:-}" = "$latest_tag" ]; then
            echo ""
            log_info "当前已是最新版本，无需更新"
            press_any_key
            return
        fi
    fi

    echo ""
    if ! confirm "是否更新到版本 ${latest_tag}?"; then
        return
    fi

    echo ""
    log_info "正在准备更新..."
    if ! _stage_release_update "$latest_tag" "$mirror_prefix"; then
        _cleanup_update_state || true
        _reset_update_state
        press_any_key
        return
    fi
    if ! _activate_release_update; then
        _cleanup_update_state || true
        _reset_update_state
        press_any_key
        return
    fi
    _reset_update_state

    echo ""
    log_info "✓ 脚本已更新到版本 ${latest_tag}！"
    log_info "上一版本保留在: ${OPS_ROOT_DIR}.previous"
    log_info "请重新运行脚本以使更新生效"
    press_any_key
    exit 0
}

# ============================================================
# 主功能菜单
# ============================================================
show_menu() {
    while true; do
        clear
        echo -e "${CYAN}"
        echo "  ============================================================"
        echo "    ███████╗███████╗██████╗ ██╗   ██╗███████╗██████╗ "
        echo "    ██╔════╝██╔════╝██╔══██╗██║   ██║██╔════╝██╔══██╗"
        echo "    ███████╗█████╗  ██████╔╝██║   ██║█████╗  ██████╔╝"
        echo "    ╚════██║██╔══╝  ██╔══██╗╚██╗ ██╔╝██╔══╝  ██╔══██╗"
        echo "    ███████║███████╗██║  ██║ ╚████╔╝ ███████╗██║  ██║"
        echo "    ╚══════╝╚══════╝╚═╝  ╚═╝  ╚═══╝  ╚══════╝╚═╝  ╚═╝"
        echo "    ██████╗ ██████╗ ███████╗                          "
        echo "    ██╔═══██╗██╔══██╗██╔════╝                          "
        echo "    ██║   ██║██████╔╝███████╗                          "
        echo "    ██║   ██║██╔═══╝ ╚════██║                          "
        echo "    ╚██████╔╝██║     ███████║                          "
        echo "     ╚═════╝ ╚═╝     ╚══════╝                          "
        echo "  ============================================================"
        echo -e "${NC}"
        echo -e "  ${BOLD}服务器运维工具集${NC}  |  系统: ${OS_NAME}"
        if [ -n "${MIRROR_URL:-}" ]; then
            echo -e "  ${YELLOW}镜像代理: ${MIRROR_URL}${NC}"
        fi
        echo ""
        print_separator
        echo ""
        echo -e "  ${BOLD}功能菜单:${NC}"
        echo ""
        echo "    1) 🔥 防火墙管理"
        echo "    2) 👤 用户管理"
        echo "    3) 👥 用户组管理"
        echo "    4) 📊 系统信息"
        echo "    5) ⏰ 定时任务管理"
        echo "    6) ⚙️  系统服务管理"
        echo "    7) 🖥️  主机设置 (主机名/时区/NTP/Swap)"
        echo "    8) 🌐 Caddy 管理"
        echo "    9) 🌐 Nginx 管理 (源码编译)"
        echo "   10) 🔑 Sudoer 管理"
        echo "   11) 📋 日志管理"
        echo ""
        echo "   12) 🔄 脚本更新"
        echo "   13) 🌐 镜像代理配置"
        echo ""
        echo "    0) 退出"
        echo ""
        print_separator
        select_option "请选择功能" 13 0

        case "$SELECTED_OPTION" in
            1)
                check_and_install_deps "防火墙管理" "nft:nftables" || continue
                source "${OPS_MODULES_DIR}/firewall.sh"
                run_firewall
                ;;
            2)
                source "${OPS_MODULES_DIR}/user_mgmt.sh"
                run_user_mgmt
                ;;
            3)
                source "${OPS_MODULES_DIR}/group_mgmt.sh"
                run_group_mgmt
                ;;
            4)
                source "${OPS_MODULES_DIR}/system_info.sh"
                run_system_info
                ;;
            5)
                check_and_install_deps "定时任务管理" "crontab:cron" || continue
                source "${OPS_MODULES_DIR}/cron_mgmt.sh"
                run_cron_mgmt
                ;;
            6)
                source "${OPS_MODULES_DIR}/service_mgmt.sh"
                run_service_mgmt
                ;;
            7)
                source "${OPS_MODULES_DIR}/host_mgmt.sh"
                run_host_mgmt
                ;;
            8)
                source "${OPS_MODULES_DIR}/caddy.sh"
                run_caddy
                ;;
            9)
                source "${OPS_MODULES_DIR}/nginx.sh"
                run_nginx
                ;;
            10)
                source "${OPS_MODULES_DIR}/sudoer_mgmt.sh"
                run_sudoer_mgmt
                ;;
            11)
                source "${OPS_MODULES_DIR}/log_clean.sh"
                run_log_mgmt
                ;;
            12)
                update_scripts
                ;;
            13)
                configure_mirror_interactive
                ;;
            0)
                echo ""
                log_info "感谢使用，再见！"
                echo ""
                exit 0
                ;;
        esac
    done
}

# ============================================================
# 主入口
# ============================================================
main() {
    pre_check

    # 检查是否已初始化
    if [ ! -f "$INIT_MARKER" ]; then
        run_initialization
    fi

    # 显示功能菜单
    show_menu
}

trap _cleanup_update_state EXIT
trap 'exit 130' INT TERM HUP
main "$@"
