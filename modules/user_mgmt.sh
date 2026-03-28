#!/usr/bin/env bash
# ============================================================
# 用户管理模块
# - 添加用户
# - 删除用户
# - 修改用户
# - 查看用户列表
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# ============================================================
# 添加用户
# ============================================================
user_add() {
    print_separator
    echo -e "${BOLD}  添加用户${NC}"
    print_separator
    echo ""

    # 输入用户名
    local username
    read_nonempty "请输入用户名" username

    # 检查用户是否已存在
    if id "$username" &>/dev/null; then
        log_error "用户 '${username}' 已存在"
        return 1
    fi

    # --- 用户组选择 ---
    echo ""
    log_step "选择用户主组"
    echo "  1) 创建同名用户组 (${username})"
    echo "  2) 选择已有用户组"
    echo "  3) 不指定（使用系统默认）"
    select_option "请选择" 3

    local group_opt=""
    case "$SELECTED_OPTION" in
        1)
            if ! getent group "$username" &>/dev/null; then
                groupadd "$username"
                log_info "已创建用户组: ${username}"
            fi
            group_opt="-g ${username}"
            ;;
        2)
            echo ""
            log_info "当前可用用户组:"
            print_thin_separator
            local groups_list=()
            local idx=1
            while IFS=: read -r gname _ gid _; do
                if [ "$gid" -ge 1000 ] || [ "$gid" -eq 0 ]; then
                    groups_list+=("$gname")
                    echo "  ${idx}) ${gname} (GID: ${gid})"
                    idx=$((idx + 1))
                fi
            done < /etc/group
            print_thin_separator
            if [ ${#groups_list[@]} -gt 0 ]; then
                select_option "请选择用户组" "${#groups_list[@]}"
                local sel_group="${groups_list[$((SELECTED_OPTION - 1))]}"
                group_opt="-g ${sel_group}"
                log_info "已选择用户组: ${sel_group}"
            fi
            ;;
        3)
            log_info "使用系统默认用户组"
            ;;
    esac

    # --- 附加用户组 ---
    echo ""
    local supp_groups=""
    if confirm "是否添加附加用户组?"; then
        echo ""
        log_info "当前可用用户组:"
        print_thin_separator
        cut -d: -f1 /etc/group | sort | while read -r g; do
            echo "  - $g"
        done
        print_thin_separator
        read_nonempty "请输入附加用户组 (多个用逗号分隔)" supp_groups
    fi

    # --- 工作目录 ---
    echo ""
    local home_opt=""
    if confirm "是否为用户创建工作目录 (home)?"; then
        local home_dir
        read_optional "工作目录路径" home_dir "/home/${username}"
        home_opt="-m -d ${home_dir}"
        log_info "工作目录: ${home_dir}"
    else
        home_opt="-M"
        log_info "不创建工作目录"
    fi

    # --- 默认 Shell ---
    echo ""
    log_step "选择默认 Shell"
    local shells_list=()
    local idx=1
    while IFS= read -r sh; do
        shells_list+=("$sh")
        if [ "$sh" = "/bin/bash" ]; then
            echo "  ${idx}) ${sh} (推荐)"
        else
            echo "  ${idx}) ${sh}"
        fi
        idx=$((idx + 1))
    done < <(list_available_shells)

    local shell_opt="/bin/bash"
    if [ ${#shells_list[@]} -gt 0 ]; then
        select_option "请选择" "${#shells_list[@]}"
        shell_opt="${shells_list[$((SELECTED_OPTION - 1))]}"
    fi
    log_info "默认 Shell: ${shell_opt}"

    # --- 用户描述 ---
    echo ""
    local comment=""
    read_optional "用户描述/备注" comment ""

    # --- 账号过期时间 ---
    echo ""
    local expire_opt=""
    if confirm "是否设置账号过期时间?"; then
        local expire_date
        read_nonempty "请输入过期日期 (格式: YYYY-MM-DD)" expire_date
        expire_opt="-e ${expire_date}"
    fi

    # --- 是否允许登录 ---
    echo ""
    local allow_login=true
    if confirm "是否允许该用户通过 SSH 登录?"; then
        allow_login=true
    else
        allow_login=false
        shell_opt="/usr/sbin/nologin"
        log_info "已禁止该用户登录（Shell 设为 nologin）"
    fi

    # --- 构建并执行命令 ---
    local cmd_args=()
    if [ -n "$group_opt" ]; then
        # group_opt is like "-g groupname"
        cmd_args+=($group_opt)
    fi
    if [ -n "$supp_groups" ]; then
        cmd_args+=("-G" "$supp_groups")
    fi
    if [ "$home_opt" = "-M" ]; then
        cmd_args+=("-M")
    else
        # home_opt is like "-m -d /home/user"
        cmd_args+=($home_opt)
    fi
    cmd_args+=("-s" "$shell_opt")
    if [ -n "$comment" ]; then
        cmd_args+=("-c" "$comment")
    fi
    if [ -n "$expire_opt" ]; then
        # expire_opt is like "-e 2025-12-31"
        cmd_args+=($expire_opt)
    fi
    cmd_args+=("$username")

    echo ""
    print_thin_separator
    log_info "即将执行: useradd ${cmd_args[*]}"
    print_thin_separator

    if confirm "确认创建用户?"; then
        if useradd "${cmd_args[@]}"; then
            log_info "用户 '${username}' 创建成功"

            # 设置密码（可选）
            if [ "$allow_login" = true ]; then
                if confirm "是否为用户设置密码? (即使禁用密码登录，某些操作如 sudo 仍可能需要)"; then
                    passwd "$username"
                fi

                # 配置 SSH 公钥
                echo ""
                log_step "配置 SSH 公钥"
                log_info "由于已禁用密码登录，用户需要 SSH 公钥才能登录"

                local user_home
                user_home=$(getent passwd "$username" | cut -d: -f6)

                if [ -d "$user_home" ]; then
                    mkdir -p "${user_home}/.ssh"

                    local pubkey
                    while true; do
                        read_nonempty "请输入该用户的 SSH 公钥" pubkey
                        if validate_ssh_pubkey "$pubkey"; then
                            break
                        fi
                        log_warn "公钥格式不正确，请输入有效的 SSH 公钥"
                    done

                    echo "$pubkey" >> "${user_home}/.ssh/authorized_keys"
                    chmod 700 "${user_home}/.ssh"
                    chmod 600 "${user_home}/.ssh/authorized_keys"
                    chown -R "${username}:$(id -gn "$username")" "${user_home}/.ssh"

                    log_info "SSH 公钥已配置"
                else
                    log_warn "用户没有工作目录，跳过 SSH 公钥配置"
                    log_warn "如果需要配置，请先创建工作目录后手动配置"
                fi
            fi

            # 显示用户信息
            echo ""
            log_info "用户信息:"
            print_thin_separator
            id "$username"
            grep "^${username}:" /etc/passwd
            print_thin_separator
        else
            log_error "用户创建失败"
        fi
    else
        log_info "已取消创建用户"
    fi
}

# ============================================================
# 删除用户
# ============================================================
user_delete() {
    print_separator
    echo -e "${BOLD}  删除用户${NC}"
    print_separator
    echo ""

    # 列出可删除的用户 (UID >= 1000，排除 nobody)
    log_info "当前系统用户列表 (普通用户):"
    print_thin_separator
    local users_list=()
    local idx=1
    while IFS=: read -r uname _ uid _ comment home shell; do
        if [ "$uid" -ge 1000 ] && [ "$uname" != "nobody" ] && [ "$uname" != "nogroup" ]; then
            users_list+=("$uname")
            printf "  %d) %-15s UID:%-6s Home:%-20s Shell:%s\n" "$idx" "$uname" "$uid" "$home" "$shell"
            idx=$((idx + 1))
        fi
    done < /etc/passwd
    print_thin_separator

    if [ ${#users_list[@]} -eq 0 ]; then
        log_warn "没有可删除的用户"
        return 0
    fi

    echo "  0) 取消"
    echo ""
    select_option "请选择要删除的用户" "${#users_list[@]}" 0

    if [ "$SELECTED_OPTION" -eq 0 ]; then
        log_info "已取消"
        return 0
    fi

    local del_user="${users_list[$((SELECTED_OPTION - 1))]}"
    echo ""
    log_warn "即将删除用户: ${del_user}"

    # 检查用户是否有运行中的进程
    local procs
    procs=$(ps -u "$del_user" -o pid,comm 2>/dev/null | tail -n +2)
    if [ -n "$procs" ]; then
        log_warn "该用户有以下运行中的进程:"
        echo "$procs"
        if confirm "是否终止这些进程?"; then
            pkill -u "$del_user"
            sleep 1
            pkill -9 -u "$del_user" 2>/dev/null
            log_info "已终止所有进程"
        else
            log_warn "用户仍有运行中的进程，删除可能失败"
        fi
    fi

    # 是否删除工作目录
    local del_home=""
    if confirm "是否同时删除用户的工作目录和邮件?"; then
        del_home="-r"
    fi

    # 是否强制删除
    local force_opt=""
    if confirm "是否强制删除 (即使用户仍在登录)?"; then
        force_opt="-f"
    fi

    if confirm "最终确认: 删除用户 '${del_user}'?"; then
        userdel $force_opt $del_home "$del_user"
        if [ $? -eq 0 ]; then
            log_info "用户 '${del_user}' 已删除"
        else
            log_error "删除用户失败"
        fi
    else
        log_info "已取消删除"
    fi
}

# ============================================================
# 修改用户
# ============================================================
user_modify() {
    print_separator
    echo -e "${BOLD}  修改用户${NC}"
    print_separator
    echo ""

    # 列出用户
    log_info "当前系统用户列表:"
    print_thin_separator
    local users_list=()
    local idx=1
    while IFS=: read -r uname _ uid _ _ _ _; do
        if [ "$uid" -ge 1000 ] && [ "$uname" != "nobody" ]; then
            users_list+=("$uname")
            echo "  ${idx}) ${uname} (UID: ${uid})"
            idx=$((idx + 1))
        fi
    done < /etc/passwd
    print_thin_separator

    if [ ${#users_list[@]} -eq 0 ]; then
        log_warn "没有可修改的用户"
        return 0
    fi

    echo "  0) 取消"
    echo ""
    select_option "请选择要修改的用户" "${#users_list[@]}" 0

    if [ "$SELECTED_OPTION" -eq 0 ]; then
        return 0
    fi

    local mod_user="${users_list[$((SELECTED_OPTION - 1))]}"

    echo ""
    log_info "用户 '${mod_user}' 当前信息:"
    id "$mod_user"
    grep "^${mod_user}:" /etc/passwd
    echo ""

    echo "请选择修改项:"
    echo "  1) 修改默认 Shell"
    echo "  2) 修改用户组"
    echo "  3) 修改用户描述"
    echo "  4) 锁定/解锁用户"
    echo "  5) 修改账号过期时间"
    echo "  6) 重置密码"
    echo "  7) 管理 SSH 公钥"
    echo "  0) 返回"
    echo ""
    select_option "请选择" 7 0

    case "$SELECTED_OPTION" in
        1)
            log_step "修改默认 Shell"
            local shells_list=()
            local idx=1
            while IFS= read -r sh; do
                shells_list+=("$sh")
                echo "  ${idx}) ${sh}"
                idx=$((idx + 1))
            done < <(list_available_shells)
            select_option "请选择新 Shell" "${#shells_list[@]}"
            local new_shell="${shells_list[$((SELECTED_OPTION - 1))]}"
            usermod -s "$new_shell" "$mod_user"
            log_info "Shell 已修改为: ${new_shell}"
            ;;
        2)
            log_step "修改用户组"
            echo "  1) 修改主用户组"
            echo "  2) 添加附加用户组"
            echo "  3) 从附加用户组中移除"
            select_option "请选择" 3
            case "$SELECTED_OPTION" in
                1)
                    local grp
                    read_nonempty "请输入新的主用户组名" grp
                    usermod -g "$grp" "$mod_user"
                    log_info "主用户组已修改"
                    ;;
                2)
                    local grp
                    read_nonempty "请输入要添加的附加用户组 (多个用逗号分隔)" grp
                    usermod -aG "$grp" "$mod_user"
                    log_info "附加用户组已添加"
                    ;;
                3)
                    local grp
                    read_nonempty "请输入要移除的附加用户组" grp
                    gpasswd -d "$mod_user" "$grp"
                    log_info "已从用户组移除"
                    ;;
            esac
            ;;
        3)
            local comment
            read_nonempty "请输入新的用户描述" comment
            usermod -c "$comment" "$mod_user"
            log_info "用户描述已修改"
            ;;
        4)
            local locked
            locked=$(passwd -S "$mod_user" 2>/dev/null | awk '{print $2}')
            if [ "$locked" = "L" ]; then
                log_info "用户当前状态: 已锁定"
                if confirm "是否解锁用户?"; then
                    usermod -U "$mod_user"
                    log_info "用户已解锁"
                fi
            else
                log_info "用户当前状态: 正常"
                if confirm "是否锁定用户?"; then
                    usermod -L "$mod_user"
                    log_info "用户已锁定"
                fi
            fi
            ;;
        5)
            local date
            read_nonempty "请输入新的过期日期 (YYYY-MM-DD) 或输入 -1 取消过期" date
            if [ "$date" = "-1" ]; then
                usermod -e "" "$mod_user"
                log_info "已取消账号过期时间"
            else
                usermod -e "$date" "$mod_user"
                log_info "账号过期时间已设置为: ${date}"
            fi
            ;;
        6)
            passwd "$mod_user"
            ;;
        7)
            _manage_user_ssh_keys "$mod_user"
            ;;
        0) return 0 ;;
    esac
}

# ---------- 管理用户 SSH 公钥 ----------
_manage_user_ssh_keys() {
    local username="$1"
    local user_home
    user_home=$(getent passwd "$username" | cut -d: -f6)

    if [ ! -d "$user_home" ]; then
        log_error "用户没有工作目录: ${user_home}"
        return 1
    fi

    local auth_keys="${user_home}/.ssh/authorized_keys"

    echo ""
    echo "  1) 查看当前公钥"
    echo "  2) 添加公钥"
    echo "  3) 删除公钥"
    echo "  4) 替换所有公钥"
    select_option "请选择" 4

    case "$SELECTED_OPTION" in
        1)
            if [ -f "$auth_keys" ]; then
                log_info "当前公钥:"
                print_thin_separator
                cat -n "$auth_keys"
                print_thin_separator
            else
                log_warn "没有配置公钥"
            fi
            ;;
        2)
            local pubkey
            while true; do
                read_nonempty "请输入 SSH 公钥" pubkey
                if validate_ssh_pubkey "$pubkey"; then
                    break
                fi
                log_warn "公钥格式不正确"
            done
            mkdir -p "${user_home}/.ssh"
            echo "$pubkey" >> "$auth_keys"
            chmod 700 "${user_home}/.ssh"
            chmod 600 "$auth_keys"
            chown -R "${username}:$(id -gn "$username")" "${user_home}/.ssh"
            log_info "公钥已添加"
            ;;
        3)
            if [ ! -f "$auth_keys" ]; then
                log_warn "没有配置公钥"
                return
            fi
            cat -n "$auth_keys"
            local line_num
            read_nonempty "请输入要删除的公钥行号" line_num
            sed -i "${line_num}d" "$auth_keys"
            log_info "公钥已删除"
            ;;
        4)
            local pubkey
            while true; do
                read_nonempty "请输入新的 SSH 公钥" pubkey
                if validate_ssh_pubkey "$pubkey"; then
                    break
                fi
                log_warn "公钥格式不正确"
            done
            mkdir -p "${user_home}/.ssh"
            echo "$pubkey" > "$auth_keys"
            chmod 700 "${user_home}/.ssh"
            chmod 600 "$auth_keys"
            chown -R "${username}:$(id -gn "$username")" "${user_home}/.ssh"
            log_info "公钥已替换"
            ;;
    esac
}

# ============================================================
# 查看用户列表
# ============================================================
user_list() {
    print_separator
    echo -e "${BOLD}  用户列表${NC}"
    print_separator
    echo ""

    echo "请选择查看范围:"
    echo "  1) 仅普通用户 (UID >= 1000)"
    echo "  2) 所有用户"
    select_option "请选择" 2

    echo ""
    printf "  ${BOLD}%-15s %-8s %-8s %-25s %-20s${NC}\n" "用户名" "UID" "GID" "工作目录" "Shell"
    print_thin_separator

    while IFS=: read -r uname _ uid gid _ home shell; do
        if [ "$SELECTED_OPTION" -eq 1 ]; then
            if [ "$uid" -ge 1000 ] && [ "$uname" != "nobody" ]; then
                printf "  %-15s %-8s %-8s %-25s %-20s\n" "$uname" "$uid" "$gid" "$home" "$shell"
            fi
        else
            printf "  %-15s %-8s %-8s %-25s %-20s\n" "$uname" "$uid" "$gid" "$home" "$shell"
        fi
    done < /etc/passwd

    print_thin_separator
}

# ============================================================
# 入口函数
# ============================================================
run_user_mgmt() {
    while true; do
        print_separator
        echo -e "${BOLD}  用户管理${NC}"
        print_separator
        echo ""
        echo "  1) 添加用户"
        echo "  2) 删除用户"
        echo "  3) 修改用户"
        echo "  4) 查看用户列表"
        echo "  0) 返回上级菜单"
        echo ""
        select_option "请选择" 4 0

        case "$SELECTED_OPTION" in
            1) user_add ;;
            2) user_delete ;;
            3) user_modify ;;
            4) user_list ;;
            0) return 0 ;;
        esac
        press_any_key
    done
}
