# 宿主机 IP 或局域网变化

Windows 代理主机的地址变化不等于 Ubuntu VM 地址变化。VMware 桥接下，宿主机与每台 VM 都应有独立地址。不要使用旧文档中的 `.254` 作为默认 SSH 目标；先在 VMware 控制台查看实际地址，或查阅路由器按各 VM 独立 MAC 配置的 DHCP 保留。

## 每次切换 Wi-Fi 后的快捷命令

将包含 `refresh-network.sh` 的项目保留在 Ubuntu 本地。切换 Wi-Fi 后无需先联网拉取代码或重跑安装器，在 Ubuntu 执行：

```bash
cd ~/vmware-ubuntu-bootstrap
sudo bash refresh-network.sh
source /etc/profile.d/90-vmware-ubuntu-bootstrap-proxy.sh
```

脚本读取 Ubuntu 当前桥接 IPv4、网关和网段，忽略安装配置中的旧 `PROXY_HOST`、旧 `PROXY_SCAN_CIDR`，扫描当前 `/24` 或更小范围内的代理，验证 GitHub 和 Docker Registry 的 HTTPS 访问后更新 Shell、APT、Git、systemd、Docker 和 Snap 的受管代理。`NO_PROXY` 也使用当前 LAN。发现多个可用代理时会停止，要求明确指定 Windows IP：

```bash
sudo bash refresh-network.sh --proxy-host 192.168.2.100
# 如代理端口不是默认值，也可追加 --proxy-port 7897
```

示例 IP 应替换为 Windows 当前 Wi-Fi 地址。脚本不能从一个可用代理端口证明该设备就是宿主机；共享网络建议明确传入 Windows IP。超过 `/24` 的 LAN 只扫描 Ubuntu 地址所在的 `/24`，宿主机在其他段时也应显式指定。代理验证强制通过指定代理，不受旧 `NO_PROXY` 绕行影响。

如果已经显示“验证某 IP 的 HTTP 代理能力”，说明该 IP 的 TCP 端口可连接；后续失败还可能来自代理节点、HTTPS 握手或目标网站。每个请求允许 8 秒连接（包括 TLS 握手）、20 秒总时间，临时超时、连接错误或部分服务端错误会重试一次。失败日志会区分 Docker Registry 与 GitHub，显示 HTTP、CONNECT、curl 退出码及错误信息。Docker Registry 返回 `401` 是正常的未登录响应；代理要求认证的 `407` 或 TLS 证书错误仍会拒绝应用配置。刷新失败时，旧代理配置保留；应在刷新成功后再执行 `source`。

如果 Ubuntu 没有获得新地址，或仍使用旧 Wi-Fi 的租约，在 **VMware 的 Ubuntu 本地终端** 执行：

```bash
sudo bash refresh-network.sh --renew
source /etc/profile.d/90-vmware-ubuntu-bootstrap-proxy.sh
```

`--renew` 使用 [NetworkManager 的 nmcli](https://networkmanager.pages.freedesktop.org/NetworkManager/NetworkManager/nmcli.html) 断开所选以太网卡，再按已有连接 UUID 重新激活 DHCP，最长等待激活 45 秒。它不会更改网络配置文件，也不会将静态连接转换成 DHCP；检测到 SSH 会话、静态连接或本项目待恢复的静态配置时停止。此操作会短暂断网，不要在 Windows SSH 会话中使用。

网卡不明确或已无活动连接时，先查看现有设备与连接，再显式传入：

```bash
ip -br link
nmcli connection show
sudo bash refresh-network.sh --renew --interface ens33 --connection <原连接UUID>
```

把 `ens33` 和 UUID 替换为实际值。重连失败会停止，且不会继续写入代理；检查 VMware 虚拟网卡已连接、桥接到当前 Wi-Fi 后，可用同一条带 UUID 的命令重试。Linux 脚本无法修改 Windows 的 VMware 桥接设置、代理 Allow LAN、监听端口或防火墙；若新 Wi-Fi 启用了客户端隔离，也需先恢复宿主机与 VM 的互通。

其他选项：

```bash
sudo bash refresh-network.sh --dry-run
sudo bash refresh-network.sh --renew --dry-run
sudo bash refresh-network.sh --config /path/to/config.env
```

普通预览会探测当前网络但不写系统配置；`--renew --dry-run` 只预览连接重建，因为新 DHCP 地址尚未知，不会提前扫描旧网段。此入口不安装软件或更新仓库，依赖首次安装已准备好。

UFW 已启用时，快捷脚本会备份规则并补上当前 LAN 到已配置 SSH 端口的放行，保留旧规则，不改变 SSH 密钥和认证设置。最终显示新的 SSH 地址；仍需从 Windows 实际登录确认。代理变化时会重启正在运行的 Docker，已有容器内的代理环境不会被自动改写；其他已运行的程序也需重启。`source` 命令只刷新当前终端，重新登录可更新完整桌面登录环境。

原 `config.env` 保留，用于安装的静态参数也不改写；**以后切换 Wi-Fi 继续使用此快捷脚本**。普通 `--phase proxy` 仍遵循保存的安装输入，若要继续使用该入口，须按下节更新配置。

### 终端可联网，但浏览器打不开网页

桌面浏览器的系统代理与 Shell 环境变量是两套设置。刷新阶段现在也会为目标用户设置 GNOME HTTP/HTTPS 代理、当前 LAN 绕过规则和手动代理模式。请在 Firefox 的连接设置中选择“使用系统代理设置”；已有独立手动代理或扩展代理仍需在浏览器内处理。

桌面配置只改动代理相关的键，每次修改记录原值，`proxy-off` 和代理阶段回滚会恢复它们；外部修改的桌面设置不会被关闭流程覆盖。若当前用户尚未登录图形桌面，脚本会明确提示桌面代理未更新，登录后重跑即可。`source` 只刷新当前终端，不能代替桌面代理设置。

已经登录的桌面和已运行的浏览器可能还继承着旧 `http_proxy` / `https_proxy`；从该桌面重新打开程序，也可能继续带入旧地址。请保存页面并从 Firefox 菜单完全退出，然后在 Ubuntu 终端执行：

```bash
source /etc/profile.d/90-vmware-ubuntu-bootstrap-proxy.sh
firefox https://www.google.com/
```

如果 Firefox 原进程仍在运行，上述命令可能只让旧进程打开一个标签页，不会刷新其环境。注销并重新登录 Ubuntu 可让整个桌面读取更新后的 `/etc/environment`；此操作会关闭当前应用，应先保存工作。

如果系统域名解析仍超时，用 `resolvectl domain` 和 `resolvectl dns` 查看是否有 VPN/TUN 接口将 `~.`（所有域名）导向不可用 DNS；这是独立的 DNS 路由问题，HTTP 代理验证成功不代表本机 DNS 也正常。

## 仅代理地址变化

在 Windows PowerShell 查看当前桥接到的物理网卡：

```powershell
Get-NetIPConfiguration |
    Where-Object { $_.NetAdapter.Status -eq 'Up' -and $_.IPv4DefaultGateway -ne $null } |
    Select-Object InterfaceAlias, IPv4Address, IPv4DefaultGateway
```

确认代理的 Allow LAN、HTTP/Mixed 端口和 Windows 防火墙，然后备份并编辑 Ubuntu 项目的 `config.env`：更新 `PROXY_HOST`/`PROXY_PORT`，必要时更新独立且不超过 256 地址的 `PROXY_SCAN_CIDR`。不要因为代理主机变化就重新分配 VM 地址。

```bash
sudo bash install.sh --phase proxy --dry-run
sudo bash install.sh --phase proxy
sudo bash install.sh --phase proxy-status
```

daemon 代理内容变化时 bootstrap 会更新自己的 drop-in 并重启运行中的 Docker，因此应安排合适的维护时间；相同配置重复执行不重启。项目不会覆盖其他 drop-in 或 daemon.json。重新登录以刷新当前 shell 环境，再检查 GitHub、Docker 与开发工具。

## 更换 LAN 或发现地址冲突

在 VMware 控制台操作，记录当前管理接口、IPv4/CIDR、网关和 MAC：

```bash
sudo bash install.sh --status
ip -4 address
ip -4 route
```

如果此前使用本项目静态配置，先按 [恢复说明](recovery.md) 用对应 `static-network` 备份 ID 显式恢复原文件。仅删除受管 YAML 可能无法还原原地址和路由。恢复后的网络是否使用 DHCP 取决于备份原配置，脚本不保证或猜测。

默认推荐保持网络并在新路由器做 DHCP 地址保留。也可以按 [兼容说明](compatibility.md) 明确分配新 `STATIC_IPV4_CIDR`、网关和 DNS，支持其他网段及 `/1`–`/30` 普通 LAN。不再限制 `192.168.1.0/24`；新旧字段不一致必须先解决。地址须排除 DHCP 动态池或由管理员保留，ARP 检测不能保证离线设备或后续租约没有冲突。

确认当前地址后更新代理；如启用 UFW，重跑 SSH 阶段会根据真实管理 CIDR（以及显式静态目标）增加来源规则，与代理扫描范围无关：

```bash
sudo bash install.sh --phase ssh
sudo ufw status numbered
```

从第二个终端确认新来源可以登录，再由管理员按实时编号删除不再需要的旧来源规则，避免误删其他项目规则。最后运行 validate/status。SSH 下写入的新静态配置只待重启，当前连接不立即切换；开机后无自动回滚保证，需记录控制台恢复路径。
