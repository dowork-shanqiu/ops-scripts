# OPS-Scripts - 服务器运维脚本集合

[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Shell](https://img.shields.io/badge/shell-bash-green.svg)](https://www.gnu.org/software/bash/)
[![OS](https://img.shields.io/badge/OS-Ubuntu%20%7C%20Debian-orange.svg)](#系统要求)

一套用于 Ubuntu / Debian 服务器运维操作的 Shell 脚本集合，提供交互式菜单驱动的系统管理功能。

## 📋 目录

- [系统要求](#系统要求)
- [快速开始](#快速开始)
- [项目结构](#项目结构)
- [功能说明](#功能说明)
  - [系统初始化](#系统初始化)
  - [防火墙管理](#防火墙管理)
  - [用户管理](#用户管理)
  - [用户组管理](#用户组管理)
  - [系统信息](#系统信息)
  - [定时任务管理](#定时任务管理)
  - [系统服务管理](#系统服务管理)
  - [主机设置](#主机设置)
  - [Caddy 管理](#caddy-管理)
  - [Nginx 管理](#nginx-管理)
  - [Sudoer 管理](#sudoer-管理)
  - [脚本更新](#脚本更新)
- [注意事项](#注意事项)
- [许可证](#许可证)

## 系统要求

- **操作系统**: Ubuntu 或 Debian（其他发行版不支持）
- **权限**: 必须以 **root** 用户执行
- **Shell**: Bash 4.0+

## 快速开始

### 一键安装（推荐）

通过 `curl` 一键下载并安装到系统中，安装完成后可以直接使用 `ops-scripts` 命令运行：

```bash
curl -fsSL https://raw.githubusercontent.com/dowork-shanqiu/ops-scripts/main/install.sh | sudo bash
```

安装完成后运行：

```bash
sudo ops-scripts
```

> **提示**：安装脚本会自动检测网络环境，中国大陆用户将自动使用镜像加速下载。

### 手动安装

```bash
# 克隆仓库
git clone https://github.com/dowork-shanqiu/ops-scripts.git
cd ops-scripts

# 赋予执行权限
chmod +x launch.sh

# 以 root 权限运行
sudo bash launch.sh
```

### 脚本更新

**方式一：通过主菜单更新**

运行脚本后，在主菜单中选择 `11) 🔄 脚本更新` 即可自动更新到最新版本。

**方式二：重新运行安装命令**

```bash
curl -fsSL https://raw.githubusercontent.com/dowork-shanqiu/ops-scripts/main/install.sh | sudo bash
```

安装脚本会自动检测已有安装并执行更新。

首次运行时，脚本会自动进入 **系统初始化** 流程。初始化完成后，后续执行将直接进入功能菜单。

## 项目结构

```
ops-scripts/
├── install.sh                  # 一键安装脚本
├── launch.sh                   # 主入口脚本
├── modules/                    # 功能模块目录
│   ├── common.sh               # 公共工具函数（颜色、日志、交互等）
│   ├── init_system.sh          # 系统初始化（APT 源、更新、基础包安装）
│   ├── init_ssh.sh             # SSH 安全配置
│   ├── firewall.sh             # 防火墙管理（nftables）
│   ├── user_mgmt.sh            # 用户管理
│   ├── group_mgmt.sh           # 用户组管理
│   ├── system_info.sh          # 系统信息查看
│   ├── cron_mgmt.sh            # 定时任务管理
│   ├── service_mgmt.sh         # 系统服务管理
│   ├── host_mgmt.sh            # 主机设置（主机名/时区/NTP/Swap）
│   ├── caddy.sh                # Caddy 安装与管理
│   ├── nginx.sh                # Nginx 源码编译安装与管理
│   └── sudoer_mgmt.sh          # Sudoer 免密 sudo 配置管理
├── README.md                   # 项目文档
├── LICENSE                     # 许可证
└── .gitignore                  # Git 忽略规则
```

## 功能说明

### 系统初始化

首次运行脚本时自动触发，完成以下操作：

#### 1. 网络环境检测与 APT 源配置

- 自动检测服务器是否位于中国大陆网络
- 如果在中国大陆，提供以下镜像源供选择：
  - 阿里云镜像
  - 腾讯云镜像
  - 清华大学镜像
  - 中科大镜像
  - 华为云镜像
- 支持传统 `sources.list` 格式和 DEB822 格式（Ubuntu 24.04+）
- 替换完成后自动执行 `apt update && apt upgrade -y`

#### 2. 基础工具安装

自动安装以下基础工具：

| 类别 | 工具 |
|------|------|
| 基础工具 | curl, wget, vim, git, rsync, jq, unzip, tar |
| 网络工具 | net-tools, iproute2, dnsutils, nftables |
| 系统监控 | htop, lsof |
| 编译工具 | build-essential, software-properties-common, ca-certificates, gnupg, lsb-release |
| 安全工具 | fail2ban, sudo |
| 其他 | tmux, cron, logrotate, bash-completion |

#### 3. SSH 安全配置

- **端口修改**: 可选修改 SSH 端口
- **安全加固**:
  - 禁止 root 密码登录（仅允许公钥认证）
  - 禁用密码认证
  - 禁止空密码登录
  - 禁用基于主机的认证
  - 启用公钥认证
  - 禁用 X11 转发
  - 限制最大认证尝试次数（3 次）
  - 设置登录超时（60 秒）
  - 禁用 DNS 反向解析
  - 设置客户端存活检测
  - 可选禁用 TCP 转发
- **公钥配置**: 要求输入 root 用户的 SSH 公钥
- 自动处理 Ubuntu (ssh) 和 Debian (sshd) 的服务名差异

---

### 防火墙管理

基于 **nftables** 的防火墙管理，Ubuntu 系统会自动关闭 ufw。

#### 防火墙初始化

- 规则文件存放于 `/etc/nftables.d/` 目录
- 基础规则文件 `base.conf` 包含:
  - 允许本地回环
  - 允许已建立连接
  - 丢弃无效连接
  - 允许 ICMP (ping)
  - 允许当前 SSH 端口
  - 可选放开 Web 端口 (80/443)
  - 日志记录被拒绝的连接
- 初始化完成后会标记，防止重复执行

#### 防火墙规则管理

| 功能 | 说明 |
|------|------|
| 查看当前规则 | 显示完整的 nftables 规则集 |
| 添加端口放行 | 支持 TCP/UDP/TCP+UDP，可限制来源 IP |
| 删除端口放行 | 列出规则供选择删除 |
| IP 白名单 | 放行指定 IP 或网段 |
| IP 黑名单 | 封禁指定 IP 或网段 |
| 端口转发 | NAT 端口转发，自动启用 IP 转发 |
| 速率限制 | 对指定端口设置连接速率限制 |
| 导出/导入规则 | 备份和恢复规则配置 |
| 恢复默认 | 删除所有自定义规则，恢复基础配置 |

---

### 用户管理

#### 添加用户

交互式创建用户，支持以下配置：

- 用户名（自动检测是否已存在）
- 主用户组（创建同名组 / 选择已有组 / 系统默认）
- 附加用户组
- 工作目录（可自定义路径）
- 默认 Shell（列出系统中所有可用 Shell 供选择）
- 用户描述/备注
- 账号过期时间
- SSH 登录权限（允许登录的用户必须提供 SSH 公钥）

#### 删除用户

- 列出所有普通用户供选择
- 自动检测用户运行中的进程
- 可选删除工作目录和邮件
- 支持强制删除

#### 修改用户

- 修改默认 Shell
- 修改用户组（主组/附加组）
- 修改用户描述
- 锁定/解锁用户
- 修改账号过期时间
- 重置密码
- 管理 SSH 公钥（查看/添加/删除/替换）

#### 查看用户列表

- 支持查看普通用户或所有用户
- 显示用户名、UID、GID、工作目录、Shell

---

### 用户组管理

#### 添加用户组

- 自动检测是否已存在
- 可选指定 GID
- 可选创建为系统用户组
- 创建后可立即添加用户到组

#### 删除用户组

- 列出所有用户组供选择
- 检查主组关联用户，提供处理方案：
  - 将用户主组改为指定组
  - 为每个用户创建同名组
- 附加组成员自动处理

#### 修改用户组

- 重命名用户组
- 修改 GID
- 添加/移除组成员

---

### 系统信息

| 功能 | 内容 |
|------|------|
| 系统概览 | OS、内核、主机名、CPU、内存、负载、在线用户等 |
| 资源使用 | CPU/内存 Top 10 进程、内存详情 |
| 网络信息 | 网络接口、路由、DNS、监听端口、公网 IP |
| 磁盘信息 | 磁盘使用、Inode 使用、大目录分析 |
| 安全信息 | SSH 登录记录、失败登录尝试、SSH 配置摘要 |

---

### 定时任务管理

- **查看任务**: 支持查看指定用户、系统级、全部任务
- **添加任务**: 提供预设模板和手动输入两种方式
  - 预设: 每分钟、每 5/10/30 分钟、每小时、每天、每周等
  - 可选输出重定向和注释
- **删除任务**: 列出任务供选择删除，支持清空全部
- **编辑任务**: 直接打开编辑器编辑

---

### 系统服务管理

- **查看服务**: 运行中/全部/已启用/失败的服务
- **服务操作**:
  - 启动/停止/重启服务
  - 重载配置
  - 启用/禁用开机自启
  - 查看服务日志（最近 N 行/今日/实时跟踪）

---

### 主机设置

| 功能 | 说明 |
|------|------|
| 主机名设置 | 修改服务器主机名 |
| 时区设置 | 提供常用时区快速选择，支持手动输入 |
| NTP 同步 | 启用/禁用 NTP、手动同步时间 |
| Swap 管理 | 创建/关闭/删除 Swap 文件、调整 swappiness |

---

### Caddy 管理

通过官方 APT 源安装 Caddy Web 服务器。

#### 安装

- 自动添加 Caddy 官方 GPG 密钥和 APT 源
- 安装完成后自动创建配置目录 `/etc/caddy.d`
- 主配置文件 `/etc/caddy/Caddyfile` 自动引入 `/etc/caddy.d/*.conf`
- 安装后标记已完成，不会重复安装
- 提供示例配置文件

#### 管理功能

| 功能 | 说明 |
|------|------|
| 安装 Caddy | 通过官方源一键安装 |
| 查看状态 | 服务状态、配置目录、配置验证 |
| 服务管理 | 启动/停止/重启/重载配置/查看日志 |

---

### Nginx 管理

通过源码编译安装 Nginx，支持完全自定义。

#### 编译安装

- **编译目录**: `/opt/nginx-compile`
- **安装目录**: `/usr/local/nginx`
- **版本选择**: 默认使用最新版本，支持指定版本号
- **依赖库**: zlib、OpenSSL、PCRE2 均从源码编译，支持指定版本
- **用户配置**: 支持新建用户/用户组或选择已有用户
- **编译参数**: 提供默认基础参数，支持选择附加模块或手动输入

##### 默认编译参数

```
--with-http_ssl_module
--with-http_v2_module
--with-http_realip_module
--with-http_gzip_static_module
--with-http_stub_status_module
--with-http_sub_module
--with-stream
--with-stream_ssl_module
--with-pcre=<pcre2源码目录>
--with-zlib=<zlib源码目录>
--with-openssl=<openssl源码目录>
```

##### 可选附加模块

- http_image_filter_module、http_xslt_module、http_geoip_module
- http_gunzip_module、http_auth_request_module
- http_dav_module、http_flv_module、http_mp4_module
- http_secure_link_module、stream_realip_module

#### 管理功能

| 功能 | 说明 |
|------|------|
| 编译安装 | 全交互式源码编译安装 |
| 查看状态 | 版本、服务状态、编译参数、配置验证 |
| 服务管理 | 启动/停止/重启/重载/验证配置/查看日志 |

---

### Sudoer 管理

管理用户免密码执行 sudo 命令的配置。

- 自动检测 sudo 是否已安装（未安装时提供安装选项）
- 配置文件存放于 `/etc/sudoers.d/` 目录，以 `ops-` 前缀命名
- 文件权限自动设置为 `0440`
- 使用 `visudo -cf` 进行配置验证，保证配置安全

#### 功能

| 功能 | 说明 |
|------|------|
| 查看配置 | 列出所有 sudoer 配置及主配置文件摘要 |
| 添加规则 | 选择用户 → 选择授权方式 → 自动创建配置文件 |
| 删除规则 | 列出所有规则配置文件供选择删除 |
| 修改规则 | 追加/删除行/编辑器编辑，变更后自动验证 |

#### 授权方式

- 允许执行所有命令（免密码）
- 允许执行指定命令（免密码）
- 允许执行所有命令（需密码）
- 允许执行指定命令（需密码）

---

### 脚本更新

在主菜单中选择「脚本更新」可将脚本更新到最新版本。

- 自动检测网络环境，中国大陆用户使用镜像加速
- 通过 Git 拉取最新代码并重置到最新版本
- 也可以重新运行安装命令来更新

---

## 注意事项

1. **首次使用务必确认 SSH 配置**：初始化完成后，在断开当前连接之前，请使用新配置测试 SSH 连接，避免因配置错误导致无法登录。

2. **防火墙初始化为一次性操作**：初始化完成后无法重新初始化，后续只能通过规则管理进行修改。

3. **标记文件位置**：系统初始化、防火墙初始化、Caddy 安装、Nginx 安装的标记文件存放在 `/etc/ops-scripts/` 目录下。

4. **备份策略**：脚本在修改关键配置（APT 源、SSH 配置、防火墙规则）前会自动备份原始配置。

5. **模块化设计**：每个功能模块独立存放在 `modules/` 目录下，方便维护和扩展。

6. **Nginx 编译安装**：编译过程需要较长时间，取决于服务器性能。编译目录默认为 `/opt/nginx-compile`，安装完成后可以手动清理。

7. **Sudoer 配置安全**：所有 sudoer 配置文件均通过 `visudo` 验证，权限强制为 `0440`，保证系统安全。

## 许可证

本项目使用 [MIT License](LICENSE) 许可证。