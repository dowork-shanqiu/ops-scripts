#!/usr/bin/env bash
# ============================================================
# Sudoer 管理模块
# - 管理用户免密码 sudo 权限
# - 配置文件放于 /etc/sudoers.d 目录
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

SUDOERS_DIR="/etc/sudoers.d"

# ============================================================
# 检查 sudo 是否已安装
# ============================================================
_check_sudo_installed() {
    if ! command -v sudo &>/dev/null; then
        log_error "sudo 未安装"
        if confirm "是否现在安装 sudo?"; then
            apt install -y sudo
            if ! command -v sudo &>/dev/null; then
                log_error "sudo 安装失败"
                return 1
            fi
            log_info "sudo 安装成功"
        else
            return 1
        fi
    fi
    return 0
}

# ============================================================
# 列出当前 sudoer 配置
# ============================================================
sudoer_list() {
    print_separator
    echo -e "${BOLD}  当前 Sudoer 配置${NC}"
    print_separator
    echo ""

    if ! _check_sudo_installed; then
        return 1
    fi

    # 列出 /etc/sudoers.d 目录中的配置文件
    if [ ! -d "$SUDOERS_DIR" ]; then
        log_warn "目录 ${SUDOERS_DIR} 不存在"
        return 0
    fi

    local files_found=false
    for f in "${SUDOERS_DIR}"/*; do
        [ -f "$f" ] || continue
        local fname
        fname=$(basename "$f")
        # 跳过带 ~ 后缀的备份文件和 README
        [[ "$fname" == *~ ]] && continue
        [[ "$fname" == "README" ]] && continue

        files_found=true
        echo ""
        log_info "配置文件: ${fname}"
        print_thin_separator
        cat "$f"
        print_thin_separator
    done

    if [ "$files_found" = false ]; then
        log_info "当前没有自定义 sudoer 配置"
    fi

    echo ""
    log_info "主配置文件 (/etc/sudoers) 中的相关配置:"
    print_thin_separator
    grep -v '^#' /etc/sudoers 2>/dev/null | grep -v '^$' | grep -v '^Defaults'
    print_thin_separator
}

# ============================================================
# 添加 sudoer 规则
# ============================================================
sudoer_add() {
    print_separator
    echo -e "${BOLD}  添加 Sudoer 规则${NC}"
    print_separator
    echo ""

    if ! _check_sudo_installed; then
        return 1
    fi

    # 选择用户
    echo "请选择要配置的用户:"
    echo ""
    local users_list=()
    local idx=1
    while IFS=: read -r uname _ uid _ _ _ _; do
        if [ "$uid" -ge 1000 ] && [ "$uname" != "nobody" ]; then
            users_list+=("$uname")
            echo "  ${idx}) ${uname} (UID: ${uid})"
            idx=$((idx + 1))
        fi
    done < /etc/passwd

    if [ ${#users_list[@]} -eq 0 ]; then
        log_warn "没有普通用户可配置"
        return 0
    fi

    echo "  ${idx}) 手动输入用户名"
    local max_opt=$idx

    echo ""
    select_option "请选择" "$max_opt"

    local target_user
    if [ "$SELECTED_OPTION" -eq "$max_opt" ]; then
        read_nonempty "请输入用户名" target_user
        if ! id "$target_user" &>/dev/null; then
            log_error "用户 '${target_user}' 不存在"
            return 1
        fi
    else
        target_user="${users_list[$((SELECTED_OPTION - 1))]}"
    fi
    log_info "目标用户: ${target_user}"

    echo ""
    echo "请选择授权方式:"
    echo "  1) 允许执行所有命令 (免密码)"
    echo "  2) 允许执行指定命令 (免密码)"
    echo "  3) 允许执行所有命令 (需密码)"
    echo "  4) 允许执行指定命令 (需密码)"
    echo ""
    select_option "请选择" 4

    local rule=""
    local nopasswd=""

    case "$SELECTED_OPTION" in
        1)
            nopasswd="NOPASSWD: "
            rule="${target_user} ALL=(ALL) ${nopasswd}ALL"
            ;;
        2)
            nopasswd="NOPASSWD: "
            echo ""
            log_info "请输入允许执行的命令（绝对路径，多个用逗号分隔）"
            log_info "示例: /usr/bin/systemctl restart nginx, /usr/bin/docker"
            echo ""

            _show_common_commands

            local commands
            read_nonempty "命令列表" commands
            rule="${target_user} ALL=(ALL) ${nopasswd}${commands}"
            ;;
        3)
            rule="${target_user} ALL=(ALL) ALL"
            ;;
        4)
            echo ""
            log_info "请输入允许执行的命令（绝对路径，多个用逗号分隔）"
            log_info "示例: /usr/bin/systemctl restart nginx, /usr/bin/docker"
            echo ""

            _show_common_commands

            local commands
            read_nonempty "命令列表" commands
            rule="${target_user} ALL=(ALL) ${commands}"
            ;;
    esac

    echo ""
    log_info "即将创建的 sudoer 规则:"
    print_thin_separator
    echo "  ${rule}"
    print_thin_separator

    if ! confirm "确认添加此规则?"; then
        log_info "已取消"
        return 0
    fi

    # 生成配置文件名
    local conf_file="${SUDOERS_DIR}/ops-${target_user}"

    # 检查是否已存在
    if [ -f "$conf_file" ]; then
        log_warn "用户 '${target_user}' 已有配置文件: ${conf_file}"
        echo ""
        log_info "现有配置:"
        cat "$conf_file"
        echo ""
        echo "  1) 追加规则"
        echo "  2) 替换规则"
        echo "  3) 取消"
        select_option "请选择" 3

        case "$SELECTED_OPTION" in
            1)
                echo "$rule" >> "$conf_file"
                ;;
            2)
                echo "$rule" > "$conf_file"
                ;;
            3)
                log_info "已取消"
                return 0
                ;;
        esac
    else
        echo "$rule" > "$conf_file"
    fi

    # 设置正确的文件权限 (必须为 0440)
    chmod 0440 "$conf_file"
    chown root:root "$conf_file"

    # 验证配置
    if visudo -cf "$conf_file" &>/dev/null; then
        log_info "规则已添加并验证通过"
        log_info "配置文件: ${conf_file}"
    else
        log_error "配置验证失败，正在回滚..."
        rm -f "$conf_file"
        log_error "请检查规则格式是否正确"
        return 1
    fi
}

# ---------- 显示常用命令列表 ----------
_show_common_commands() {
    log_info "常用命令参考:"
    echo "  - /usr/bin/systemctl            (系统服务管理)"
    echo "  - /usr/bin/journalctl           (日志查看)"
    echo "  - /usr/bin/docker               (Docker)"
    echo "  - /usr/bin/docker-compose       (Docker Compose)"
    echo "  - /usr/sbin/nginx               (Nginx - 系统安装)"
    echo "  - /usr/local/nginx/sbin/nginx   (Nginx - 编译安装)"
    echo "  - /usr/bin/caddy                (Caddy)"
    echo "  - /usr/sbin/nft                 (nftables)"
    echo "  - /usr/bin/apt                  (APT 包管理)"
    echo "  - /usr/bin/certbot              (Let's Encrypt)"
    echo ""
}

# ============================================================
# 删除 sudoer 规则
# ============================================================
sudoer_delete() {
    print_separator
    echo -e "${BOLD}  删除 Sudoer 规则${NC}"
    print_separator
    echo ""

    if ! _check_sudo_installed; then
        return 1
    fi

    # 列出配置文件
    local files_list=()
    local idx=1

    for f in "${SUDOERS_DIR}"/ops-*; do
        [ -f "$f" ] || continue
        local fname
        fname=$(basename "$f")
        files_list+=("$f")
        echo "  ${idx}) ${fname}"
        print_thin_separator
        sed 's/^/     /' "$f"
        print_thin_separator
        idx=$((idx + 1))
    done

    if [ ${#files_list[@]} -eq 0 ]; then
        log_info "没有通过本脚本创建的 sudoer 配置"
        return 0
    fi

    echo "  0) 取消"
    echo ""
    select_option "请选择要删除的配置" "${#files_list[@]}" 0

    if [ "$SELECTED_OPTION" -eq 0 ]; then
        log_info "已取消"
        return 0
    fi

    local del_file="${files_list[$((SELECTED_OPTION - 1))]}"
    local del_name
    del_name=$(basename "$del_file")

    echo ""
    log_warn "即将删除配置文件: ${del_name}"
    log_info "内容:"
    cat "$del_file"

    if confirm "确认删除?"; then
        rm -f "$del_file"
        log_info "配置文件已删除: ${del_name}"
    else
        log_info "已取消"
    fi
}

# ============================================================
# 修改 sudoer 规则
# ============================================================
sudoer_edit() {
    print_separator
    echo -e "${BOLD}  修改 Sudoer 规则${NC}"
    print_separator
    echo ""

    if ! _check_sudo_installed; then
        return 1
    fi

    # 列出配置文件
    local files_list=()
    local idx=1

    for f in "${SUDOERS_DIR}"/ops-*; do
        [ -f "$f" ] || continue
        local fname
        fname=$(basename "$f")
        files_list+=("$f")
        echo "  ${idx}) ${fname}"
        print_thin_separator
        sed 's/^/     /' "$f"
        print_thin_separator
        idx=$((idx + 1))
    done

    if [ ${#files_list[@]} -eq 0 ]; then
        log_info "没有通过本脚本创建的 sudoer 配置"
        return 0
    fi

    echo "  0) 取消"
    echo ""
    select_option "请选择要修改的配置" "${#files_list[@]}" 0

    if [ "$SELECTED_OPTION" -eq 0 ]; then
        return 0
    fi

    local edit_file="${files_list[$((SELECTED_OPTION - 1))]}"
    local edit_name
    edit_name=$(basename "$edit_file")

    echo ""
    log_info "当前内容 (${edit_name}):"
    print_thin_separator
    cat -n "$edit_file"
    print_thin_separator

    echo ""
    echo "请选择操作:"
    echo "  1) 追加新规则"
    echo "  2) 删除指定行"
    echo "  3) 使用编辑器编辑"
    echo "  0) 返回"
    select_option "请选择" 3 0

    case "$SELECTED_OPTION" in
        1)
            local new_rule
            read_nonempty "请输入新的 sudoer 规则" new_rule
            echo "$new_rule" >> "$edit_file"
            chmod 0440 "$edit_file"
            if visudo -cf "$edit_file" &>/dev/null; then
                log_info "规则已追加并验证通过"
            else
                log_error "配置验证失败，正在移除新规则..."
                # 移除最后一行
                sed -i '$ d' "$edit_file"
                chmod 0440 "$edit_file"
                log_error "请检查规则格式"
            fi
            ;;
        2)
            local line_num
            read_nonempty "请输入要删除的行号" line_num
            if [[ "$line_num" =~ ^[0-9]+$ ]]; then
                # 备份
                cp "$edit_file" "${edit_file}.bak"
                sed -i "${line_num}d" "$edit_file"
                chmod 0440 "$edit_file"
                if visudo -cf "$edit_file" &>/dev/null; then
                    log_info "行已删除，配置验证通过"
                    rm -f "${edit_file}.bak"
                else
                    log_error "配置验证失败，正在回滚..."
                    mv "${edit_file}.bak" "$edit_file"
                    chmod 0440 "$edit_file"
                fi
            else
                log_error "无效的行号"
            fi
            ;;
        3)
            # 使用 visudo 安全编辑
            log_info "使用 visudo 安全编辑 (将自动验证语法)..."
            EDITOR="${EDITOR:-vim}" visudo -f "$edit_file"
            ;;
        0) return 0 ;;
    esac
}

# ============================================================
# 入口函数
# ============================================================
run_sudoer_mgmt() {
    while true; do
        print_separator
        echo -e "${BOLD}  Sudoer 管理${NC}"
        print_separator
        echo ""
        echo "  1) 查看当前配置"
        echo "  2) 添加 Sudoer 规则"
        echo "  3) 删除 Sudoer 规则"
        echo "  4) 修改 Sudoer 规则"
        echo "  0) 返回上级菜单"
        echo ""
        select_option "请选择" 4 0

        case "$SELECTED_OPTION" in
            1) sudoer_list ;;
            2) sudoer_add ;;
            3) sudoer_delete ;;
            4) sudoer_edit ;;
            0) return 0 ;;
        esac
        press_any_key
    done
}
