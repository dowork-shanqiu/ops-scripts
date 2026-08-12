#!/usr/bin/env bash
# ============================================================
# OPS-Scripts 安装脚本
#
# 交互安装：
#   curl -fsSL https://raw.githubusercontent.com/uuuuupdate/ops-scripts/main/install.sh | sudo bash
# 非交互安装：
#   curl -fsSL https://raw.githubusercontent.com/uuuuupdate/ops-scripts/main/install.sh | sudo bash -s -- --non-interactive
# ============================================================

set -euo pipefail

# ---------- 固定配置 ----------
readonly GITHUB_REPO="uuuuupdate/ops-scripts"
readonly GITHUB_API="https://api.github.com/repos/${GITHUB_REPO}/releases/latest"
readonly GITHUB_TARBALL_API="https://api.github.com/repos/${GITHUB_REPO}/tarball"
readonly INSTALL_DIR="${OPS_INSTALL_DIR:-/opt/ops-scripts}"
readonly BIN_LINK="${OPS_BIN_LINK:-/usr/bin/ops-scripts}"
readonly MARKER_DIR="${OPS_MARKER_DIR:-/etc/ops-scripts}"
readonly MIRROR_CONF_FILE="${MARKER_DIR}/mirror.conf"
readonly VERSION_FILE="${INSTALL_DIR}/.version"
readonly AUTO_MIRROR_PREFIX="https://ghproxy.cn/"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

NON_INTERACTIVE="${OPS_NON_INTERACTIVE:-0}"
FORCE_INSTALL="${OPS_FORCE_INSTALL:-0}"
REQUESTED_TAG="${OPS_INSTALL_VERSION:-}"
MIRROR_URL="${OPS_MIRROR_URL:-}"
NO_MIRROR="${OPS_NO_MIRROR:-0}"
MIRROR_URL_EXPLICIT=0
MIRROR_HEADERS_EXPLICIT=0
[ -z "${OPS_MIRROR_URL+x}" ] || MIRROR_URL_EXPLICIT=1
[ -z "${OPS_MIRROR_HEADERS+x}" ] || MIRROR_HEADERS_EXPLICIT=1
MIRROR_HEADERS=()
MIRROR_CURL_ARGS=()
INSTALL_TMP_DIR=""
INSTALL_STAGE_DIR=""
INSTALL_ROLLBACK_DIR=""
INSTALL_SWITCHING=0
HAS_TTY=0

log_info() {
    printf '%b[INFO]%b %s\n' "$GREEN" "$NC" "$*"
}

log_warn() {
    printf '%b[WARN]%b %s\n' "$YELLOW" "$NC" "$*" >&2
}

log_error() {
    printf '%b[ERROR]%b %s\n' "$RED" "$NC" "$*" >&2
}

show_help() {
    cat <<'EOF'
用法：install.sh [选项]

  --non-interactive    不读取交互输入，使用现有配置或安全默认值
  --version TAG        安装指定 Release 标签；默认安装最新 Release
  --mirror URL         使用指定的 HTTPS GitHub 镜像前缀
  --header HEADER      为镜像请求增加请求头，可重复指定
  --no-mirror          不使用且删除已保存的镜像配置
  --force              即使版本相同也重新安装
  -h, --help           显示帮助

等价环境变量：OPS_NON_INTERACTIVE、OPS_INSTALL_VERSION、OPS_MIRROR_URL、
OPS_MIRROR_HEADERS（每行一个请求头）、OPS_NO_MIRROR、OPS_FORCE_INSTALL。
EOF
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --non-interactive)
                NON_INTERACTIVE=1
                ;;
            --force)
                FORCE_INSTALL=1
                ;;
            --no-mirror)
                NO_MIRROR=1
                ;;
            --version)
                [ "$#" -ge 2 ] || { log_error "--version 缺少参数"; return 2; }
                REQUESTED_TAG="$2"
                shift
                ;;
            --mirror)
                [ "$#" -ge 2 ] || { log_error "--mirror 缺少参数"; return 2; }
                MIRROR_URL="$2"
                MIRROR_URL_EXPLICIT=1
                shift
                ;;
            --header)
                [ "$#" -ge 2 ] || { log_error "--header 缺少参数"; return 2; }
                MIRROR_HEADERS+=("$2")
                MIRROR_HEADERS_EXPLICIT=1
                shift
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                log_error "未知参数: $1"
                show_help >&2
                return 2
                ;;
        esac
        shift
    done

    if [ -n "${OPS_MIRROR_HEADERS:-}" ]; then
        local header
        while IFS= read -r header; do
            [ -n "$header" ] && MIRROR_HEADERS+=("$header")
        done <<< "${OPS_MIRROR_HEADERS}"
    fi
}

validate_fixed_paths() {
    case "$INSTALL_DIR" in
        /*) ;;
        *) log_error "安装目录必须是绝对路径: ${INSTALL_DIR}"; return 1 ;;
    esac
    case "$BIN_LINK" in
        /*) ;;
        *) log_error "命令链接必须是绝对路径: ${BIN_LINK}"; return 1 ;;
    esac
    case "$MARKER_DIR" in
        /*) ;;
        *) log_error "配置目录必须是绝对路径: ${MARKER_DIR}"; return 1 ;;
    esac
    [ "$INSTALL_DIR" != "/" ] || { log_error "拒绝使用根目录作为安装目录"; return 1; }
}

detect_tty() {
    # 管道执行时 stdin 不是终端；正常交互终端仍会让 stderr 指向 TTY。
    if [ -t 2 ] && [ -r /dev/tty ] && [ -w /dev/tty ]; then
        HAS_TTY=1
    else
        HAS_TTY=0
        NON_INTERACTIVE=1
    fi
}

read_tty() {
    local prompt="$1"
    local variable="$2"
    local value=""
    [ "$HAS_TTY" -eq 1 ] || return 1
    printf '%b%s%b' "$CYAN" "$prompt" "$NC" > /dev/tty
    IFS= read -r value < /dev/tty || return 1
    printf -v "$variable" '%s' "$value"
}

confirm_tty() {
    local prompt="$1"
    local answer=""
    while read_tty "${prompt} [y/n]: " answer; do
        case "$answer" in
            [Yy]|[Yy][Ee][Ss]) return 0 ;;
            [Nn]|[Nn][Oo]|"") return 1 ;;
            *) log_warn "请输入 y 或 n" ;;
        esac
    done
    return 1
}

validate_tag() {
    [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]{0,127}$ ]]
}

validate_mirror_url() {
    local value="$1"
    [ -z "$value" ] && return 0
    [[ "$value" =~ ^https://[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?([:/][^[:space:]]*)?$ ]]
}

validate_header() {
    local value="$1"
    [[ "$value" =~ ^[A-Za-z0-9!#$%\&\'*+.^_\`\|~-]+:[[:space:]]*[^[:cntrl:]]+$ ]]
}

rebuild_mirror_curl_args() {
    MIRROR_CURL_ARGS=()
    local header
    for header in "${MIRROR_HEADERS[@]+"${MIRROR_HEADERS[@]}"}"; do
        if ! validate_header "$header"; then
            log_error "镜像请求头格式无效，仅允许 'Header-Name: value'"
            return 1
        fi
        MIRROR_CURL_ARGS+=(-H "$header")
    done
}

load_mirror_config() {
    [ -f "$MIRROR_CONF_FILE" ] || return 0

    local raw=""
    local count=0
    local index=0
    if [ "$MIRROR_URL_EXPLICIT" -eq 0 ] && [ -z "$MIRROR_URL" ]; then
        raw=$(grep -m1 '^MIRROR_URL=' "$MIRROR_CONF_FILE" 2>/dev/null | cut -d= -f2-) || true
        MIRROR_URL="${raw:-}"
    fi
    # 显式更换镜像时绝不复用旧镜像凭据，避免认证头泄露到新主机。
    if [ "$MIRROR_URL_EXPLICIT" -eq 0 ] && [ "$MIRROR_HEADERS_EXPLICIT" -eq 0 ] &&
       [ "${#MIRROR_HEADERS[@]}" -eq 0 ]; then
        raw=$(grep -m1 '^HEADER_COUNT=' "$MIRROR_CONF_FILE" 2>/dev/null | cut -d= -f2-) || true
        count="${raw:-0}"
        [[ "$count" =~ ^[0-9]+$ ]] || count=0
        [ "$count" -le 64 ] || { log_error "镜像配置中的请求头数量异常"; return 1; }
        while [ "$index" -lt "$count" ]; do
            raw=$(grep -m1 "^HEADER_${index}=" "$MIRROR_CONF_FILE" 2>/dev/null | cut -d= -f2-) || true
            [ -n "${raw:-}" ] && MIRROR_HEADERS+=("$raw")
            index=$((index + 1))
        done
    fi
}

save_mirror_config() {
    mkdir -p "$MARKER_DIR"
    chmod 0700 "$MARKER_DIR"
    local tmp_file
    local old_umask
    old_umask=$(umask)
    umask 077
    tmp_file=$(mktemp "${MARKER_DIR}/.mirror.conf.XXXXXX")
    {
        printf 'MIRROR_URL=%s\n' "$MIRROR_URL"
        printf 'HEADER_COUNT=%d\n' "${#MIRROR_HEADERS[@]}"
        local index=0
        local header
        for header in "${MIRROR_HEADERS[@]+"${MIRROR_HEADERS[@]}"}"; do
            printf 'HEADER_%d=%s\n' "$index" "$header"
            index=$((index + 1))
        done
    } > "$tmp_file"
    chmod 0600 "$tmp_file"
    mv -f -- "$tmp_file" "$MIRROR_CONF_FILE"
    umask "$old_umask"
}

clear_mirror_config() {
    MIRROR_URL=""
    MIRROR_HEADERS=()
    MIRROR_CURL_ARGS=()
    if [ -e "$MIRROR_CONF_FILE" ] || [ -L "$MIRROR_CONF_FILE" ]; then
        rm -f -- "$MIRROR_CONF_FILE"
    fi
}

show_mirror_status() {
    if [ -z "$MIRROR_URL" ]; then
        log_info "当前未配置镜像代理"
        return
    fi
    log_info "镜像地址: ${MIRROR_URL}"
    log_info "认证请求头: ${#MIRROR_HEADERS[@]} 个（值已隐藏）"
}

configure_headers_interactive() {
    MIRROR_HEADERS=()
    local header=""
    local index=1
    log_info "请输入镜像认证请求头，直接回车结束；请求头值不会显示在日志中"
    while read_tty "  第 ${index} 个请求头 (Header-Name: value): " header; do
        [ -n "$header" ] || break
        if ! validate_header "$header"; then
            log_warn "格式无效，请使用 'Header-Name: value'"
            continue
        fi
        MIRROR_HEADERS+=("$header")
        log_info "已添加请求头: ${header%%:*}: ****"
        index=$((index + 1))
    done
}

configure_mirror() {
    if [ "$NO_MIRROR" = "1" ]; then
        clear_mirror_config
        log_info "已禁用镜像代理"
        return
    fi

    load_mirror_config
    if ! validate_mirror_url "$MIRROR_URL"; then
        log_error "镜像地址必须使用有效的 HTTPS URL: ${MIRROR_URL}"
        return 1
    fi
    rebuild_mirror_curl_args

    if [ "$NON_INTERACTIVE" = "1" ]; then
        if [ -n "$MIRROR_URL" ]; then
            save_mirror_config
        elif [ -f "$MIRROR_CONF_FILE" ]; then
            chmod 0600 "$MIRROR_CONF_FILE"
        fi
        show_mirror_status
        return
    fi

    printf '\n'
    show_mirror_status
    if [ -n "$MIRROR_URL" ] && ! confirm_tty "是否重新配置镜像代理?"; then
        chmod 0600 "$MIRROR_CONF_FILE"
        return
    fi
    if ! confirm_tty "是否配置 HTTPS GitHub 镜像代理?"; then
        clear_mirror_config
        log_info "未使用镜像代理"
        return
    fi

    local new_url=""
    while read_tty "请输入 HTTPS 镜像地址: " new_url; do
        new_url="${new_url%/}"
        if validate_mirror_url "$new_url" && [ -n "$new_url" ]; then
            MIRROR_URL="$new_url"
            break
        fi
        log_warn "请输入有效的 HTTPS URL"
    done
    [ -n "$MIRROR_URL" ] || { log_error "未获得有效镜像地址"; return 1; }

    if confirm_tty "是否配置镜像认证请求头?"; then
        configure_headers_interactive
    else
        MIRROR_HEADERS=()
    fi
    rebuild_mirror_curl_args
    save_mirror_config
    show_mirror_status
}

check_dependencies() {
    local missing=()
    local command_name
    for command_name in curl tar mktemp; do
        command -v "$command_name" >/dev/null 2>&1 || missing+=("$command_name")
    done
    [ "${#missing[@]}" -eq 0 ] && return 0

    log_warn "缺少依赖: ${missing[*]}"
    if command -v apt-get >/dev/null 2>&1; then
        log_info "正在安装缺少的依赖..."
        apt-get update -qq
        apt-get install -y -qq curl tar coreutils
    else
        log_error "无法自动安装依赖，请先安装 curl、tar 和 coreutils"
        return 1
    fi
}

is_china_network() {
    local api_url
    local response=""
    local country=""
    for api_url in \
        "https://blog.cloudflare.com/cdn-cgi/trace" \
        "https://dash.cloudflare.com/cdn-cgi/trace"; do
        response=$(curl --proto '=https' -A 'Mozilla/5.0' --connect-timeout 3 --max-time 5 -sS "$api_url" 2>/dev/null) || continue
        country=$(sed -n 's/^loc=\([A-Z][A-Z]\).*/\1/p' <<< "$response")
        [ "$country" = "CN" ] && return 0
        [ -n "$country" ] && return 1
    done
    return 1
}

mirror_url_for() {
    local url="$1"
    local prefix="$2"
    if [ -n "$prefix" ]; then
        printf '%s%s\n' "$prefix" "$url"
    else
        printf '%s\n' "$url"
    fi
}

get_latest_tag() {
    local prefix="$1"
    local api_url
    local tag=""
    local response=""
    api_url=$(mirror_url_for "$GITHUB_API" "$prefix")
    response=$(curl --proto '=https' --proto-redir '=https' -fsSL \
        --connect-timeout 10 --max-time 20 \
        -H 'Accept: application/vnd.github+json' \
        -H 'X-GitHub-Api-Version: 2022-11-28' \
        "${MIRROR_CURL_ARGS[@]+"${MIRROR_CURL_ARGS[@]}"}" "$api_url") || return 1
    tag=$(sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' <<< "$response") || return 1
    validate_tag "$tag" || return 1
    printf '%s\n' "$tag"
}

validate_archive() {
    local archive="$1"
    local entry=""
    local root=""
    local item_type=""

    tar -tzf "$archive" >/dev/null
    while IFS= read -r entry; do
        [ -n "$entry" ] || { log_error "归档包含空路径"; return 1; }
        case "$entry" in
            /*|*\\*) log_error "归档包含危险路径: ${entry}"; return 1 ;;
        esac
        case "/${entry}/" in
            */../*) log_error "归档包含路径穿越条目: ${entry}"; return 1 ;;
        esac
        if [ -z "$root" ]; then
            root="${entry%%/*}"
            [ -n "$root" ] && [ "$root" != "." ] && [ "$root" != ".." ] || return 1
        fi
        case "$entry" in
            "$root"|"$root"/*) ;;
            *) log_error "归档必须仅包含一个顶层目录"; return 1 ;;
        esac
    done < <(tar -tzf "$archive" --quoting-style=escape)
    [ -n "$root" ] || { log_error "归档为空"; return 1; }

    while IFS= read -r entry; do
        item_type="${entry:0:1}"
        case "$item_type" in
            -|d) ;;
            *) log_error "归档包含不允许的链接或设备条目"; return 1 ;;
        esac
    done < <(tar -tvzf "$archive" --quoting-style=escape)
}

verify_extracted_tree() {
    local directory="$1"
    local required
    for required in launch.sh install.sh modules/common.sh; do
        if [ ! -f "${directory}/${required}" ] || [ -L "${directory}/${required}" ]; then
            log_error "下载内容缺少安全的必需文件: ${required}"
            return 1
        fi
    done

    local script
    while IFS= read -r -d '' script; do
        if ! bash -n "$script"; then
            log_error "下载脚本语法检查失败: ${script#${directory}/}"
            return 1
        fi
    done < <(find "$directory" -type f -name '*.sh' -print0)
}

cleanup_install_state() {
    local status=$?
    if [ "$INSTALL_SWITCHING" -eq 1 ]; then
        rollback_activated_install || true
    fi
    if [ -n "$INSTALL_STAGE_DIR" ] && { [ -e "$INSTALL_STAGE_DIR" ] || [ -L "$INSTALL_STAGE_DIR" ]; }; then
        rm -rf -- "$INSTALL_STAGE_DIR"
    fi
    if [ -n "$INSTALL_TMP_DIR" ] && [ -d "$INSTALL_TMP_DIR" ]; then
        rm -rf -- "$INSTALL_TMP_DIR"
    fi
    return "$status"
}

rollback_activated_install() {
    local failed_install="${INSTALL_DIR}.failed.$$"

    if [ -n "$INSTALL_ROLLBACK_DIR" ] && \
       { [ -e "$INSTALL_ROLLBACK_DIR" ] || [ -L "$INSTALL_ROLLBACK_DIR" ]; }; then
        if [ -e "$INSTALL_DIR" ] || [ -L "$INSTALL_DIR" ]; then
            mv -- "$INSTALL_DIR" "$failed_install" || return 1
        fi
        if ! mv -- "$INSTALL_ROLLBACK_DIR" "$INSTALL_DIR"; then
            if [ -e "$failed_install" ] || [ -L "$failed_install" ]; then
                mv -- "$failed_install" "$INSTALL_DIR" || true
            fi
            return 1
        fi
        if [ -e "$failed_install" ] || [ -L "$failed_install" ]; then
            rm -rf -- "$failed_install"
        fi
    elif [ -e "$INSTALL_DIR" ] || [ -L "$INSTALL_DIR" ]; then
        rm -rf -- "$INSTALL_DIR"
    fi
    INSTALL_SWITCHING=0
}

download_and_stage() {
    local tag="$1"
    local prefix="$2"
    local install_parent
    local install_name
    local tarball_url
    local archive
    local extract_dir

    install_parent=$(dirname "$INSTALL_DIR")
    install_name=$(basename "$INSTALL_DIR")
    mkdir -p "$install_parent"
    INSTALL_TMP_DIR=$(mktemp -d)
    archive="${INSTALL_TMP_DIR}/ops-scripts.tar.gz"
    extract_dir="${INSTALL_TMP_DIR}/extract"
    mkdir -p "$extract_dir"
    tarball_url=$(mirror_url_for "${GITHUB_TARBALL_API}/${tag}" "$prefix")

    log_info "正在通过 GitHub API 下载版本 ${tag}..."
    log_warn "源码归档没有上游发布者提供的独立校验和；本次仅能依赖 HTTPS 传输和归档内容检查。"
    curl --proto '=https' --proto-redir '=https' -fsSL \
        --connect-timeout 10 --max-time 120 \
        -H 'Accept: application/vnd.github+json' \
        -H 'X-GitHub-Api-Version: 2022-11-28' \
        "${MIRROR_CURL_ARGS[@]+"${MIRROR_CURL_ARGS[@]}"}" \
        -o "$archive" "$tarball_url"

    validate_archive "$archive"
    tar -xzf "$archive" -C "$extract_dir" --strip-components=1 \
        --no-same-owner --no-same-permissions
    verify_extracted_tree "$extract_dir"

    INSTALL_STAGE_DIR=$(mktemp -d "${install_parent}/.${install_name}.new.XXXXXX")
    cp -a "${extract_dir}/." "${INSTALL_STAGE_DIR}/"
    printf '%s\n' "$tag" > "${INSTALL_STAGE_DIR}/.version"
    chmod 0755 "${INSTALL_STAGE_DIR}/launch.sh" "${INSTALL_STAGE_DIR}/install.sh"
}

activate_staged_install() {
    local previous="${INSTALL_DIR}.previous"

    if [ -e "$previous" ] || [ -L "$previous" ]; then
        rm -rf -- "$previous"
    fi
    INSTALL_ROLLBACK_DIR="$previous"
    INSTALL_SWITCHING=1
    if [ -e "$INSTALL_DIR" ] || [ -L "$INSTALL_DIR" ]; then
        mv -- "$INSTALL_DIR" "$INSTALL_ROLLBACK_DIR"
    else
        INSTALL_ROLLBACK_DIR=""
    fi

    if ! mv -- "$INSTALL_STAGE_DIR" "$INSTALL_DIR"; then
        if [ -n "$INSTALL_ROLLBACK_DIR" ] && \
           { [ -e "$INSTALL_ROLLBACK_DIR" ] || [ -L "$INSTALL_ROLLBACK_DIR" ]; }; then
            mv -- "$INSTALL_ROLLBACK_DIR" "$INSTALL_DIR" || true
        fi
        INSTALL_SWITCHING=0
        log_error "切换新版本失败，已尝试恢复原安装"
        return 1
    fi
    INSTALL_STAGE_DIR=""
}

ensure_command_link() {
    mkdir -p "$(dirname "$BIN_LINK")"
    local temp_link="${BIN_LINK}.new.$$"
    if ! ln -sfn "$INSTALL_DIR/launch.sh" "$temp_link"; then
        return 1
    fi
    if ! mv -Tf -- "$temp_link" "$BIN_LINK"; then
        rm -f -- "$temp_link"
        return 1
    fi
    log_info "命令链接已就绪: ${BIN_LINK}"
}

main() {
    parse_args "$@"
    validate_fixed_paths
    detect_tty

    printf '%b\n' "$CYAN"
    printf '  ============================================================\n'
    printf '   OPS-Scripts 安装程序\n'
    printf '   服务器运维脚本集合 - 仅支持 Ubuntu / Debian\n'
    printf '  ============================================================\n'
    printf '%b\n' "$NC"

    if [ "$(id -u)" -ne 0 ]; then
        log_error "此脚本必须以 root 权限运行"
        log_info "请使用: curl -fsSL <URL> | sudo bash"
        return 1
    fi

    if [ ! -f /etc/os-release ]; then
        log_error "无法检测操作系统"
        return 1
    fi
    # shellcheck disable=SC1091
    . /etc/os-release
    if [ "${ID:-}" != "ubuntu" ] && [ "${ID:-}" != "debian" ]; then
        log_error "仅支持 Ubuntu 和 Debian，当前系统: ${PRETTY_NAME:-unknown}"
        return 1
    fi

    check_dependencies
    configure_mirror

    local mirror_prefix=""
    if [ -n "$MIRROR_URL" ]; then
        mirror_prefix="${MIRROR_URL%/}/"
    elif [ "$NO_MIRROR" != "1" ] && is_china_network; then
        mirror_prefix="$AUTO_MIRROR_PREFIX"
        log_info "检测到中国大陆网络，临时使用默认 HTTPS 镜像"
    fi

    local latest_tag="$REQUESTED_TAG"
    if [ -z "$latest_tag" ]; then
        log_info "正在获取最新 Release 信息..."
        latest_tag=$(get_latest_tag "$mirror_prefix") || {
            log_error "无法获取最新 Release 信息"
            return 1
        }
    elif ! validate_tag "$latest_tag"; then
        log_error "版本标签格式无效: ${latest_tag}"
        return 1
    fi
    log_info "目标版本: ${latest_tag}"

    local current_version=""
    if [ -f "$VERSION_FILE" ]; then
        current_version=$(head -n 1 "$VERSION_FILE") || true
    fi
    if [ "$current_version" = "$latest_tag" ] && [ "$FORCE_INSTALL" != "1" ]; then
        log_info "当前已是目标版本，跳过下载"
        chmod 0755 "$INSTALL_DIR/launch.sh"
        ensure_command_link
        if [ -f "$MIRROR_CONF_FILE" ] && ! chmod 0600 "$MIRROR_CONF_FILE"; then
            log_warn "无法收紧镜像配置权限，请立即手动执行: chmod 600 ${MIRROR_CONF_FILE}"
        fi
        return 0
    fi

    download_and_stage "$latest_tag" "$mirror_prefix"
    activate_staged_install
    if ! ensure_command_link; then
        log_error "创建命令链接失败，正在恢复原安装"
        rollback_activated_install || log_error "自动恢复失败，请检查 ${INSTALL_DIR} 和 ${INSTALL_ROLLBACK_DIR}"
        return 1
    fi
    INSTALL_SWITCHING=0
    if [ -f "$MIRROR_CONF_FILE" ] && ! chmod 0600 "$MIRROR_CONF_FILE"; then
        log_warn "无法收紧镜像配置权限，请立即手动执行: chmod 600 ${MIRROR_CONF_FILE}"
    fi

    printf '\n%bOPS-Scripts 安装完成（版本: %s）%b\n' "$GREEN$BOLD" "$latest_tag" "$NC"
    printf '运行方式: %bsudo ops-scripts%b\n\n' "$CYAN" "$NC"
    if [ -e "${INSTALL_DIR}.previous" ] || [ -L "${INSTALL_DIR}.previous" ]; then
        log_info "上一版本保留在: ${INSTALL_DIR}.previous"
    fi
}

# 直接执行文件时 BASH_SOURCE[0] 等于 $0；通过 `curl ... | bash` 从标准输入
# 执行时 BASH_SOURCE[0] 为空。仅在被其他脚本 source 时跳过 main。
if [ -z "${BASH_SOURCE[0]:-}" ] || [ "${BASH_SOURCE[0]}" = "$0" ]; then
    trap cleanup_install_state EXIT
    trap 'exit 130' INT TERM HUP
    main "$@"
fi
