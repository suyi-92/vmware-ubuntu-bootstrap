# Docker 与网络兼容

本说明适用于 Ubuntu 24.04 Desktop x86_64、VMware 桥接网络，以及在同一 VM 中先后安装或继续开发 MDD 与 bootstrap 的场景。

## Docker 来源与连接目标

| 初始状态 | bootstrap | MDD vmware |
| --- | --- | --- |
| 没有 Docker 或不明容器运行时残留 | 上游源开启选 CE，关闭选 docker.io | 先模拟 APT，再用 `--no-remove` 首次安装 docker.io |
| 健康 CE | 保留 CE，可同来源升级 | 复用，不改 Docker 包、不重启 daemon |
| 健康 docker.io | 保留 docker.io，可同来源升级 | 复用，不改 Docker 包、不重启 daemon |
| 正常停止的本机服务 | 只启动并有界验收 | 只启动并有界验收 |
| masked / failed / 不完整 / 不明安装 | 报错，停止自动安装 | 报错，停止自动安装 |

不用关闭 `INSTALL_DOCKER` 绕过冲突。普通安装没有隐式迁移选项；切换上游源开关不会删除现有 Docker 源。CE 的 Compose/Buildx 包分别是 `docker-compose-plugin`、`docker-buildx-plugin`；发行版使用 `docker-compose-v2`、`docker-buildx`，最终检查实际插件命令，不硬性要求 CE 包。

Docker 验证明确使用 `unix:///var/run/docker.sock`，不拿远程 `docker info` 成功当作本机证明，也不修改用户全局 context。CLI-only、rootless-only、远程、Docker Desktop、Podman 不符合本机 rootful 要求；正常 rootful 与 rootless 共存可以复用。保留 HTTP/HTTPS 代理。CLI 的环境变量与 context 优先级见 [Docker 官方文档](https://docs.docker.com/reference/cli/docker/)。

不自动清理 Docker 数据目录、daemon.json、其他项目容器、镜像、卷或网络。bootstrap 保留用户组及代理配置功能，仅当本项目的 daemon 代理内容变化时重启 Docker；普通重复运行不无故重启。APT 同来源升级仍可能由包维护脚本重启服务，这是升级策略原有行为。诊断示例见 [恢复说明](recovery.md)。

## 新安装

复制配置示例后保持：

```dotenv
VUB_CONFIG_VERSION="5"
CONFIGURE_STATIC_NETWORK="false"
NETWORK_INTERFACE=""
STATIC_IPV4_CIDR=""
PROXY_SCAN_CIDR=""
```

保持模式既不强制 DHCP，也不把当前 DHCP 租约改为静态。摘要、状态和 SSH 提示显示真实管理接口、IPv4/CIDR、网关和 MAC。多默认路由不能可靠判断时，明确填写管理物理以太网卡。脚本不会选择 Docker bridge、VPN 或蜂窝接口，也不会修改路由器。

推荐为两台 VM 保留不同 MAC，并在路由器按 MAC 分别配置 DHCP 地址保留。两台 VM 在同一 LAN 时不能共用一个地址；即使现在分处不同网段，也不能把文档示例当作可直接套用的地址分配。

## 显式静态 IPv4

交互界面只有在明确开启静态网络时才询问完整 CIDR、网关及 DNS。配置文件方式如下，**占位符必须替换为管理员分配的实际值**：

```dotenv
CONFIGURE_STATIC_NETWORK="true"
NETWORK_INTERFACE="<所选管理以太网卡>"
STATIC_IPV4_CIDR="<管理员分配的IPv4/前缀长度>"
GATEWAY_IPV4="<该网段网关>"
DNS_SERVERS="<DNS地址，多个用空格分隔>"
```

支持普通 IPv4 LAN `/1`–`/30`。例如自动化测试会分别渲染 `192.168.50.20/24`、`192.168.50.21/24` 和 `10.20.30.255/23`；这些是测试地址，不是为用户分配的地址。`10.20.30.255/23` 可作主机地址，而 `10.20.31.255/23` 是广播地址。网关必须是同网段有效主机，且不同于目标地址。网络/广播/特殊用途地址、非法 DNS、已知代理或其他本机接口冲突均会拒绝。

ARP 使用 Ubuntu 的 `iputils-arping -D`，在所选接口执行；发现重复地址、工具缺失、不支持的 arping 实现、权限/链路/执行错误都会阻止写入。重复运行仍做 DAD，不能因目标已在本接口而忽略别的设备声称拥有该地址。`--yes` 不跳过校验和冲突。同时核对已发送探针数，拒绝 NOARP 等“退出 0 但未探测”的情况。DAD 忽略本机 MAC 的逻辑及特殊返回值见 [iputils 源码](https://github.com/iputils/iputils/blob/20240117/arping.c)。退出码语义见 [Ubuntu iputils 手册](https://manpages.ubuntu.com/manpages/noble/man8/arping.8.html)。

ARP 只能反映当时可观察的网络，不能保证离线设备、DHCP 后续分配或并发安装不冲突。必须由用户/管理员确认地址在 DHCP 动态池之外，或已做合适的地址保留；脚本不猜测地址池，不随机选址。

只改所选接口的 IPv4；保留其他接口、IPv6、全局 renderer。Netplan 会合并多个文件，因此必要时备份并清理原 YAML 中同一接口的 IPv4 地址/默认路由，再写受管定义；不能仅删除一个新 YAML 来还原。共享/通配 match、多定义、策略路由/on-link、`/run/netplan` 或 `/lib/netplan` 定义等不能确认可安全修改的情况会明确拒绝，由管理员先消除歧义。不会通过改全局 renderer 绕过问题。

`PROXY_SCAN_CIDR` 独立限制在至多 256 地址。未填写时从所选接口当前地址计算 `/24` 或更小范围；静态 `/16` 不会导致扫描整个 `/16`。UFW 来源与 NO_PROXY 使用实际管理 CIDR，并包含显式静态目标网段，不能用代理扫描范围代替 LAN 前缀。

## 升级旧配置与重复执行

继续读取旧的 `CONFIGURE_STATIC_NETWORK`、`STATIC_IPV4_PREFIX`、`STATIC_IPV4_LAST_OCTET`、`PREFIX_LENGTH`。完整旧地址会转换为同一个 CIDR；新旧地址同时存在且不一致时报错，不能静默覆盖。旧格式只有 prefix/last 且缺少长度时沿用旧契约 `/24`；不完整地址字段拒绝补猜。没有配置文件绝不会补出 `.254`。

交互保存写入版本 5 和统一 `STATIC_IPV4_CIDR`。使用 `--config ... --yes` 会兼容读取旧文件，不强制改写。已有旧配置中显式开启静态网络的设置仍有效；如果希望停止新增网络变化，明确将 `CONFIGURE_STATIC_NETWORK=false`，但这不撤销以前写入的网络配置。

静态配置相同时不重复生成条目；SSH 待重启配置相同时保留原备份和状态。保持模式保留旧的静态文件与 `pending-reboot`，并显示恢复路径，不声称 DHCP 已恢复或重启不会改地址。

## 应用、验收与恢复

- `sudo bash install.sh --phase static-network --dry-run`：解析、生成临时计划，不发 ARP、不写系统配置、不执行 netplan。
- `sudo bash install.sh --phase static-network`：SSH 会话只备份/写盘/语法校验，记录 `pending-reboot`，显示当前及待生效地址、备份 ID。
- 控制台立即应用使用 `netplan try --timeout 120`；超时、生成或检查失败恢复原文件，检查通过才记为 complete。
- SSH 待重启路径没有开机自动回滚保证。确认备份、VMware 控制台与地址分配后，由用户决定何时重启。
- 重启后运行 `sudo bash install.sh --phase validate` 和 `sudo bash install.sh --status`；旧 pending 状态未核实或回滚前不会被保持模式清成 complete。
- 显式撤销使用 `sudo bash install.sh --rollback <static-network备份ID>`。SSH 下恢复磁盘，不立即切断当前连接；具体步骤见 [恢复说明](recovery.md)。

## 自动测试与实机界限

`bash tests/run.sh` 跑语法、Python、ShellCheck 与普通用户测试；`sudo bash tests/run.sh` 补跑需要文件所有权的临时目录/mock 测试。`test_network_compat.py` 覆盖 CIDR、旧字段读写往返、真实阶段的 SSH staging、ARP 错误、控制台超时及备份恢复；`test_docker_local.py` 用受限命令 mock 验证安装、复用、失败与两种来源的顺序/重复选择。

旧测试中强制 restart/socket 的断言与“所有 Netplan YAML 一律 chmod”的断言已改为新契约；对应安全行为由实际命令调用测试覆盖，未移除 Git、网络连接、备份恢复或秘密检查门禁。

本次源码任务不部署。真实 VMware 双 VM 同 LAN/异网段、ARP 报文、重启后 SSH/DNS、现有容器持续运行、Docker APT 维护脚本行为与 MDD Engine/TUN/NET_ADMIN 集成验收均未执行，必须在专用 VM 验证。静态检查通过不代表双 VM 安装通过。
