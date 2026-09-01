# VMware Ubuntu Bootstrap

用于初始化本地 VMware Workstation 中的 Ubuntu 24.04 Desktop。完成一次交互配置后，脚本会按阶段配置代理、常用软件、固定网络、电源策略、SSH、VMware 桌面集成以及 Codex/CPA，并提供状态检查和回滚入口。

建议先为新安装的虚拟机创建 VMware 快照，再运行本项目。

## 1. 主要功能

- 自动扫描当前局域网内可用的 `7890` HTTP/Mixed 代理。
- 为普通用户、root、sudo、APT、Git、Docker、Snap 和遵循代理环境变量的 systemd 服务配置代理。
- 配置桥接网卡固定 IPv4，应用前检查地址冲突，并通过 `netplan try` 提供超时回滚。
- 关闭 GNOME 息屏、锁屏、自动挂起，以及系统休眠相关 target。
- 安装并配置 OpenSSH Server、公钥登录、自定义端口和可选 UFW。
- 安装 `open-vm-tools`、`open-vm-tools-desktop`，支持 Windows 与 Ubuntu 桌面之间复制粘贴。
- 安装常用开发与诊断软件，可选安装 Docker。
- 安装 Codex CLI，并可配置指向 CPA `/v1` Responses API 的自定义 Provider。
- 保存分阶段状态、受保护日志和配置备份，支持检查与回滚。

`7890` HTTP/Mixed 代理只覆盖支持 HTTP/HTTPS 代理的程序，不等同于 TUN 或透明代理，不会接管 ICMP、任意 UDP 或不支持代理设置的程序。

## 2. 支持环境

- VMware Workstation
- Ubuntu 24.04 Desktop x86_64
- 一块桥接网卡
- 当前局域网不大于 `/24`
- Windows 代理软件提供可从局域网访问的 `7890` HTTP/Mixed 端口

当前固定网络配置面向 `192.168.1.0/24`：默认地址为 `192.168.1.254/24`，末位可在 `2–254` 范围内修改。`192.168.1.255` 是 `/24` 的广播地址，不能分配给虚拟机。

## 3. VMware 与 Windows 准备

建议的虚拟机配置：

```text
Guest OS: Ubuntu 24.04 x86_64
CPU: 4 核或以上
Memory: 8 GB 或以上
Disk: 80 GB 或以上
Network Adapter: Bridged
Options > Guest Isolation: Enable copy and paste
```

Windows 代理软件需要开启：

```text
Allow LAN: 开启
HTTP / Mixed Port: 7890
Windows 防火墙: 允许虚拟机所在局域网访问 7890
```

脚本不能修改 VMware Workstation 的 Guest Isolation 设置。复制粘贴需要宿主机允许该功能，并且 Ubuntu 已安装桌面版 VMware Tools。

## 4. 准备 Windows SSH 公钥

在 Windows PowerShell 中执行：

```powershell
if (!(Test-Path "$env:USERPROFILE\.ssh\id_ed25519")) {
    ssh-keygen -t ed25519
}
Get-Content "$env:USERPROFILE\.ssh\id_ed25519.pub"
```

安装器会要求输入这里显示的 `.pub` 公钥。不要把 `id_ed25519` 私钥复制到 Ubuntu、安装目录或 Git 仓库。

## 5. 新装 Ubuntu 后，先从 Windows PowerShell 连接

刚安装好的 Ubuntu 尚未具备 VMware 复制粘贴支持。为了避免在虚拟机控制台输入长命令，只需要先在 Ubuntu 控制台完成最短的 SSH 引导。

先在 Windows PowerShell 中查看当前联网网卡的局域网 IPv4：

```powershell
Get-NetIPConfiguration |
    Where-Object { $_.NetAdapter.Status -eq 'Up' -and $_.IPv4DefaultGateway -ne $null } |
    Select-Object InterfaceAlias, @{Name='IPv4'; Expression={$_.IPv4Address.IPAddress}}
```

如果输出多个地址，选择 `Wi-Fi` 或 `Ethernet` 中与 Ubuntu 桥接地址处于同一网段的地址。例如 Ubuntu 是 `192.168.1.106`，通常应选择同为 `192.168.1.*` 的 Windows 地址，后面将它作为代理主机地址。

在 Ubuntu 控制台执行：

```bash
hostname -I
sudo apt-get update
sudo apt-get install -y openssh-server
sudo systemctl enable --now ssh
```

记下 `hostname -I` 显示的桥接 IPv4，例如 `192.168.1.106`。然后在 Windows PowerShell 中连接：

```powershell
ssh suyi@192.168.1.106
```

将 `suyi` 和地址替换为实际 Ubuntu 用户及 IPv4。首次连接输入 `yes`，随后输入 Ubuntu 用户密码。

如果 GitHub 需要经过 Windows 主机代理，在已经建立的 SSH 会话中粘贴：

```bash
PROXY_URL="http://192.168.1.100:7890"
export http_proxy="$PROXY_URL" https_proxy="$PROXY_URL"
export HTTP_PROXY="$PROXY_URL" HTTPS_PROXY="$PROXY_URL"
```

将 `192.168.1.100` 替换为 Windows 主机当前的局域网地址。

### 一键运行

在 SSH 会话中执行：

```bash
bash <(wget -qO- https://raw.githubusercontent.com/suyi-92/vmware-ubuntu-bootstrap/main/install.sh)
```

远程入口会安装缺失的 Git，把仓库克隆或快进更新到 `~/vmware-ubuntu-bootstrap`，再启动仓库内的交互安装器。请以普通 Ubuntu 用户运行这条命令，不要在前面添加 `sudo`；安装器会在需要时自行提权。

通过 SSH 运行时，脚本会安全延后固定 IP 阶段，继续完成代理、软件包、桌面集成、SSH、Codex 等配置。之后回到 VMware 控制台执行：

```bash
cd ~/vmware-ubuntu-bootstrap
sudo bash install.sh --phase static-network
```

确认 `netplan try` 后，后续 SSH 应使用新的固定地址。

### 克隆后再运行

如果希望先检查源码：

```bash
git clone https://github.com/suyi-92/vmware-ubuntu-bootstrap.git
cd vmware-ubuntu-bootstrap
sudo --preserve-env=http_proxy,https_proxy,HTTP_PROXY,HTTPS_PROXY bash install.sh
```

## 6. 交互配置

直接按回车会采用显示的默认值。主要配置如下：

| 配置 | 默认值 | 说明 |
| --- | --- | --- |
| 代理主机 | 自动发现 | 扫描当前 `/24` 中真正可用的 `7890` 代理 |
| 固定 IPv4 | `192.168.1.254/24` | 应确保不在 DHCP 动态分配范围且未被占用 |
| SSH 端口 | `22` | 支持自定义端口 |
| Windows SSH 公钥 | 必填 | 写入目标用户的 `authorized_keys` |
| UFW | 不开启 | 已经处于 active 状态时仍会添加 SSH 放行规则 |
| SSH 密码登录 | 保留现状 | 只有确认公钥登录成功后才允许关闭 |
| Codex/CPA | 配置 | 可在交互中选择跳过 |
| Docker | 不安装 | 可在交互中选择安装 |

CPA API key 使用无回显输入，保存到用户目录下权限为 `600` 的凭据文件，不写入 TOML、日志或 Git。

## 7. SSH 配置结果

完整安装会：

1. 安装并启动 `openssh-server`。
2. 写入并校验 Windows 公钥，设置正确的 `.ssh` 和 `authorized_keys` 权限。
3. 启用公钥认证并禁止 root 远程登录。
4. 支持 Ubuntu 24.04 的 `ssh.socket` 和传统 `ssh.service`，包括自定义端口。
5. 默认保留密码登录；只有明确确认公钥登录成功后才关闭。
6. 在 UFW 已启用或用户选择启用时，添加当前局域网到 SSH 端口的放行规则。
7. 执行 `sshd -t`、监听端口和服务状态检查。

完成后可以直接从 Windows PowerShell 连接：

```powershell
ssh -p 22 suyi@192.168.1.254
```

请替换为安装时选择的端口、用户和最终 IPv4。如果固定网络阶段因 SSH 会话被延后，应先使用当前 DHCP 地址，完成控制台固定网络阶段后再切换到固定地址。

## 8. 完成安装与验证

首次完整执行后需要重启：

```bash
sudo reboot
```

重新登录后执行：

```bash
cd ~/vmware-ubuntu-bootstrap
sudo bash install.sh --phase validate
sudo bash install.sh --status
```

只有固定网络不再处于延后状态，并且重启后的全部检查通过，最终状态才会成为 `complete`。

## 9. 常用命令

```bash
# 完整交互安装
sudo bash install.sh

# 只读状态
sudo bash install.sh --status
sudo bash install.sh --phase proxy-status

# 重新检测并配置代理
sudo bash install.sh --phase proxy

# 关闭本项目管理的代理
sudo bash install.sh --phase proxy-off

# 单独执行阶段
sudo bash install.sh --phase packages
sudo bash install.sh --phase static-network
sudo bash install.sh --phase power
sudo bash install.sh --phase ssh
sudo bash install.sh --phase codex
sudo bash install.sh --phase validate

# 预览，不修改系统
sudo bash install.sh --dry-run

# 回滚最近一次受管修改
sudo bash install.sh --rollback-last
```

## 10. 复制粘贴验证

重启并登录 Ubuntu 图形桌面后执行：

```bash
dpkg-query -W open-vm-tools open-vm-tools-desktop
systemctl is-active open-vm-tools
pgrep -a -u "$USER" -x vmtoolsd | grep -- '-n vmusr'
```

然后分别测试 Windows 到 Ubuntu、Ubuntu 到 Windows。如果 Guest Isolation 已启用但 Wayland 会话仍无法交互，可在 Ubuntu 登录界面选择 `Ubuntu on Xorg` 后复验。

## 11. 状态、日志与恢复

```text
/etc/vmware-ubuntu-bootstrap/           系统配置与非秘密状态
/var/lib/vmware-ubuntu-bootstrap/       阶段状态
/var/log/vmware-ubuntu-bootstrap/       脱敏日志
/var/backups/vmware-ubuntu-bootstrap/   修改前备份
~/.config/vmware-ubuntu-bootstrap/      用户配置与 CPA 凭据
```

网络变更使用 `netplan try --timeout 120`。未确认时应自动回滚；如果仍失去网络，请在 VMware 控制台按照 [`docs/recovery.md`](docs/recovery.md) 恢复。

## 12. 文档与测试

- [安装流程](docs/install-flow.md)
- [验证清单](docs/verification.md)
- [恢复说明](docs/recovery.md)

开发检查：

```bash
bash tests/run.sh
```

Shell 脚本统一使用 LF。真实 API key、SSH 私钥、运行日志、`config.env` 和备份文件均不得提交到仓库。
