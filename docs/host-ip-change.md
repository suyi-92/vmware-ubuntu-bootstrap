# 宿主机 IP 或局域网变化

Windows 代理主机的地址变化不等于 Ubuntu VM 地址变化。VMware 桥接下，宿主机与每台 VM 都应有独立地址。不要使用旧文档中的 `.254` 作为默认 SSH 目标；先在 VMware 控制台查看实际地址，或查阅路由器按各 VM 独立 MAC 配置的 DHCP 保留。

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
