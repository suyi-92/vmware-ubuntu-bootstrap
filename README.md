# VMware Ubuntu Bootstrap

> 状态：可运行首版 v0.1（2026-08-31）
> 已实现分阶段脚本、备份回滚和隔离测试；尚需在全新 VMware Ubuntu 24.04 快照上完成真实 canary，验证前不要用于唯一生产环境。

## 1. 项目目标

本项目用于把一台刚在本地 VMware 中手动安装完成的 Ubuntu 24.04 虚拟机，初始化成可长期使用、可重复部署、可验证、可回滚的开发环境。

预期使用流程：

1. 用户在 VMware 中手动创建虚拟机、安装 Ubuntu，并把网卡设为桥接模式。
2. 用户临时指定 Windows 主机上的 `7890` HTTP/Mixed 代理，以便安装 `git`、克隆本仓库并启动安装入口。
3. 项目的一键脚本接管后，自动发现局域网内真正可用的 `7890` 代理，持久化各类代理配置。
4. 脚本按阶段完成固定 IP、电源策略、SSH、公用软件包、Codex 和 CPA Provider 配置。
5. 脚本完成验证并输出状态；失败时停在明确阶段，不把部分成功冒充完整成功。

项目仓库为 `https://github.com/suyi-92/vmware-ubuntu-bootstrap`。仓库中只能保存源码、模板、测试和文档，不能保存真实 API key、私钥、运行日志、机器配置或备份。

快速入口：

```bash
sudo bash install.sh
```

安装、恢复和验证细节分别见 [`docs/install-flow.md`](docs/install-flow.md)、[`docs/recovery.md`](docs/recovery.md) 和 [`docs/verification.md`](docs/verification.md)。

## 2. 当前范围与非目标

### 2.1 首版支持范围

- VMware Workstation 中的 Ubuntu 24.04 Desktop x86_64。
- 一块桥接网卡，首选自动识别当前默认路由对应接口，例如 `ens33`。
- 局域网为 `192.168.1.0/24`。
- Windows 代理软件已开启 `Allow LAN`，HTTP/Mixed 端口为 `7890`。
- 普通 Ubuntu 用户通过 `sudo` 执行安装脚本，不配置 root 远程登录。
- Codex CLI 使用自定义 `cpa` Provider，并连接 CPA 的 `/v1` 接口。

### 2.2 “所有流量经过代理”的准确边界

普通 HTTP/Mixed `7890` 代理不能透明接管任意三层流量。本项目首版保证下列“支持 HTTP/HTTPS 代理”的程序和服务使用代理：

- 普通用户和 root 的 shell 环境；
- `sudo curl`、`sudo wget` 等保留代理环境后的命令；
- APT；
- 普通用户、root 和系统级 Git；
- Docker daemon 及普通用户/root 的 Docker build 客户端（仅在已安装 Docker 时）；
- Snap；
- 由 systemd 启动、且遵循 `HTTP_PROXY` / `HTTPS_PROXY` 的服务；
- Codex 安装下载及访问非局域网 Provider 的 HTTP(S) 请求。

以下流量不在首版承诺范围内：ICMP、任意 UDP、不支持代理环境变量的程序，以及需要透明转发的原始 TCP。若未来需要真正的全流量代理，应独立增加 TUN/透明代理模式，不能把 HTTP 代理配置宣称为全流量代理。

### 2.3 首版不默认执行

- 不自动安装 Ubuntu 本身。
- 不自动修改 VMware 宿主机设置。
- 不默认启用 UFW、fail2ban 或关闭 SSH 密码登录。
- 不默认安装 Docker；如果系统已有 Docker则配置代理，未来可把 Docker 安装作为可选阶段。
- 不执行 `do-release-upgrade`、`full-upgrade` 或发行版升级。
- 不上传 Git、不创建远端、不提交任何凭据。
- 不部署 MDD 或其他具体业务项目。

## 3. 必须纠正的固定 IP 默认值

用户原始需求中的 `192.168.1.255` 在 `192.168.1.0/24` 中是广播地址，不能分配给虚拟机。

首版采用：

```text
默认地址：192.168.1.254/24
允许末位：2–254
默认网关：从当前 DHCP 默认路由自动读取，并让用户确认
默认 DNS：从当前有效连接自动读取，并让用户确认
```

`.254` 也不能无条件使用。应用前必须确认：

1. 不是当前网关、Windows 主机、代理主机或其他已知设备地址；
2. `arping`/邻居探测未发现占用；
3. 用户已确认该地址不在路由器可能重新分配的 DHCP 范围内，或已在路由器设置 DHCP 保留；
4. 网络配置存在自动回滚机制。

只要检测到冲突或无法建立回滚点，就停止网络阶段。

## 4. 手动前置步骤

### 4.1 VMware

建议虚拟机配置：

```text
Guest OS：Ubuntu 24.04 x86_64
CPU：4 核或以上
内存：8 GB 或以上
硬盘：80 GB 或以上
Network Adapter：Bridged
USB Controller：按实际设备需要
```

Ubuntu 安装完成后，先在控制台确认：

```bash
ip -4 address
ip -4 route
```

### 4.2 Windows 代理

Windows 代理软件需要满足：

```text
Allow LAN：开启
HTTP / Mixed Port：7890
Windows 防火墙：允许 Ubuntu 所在局域网访问该端口
```

### 4.3 Windows SSH 公钥

若 Windows 尚无 SSH key，在 PowerShell 中执行：

```powershell
ssh-keygen -t ed25519
Get-Content $env:USERPROFILE\.ssh\id_ed25519.pub
```

安装脚本只需要粘贴 `.pub` 公钥。私钥永远不能复制到 Ubuntu 安装项目或 Git 仓库中。

## 5. 首次从 Git 启动的“鸡生蛋”流程

自动代理脚本尚未运行时，Ubuntu 必须先临时使用 Windows 主机代理，才能安装依赖并克隆仓库。

```bash
PROXY_HOST="192.168.1.100"
PROXY_URL="http://${PROXY_HOST}:7890"

export http_proxy="$PROXY_URL"
export https_proxy="$PROXY_URL"
export HTTP_PROXY="$PROXY_URL"
export HTTPS_PROXY="$PROXY_URL"

sudo apt-get \
  -o Acquire::http::Proxy="${PROXY_URL}/" \
  -o Acquire::https::Proxy="${PROXY_URL}/" \
  update

sudo apt-get \
  -o Acquire::http::Proxy="${PROXY_URL}/" \
  -o Acquire::https::Proxy="${PROXY_URL}/" \
  install -y git curl ca-certificates python3

git -c http.proxy="$PROXY_URL" \
    -c https.proxy="$PROXY_URL" \
    clone https://github.com/suyi-92/vmware-ubuntu-bootstrap.git vmware-ubuntu-bootstrap

cd vmware-ubuntu-bootstrap
sudo --preserve-env=http_proxy,https_proxy,HTTP_PROXY,HTTPS_PROXY \
  bash install.sh
```

推荐使用“克隆、检查、再执行”的方式。远程 `curl | sudo bash` 只有在项目发布固定版本、提供校验值并完成安全评审后才考虑提供；首版不把未经检查的远程主分支直接管道给 root shell。

## 6. 当前仓库结构

```text
vmware-ubuntu-bootstrap/
├── README.md
├── .github/workflows/ci.yml
├── .gitattributes
├── .gitignore
├── install.sh
├── bootstrap.sh
├── config.example.env
├── .gitignore
├── scripts/
│   ├── 00-lib.sh
│   ├── 01-preflight.sh
│   ├── 02-proxy.sh
│   ├── 03-packages.sh
│   ├── 04-static-network.sh
│   ├── 05-power-policy.sh
│   ├── 06-ssh.sh
│   ├── 07-codex.sh
│   ├── 08-validate.sh
│   ├── 09-status.sh
│   ├── 10-rollback.sh
│   ├── proxy_scan.py
│   ├── cpa_client.py
│   ├── render_codex_config.py
│   └── secret_guard.py
├── templates/
│   ├── apt-proxy.conf.tpl
│   ├── systemd-proxy.conf.tpl
│   ├── sshd-local.conf.tpl
│   └── codex-cpa.config.toml.tpl
├── docs/
│   ├── install-flow.md
│   ├── recovery.md
│   └── verification.md
└── tests/
    ├── run.sh
    ├── test_backup_rollback.sh
    ├── test_status_read_only.sh
    ├── test_preflight_dry_run.sh
    ├── test_input_validation.sh
    ├── test_proxy_detection.py
    ├── test_cpa_client.py
    └── test_config_rendering.py
```

Shell 脚本统一使用 LF。Windows 上的 Git 应通过 `.gitattributes` 固定 `*.sh text eol=lf`。

## 7. 交互输入合同

交互方式参考 `reality-relay-bootstrap/install.sh`，但只复用其输入模式，不复用其业务配置：

1. 从 `/dev/tty` 读取，确保脚本从管道启动时仍能交互；没有交互终端则停止。
2. 普通值显示默认值，直接回车接受。
3. API key 使用关闭回显的敏感输入，不在确认摘要中显示。
4. 布尔值统一使用 `Y/n` 或 `y/N`，非法输入循环询问。
5. 所有输入先校验，再写入配置。
6. 再次运行时读取上一次非敏感配置作为默认值，不自动重置密钥。
7. 应用前输出脱敏摘要并要求最终确认。
8. 支持 `--config config.env`、`--dry-run`、`--verbose` 和分阶段运行。
9. `--yes` 不能跳过固定 IP、SSH 锁机风险和秘密存储失败等高风险确认。

计划输入如下：

| 配置项 | 默认值 | 校验与说明 |
| --- | --- | --- |
| `TARGET_USER` | `SUDO_USER` | 必须是现有非 root 用户 |
| `NETWORK_INTERFACE` | 当前默认路由接口 | 必须为已连接的桥接网卡 |
| `PROXY_SCAN_CIDR` | 当前 IPv4 所在 `/24` | 首版只扫描当前 `/24`，不扫其他网段 |
| `PROXY_PORT` | `7890` | 范围 `1–65535` |
| `STATIC_IPV4_PREFIX` | `192.168.1` | 首版固定前三段 |
| `STATIC_IPV4_LAST_OCTET` | `254` | 仅允许 `2–254`，并执行冲突检测 |
| `PREFIX_LENGTH` | `24` | 首版固定 |
| `GATEWAY_IPV4` | 当前默认网关 | 必须与静态地址同网段且不能相同 |
| `DNS_SERVERS` | 当前连接的 DNS | 至少一个合法地址 |
| `HOSTNAME` | 当前主机名 | 可选修改，需符合 hostname 规则 |
| `TIMEZONE` | `Asia/Shanghai` | 用户可修改 |
| `SSH_PORT` | `22` | 范围 `1–65535`，检查端口占用 |
| `ADMIN_PUBKEYS` | 已有 key；否则必填 | 支持一行一个 OpenSSH 公钥，去重并验证 |
| `ENABLE_UFW` | `false` | 首版默认不开启 |
| `DISABLE_SSH_PASSWORD` | `false` | 必须先完成第二终端公钥登录验证 |
| `CPA_BASE_URL` | 无 | 必须以 `/v1` 结束，例如 `https://cpa.example.com/v1` |
| `CPA_MODEL_ID` | 从 `/v1/models` 选择 | 不能凭空猜测模型名 |
| `CPA_API_KEY` | 无 | 必填、静默输入、不得输出 |
| `INSTALL_DOCKER` | `false` | 可选扩展，首版默认不安装 |

交互示例：

```text
目标用户 [suyi]:
代理端口 [7890]:
固定 IPv4 末位 [254]:
默认网关 [192.168.1.1]:
SSH 端口 [22]:
是否开启 UFW [y/N]:
CPA /v1 地址:
CPA 模型 ID:
CPA API key:                 # 不回显
```

## 8. 执行阶段

### 8.1 `preflight`

- 要求 Ubuntu 24.04，拒绝未经支持的发行版。
- 确认以 root 权限运行，同时解析真实登录用户及其 home。
- 检查桥接接口、当前 IPv4、默认路由、DNS、磁盘空间和时间。
- 检查 `/dev/tty`、`systemd`、`apt`、`ip`、`curl`、`python3` 等基础能力。
- 创建状态、日志和备份目录；任何写操作前先验证这些目录可用。
- 若检测到当前会话来自 SSH，默认禁止立即修改 IP；只有显式确认并建立回滚点后才允许。

### 8.2 `proxy`

自动发现逻辑：

1. 根据默认路由接口确定当前 IPv4 和 `/24` 网段。
2. 并发检测该网段的 TCP `7890`，排除虚拟机自身地址。
3. 对开放端口执行真正的 HTTP 代理验证，而不是仅依据端口开放。
4. Docker Registry 返回 `200` 或预期的 `401` 均可作为代理通路证据；同时测试 GitHub HTTPS。
5. 找到一个有效代理时采用；找到多个时列出并让用户选择；一个都没有时停止。

持久化矩阵：

| 消费方 | 管理位置 | 验证 |
| --- | --- | --- |
| 登录 shell | `/etc/environment`、受管的 `/etc/profile.d/` 文件 | 新 shell 中读取环境变量 |
| sudo | `/etc/sudoers.d/` 的最小 `env_keep`，写入前后运行 `visudo -cf` | `sudo --preserve-env ... env` |
| APT | `/etc/apt/apt.conf.d/95-vmware-ubuntu-bootstrap-proxy` | `apt-get update` |
| Git system | `git config --system` | `git config --show-origin --get http.proxy` |
| Git user/root | 各自 `git config --global` | 分别以用户和 root 查询 HTTP/HTTPS proxy |
| curl/wget | 环境变量；wget 使用受管配置时单独备份 | 普通用户和 `sudo` 各做一次 HTTPS 请求 |
| Docker daemon | systemd drop-in | `systemctl show docker -p Environment` |
| Docker client/build | 用户及 root 的 Docker JSON 合并 | JSON 解析和 `docker info` |
| Snap | `snap set system proxy.*` | `snap get system proxy` |
| systemd 服务 | 受管的 `DefaultEnvironment` drop-in | `systemctl show-environment` 或目标服务验证 |

`NO_PROXY` 至少包含本机、回环、当前局域网和 `.local`；同时加入 CPA 的局域网地址。不同程序对 CIDR 的支持不一致，因此关键主机地址要同时以精确值写入并逐项验证。

代理状态至少提供：

```bash
sudo bash install.sh --phase proxy
sudo bash install.sh --phase proxy-status
sudo bash install.sh --phase proxy-off
```

换 Wi-Fi 或 Windows IP 后，重新执行 `proxy` 即可。`proxy-off` 只能移除本项目管理的配置，不能删除其他程序已有的代理项。

### 8.3 `packages`

默认安装：

```text
git curl wget ca-certificates openssh-server
open-vm-tools open-vm-tools-desktop
jq python3 python3-venv python3-pip pipx
build-essential pkg-config
unzip zip tar rsync
gnupg lsb-release software-properties-common
iproute2 iputils-ping iputils-arping dnsutils traceroute
net-tools ethtool
vim nano tmux htop tree ripgrep fd-find git-lfs bash-completion shellcheck ufw
```

要求：

- 使用 `DEBIAN_FRONTEND=noninteractive`。
- 默认只执行 `apt-get update` 和安装缺失包，不自动进行发行版升级。
- 成功后启用并验证 `open-vm-tools`、SSH 和时间同步。
- 包安装失败时只显示相关日志尾部，完整日志保存在受保护目录。

### 8.4 `static-network`

- 识别当前使用 NetworkManager 还是 systemd-networkd/netplan，不同时修改两套权威配置。
- 完整备份当前连接和 netplan 文件，并记录文件哈希。
- 校验地址、网关、DNS、接口和地址冲突。
- NetworkManager 使用 checkpoint/自动恢复机制；netplan 路径先运行 `netplan generate`，再使用带超时回滚的 `netplan try`。
- IP 切换后重新验证默认路由、DNS、Windows 代理和公网 HTTPS。
- 用户未确认新网络有效时自动恢复旧配置。
- 完成重启验证前，不删除网络备份。

### 8.5 `power-policy`

以真实桌面用户及其 DBus 会话执行 GNOME 设置：

```bash
gsettings set org.gnome.desktop.session idle-delay 0
gsettings set org.gnome.desktop.screensaver lock-enabled false
gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type 'nothing'
```

系统级禁用：

```bash
systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target
```

如果系统没有 GNOME，会明确跳过 GNOME 项而不是失败或伪造成功。恢复阶段必须能还原修改前的 gsettings 值并解除本项目添加的 mask。

### 8.6 `ssh`

1. 安装并启用 `openssh-server`。
2. 把用户粘贴的公钥追加到目标普通用户的 `~/.ssh/authorized_keys`，去重并设置 `0700/0600` 权限。
3. 通过 `ssh-keygen -lf` 验证每个公钥格式。
4. 使用独立 `/etc/ssh/sshd_config.d/` drop-in，不直接重写完整 `sshd_config`。
5. 应用前执行 `sshd -t`；失败则恢复。
6. 自动识别 Ubuntu 24.04 的 `ssh.socket` activation；保留当前 socket/service 模式，并在修改端口后重载对应 unit。
7. 不开启 root SSH。
8. 默认保留密码登录，提示用户从 Windows 新开终端验证：

```powershell
ssh suyi@192.168.1.254
```

只有用户明确确认公钥登录成功，才允许可选地关闭密码认证。

UFW 默认关闭。若用户选择开启，则必须先添加局域网 SSH 放行规则、显示规则预览、验证 `sshd` 正常，再启用：

```text
allow from 192.168.1.0/24 to any port 22 proto tcp
```

实际规则使用用户选择的 SSH 端口。

### 8.7 `codex`

Codex CLI 安装采用 OpenAI 官方 Linux 安装入口：

```bash
curl -fsSL https://chatgpt.com/codex/install.sh | sh
```

脚本运行时沿用已经验证的代理，并在安装后执行 `codex --version`。npm 安装只作为官方支持的备用方式，不为了安装 Codex 强制引入 Node.js。

CPA Provider 的目标配置为：

```toml
model = "<CPA_MODEL_ID>"
model_provider = "cpa"

[model_providers.cpa]
name = "CPA"
base_url = "<CPA_BASE_URL_WITH_V1>"
wire_api = "responses"

[model_providers.cpa.auth]
command = "/home/<TARGET_USER>/.local/libexec/codex-cpa-token"
timeout_ms = 1000
refresh_interval_ms = 0
```

安全要求：

- Provider 配置写入用户级 `~/.codex/config.toml`；项目级 `.codex/config.toml` 不接受 `model_provider` / `model_providers` 等认证重定向设置。
- 新机器可写入受管的用户主配置；若检测到用户已有 `~/.codex/config.toml`，则保留原文件，只创建 `~/.codex/cpa.config.toml` 和 `codex-cpa` 入口，不做不可靠的文本拼接。
- API key 静默输入，保存到 `~/.config/vmware-ubuntu-bootstrap/secrets/cpa-api-key`，目录 `0700`、文件 `0600`。
- `codex-cpa-token` 只读取该文件并把 token 输出给 Codex；API key 不写入 TOML、Git、日志、进程命令行或普通环境变量。
- 如果改用 `env_key`，只作为显式兼容模式；不得把 key 明文写入仓库。
- CPA URL 默认要求 HTTPS。只有 `localhost`、回环或明确确认的私有局域网地址才允许 HTTP，并显示 bearer token 明文传输风险。

兼容性门槛：

1. `GET <CPA_BASE_URL>/models` 能认证并返回可选模型；
2. 用户选择的模型真实存在；
3. CPA 必须支持 Responses API，即 `<CPA_BASE_URL>/responses`；当前 Codex 自定义 Provider 的 `wire_api` 只支持 `responses`；
4. 经用户确认后发送一次最小请求验证响应结构；该请求可能产生少量 API 费用；
5. 再执行一次最小 `codex exec` 冒烟验证。

若 CPA 只有 Chat Completions 而没有 Responses API，Codex 阶段必须停止并报告 CPA 兼容性缺口，不能改写成未经官方支持的配置后宣称成功。

相关 OpenAI 官方文档：

- [Codex CLI](https://developers.openai.com/codex/cli)
- [Codex Advanced Configuration](https://developers.openai.com/codex/config-advanced)
- [Codex Configuration Reference](https://developers.openai.com/codex/config-reference)

### 8.8 `validate`

最终验证矩阵：

| 类别 | 必须验证的结果 |
| --- | --- |
| OS | Ubuntu 24.04、时间同步、磁盘空间正常 |
| VMware | `open-vm-tools` active |
| 网络 | 固定地址、默认路由、DNS、重启后仍生效 |
| 代理 | 普通 `curl`、`sudo curl`、用户 Git、root Git、APT 均成功 |
| Docker | 仅在已安装时验证 daemon/client 代理和一次拉取 |
| 电源 | GNOME 三项值正确，四个 systemd target 为 masked |
| SSH | `sshd -t`、服务 active、Windows 公钥登录已人工确认 |
| Codex | CLI 版本、TOML 解析、凭据权限、CPA Responses、最小 Codex 请求 |
| 敏感信息 | 日志和 Git 工作树中不存在 API key、私钥或真实凭据 |

完整成功必须经过一次 Ubuntu 重启后的复验。脚本可以输出“需要重启”，但在重启复验前状态只能是 `configured-pending-reboot`，不能是 `complete`。

## 9. 状态、备份和回滚

计划目录：

```text
/etc/vmware-ubuntu-bootstrap/          # 系统配置与非秘密状态
/var/lib/vmware-ubuntu-bootstrap/      # 阶段状态
/var/log/vmware-ubuntu-bootstrap/      # 脱敏日志
/var/backups/vmware-ubuntu-bootstrap/  # 按时间戳保存的修改前快照
~/.config/vmware-ubuntu-bootstrap/     # 用户配置和 0600 凭据
```

每一阶段必须：

1. 在任何覆盖前保存原文件、权限、所有者和 SHA-256；
2. 写入 manifest，注明阶段、时间、目标用户和变更路径；
3. 使用临时文件 + 原子替换；
4. 只管理带项目标识的 drop-in 或精确配置键；
5. 验证成功后写阶段状态；
6. 失败时自动恢复本阶段，保留诊断日志；
7. 不把 API key、Authorization header 或完整秘密响应写入日志。

提供：

```bash
sudo bash install.sh --status
sudo bash install.sh --rollback-last
sudo bash install.sh --rollback <backup-id>
sudo bash install.sh --dry-run
```

网络回滚优先级最高；SSH 回滚不得关闭当前仍可用的连接。

## 10. 明确停止条件

遇到下列任一情况必须停止：

- 没有代理、发现多个代理但用户未选择，或端口开放但代理验证失败；
- 输入 `.0`、`.1`（若为网关）、`.255`、已占用地址或无法排除 DHCP 冲突；
- 无法识别权威网络配置、无法备份、无法建立自动回滚点；
- 当前仅通过 SSH 操作且用户未授权网络中断；
- 公钥非法、`sshd -t` 失败或第二终端尚未确认时要求关闭密码登录；
- UFW 开启前没有有效 SSH 放行规则；
- 现有 Git/Codex/TOML/Docker 配置无法安全合并；
- 无法以 `0600` 保存 CPA key，或日志脱敏检查失败；
- CPA URL、模型或认证失败；
- CPA 不支持 `/v1/responses`；
- 重启后固定网络、代理、SSH 或 Codex 任一关键门槛失效。

不得使用删除用户配置、覆盖整个配置文件、`git reset --hard`、关闭安全校验或谎报成功来绕过停止条件。

## 11. Git 与秘密管理

未来 `.gitignore` 至少包含：

```gitignore
config.env
config.local.env
.env
secrets/
*.key
*.token
*.log
backups/
state/
artifacts/local/
```

提交前检查：

- `git status --short`
- `git diff --check`
- Shell 语法和 `shellcheck`
- 输入校验与配置渲染测试
- API key、Bearer、私钥头和常见 token 模式扫描
- 确认示例只包含占位符，不包含真实 IP 之外的个人配置和凭据

Git 私有仓库也不是加密存储，真实 CPA API key 和私钥永远不提交。

## 12. 实现与验收顺序

建议按以下顺序实现，避免一次编写巨大脚本后再排查：

1. 交互库、配置文件、脱敏日志、备份和 `--dry-run`。
2. 代理发现、持久化、状态和关闭；先在临时 Ubuntu VM 验证。
3. 基础包与 VMware tools。
4. 固定网络，必须先完成自动回滚测试。
5. 电源策略。
6. SSH 公钥与可选 UFW，必须通过双终端锁机测试。
7. Codex 安装、CPA 凭据 helper、TOML 合并与 Responses 验证。
8. 全量 `validate`、重启复验和回滚演练。
9. 在 VMware 快照克隆上至少完成一次从全新 Ubuntu 到 `complete` 的 canary。
10. 通过后再发布 Git 远端和固定版本安装方式。

首个可发布版本的验收标准是：同一台干净 VM 连续运行两次不产生破坏性变化；第二次只报告已满足或更新明确的受管项；执行回滚后可恢复网络、SSH、代理和 Codex 修改前状态。
