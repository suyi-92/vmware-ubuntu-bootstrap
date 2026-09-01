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

本地安装器会在交互前完成最小启动依赖检查。完整配置时先建立代理，再只安装其余缺失的常用包、Docker 和编译工具链；Docker 默认为安装。

安装器从 `/dev/tty` 逐项读取配置。冒号后的普通值可直接回车采用，也可以编辑后确认；CPA API key 只显示 `*` 掩码，真实字符不回显。Windows SSH 公钥必须粘贴 `.pub` 内容，不得粘贴私钥。首次安装保持“关闭 SSH 密码登录”为 `N`，确认 Windows 公钥可以从另一终端登录后再改为 `Y`。公网 CPA `/v1` 地址必须使用 HTTPS。输入 key 后会请求 `/v1/models`：单模型自动采用，多模型按编号选择，已有模型作为默认项。

## 4. 从 SSH 安装时的固定网络处理

通过 SSH 运行完整安装时，脚本会先检查目标固定地址是否冲突，写入并校验 Netplan，然后把网络阶段标记为 `pending-reboot`。它不会在当前会话中执行 `netplan apply`，因此当前 DHCP SSH 连接不会中断，后续软件包、VMware Tools、SSH 和 Codex 阶段可以继续完成。

其余阶段完成后直接在当前 SSH 会话执行：

```bash
sudo reboot
```

连接会正常断开。虚拟机启动后，从 Windows 使用安装器显示的固定地址重新 SSH 登录。无需回 VMware 控制台再次运行安装器。只有直接从 VMware 控制台运行 `static-network` 阶段时，脚本才会用 `netplan try --timeout 120` 立即切换；未确认时自动回滚。

## 5. 分阶段运行

```bash
cd ~/vmware-ubuntu-bootstrap
sudo bash install.sh --phase dependencies
sudo bash install.sh --phase preflight
sudo bash install.sh --phase proxy
sudo bash install.sh --phase packages
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

SSH 中写入固定网络但尚未重启时状态为 `configured-pending-reboot`；只有重启后固定地址生效且所有检查通过，状态才会成为 `complete`。Codex/CPA 安装完成后直接运行标准命令 `codex`。
