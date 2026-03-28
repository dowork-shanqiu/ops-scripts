#!/usr/bin/env bash
# ============================================================
# 用户组管理模块
# - 添加用户组
# - 删除用户组
# - 修改用户组
# - 查看用户组列表
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# ============================================================
# 添加用户组
# ============================================================
group_add() {
    print_separator
    echo -e "${BOLD}  添加用户组${NC}"
    print_separator
    echo ""

    local groupname
    read_nonempty "请输入用户组名" groupname

    # 检查用户组是否已存在
    if getent group "$groupname" &>/dev/null; then
        log_error "用户组 '${groupname}' 已存在"
        return 1
    fi

    # GID 设置
    echo ""
    local gid_opt=""
    if confirm "是否指定 GID?"; then
        local gid
        read_nonempty "请输入 GID" gid
        if [[ "$gid" =~ ^[0-9]+$ ]]; then
            # 检查 GID 是否已被占用
            if getent group "$gid" &>/dev/null; then
                log_error "GID ${gid} 已被占用"
                return 1
            fi
            gid_opt="-g ${gid}"
        else
            log_error "GID 必须为数字"
            return 1
        fi
    fi

    # 是否为系统组
    local sys_opt=""
    if confirm "是否创建为系统用户组 (GID < 1000)?"; then
        sys_opt="-r"
    fi

    # 执行创建
    local cmd_args=()
    [ -n "$sys_opt" ] && cmd_args+=("$sys_opt")
    if [ -n "$gid_opt" ]; then
        # gid_opt is like "-g 1001"
        cmd_args+=($gid_opt)
    fi
    cmd_args+=("$groupname")

    log_info "即将执行: groupadd ${cmd_args[*]}"

    if confirm "确认创建用户组?"; then
        if groupadd "${cmd_args[@]}"; then
            log_info "用户组 '${groupname}' 创建成功"
            getent group "$groupname"

            # 是否立即添加用户到此组
            if confirm "是否立即将用户添加到此组?"; then
                echo ""
                log_info "当前系统用户:"
                print_thin_separator
                local users_list=()
                local idx=1
                while IFS=: read -r uname _ uid _ _ _ _; do
                    if [ "$uid" -ge 1000 ] && [ "$uname" != "nobody" ]; then
                        users_list+=("$uname")
                        echo "  ${idx}) ${uname}"
                        idx=$((idx + 1))
                    fi
                done < /etc/passwd
                print_thin_separator

                if [ ${#users_list[@]} -gt 0 ]; then
                    local users_to_add
                    read_nonempty "请输入要添加的用户编号 (多个用空格分隔)" users_to_add
                    for num in $users_to_add; do
                        if [[ "$num" =~ ^[0-9]+$ ]] && [ "$num" -ge 1 ] && [ "$num" -le ${#users_list[@]} ]; then
                            local u="${users_list[$((num - 1))]}"
                            usermod -aG "$groupname" "$u"
                            log_info "已将用户 '${u}' 添加到组 '${groupname}'"
                        fi
                    done
                else
                    log_warn "没有可添加的用户"
                fi
            fi
        else
            log_error "用户组创建失败"
        fi
    else
        log_info "已取消创建用户组"
    fi
}

# ============================================================
# 删除用户组
# ============================================================
group_delete() {
    print_separator
    echo -e "${BOLD}  删除用户组${NC}"
    print_separator
    echo ""

    # 列出可删除的用户组
    log_info "当前用户组列表 (GID >= 1000):"
    print_thin_separator
    local groups_list=()
    local idx=1
    while IFS=: read -r gname _ gid members; do
        if [ "$gid" -ge 1000 ] && [ "$gname" != "nogroup" ] && [ "$gname" != "nobody" ]; then
            groups_list+=("$gname")
            local member_count=0
            if [ -n "$members" ]; then
                member_count=$(echo "$members" | tr ',' '\n' | wc -l)
            fi
            printf "  %d) %-20s GID:%-8s 成员数:%s\n" "$idx" "$gname" "$gid" "$member_count"
            if [ -n "$members" ]; then
                echo "     成员: ${members}"
            fi
            idx=$((idx + 1))
        fi
    done < /etc/group
    print_thin_separator

    if [ ${#groups_list[@]} -eq 0 ]; then
        log_warn "没有可删除的用户组"
        return 0
    fi

    echo "  0) 取消"
    echo ""
    select_option "请选择要删除的用户组" "${#groups_list[@]}" 0

    if [ "$SELECTED_OPTION" -eq 0 ]; then
        log_info "已取消"
        return 0
    fi

    local del_group="${groups_list[$((SELECTED_OPTION - 1))]}"

    # 检查组内成员
    local members
    members=$(getent group "$del_group" | cut -d: -f4)
    local primary_users=()

    # 检查以此为主组的用户
    while IFS=: read -r uname _ _ gid _ _ _; do
        local user_gname
        user_gname=$(getent group "$gid" | cut -d: -f1)
        if [ "$user_gname" = "$del_group" ]; then
            primary_users+=("$uname")
        fi
    done < /etc/passwd

    if [ ${#primary_users[@]} -gt 0 ]; then
        log_warn "以下用户的主组为 '${del_group}':"
        for u in "${primary_users[@]}"; do
            echo "  - ${u}"
        done
        echo ""
        log_warn "删除此组前，必须先处理这些用户的主组"
        echo ""
        echo "请选择处理方式:"
        echo "  1) 将这些用户的主组改为指定组"
        echo "  2) 为每个用户创建同名组作为主组"
        echo "  3) 取消删除"
        select_option "请选择" 3

        case "$SELECTED_OPTION" in
            1)
                local new_group
                read_nonempty "请输入新的主组名" new_group
                if ! getent group "$new_group" &>/dev/null; then
                    log_error "用户组 '${new_group}' 不存在"
                    return 1
                fi
                for u in "${primary_users[@]}"; do
                    usermod -g "$new_group" "$u"
                    log_info "已将用户 '${u}' 的主组改为 '${new_group}'"
                done
                ;;
            2)
                for u in "${primary_users[@]}"; do
                    if ! getent group "$u" &>/dev/null; then
                        groupadd "$u"
                    fi
                    usermod -g "$u" "$u"
                    log_info "已将用户 '${u}' 的主组改为同名组"
                done
                ;;
            3)
                log_info "已取消删除"
                return 0
                ;;
        esac
    fi

    # 处理附加成员
    if [ -n "$members" ]; then
        log_info "以下用户在此组的附加组列表中: ${members}"
        log_info "删除组后，这些用户将自动从附加组中移除"
    fi

    echo ""
    if confirm "确认删除用户组 '${del_group}'?"; then
        groupdel "$del_group"
        if [ $? -eq 0 ]; then
            log_info "用户组 '${del_group}' 已删除"
        else
            log_error "删除用户组失败"
        fi
    else
        log_info "已取消删除"
    fi
}

# ============================================================
# 修改用户组
# ============================================================
group_modify() {
    print_separator
    echo -e "${BOLD}  修改用户组${NC}"
    print_separator
    echo ""

    # 列出用户组
    log_info "当前用户组列表:"
    print_thin_separator
    local groups_list=()
    local idx=1
    while IFS=: read -r gname _ gid members; do
        if [ "$gid" -ge 1000 ] && [ "$gname" != "nogroup" ]; then
            groups_list+=("$gname")
            printf "  %d) %-20s GID:%-8s 成员:%s\n" "$idx" "$gname" "$gid" "${members:-无}"
            idx=$((idx + 1))
        fi
    done < /etc/group
    print_thin_separator

    if [ ${#groups_list[@]} -eq 0 ]; then
        log_warn "没有可修改的用户组"
        return 0
    fi

    echo "  0) 取消"
    echo ""
    select_option "请选择要修改的用户组" "${#groups_list[@]}" 0

    if [ "$SELECTED_OPTION" -eq 0 ]; then
        return 0
    fi

    local mod_group="${groups_list[$((SELECTED_OPTION - 1))]}"

    echo ""
    echo "请选择修改项:"
    echo "  1) 重命名用户组"
    echo "  2) 修改 GID"
    echo "  3) 添加用户到此组"
    echo "  4) 从此组移除用户"
    echo "  0) 返回"
    select_option "请选择" 4 0

    case "$SELECTED_OPTION" in
        1)
            local new_name
            read_nonempty "请输入新的组名" new_name
            if getent group "$new_name" &>/dev/null; then
                log_error "组名 '${new_name}' 已存在"
                return 1
            fi
            groupmod -n "$new_name" "$mod_group"
            log_info "用户组已重命名: ${mod_group} -> ${new_name}"
            ;;
        2)
            local new_gid
            read_nonempty "请输入新的 GID" new_gid
            if getent group "$new_gid" &>/dev/null; then
                log_error "GID ${new_gid} 已被占用"
                return 1
            fi
            groupmod -g "$new_gid" "$mod_group"
            log_info "GID 已修改为: ${new_gid}"
            ;;
        3)
            local username
            read_nonempty "请输入要添加的用户名" username
            if ! id "$username" &>/dev/null; then
                log_error "用户 '${username}' 不存在"
                return 1
            fi
            usermod -aG "$mod_group" "$username"
            log_info "已将用户 '${username}' 添加到组 '${mod_group}'"
            ;;
        4)
            local members
            members=$(getent group "$mod_group" | cut -d: -f4)
            if [ -z "$members" ]; then
                log_warn "此组没有附加成员"
                return 0
            fi
            log_info "当前成员: ${members}"
            local username
            read_nonempty "请输入要移除的用户名" username
            gpasswd -d "$username" "$mod_group"
            log_info "已将用户 '${username}' 从组 '${mod_group}' 移除"
            ;;
        0) return 0 ;;
    esac
}

# ============================================================
# 查看用户组列表
# ============================================================
group_list() {
    print_separator
    echo -e "${BOLD}  用户组列表${NC}"
    print_separator
    echo ""

    echo "请选择查看范围:"
    echo "  1) 仅普通用户组 (GID >= 1000)"
    echo "  2) 所有用户组"
    select_option "请选择" 2

    echo ""
    printf "  ${BOLD}%-20s %-10s %-30s${NC}\n" "组名" "GID" "成员"
    print_thin_separator

    while IFS=: read -r gname _ gid members; do
        if [ "$SELECTED_OPTION" -eq 1 ]; then
            if [ "$gid" -ge 1000 ] && [ "$gname" != "nogroup" ]; then
                printf "  %-20s %-10s %-30s\n" "$gname" "$gid" "${members:-无}"
            fi
        else
            printf "  %-20s %-10s %-30s\n" "$gname" "$gid" "${members:-无}"
        fi
    done < /etc/group

    print_thin_separator
}

# ============================================================
# 入口函数
# ============================================================
run_group_mgmt() {
    while true; do
        print_separator
        echo -e "${BOLD}  用户组管理${NC}"
        print_separator
        echo ""
        echo "  1) 添加用户组"
        echo "  2) 删除用户组"
        echo "  3) 修改用户组"
        echo "  4) 查看用户组列表"
        echo "  0) 返回上级菜单"
        echo ""
        select_option "请选择" 4 0

        case "$SELECTED_OPTION" in
            1) group_add ;;
            2) group_delete ;;
            3) group_modify ;;
            4) group_list ;;
            0) return 0 ;;
        esac
        press_any_key
    done
}
