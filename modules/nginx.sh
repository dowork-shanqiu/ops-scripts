#!/usr/bin/env bash
# ============================================================
# Nginx 源码编译安装模块
# - 支持自定义版本号、用户、编译参数
# - 依赖库 (zlib, openssl, pcre2) 源码编译链接
# - 编译目录: /opt/nginx-compile
# - 安装目录: /usr/local/nginx
# ============================================================

NGINX_MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${NGINX_MODULE_DIR}/common.sh"

NGINX_MARKER="/etc/ops-scripts/.nginx_installed"
NGINX_COMPILE_DIR="/opt/nginx-compile"
NGINX_INSTALL_DIR="/usr/local/nginx"
NGINX_CREATE_IDENTITY=false
NGINX_CREATED_USER=false
NGINX_CREATED_GROUP=false

_cleanup_nginx_created_identity() {
    if [ "$NGINX_CREATED_USER" = true ]; then
        userdel "$NGINX_USER" 2>/dev/null || true
        NGINX_CREATED_USER=false
    fi
    if [ "$NGINX_CREATED_GROUP" = true ]; then
        groupdel "$NGINX_GROUP" 2>/dev/null || true
        NGINX_CREATED_GROUP=false
    fi
}

_create_nginx_identity() {
    [ "$NGINX_CREATE_IDENTITY" = true ] || return 0
    if ! getent group "$NGINX_GROUP" &>/dev/null; then
        if ! groupadd -r "$NGINX_GROUP"; then
            log_error "Nginx 用户组创建失败"
            return 1
        fi
        NGINX_CREATED_GROUP=true
        log_info "已创建用户组: ${NGINX_GROUP}"
    fi
    if ! id "$NGINX_USER" &>/dev/null; then
        if ! useradd -r -g "$NGINX_GROUP" -s /usr/sbin/nologin -M "$NGINX_USER"; then
            _cleanup_nginx_created_identity
            log_error "Nginx 用户创建失败"
            return 1
        fi
        NGINX_CREATED_USER=true
        log_info "已创建用户: ${NGINX_USER}"
    fi
}

# ============================================================
# 获取最新版本号
# ============================================================
_get_latest_nginx_version() {
    local ver
    ver=$(curl -s --connect-timeout 10 "https://nginx.org/en/download.html" 2>/dev/null \
        | grep -oP 'nginx-\K[0-9]+\.[0-9]+\.[0-9]+' | sed -n '1p' || true)
    echo "$ver"
}

_get_latest_zlib_version() {
    local ver
    ver=$(curl -s --connect-timeout 10 "https://zlib.net/" 2>/dev/null \
        | grep -oP 'zlib-\K[0-9]+\.[0-9]+(\.[0-9]+)?' | sed -n '1p' || true)
    echo "$ver"
}

_get_latest_openssl_version() {
    local ver
    ver=$(curl -s --connect-timeout 10 "https://api.github.com/repos/openssl/openssl/releases" 2>/dev/null \
        | grep -oP '"tag_name":\s*"openssl-\K[0-9]+\.[0-9]+\.[0-9]+' | sed -n '1p' || true)
    echo "$ver"
}

_get_latest_pcre2_version() {
    local ver
    ver=$(curl -s --connect-timeout 10 "https://api.github.com/repos/PCRE2Project/pcre2/releases/latest" 2>/dev/null \
        | grep -oP '"tag_name":\s*"pcre2-\K[0-9]+\.[0-9]+' | sed -n '1p' || true)
    echo "$ver"
}

_get_latest_geoip2_module_version() {
    local ver
    ver=$(curl -s --connect-timeout 10 "https://api.github.com/repos/leev/ngx_http_geoip2_module/releases/latest" 2>/dev/null \
        | grep -oP '"tag_name":\s*"\K[0-9]+\.[0-9]+' | sed -n '1p' || true)
    echo "$ver"
}

# ============================================================
# 配置 GeoIP2 模块
# ============================================================
_configure_geoip2_module() {
    local latest_geoip2="$1"

    GEOIP2_MODULE_ENABLED=false
    GEOIP2_MODULE_DIR_NAME=""
    echo ""
    if confirm "是否启用 ngx_http_geoip2_module? (基于 MaxMind GeoIP2 的地理位置模块)"; then
        GEOIP2_MODULE_ENABLED=true
        local geoip2_module_version="$latest_geoip2"
        if confirm "是否指定 ngx_http_geoip2_module 版本号? (默认: ${latest_geoip2})"; then
            read_nonempty "请输入 ngx_http_geoip2_module 版本号" geoip2_module_version
        fi
        if [[ ! "$geoip2_module_version" =~ ^[0-9]+\.[0-9]+([.][0-9]+)?$ ]]; then
            log_error "GeoIP2 模块版本号格式无效"
            return 1
        fi
        GEOIP2_MODULE_DIR_NAME="ngx_http_geoip2_module-${geoip2_module_version}"
    fi
}

# ============================================================
# 安装编译依赖
# ============================================================
_install_compile_deps() {
    log_step "安装编译所需依赖..."
    apt install -y \
        build-essential \
        libgd-dev \
        libgeoip-dev \
        libmaxminddb-dev \
        libxml2-dev \
        libxslt1-dev \
        perl \
        curl \
        wget
}

# ============================================================
# 下载并解压源码
# ============================================================
_download_and_extract() {
    local name="$1"
    local url="$2"

    log_step "下载 ${name}..."
    local filename
    filename=$(basename "$url")
    if [[ "$filename" != *.tar.gz && "$filename" != *.tar.xz && "$filename" != *.tgz ]]; then
        log_error "不支持的源码归档格式: ${filename}"
        return 1
    fi

    if [ -f "${NGINX_COMPILE_DIR}/${filename}" ]; then
        log_info "${filename} 已存在，跳过下载"
    else
        if ! wget -q --show-progress -O "${NGINX_COMPILE_DIR}/${filename}" "$url"; then
            log_error "${name} 下载失败: ${url}"
            return 1
        fi
    fi

    local archive_path="${NGINX_COMPILE_DIR}/${filename}"
    local expected_dir="${filename%.tar.gz}"
    expected_dir="${expected_dir%.tar.xz}"
    expected_dir="${expected_dir%.tgz}"
    if [[ ! "$expected_dir" =~ ^[A-Za-z0-9._-]+$ ]]; then
        log_error "归档目录名称无效: ${expected_dir}"
        return 1
    fi
    if tar -tf "$archive_path" | awk '
        /^\// { bad=1 }
        { n=split($0, p, "/"); for (i=1; i<=n; i++) if (p[i] == "..") bad=1 }
        END { exit bad ? 0 : 1 }
    '; then
        log_error "归档包含绝对路径或路径穿越条目，拒绝解压"
        return 1
    fi
    if ! tar -tf "$archive_path" | awk -v expected="$expected_dir/" 'index($0, expected) == 1 { found=1 } END { exit !found }'; then
        log_error "归档不包含预期目录: ${expected_dir}"
        return 1
    fi
    log_step "解压 ${name}..."
    if ! tar -xf "$archive_path" -C "$NGINX_COMPILE_DIR"; then
        log_error "${name} 解压失败"
        return 1
    fi
    log_info "${name} 解压完成"
}

# ============================================================
# 配置用户和用户组
# ============================================================
_setup_nginx_user() {
    echo ""
    log_step "配置 Nginx 运行用户"
    echo ""
    echo "  1) 新建用户和用户组"
    echo "  2) 使用已有用户和用户组"
    select_option "请选择" 2

    if [ "$SELECTED_OPTION" -eq 1 ]; then
        NGINX_CREATE_IDENTITY=true
        read_optional "Nginx 用户名" NGINX_USER "nginx"
        read_optional "Nginx 用户组" NGINX_GROUP "$NGINX_USER"
        if ! validate_username "$NGINX_USER" || ! validate_groupname "$NGINX_GROUP"; then
            log_error "Nginx 用户名或用户组名格式无效"
            return 1
        fi

        if id "$NGINX_USER" &>/dev/null && [ "$(id -gn "$NGINX_USER")" != "$NGINX_GROUP" ]; then
            log_error "已有用户 '${NGINX_USER}' 的主组不是 '${NGINX_GROUP}'"
            return 1
        fi
    else
        # 列出可用用户
        log_info "可用的系统用户:"
        print_thin_separator
        local users_list=()
        local idx=1
        while IFS=: read -r uname _ uid _ _ _ _; do
            if [ "$uid" -lt 1000 ] && [ "$uid" -gt 0 ] && [ "$uname" != "nobody" ]; then
                users_list+=("$uname")
                echo "  ${idx}) ${uname} (UID: ${uid})"
                idx=$((idx + 1))
            fi
        done < /etc/passwd
        # 也显示普通用户
        while IFS=: read -r uname _ uid _ _ _ _; do
            if [ "$uid" -ge 1000 ] && [ "$uname" != "nobody" ]; then
                users_list+=("$uname")
                echo "  ${idx}) ${uname} (UID: ${uid})"
                idx=$((idx + 1))
            fi
        done < /etc/passwd
        print_thin_separator

        if [ ${#users_list[@]} -gt 0 ]; then
            select_option "请选择用户" "${#users_list[@]}"
            NGINX_USER="${users_list[$((SELECTED_OPTION - 1))]}"
        else
            read_nonempty "请输入用户名" NGINX_USER
        fi

        NGINX_GROUP=$(id -gn "$NGINX_USER" 2>/dev/null)
        if [ -z "$NGINX_GROUP" ]; then
            read_nonempty "请输入用户组" NGINX_GROUP
        fi
        log_info "使用用户: ${NGINX_USER}, 用户组: ${NGINX_GROUP}"
    fi
}

# ============================================================
# 配置编译参数
# ============================================================
_setup_compile_args() {
    echo ""
    log_step "配置编译参数"
    echo ""

    # 默认基础编译参数
    local default_args=(
        "--prefix=${NGINX_INSTALL_DIR}"
        "--user=${NGINX_USER}"
        "--group=${NGINX_GROUP}"
        "--with-http_ssl_module"
        "--with-http_v2_module"
        "--with-http_v3_module"
        "--with-http_addition_module"
        "--with-http_realip_module"
        "--with-http_gzip_static_module"
        "--with-http_stub_status_module"
        "--with-http_sub_module"
        "--with-stream"
        "--with-stream_ssl_module"
        "--with-stream_realip_module"
        "--with-pcre-jit"
        "--with-pcre=${NGINX_COMPILE_DIR}/${PCRE2_DIR_NAME}"
        "--with-zlib=${NGINX_COMPILE_DIR}/${ZLIB_DIR_NAME}"
        "--with-openssl=${NGINX_COMPILE_DIR}/${OPENSSL_DIR_NAME}"
    )

    log_info "默认编译参数:"
    print_thin_separator
    for arg in "${default_args[@]}"; do
        echo "  ${arg}"
    done
    print_thin_separator

    echo ""
    echo "可选附加模块:"
    echo "  1) --with-http_image_filter_module"
    echo "  2) --with-http_xslt_module"
    echo "  3) --with-http_geoip_module"
    echo "  4) --with-http_gunzip_module"
    echo "  5) --with-http_auth_request_module"
    echo "  6) --with-http_dav_module"
    echo "  7) --with-http_flv_module"
    echo "  8) --with-http_mp4_module"
    echo "  9) --with-http_secure_link_module"
    echo " 10) --with-http_slice_module"
    echo " 11) --with-stream_realip_module"
    echo " 12) --with-compat"
    echo " 13) --with-threads"
    echo ""

    local extra_args=()
    if confirm "是否添加附加模块?"; then
        echo ""
        log_info "请输入要添加的模块编号（多个用空格分隔，如: 1 4 5）"
        local modules_input
        read_nonempty "模块编号" modules_input

        for num in $modules_input; do
            case "$num" in
                1) extra_args+=("--with-http_image_filter_module") ;;
                2) extra_args+=("--with-http_xslt_module") ;;
                3) extra_args+=("--with-http_geoip_module") ;;
                4) extra_args+=("--with-http_gunzip_module") ;;
                5) extra_args+=("--with-http_auth_request_module") ;;
                6) extra_args+=("--with-http_dav_module") ;;
                7) extra_args+=("--with-http_flv_module") ;;
                8) extra_args+=("--with-http_mp4_module") ;;
                9) extra_args+=("--with-http_secure_link_module") ;;
                10) extra_args+=("--with-http_slice_module") ;;
                11) extra_args+=("--with-stream_realip_module") ;;
                12) extra_args+=("--with-compat") ;;
                13) extra_args+=("--with-threads") ;;
                *) log_warn "忽略未知编号: ${num}" ;;
            esac
        done
    fi

    # 允许用户手动输入其他参数
    if confirm "是否手动输入其他编译参数?"; then
        local custom_args
        read_nonempty "请输入编译参数（多个用空格分隔）" custom_args
        # shellcheck disable=SC2206
        extra_args+=($custom_args)
    fi

    # 合并所有参数
    CONFIGURE_ARGS=("${default_args[@]}" "${extra_args[@]}")

    echo ""
    log_info "最终编译参数:"
    print_thin_separator
    for arg in "${CONFIGURE_ARGS[@]}"; do
        echo "  ${arg}"
    done
    print_thin_separator
}

# ============================================================
# 创建 systemd 服务文件
# ============================================================
_create_systemd_service() {
    log_step "创建 systemd 服务文件..."
    cat > /etc/systemd/system/nginx.service << EOF
[Unit]
Description=Nginx HTTP Server
After=network-online.target remote-fs.target nss-lookup.target
Wants=network-online.target

[Service]
Type=forking
PIDFile=${NGINX_INSTALL_DIR}/logs/nginx.pid
ExecStartPre=${NGINX_INSTALL_DIR}/sbin/nginx -t
ExecStart=${NGINX_INSTALL_DIR}/sbin/nginx
ExecReload=/bin/kill -s HUP \$MAINPID
ExecStop=/bin/kill -s QUIT \$MAINPID
PrivateTmp=true
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    log_info "systemd 服务文件已创建"
}

# ============================================================
# 创建环境变量链接
# ============================================================
_create_symlinks() {
    log_step "创建命令链接..."
    if [ ! -L /usr/local/bin/nginx ]; then
        ln -sf "${NGINX_INSTALL_DIR}/sbin/nginx" /usr/local/bin/nginx
    fi
    log_info "已创建 nginx 命令链接到 /usr/local/bin/nginx"
}

# ============================================================
# 主安装流程
# ============================================================
nginx_install() {
    print_separator
    echo -e "${BOLD}  Nginx 源码编译安装${NC}"
    print_separator
    echo ""

    # 检查是否已安装
    if [ -f "$NGINX_MARKER" ]; then
        log_warn "Nginx 已通过本脚本编译安装，无需再次执行"
        if [ -x "${NGINX_INSTALL_DIR}/sbin/nginx" ]; then
            log_info "当前版本: $(${NGINX_INSTALL_DIR}/sbin/nginx -v 2>&1)"
        fi
        return 0
    fi

    if [ -x "${NGINX_INSTALL_DIR}/sbin/nginx" ]; then
        log_warn "检测到 ${NGINX_INSTALL_DIR} 中已存在 Nginx"
        log_info "版本: $(${NGINX_INSTALL_DIR}/sbin/nginx -v 2>&1)"
        if ! confirm "是否跳过安装并标记为已完成?"; then
            return 0
        fi
        ensure_marker_dir
        touch "$NGINX_MARKER"
        return 0
    fi

    # ---- 版本选择 ----
    log_step "获取最新版本信息..."
    local latest_nginx latest_zlib latest_openssl latest_pcre2

    latest_nginx=$(_get_latest_nginx_version)
    latest_zlib=$(_get_latest_zlib_version)
    latest_openssl=$(_get_latest_openssl_version)
    latest_pcre2=$(_get_latest_pcre2_version)
    local latest_geoip2
    latest_geoip2=$(_get_latest_geoip2_module_version)

    [ -z "$latest_nginx" ] && latest_nginx="1.26.3"
    [ -z "$latest_zlib" ] && latest_zlib="1.3.1"
    [ -z "$latest_openssl" ] && latest_openssl="3.4.1"
    [ -z "$latest_pcre2" ] && latest_pcre2="10.44"
    [ -z "$latest_geoip2" ] && latest_geoip2="3.4"

    echo ""
    log_info "检测到最新版本:"
    echo "  Nginx:                  ${latest_nginx}"
    echo "  zlib:                   ${latest_zlib}"
    echo "  OpenSSL:                ${latest_openssl}"
    echo "  PCRE2:                  ${latest_pcre2}"
    echo "  ngx_http_geoip2_module: ${latest_geoip2}"
    echo ""

    # Nginx 版本
    local nginx_version="$latest_nginx"
    if confirm "是否指定 Nginx 版本号? (默认: ${latest_nginx})"; then
        read_nonempty "请输入 Nginx 版本号 (如: 1.26.3)" nginx_version
    fi

    # zlib 版本
    local zlib_version="$latest_zlib"
    if confirm "是否指定 zlib 版本号? (默认: ${latest_zlib})"; then
        read_nonempty "请输入 zlib 版本号" zlib_version
    fi

    # OpenSSL 版本
    local openssl_version="$latest_openssl"
    if confirm "是否指定 OpenSSL 版本号? (默认: ${latest_openssl})"; then
        read_nonempty "请输入 OpenSSL 版本号" openssl_version
    fi

    # PCRE2 版本
    local pcre2_version="$latest_pcre2"
    if confirm "是否指定 PCRE2 版本号? (默认: ${latest_pcre2})"; then
        read_nonempty "请输入 PCRE2 版本号" pcre2_version
    fi

    # GeoIP2 模块
    _configure_geoip2_module "$latest_geoip2"
    local geoip2_module_version="${GEOIP2_MODULE_DIR_NAME#ngx_http_geoip2_module-}"

    if [[ ! "$nginx_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
       [[ ! "$zlib_version" =~ ^[0-9]+\.[0-9]+([.][0-9]+)?$ ]] ||
       [[ ! "$openssl_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([A-Za-z0-9.-]*)$ ]] ||
       [[ ! "$pcre2_version" =~ ^[0-9]+\.[0-9]+([.][0-9]+)?$ ]]; then
        log_error "一个或多个源码版本号格式无效"
        return 1
    fi

    # 用于 configure 引用的目录名
    ZLIB_DIR_NAME="zlib-${zlib_version}"
    OPENSSL_DIR_NAME="openssl-${openssl_version}"
    PCRE2_DIR_NAME="pcre2-${pcre2_version}"

    # ---- 用户配置 ----
    _setup_nginx_user

    # ---- 编译参数 ----
    _setup_compile_args

    # 如启用 GeoIP2 模块，追加 --add-module 参数
    if [ "$GEOIP2_MODULE_ENABLED" = true ]; then
        CONFIGURE_ARGS+=("--add-module=${NGINX_COMPILE_DIR}/${GEOIP2_MODULE_DIR_NAME}")
        log_info "已追加编译参数: --add-module=${NGINX_COMPILE_DIR}/${GEOIP2_MODULE_DIR_NAME}"
    fi

    # ---- 确认 ----
    echo ""
    print_separator
    log_info "安装摘要:"
    echo "  Nginx 版本:   ${nginx_version}"
    echo "  zlib 版本:    ${zlib_version}"
    echo "  OpenSSL 版本: ${openssl_version}"
    echo "  PCRE2 版本:   ${pcre2_version}"
    if [ "$GEOIP2_MODULE_ENABLED" = true ]; then
        echo "  GeoIP2 模块:  ${geoip2_module_version} (ngx_http_geoip2_module)"
    fi
    echo "  运行用户:     ${NGINX_USER}"
    echo "  运行用户组:   ${NGINX_GROUP}"
    echo "  编译目录:     ${NGINX_COMPILE_DIR}"
    echo "  安装目录:     ${NGINX_INSTALL_DIR}"
    print_separator
    echo ""

    if ! confirm "确认开始编译安装 Nginx?"; then
        log_info "已取消安装"
        return 0
    fi

    if ! _create_nginx_identity; then
        return 1
    fi

    # ---- 开始安装 ----
    # 安装编译依赖
    if ! _install_compile_deps; then
        _cleanup_nginx_created_identity
        return 1
    fi

    # 创建编译目录
    mkdir -p "$NGINX_COMPILE_DIR"
    cd "$NGINX_COMPILE_DIR" || {
        _cleanup_nginx_created_identity
        return 1
    }

    # 下载源码
    if ! _download_and_extract "Nginx ${nginx_version}" \
        "https://nginx.org/download/nginx-${nginx_version}.tar.gz"; then
        _cleanup_nginx_created_identity
        return 1
    fi

    if ! _download_and_extract "zlib ${zlib_version}" \
        "https://zlib.net/zlib-${zlib_version}.tar.gz"; then
        _cleanup_nginx_created_identity
        return 1
    fi

    if ! _download_and_extract "OpenSSL ${openssl_version}" \
        "https://github.com/openssl/openssl/releases/download/openssl-${openssl_version}/openssl-${openssl_version}.tar.gz"; then
        _cleanup_nginx_created_identity
        return 1
    fi

    if ! _download_and_extract "PCRE2 ${pcre2_version}" \
        "https://github.com/PCRE2Project/pcre2/releases/download/pcre2-${pcre2_version}/pcre2-${pcre2_version}.tar.gz"; then
        _cleanup_nginx_created_identity
        return 1
    fi

    if [ "$GEOIP2_MODULE_ENABLED" = true ]; then
        if ! _download_and_extract "ngx_http_geoip2_module ${geoip2_module_version}" \
            "https://github.com/leev/ngx_http_geoip2_module/archive/refs/tags/${geoip2_module_version}.tar.gz"; then
            _cleanup_nginx_created_identity
            return 1
        fi
    fi

    # 编译 Nginx
    log_step "开始编译 Nginx..."
    cd "${NGINX_COMPILE_DIR}/nginx-${nginx_version}" || {
        log_error "无法进入 Nginx 源码目录"
        _cleanup_nginx_created_identity
        return 1
    }

    log_step "执行 configure..."
    if ! ./configure "${CONFIGURE_ARGS[@]}"; then
        log_error "configure 失败，请检查错误信息"
        _cleanup_nginx_created_identity
        return 1
    fi

    local cpu_cores
    cpu_cores=$(nproc 2>/dev/null || echo 2)
    log_step "执行 make (使用 ${cpu_cores} 核编译)..."
    if ! make -j"$cpu_cores"; then
        log_error "make 失败，请检查错误信息"
        _cleanup_nginx_created_identity
        return 1
    fi

    log_step "执行 make install..."
    if ! make install; then
        log_error "make install 失败"
        _cleanup_nginx_created_identity
        return 1
    fi

    log_info "Nginx 编译安装完成"

    # 创建日志目录
    mkdir -p "${NGINX_INSTALL_DIR}/logs"

    # 创建 systemd 服务
    _create_systemd_service

    # 创建命令链接
    _create_symlinks

    # 启用并启动
    systemctl enable nginx
    systemctl start nginx

    if systemctl is-active --quiet nginx; then
        log_info "Nginx 服务已启动"
    else
        log_warn "Nginx 服务启动可能有问题，请检查: systemctl status nginx"
    fi

    # 标记安装完成
    ensure_marker_dir
    touch "$NGINX_MARKER"

    echo ""
    log_info "Nginx 安装完成"
    log_info "安装目录: ${NGINX_INSTALL_DIR}"
    log_info "配置文件: ${NGINX_INSTALL_DIR}/conf/nginx.conf"
    log_info "版本信息: $(${NGINX_INSTALL_DIR}/sbin/nginx -v 2>&1)"
}

# ============================================================
# Nginx 状态查看
# ============================================================
nginx_status() {
    print_separator
    echo -e "${BOLD}  Nginx 状态${NC}"
    print_separator
    echo ""

    if [ ! -x "${NGINX_INSTALL_DIR}/sbin/nginx" ] && ! command -v nginx &>/dev/null; then
        log_warn "Nginx 未安装"
        return 0
    fi

    local nginx_bin="${NGINX_INSTALL_DIR}/sbin/nginx"
    [ ! -x "$nginx_bin" ] && nginx_bin="nginx"

    echo -e "  ${BOLD}版本:${NC}    $($nginx_bin -v 2>&1)"
    echo ""

    log_step "服务状态:"
    systemctl status nginx --no-pager 2>/dev/null | sed -n '1,15p' || true
    echo ""

    log_step "编译参数:"
    $nginx_bin -V 2>&1
    echo ""

    log_step "验证配置:"
    $nginx_bin -t 2>&1
}

# ============================================================
# Nginx 服务管理
# ============================================================
nginx_service() {
    print_separator
    echo -e "${BOLD}  Nginx 服务管理${NC}"
    print_separator
    echo ""

    local nginx_bin="${NGINX_INSTALL_DIR}/sbin/nginx"
    if [ ! -x "$nginx_bin" ] && ! command -v nginx &>/dev/null; then
        log_warn "Nginx 未安装"
        return 0
    fi

    echo "  1) 启动 Nginx"
    echo "  2) 停止 Nginx"
    echo "  3) 重启 Nginx"
    echo "  4) 重载配置"
    echo "  5) 验证配置"
    echo "  6) 查看日志"
    echo "  0) 返回"
    echo ""
    select_option "请选择" 6 0

    case "$SELECTED_OPTION" in
        1) systemctl start nginx && log_info "Nginx 已启动" ;;
        2) systemctl stop nginx && log_info "Nginx 已停止" ;;
        3) systemctl restart nginx && log_info "Nginx 已重启" ;;
        4) systemctl reload nginx && log_info "Nginx 配置已重载" ;;
        5) $nginx_bin -t 2>&1 ;;
        6)
            echo "  1) access.log 最近 50 行"
            echo "  2) error.log 最近 50 行"
            echo "  3) systemd 日志"
            select_option "请选择" 3
            case "$SELECTED_OPTION" in
                1) tail -n 50 "${NGINX_INSTALL_DIR}/logs/access.log" 2>/dev/null || log_warn "日志文件不存在" ;;
                2) tail -n 50 "${NGINX_INSTALL_DIR}/logs/error.log" 2>/dev/null || log_warn "日志文件不存在" ;;
                3) journalctl -u nginx -n 50 --no-pager ;;
            esac
            ;;
        0) return 0 ;;
    esac
}

# ============================================================
# 入口函数
# ============================================================
run_nginx() {
    while true; do
        print_separator
        echo -e "${BOLD}  Nginx 管理${NC}"
        print_separator
        echo ""
        echo "  1) 编译安装 Nginx"
        echo "  2) 查看状态"
        echo "  3) 服务管理"
        echo "  0) 返回上级菜单"
        echo ""
        select_option "请选择" 3 0

        case "$SELECTED_OPTION" in
            1) nginx_install ;;
            2) nginx_status ;;
            3) nginx_service ;;
            0) return 0 ;;
        esac
        press_any_key
    done
}
