# OPS-Scripts - 服务器运维脚本集合

[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Shell](https://img.shields.io/badge/shell-bash-green.svg)](https://www.gnu.org/software/bash/)
[![OS](https://img.shields.io/badge/OS-Ubuntu%20%7C%20Debian-orange.svg)](#系统要求)

面向 Ubuntu 和 Debian 服务器的交互式 Bash 运维工具集，涵盖系统初始化、防火墙、账号、服务、日志以及 Web 服务器管理。

> 本项目会以 root 权限修改系统配置。使用前请先阅读[安全与注意事项](#安全与注意事项)，并在可回滚的测试环境中验证。

## 目录

- [系统要求](#系统要求)
- [安装与运行](#安装与运行)
- [项目结构](#项目结构)
- [功能概览](#功能概览)
- [系统初始化](#系统初始化)
- [防火墙管理](#防火墙管理)
- [用户与用户组管理](#用户与用户组管理)
- [系统信息与主机设置](#系统信息与主机设置)
- [定时任务与服务管理](#定时任务与服务管理)
- [日志管理](#日志管理)
- [Caddy 管理](#caddy-管理)
- [Nginx 管理](#nginx-管理)
- [Sudoer 管理](#sudoer-管理)
- [镜像代理配置](#镜像代理配置)
- [脚本更新](#脚本更新)
- [验证边界与限制](#验证边界与限制)
- [安全与注意事项](#安全与注意事项)
- [开发与验证](#开发与验证)
- [许可证](#许可证)

## 系统要求

- **操作系统**：Ubuntu 或 Debian；其他发行版会被入口脚本拒绝。
- **权限**：必须以 `root` 用户执行，通常通过 `sudo` 获取权限。
- **Shell**：Bash 4.0+。
- **服务管理**：依赖 systemd。
- **安装前置命令**：至少需要 `curl` 和 `tar`；安装器会在 APT 系统上尝试补齐。
- **网络**：安装、更新、Caddy 安装和 Nginx 源码编译需要访问相应软件源。

## 安装与运行

### 一行安装

安装器支持从管道运行。交互内容会直接从 `/dev/tty` 读取，不会与 `curl` 的脚本内容争用标准输入：

```bash
curl -fsSL \
  https://raw.githubusercontent.com/uuuuupdate/ops-scripts/main/install.sh \
  | sudo bash
```

在自动化环境中可显式使用非交互模式：

```bash
curl -fsSL \
  https://raw.githubusercontent.com/uuuuupdate/ops-scripts/main/install.sh \
  | sudo bash -s -- --non-interactive
```

> 管道安装会立即以 root 执行远程脚本。生产环境建议先下载、审查并固定 Release 标签。

### 下载审查后安装

```bash
installer="$(mktemp)"
trap 'rm -f "$installer"' EXIT
curl -fsSLo "$installer" \
  https://raw.githubusercontent.com/uuuuupdate/ops-scripts/main/install.sh

less "$installer"
sudo bash "$installer"
```

安装器会获取 GitHub 上的最新 Release 标签，并安装到：

- 程序目录：`/opt/ops-scripts`
- 命令链接：`/usr/bin/ops-scripts`
- 版本文件：`/opt/ops-scripts/.version`
- 状态与镜像配置目录：`/etc/ops-scripts`

安装完成后运行：

```bash
sudo ops-scripts
```

### 固定版本与安装参数

将 `TAG` 替换为已有 Release 标签，例如 `v0.0.5`：

```bash
curl -fsSL \
  https://raw.githubusercontent.com/uuuuupdate/ops-scripts/main/install.sh \
  | sudo bash -s -- --non-interactive --version TAG
```

安装器参数：

| 参数 | 作用 |
|---|---|
| `--non-interactive` | 不读取交互输入，使用已有配置或安全默认值 |
| `--version TAG` | 安装指定 Release 标签 |
| `--mirror URL` | 使用指定的 HTTPS GitHub 镜像前缀 |
| `--header 'Name: value'` | 增加镜像请求头，可重复指定 |
| `--no-mirror` | 禁用并删除已保存的镜像配置 |
| `--force` | 版本相同时也重新安装 |

对应环境变量为 `OPS_NON_INTERACTIVE=1`、`OPS_INSTALL_VERSION`、`OPS_MIRROR_URL`、`OPS_MIRROR_HEADERS`（每行一个请求头）、`OPS_NO_MIRROR=1` 和 `OPS_FORCE_INSTALL=1`。通过 `sudo` 时环境变量是否保留取决于 sudoers 配置，自动化场景优先使用命令行参数。

安装器先在临时目录下载和检查归档，再在 `/opt` 下准备完整的新目录并切换；更新已有安装时，上一版本保留在 `/opt/ops-scripts.previous`。归档会检查路径穿越、链接/设备条目、必需文件和全部 Shell 文件语法。

项目目前没有一键卸载器。删除程序目录不会撤销脚本已经写入的 SSH、防火墙、账号、systemd 或其他系统配置，卸载前需要逐项审计和恢复。

首次运行且 `/etc/ops-scripts/.initialized` 不存在时，入口会询问是否执行系统初始化。该流程包括 APT 更新与升级、软件安装、时区设置和 SSH 加固，不是只读检查。

## 项目结构

```text
ops-scripts/
├── install.sh                  # 下载最新 Release 并安装
├── launch.sh                   # 主入口、初始化、更新和菜单调度
├── modules/
│   ├── common.sh               # 日志、交互、系统检测、镜像与依赖函数
│   ├── init_system.sh          # APT 源、系统升级、基础包和时区
│   ├── init_ssh.sh             # SSH 端口、公钥与安全配置
│   ├── firewall.sh             # nftables、Fail2ban 和临时白名单
│   ├── user_mgmt.sh            # 用户及 SSH 公钥管理
│   ├── group_mgmt.sh           # 用户组管理
│   ├── system_info.sh          # 系统、资源、网络、磁盘和安全信息
│   ├── cron_mgmt.sh            # crontab 管理
│   ├── service_mgmt.sh         # systemd 服务管理
│   ├── host_mgmt.sh            # 主机名、时区、NTP 和 Swap
│   ├── log_clean.sh            # 日志清理与 logrotate 管理
│   ├── caddy.sh                # Caddy 安装与服务管理
│   ├── nginx.sh                # Nginx 源码编译与服务管理
│   └── sudoer_mgmt.sh          # /etc/sudoers.d 规则管理
├── AGENTS.md                   # 维护者与自动化代理协作规范
├── README.md                   # 使用文档
├── LICENSE
└── .gitignore
```

## 功能概览

主菜单当前包含以下项目：

| 编号 | 功能 | 入口模块 |
|---:|---|---|
| 1 | 防火墙管理 | `modules/firewall.sh` |
| 2 | 用户管理 | `modules/user_mgmt.sh` |
| 3 | 用户组管理 | `modules/group_mgmt.sh` |
| 4 | 系统信息 | `modules/system_info.sh` |
| 5 | 定时任务管理 | `modules/cron_mgmt.sh` |
| 6 | 系统服务管理 | `modules/service_mgmt.sh` |
| 7 | 主机设置 | `modules/host_mgmt.sh` |
| 8 | Caddy 管理 | `modules/caddy.sh` |
| 9 | Nginx 管理 | `modules/nginx.sh` |
| 10 | Sudoer 管理 | `modules/sudoer_mgmt.sh` |
| 11 | 日志管理 | `modules/log_clean.sh` |
| 12 | 脚本更新 | `launch.sh` |
| 13 | 镜像代理配置 | `modules/common.sh` |

## 系统初始化

初始化由 `launch.sh` 调用两个模块完成。

### 系统环境

- 检测中国大陆网络，并可选择阿里云、腾讯云、清华、中科大或华为云 APT 镜像。
- 识别 Ubuntu 24.04+ 的 `ubuntu.sources` DEB822 配置；传统配置写入 `/etc/apt/sources.list`。
- 执行 `apt update && apt upgrade -y`。
- 安装以下基础软件：

| 类别 | 实际安装的软件包 |
|---|---|
| 基础工具 | curl, wget, vim, git, rsync, jq, unzip, tar |
| 网络与防火墙 | net-tools, iproute2, nftables |
| 编译与证书 | build-essential, apt-transport-https, ca-certificates |
| 安全与服务 | fail2ban, sudo, cron, logrotate |
| 其他 | tmux |
| 仅 Ubuntu | software-properties-common |

- 可选择常用时区，或手动输入 systemd 支持的时区名称。

### SSH 加固

- 可修改 SSH 端口。
- 禁用密码、空密码、基于主机、GSSAPI 和 X11 认证相关选项。
- 将 root 登录限制为公钥认证，并要求配置 root 公钥。
- 设置最大认证次数、登录超时、客户端存活检测和详细日志。
- 可选择禁用 TCP 转发。
- 修改前备份 `/etc/ssh/sshd_config`，修改后调用 `sshd -t` 验证并重启 SSH 服务；任一步失败会恢复原服务配置，只有完整成功后才写入初始化标记。

## 防火墙管理

防火墙模块基于 nftables，并提供：

- 初始化基础规则，默认允许回环、已建立连接、ICMP 和当前 SSH 端口，可选开放 80/443。
- 添加或删除 TCP/UDP 端口规则、IP 白名单、IP 黑名单、端口转发和数据包速率限制。
- 规则查看、验证、重载、导出、导入与恢复默认配置。
- Fail2ban 状态、Jail、封禁/解封、配置和服务管理。
- 一键拉黑恶意 IP。
- 带过期时间的临时 IP 白名单及自动清理任务。

规则目录为 `/etc/nftables.d`，主配置为 `/etc/nftables.conf`。过滤规则集中在一个 `inet ops_filter` 表中，自定义普通链通过 `jump` 接入唯一的 `input`/`forward` base chain，避免跨 base chain 的 `accept` 失效。旧版受管规则会在完整验证后迁移。

所有受管规则先写入候选文件并用 `nft -c -f` 检查，替换或服务重载失败时恢复上一版本。端口转发同时限定 DNAT、forward 和 masquerade 的协议、目标 IP 与端口，并同步管理 IPv4 forwarding。规则导入只接受不含 `flush ruleset` 或 `include` 的自包含 ruleset；导入会清空本工具原有自定义规则文件。

Ubuntu 上初始化流程会在候选规则预检后停用 ufw，再加载 nftables；即使具备回滚逻辑，远程操作仍应保留当前 SSH 会话和带外控制台，并提前确认 SSH 端口。

## 用户与用户组管理

### 用户管理

- 创建用户，选择主组、附加组、Home、Shell、描述和过期时间。
- 为允许 SSH 登录的用户配置公钥。
- 删除用户，可终止其进程，并选择是否删除 Home 和邮件。
- 修改 Shell、主组/附加组、描述、锁定状态、过期时间和密码。
- 查看或维护用户的 `authorized_keys`。

### 用户组管理

- 创建普通组或系统组，可指定 GID。
- 删除组前处理以该组为主组的用户。
- 重命名用户组、修改 GID、添加或移除成员。
- 查看普通组或全部用户组。

## 系统信息与主机设置

系统信息页面提供系统概览、CPU/内存资源、网络、磁盘以及 SSH 安全相关信息。

主机设置支持：

- 修改主机名。
- 设置时区。
- 启用、禁用或手动同步 NTP。
- 创建、启用、关闭或删除 Swap 文件，并调整 `vm.swappiness`；删除只接受 `swapon --show` 中的活动普通文件，`/etc/fstab` 通过同目录候选文件更新并可回滚。

## 定时任务与服务管理

### 定时任务

- 查看 root、指定用户或系统级任务。
- 使用预设周期或手写 cron 表达式添加任务。
- 删除单行任务或清空指定用户的 crontab。
- 通过 `$EDITOR`（默认 `vim`）编辑 crontab。

### systemd 服务

- 查看运行中、全部、已启用或失败的服务。
- 启动、停止、重启、重载以及启用/禁用开机自启。
- 查看最近日志、当天日志或实时跟踪日志。

## 日志管理

### 日志空间清理

- 分析根分区、`/var/log`、journald 和 APT 缓存占用。
- 按时间或大小清理 journald。
- 删除 `/var/log` 下的压缩、轮转或超过指定天数的日志。
- 执行 `apt autoclean`、`apt clean` 和 `apt autoremove`。
- 对允许范围内的应用日志/数据子目录执行旧文件清理；拒绝 `/`、`/etc`、`/var`、Home 根目录等过宽路径，且不跟随符号链接或跨文件系统。

### logrotate 管理

- 查看主配置、服务配置和轮转状态。
- 正常、强制或模拟执行轮转。
- 创建自定义 `/etc/logrotate.d/ops-<名称>` 配置，并在替换前执行语法验证。
- 查看全部配置，但只允许删除本项目创建的 `/etc/logrotate.d/ops-*` 文件。

日志清理和配置删除可能不可恢复。执行前请仔细核对目标目录、候选文件列表和备份。

## Caddy 管理

- 通过 Caddy 官方 APT 源安装。
- 新安装时备份并重写 `/etc/caddy/Caddyfile`，使其导入 `/etc/caddy.d/*.conf`。
- 创建禁用状态的示例站点配置。
- 查看版本、服务状态、配置目录和配置验证结果。
- 启动、停止、重启、重载和查看服务日志。

> 如果系统已经存在 Caddy，选择“跳过安装并标记”只会创建配置目录，不会重写主 Caddyfile。

## Nginx 管理

Nginx 通过源码编译安装到 `/usr/local/nginx`，源码和依赖下载到 `/opt/nginx-compile`。

- 自动检测或手动指定 Nginx、zlib、OpenSSL、PCRE2 版本。
- 可选择编译第三方 `ngx_http_geoip2_module`。
- 可创建专用运行用户/组，或选择已有用户。
- 默认启用 SSL、HTTP/2、HTTP/3、realip、gzip static、stub status、sub、stream、PCRE JIT 等模块。
- 可选择 image filter、XSLT、GeoIP、gunzip、auth request、DAV、FLV、MP4、secure link、slice、compat、threads 等附加参数。
- 创建 systemd 服务和 `/usr/local/bin/nginx` 链接。
- 提供状态、配置验证、服务操作和日志查看。

源码包当前只依赖 HTTPS 下载结果，没有额外的校验和或签名验证；在高安全环境中应自行校验来源和摘要。

## Sudoer 管理

- 管理 `/etc/sudoers.d/ops-*` 配置，支持免密码或需要密码的全部/指定命令授权。
- 新建规则使用临时文件验证，文件权限设置为 `0440`。
- 支持追加、删除行以及通过 `visudo` 编辑。
- 使用 `visudo -cf` 验证新增或修改后的配置。

## 镜像代理配置

主菜单第 13 项可配置 GitHub 下载镜像地址和可选认证请求头。配置保存在 `/etc/ops-scripts/mirror.conf`，安装和更新时会把镜像前缀加到 GitHub API 与归档地址前。

未配置自定义镜像时，脚本会检测网络环境，并可能使用内置的 `https://ghproxy.cn/` 前缀。

认证请求头可能包含令牌。配置目录使用 `0700`、`mirror.conf` 使用 `0600`，但内容仍是明文；请避免将其复制到日志、工单或代码仓库。

## 脚本更新

主菜单提供 `12) 脚本更新`。更新器获取最新 Release，在私有临时目录检查归档和 Shell 语法，在安装目录的同一文件系统准备候选版本，再切换目录；上一版本保留为 `/opt/ops-scripts.previous`，切换失败会恢复旧版本。成功后当前旧进程退出，需要重新运行 `sudo ops-scripts`。

## 验证边界与限制

- GitHub 源码归档目前没有由本项目发布者提供的独立 checksum 或签名；安装器和更新器只能依赖 HTTPS、归档结构检查和 Shell 语法验证。高安全环境应固定版本并建立独立摘要/签名校验。
- Nginx 源码及依赖同样尚未校验上游摘要或签名。
- 端口转发当前只支持单个 IPv4 目标；不是通用 IPv6 转发管理器。
- 项目没有统一的系统状态快照或一键卸载/整体回滚。各高风险模块只对其当前事务负责，不能替代虚拟机快照、云主机快照或带外恢复通道。
- 本项目只支持 Ubuntu/Debian + systemd。发布前仍应在可丢弃的两个发行版环境中完成真实 SSH、nftables、APT 和 systemd 集成测试。

## 安全与注意事项

1. **先在测试环境验证**：脚本会修改 APT、SSH、防火墙、systemd、账号、sudoers、cron、日志和 Swap 配置。
2. **保留远程恢复通道**：修改 SSH 或防火墙时保持现有会话，并准备云控制台、KVM 或其他带外入口。
3. **初始化会升级系统**：首次初始化执行非交互式 `apt upgrade -y`，可能影响已部署服务并需要重启。
4. **事务回滚不等于系统快照**：SSH、防火墙、sudoers、Swap 持久化配置和安装更新等关键路径具备局部回滚，但 APT 升级、账号操作、日志删除等无法整体撤销。
5. **日志清理不可恢复**：即使目录受到边界限制并先冻结候选清单，实际删除的文件仍无法自动恢复。
6. **保护镜像凭据**：`mirror.conf` 中的认证请求头为明文数据。
7. **审查远程内容**：安装器、更新器和源码编译会下载并执行或编译远程内容；生产环境应固定版本并验证摘要。
8. **状态标记不是健康检查**：`/etc/ops-scripts` 下的标记文件仅表示流程曾执行，不保证服务当前配置有效。

## 开发与验证

项目维护约定见 [AGENTS.md](AGENTS.md)。至少应对所有 Shell 文件执行语法检查：

```bash
bash -n install.sh launch.sh modules/*.sh
```

推荐额外使用 ShellCheck，并在隔离的 Ubuntu、Debian 测试机或容器中逐项验证。不要在开发机直接以 root 运行完整入口脚本。

## 许可证

本项目使用 [MIT License](LICENSE)。
