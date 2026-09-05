# 安装流程

## 1. 准备 VMware 与 Windows

1. 在 VMware Workstation 中安装 Ubuntu 24.04 Desktop，并将网卡设置为桥接模式。
2. 在 `VM > Settings > Options > Guest Isolation` 中允许复制粘贴。
3. Windows 代理软件开启 `Allow LAN`，提供 `7890` HTTP/Mixed 端口，并允许局域网防火墙访问。
4. 在 Windows PowerShell 中准备 SSH 公钥：

```powershell
if (!(Test-Path "$env:USERPROFILE\.ssh\id_ed25519")) {
    ssh-keygen -t ed25519
}
Get-Content "$env:USERPROFILE\.ssh\id_ed25519.pub"
```

查看 Windows 当前联网网卡的局域网 IPv4：

```powershell
Get-NetIPConfiguration |
    Where-Object { $_.NetAdapter.Status -eq 'Up' -and $_.IPv4DefaultGateway -ne $null } |
    Select-Object InterfaceAlias, @{Name='IPv4'; Expression={$_.IPv4Address.IPAddress}}
```

多条结果中选择与 Ubuntu 桥接地址同网段的 `Wi-Fi` 或 `Ethernet` 地址，并把它用于后续 `PROXY_URL`。

## 2. 在 Ubuntu 控制台开启临时 SSH

新系统尚不能和 Windows 复制粘贴，只在 VMware 控制台输入以下短命令：

```bash
hostname -I
sudo apt-get update
sudo apt-get install -y openssh-server
sudo systemctl enable --now ssh
```

记录 `hostname -I` 显示的地址，然后从 Windows PowerShell 连接：

```powershell
ssh suyi@192.168.1.106
```

替换为实际 Ubuntu 用户和 DHCP 地址，首次连接使用 Ubuntu 用户密码。

## 3. 从 PowerShell SSH 会话一键运行

如果访问 GitHub 需要 Windows 代理，先在 SSH 会话中设置：

```bash
PROXY_URL="http://192.168.1.100:7890"
export http_proxy="$PROXY_URL" https_proxy="$PROXY_URL"
export HTTP_PROXY="$PROXY_URL" HTTPS_PROXY="$PROXY_URL"
export all_proxy="$PROXY_URL" ALL_PROXY="$PROXY_URL"
```

执行远程入口：

```bash
bash <(wget -qO- https://raw.githubusercontent.com/suyi-92/vmware-ubuntu-bootstrap/main/install.sh)
```

不要给这条命令添加 `sudo`。入口会安装缺失的 Git、curl、Python、证书和网络基础命令，将仓库准备到 `~/vmware-ubuntu-bootstrap`，然后由本地安装器自行提权。

安装器会询问是否为目标用户开启免密 sudo，默认 `Y`。首次启动仍需输入一次 Ubuntu 用户密码；只有 `sudo-policy` 阶段成功写入并通过 `visudo` 校验后，后续运行才不再询问密码。

本地安装器会在交互前完成最小启动依赖检查。完整配置时先建立代理，再校验密钥指纹并配置 GitHub CLI、Git/Git LFS、Kitware CMake 和 Docker（如启用）软件源，更新索引、升级已安装的 APT 包，并安装包含 Node.js、npm、npx 与 node-gyp 的完整工具链。全新系统默认从官方源安装 Docker CE、Compose 和 Buildx；已有 rootful CE/docker.io 保留来源，参见 [兼容说明](compatibility.md)。输入法阶段默认通过 GitHub HTTPS 安装 Plum 与雾凇拼音，把 Rime 固定部署到 `~/.local/share/fcitx5/rime`，并把中州韵设为登录后直接激活的默认中文输入法。启用 Codex 时还会按 Ubuntu 24.04 的要求安装 bubblewrap/AppArmor、加载 `bwrap-userns-restrict` profile，并执行本地 sandbox 验证。

安装器从 `/dev/tty` 逐项读取配置。冒号后的普通值可直接回车采用，也可以编辑后确认；CPA API key 只显示 `*` 掩码，真实字符不回显。Windows SSH 公钥必须粘贴 `.pub` 内容，不得粘贴私钥。首次安装保持“关闭 SSH 密码登录”为 `N`，确认 Windows 公钥可以从另一终端登录后再改为 `Y`。公网 CPA `/v1` 地址必须使用 HTTPS。输入 key 后会请求 `/v1/models`：单模型自动采用，多模型按编号选择，已有模型作为默认项。

## 4. 网络默认保持与显式静态配置

新配置默认保持当前网络，记录实际管理网卡、IPv4/CIDR、网关、MAC，推荐在路由器按各 VM 独立 MAC 做 DHCP 地址保留。此阶段不会把 DHCP 租约转成静态，也不会将已有静态配置恢复为 DHCP。

只有明确启用 `CONFIGURE_STATIC_NETWORK=true` 时才输入完整 `STATIC_IPV4_CIDR`、所选管理接口的网关和 DNS。多默认路由需要明确选择物理以太网卡；不自动选择 Docker bridge、VPN 或蜂窝接口。配置与 ARP 检测不能被 `--yes` 跳过。

SSH 会话只备份和写盘，经 `netplan generate` 后记为 `pending-reboot`，显示当前地址、待生效地址和备份 ID。当前 SSH 不立即切换。记录恢复方法后由用户决定何时重启；重启后生效不含自动回滚保证。控制台使用 `netplan try --timeout 120`，真实应用并通过检查才记为 complete。完整旧配置、重复运行和回滚细节见 [兼容说明](compatibility.md) 及 [恢复说明](recovery.md)。

## 5. 分阶段运行

```bash
cd ~/vmware-ubuntu-bootstrap
sudo bash install.sh --phase dependencies
sudo bash install.sh --phase preflight
sudo bash install.sh --phase proxy
sudo bash install.sh --phase packages
sudo bash install.sh --phase input-method
sudo bash install.sh --phase sudo-policy
sudo bash install.sh --phase static-network
sudo bash install.sh --phase power
sudo bash install.sh --phase ssh
sudo bash install.sh --phase codex
sudo bash install.sh --phase validate
```

查看状态不会修改系统：

```bash
sudo bash install.sh --status
sudo bash install.sh --phase proxy-status
```

关闭本项目管理的代理：

```bash
sudo bash install.sh --phase proxy-off
```

## 6. 重启验收

```bash
sudo reboot
```

重启并重新登录后：

```bash
cd ~/vmware-ubuntu-bootstrap
sudo bash install.sh --phase validate
sudo bash install.sh --status
```

SSH 中写入固定网络但尚未重启时状态为 `configured-pending-reboot`；只有重启后固定地址生效且所有检查通过，状态才会成为 `complete`。重启后的图形会话会启动 Fcitx5，默认使用中州韵/雾凇拼音；不要在终端反复运行 `fcitx5 -rd`。Codex/CPA 安装完成后直接运行标准命令 `codex`。
