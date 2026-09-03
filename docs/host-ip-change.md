# 宿主机 IP 变更处理

本项目使用桥接网卡。Windows 宿主机的 IPv4 变化，不等于 Ubuntu 虚拟机的 SSH 地址一定变化：

- 宿主机仍在 `192.168.1.0/24`，只是 DHCP 分配的末位变化时，Ubuntu 的固定地址通常保持不变；如果 Ubuntu 通过 Windows 的 `7890` 端口上网，只需更新代理地址。
- 宿主机切换到了另一个局域网时，Ubuntu 的地址、网关、DNS、代理扫描网段和 UFW 来源网段都可能需要调整。
- 当前版本只支持为 Ubuntu 配置 `192.168.1.0/24` 固定地址。新局域网不是这个网段时，不要把其他前缀直接写入 `STATIC_IPV4_PREFIX`；校验会拒绝该配置。先使用 DHCP，待项目正式支持任意网段后再恢复受管固定地址。

不要逐个手改 `/etc/environment`、APT、Git、Docker、Snap 或 systemd 的代理文件。修改项目的 `config.env` 后重跑对应阶段，脚本会统一更新这些受管位置并留下回滚快照。

## 1. 记录 Windows 当前网络

在 Windows PowerShell 中执行：

```powershell
Get-NetIPConfiguration |
    Where-Object { $_.NetAdapter.Status -eq 'Up' -and $_.IPv4DefaultGateway -ne $null } |
    Select-Object InterfaceAlias,
        @{Name='IPv4'; Expression={$_.IPv4Address.IPAddress}},
        @{Name='Gateway'; Expression={$_.IPv4DefaultGateway.NextHop}},
        @{Name='PrefixLength'; Expression={$_.IPv4Address.PrefixLength}}
```

选择 VMware 实际桥接的 `Wi-Fi` 或 `Ethernet`。同时确认代理软件仍满足：

- `Allow LAN` 已开启；
- HTTP/Mixed 端口仍为 `7890`，或记录新的端口；
- Windows 防火墙允许 Ubuntu 所在局域网访问该端口。

下文以宿主机新地址 `192.168.1.120`、代理端口 `7890` 为例。

## 2. 仅宿主机末位变化，局域网仍为 `192.168.1.0/24`

Ubuntu 固定地址、网关和 SSH 目标地址不需要跟着宿主机修改。先登录 Ubuntu；如果安装时采用默认值，SSH 目标仍是 Ubuntu 自己的 `192.168.1.254`，不是 Windows 的新地址：

```powershell
ssh -p 22 suyi@192.168.1.254
```

旧代理地址可能已经让 Git 无法访问 GitHub，因此先用本地已有脚本修复代理，再执行 `git pull`。

### 2.1 备份并修改配置

```bash
cd ~/vmware-ubuntu-bootstrap
sudo install -d -m 0700 /var/backups/vmware-ubuntu-bootstrap/manual
sudo cp -a config.env "/var/backups/vmware-ubuntu-bootstrap/manual/config.env.before-host-ip-change-$(date +%Y%m%d-%H%M%S)"
sudoedit config.env
```

修改以下值：

```dotenv
PROXY_HOST="192.168.1.120"
PROXY_PORT="7890"
PROXY_SCAN_CIDR="192.168.1.0/24"
```

推荐明确填写 `PROXY_HOST`，结果最可控。也可以设为 `PROXY_HOST=""` 让脚本扫描 `PROXY_SCAN_CIDR`；扫描到多个可用代理时必须人工选择。

不要修改这些仍然有效的网络项：

```dotenv
STATIC_IPV4_PREFIX="192.168.1"
STATIC_IPV4_LAST_OCTET="254"
PREFIX_LENGTH="24"
GATEWAY_IPV4="192.168.1.1"
```

实际末位、网关和 DNS 以原配置及当前局域网为准。

### 2.2 预检、应用和验收

先从 Ubuntu 直接验证新代理确实可用：

```bash
curl -I --proxy http://192.168.1.120:7890 \
  --connect-timeout 3 --max-time 10 https://github.com/
sudo bash install.sh --phase proxy --dry-run
```

两步成功后再应用：

```bash
sudo bash install.sh --phase proxy
sudo bash install.sh --phase proxy-status
```

`proxy` 阶段会更新普通用户、root、sudo、APT、Git、Docker、Snap 和 systemd 使用的代理；Docker 正在运行时会被重启。现有登录 shell 仍可能保留旧环境变量，退出并重新建立 SSH 会话后再验收：

```bash
cd ~/vmware-ubuntu-bootstrap
git pull --ff-only origin main
sudo bash install.sh --phase validate
sudo bash install.sh --status
```

如果不再使用 Windows 代理，执行 `sudo bash install.sh --phase proxy-off`，不要只删除某一个代理文件。

### 2.3 新宿主机地址与 Ubuntu 固定地址冲突

如果 Windows 恰好取得了 Ubuntu 正在使用的固定地址，局域网会出现地址冲突。不要继续通过 SSH 修改；在 VMware 控制台打开 Ubuntu，先在 `config.env` 中选择一个不在 DHCP 池且未被占用的末位，例如：

```dotenv
STATIC_IPV4_LAST_OCTET="253"
```

然后从控制台预检并应用。脚本会先用 ARP 检查目标地址，随后通过 `netplan try` 提供 120 秒确认窗口：

```bash
cd ~/vmware-ubuntu-bootstrap
sudo bash install.sh --phase static-network --dry-run
sudo bash install.sh --phase static-network
```

确认网络后，改用 Ubuntu 的新固定地址登录，再按 2.2 节更新代理。长期使用时，应在路由器中为宿主机和 Ubuntu 建立 DHCP 保留，或把 Ubuntu 固定地址放在 DHCP 动态池之外。

## 3. 宿主机切换到其他局域网

例如 Windows 从 `192.168.1.120/24` 变为 `192.168.50.20/24` 时，Ubuntu 原固定地址通常已经无法通过 SSH 访问。使用 VMware 控制台操作，避免在远程 SSH 中直接切换网络。

### 3.1 先恢复 Ubuntu DHCP

在 VMware 控制台登录 Ubuntu，移除本项目生成的固定 Netplan 文件并应用原有网络配置：

```bash
sudo install -d -m 0700 /var/backups/vmware-ubuntu-bootstrap/manual
sudo cp -a /etc/netplan/90-vmware-ubuntu-bootstrap-static.yaml \
  "/var/backups/vmware-ubuntu-bootstrap/manual/90-vmware-ubuntu-bootstrap-static.before-lan-change-$(date +%Y%m%d-%H%M%S).yaml"
sudo rm -f /etc/netplan/90-vmware-ubuntu-bootstrap-static.yaml
sudo netplan generate
sudo netplan apply
ip -4 address
ip -4 route
```

记录 DHCP 分配给 Ubuntu 的新地址。若没有立即取得地址，重启 Ubuntu 后再次检查；后续从 Windows SSH 到这个 Ubuntu 地址。

### 3.2 更新项目配置

按 2.1 节先备份 `config.env`，然后按实际网络修改：

```dotenv
PROXY_HOST="192.168.50.20"
PROXY_PORT="7890"
PROXY_SCAN_CIDR="192.168.50.0/24"
CONFIGURE_STATIC_NETWORK="false"
GATEWAY_IPV4="192.168.50.1"
DNS_SERVERS="192.168.50.1"
```

保持下面两项不变，因为当前配置校验仍要求 `192.168.1.0/24`；`CONFIGURE_STATIC_NETWORK="false"` 时它们不会被应用：

```dotenv
STATIC_IPV4_PREFIX="192.168.1"
PREFIX_LENGTH="24"
```

然后验证并重写代理：

```bash
curl -I --proxy http://192.168.50.20:7890 \
  --connect-timeout 3 --max-time 10 https://github.com/
sudo bash install.sh --phase proxy --dry-run
sudo bash install.sh --phase proxy
```

### 3.3 更新 UFW 来源网段

如果 UFW 已启用，先用新 `PROXY_SCAN_CIDR` 重跑 SSH 阶段，确保新网段的规则已经加入：

```bash
sudo bash install.sh --phase ssh
sudo ufw status numbered
```

确认新网段可以登录后，再按编号删除仍允许旧网段 `192.168.1.0/24` 的 `vmware-ubuntu-bootstrap ssh` 规则。每删除一条后重新运行 `sudo ufw status numbered`，避免编号变化导致误删：

```bash
old_rule_number=3  # 替换为刚才列表中的实际编号
sudo ufw delete "$old_rule_number"
```

### 3.4 最终验收

退出 VMware 控制台或旧 SSH 会话，从 Windows 使用 Ubuntu 的新 DHCP 地址重新登录，然后执行：

```bash
cd ~/vmware-ubuntu-bootstrap
git pull --ff-only origin main
sudo bash install.sh --phase proxy-status
sudo bash install.sh --phase validate
sudo bash install.sh --status
```

验收应至少确认：Ubuntu 地址和默认路由属于新局域网、代理状态显示宿主机新地址、GitHub 可访问、SSH 可从 Windows 登录；启用 Docker 时还应确认 Docker daemon 使用新代理。

## 4. 失败时回退

- 新代理无法通过预检时，不要继续应用；检查宿主机地址、`Allow LAN`、端口和 Windows 防火墙。
- `proxy` 或 `ssh` 阶段写入后出现问题，可执行 `sudo bash install.sh --rollback-last` 回滚最近一次受管修改。
- Ubuntu 因固定网络失联时，在 VMware 控制台按 3.1 节恢复 DHCP；不要在失联状态下反复猜测网关或 DNS。
- 需要在 `192.168.1.0/24` 以外继续使用受管固定 IP 时，应先扩展项目的网络参数与测试；当前版本使用 DHCP 是可验证且受支持的临时方案。
