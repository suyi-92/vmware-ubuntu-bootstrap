# Docker/网络兼容修复交付记录（2026-09-05）

## 1. 基线与发现

开发 checkout：`/home/suyi/src/vmware-ubuntu-bootstrap`，分支 `main`，基线 HEAD `f8ca3332a8d232893cc51bdf922fd7517c48a83f`。仓库未发现 AGENTS.md，已阅读 README、安装/恢复/验收文档及相关测试。初始工作区干净；用户本地忽略的 config.env 未修改。初次仅进行源码验证；后续已获用户授权推送兼容性修改。未运行 bootstrap 完整安装器或改变当前网络。

`03-packages.sh` 按上游源开关选择 Docker，导致已有 docker.io 隐式迁移 CE；`00-lib.sh` 无条件重启并要求统一 socket unit；APT 源和验收逻辑没有按已有来源分支。网络默认开启 `.254/24`，交互只允许输入末位，摘要、代理、UFW 与验收存在固定前缀依赖；旧 pending 状态与回滚提示也需要同步。

## 2. 修改与关键选择

- Docker 状态判断位于正式阶段引用的 `scripts/docker-local.sh`，与 MDD 版本一致；`00-lib.sh` 提供现有来源选择、正常服务启动、插件包选择及本机 API 验收。前置检查会在代理阶段之前发现不支持的 Docker 状态。
- 全新系统仍按上游源开关选择 CE/docker.io；已有来源优先，保留其源和密钥，同来源升级仍可执行，APT 禁止移除包。Compose/Buildx 按 CE/发行版选择，最终验证实际命令。重复运行不无条件重启 Docker；本项目 daemon 代理变化时仍按原开发功能更新并重启。
- `config.example.env`、`install.sh`、`00-lib.sh` 的新配置默认保持网络，版本 5 使用完整 `STATIC_IPV4_CIDR`。兼容完整旧字段，冲突/不完整地址拒绝猜测，保存后可再次读取同一地址。
- `network_config.py` 与 `network-lib.sh` 被正式静态网络、摘要、SSH、代理和验收调用：从明确的物理管理接口取值，校验普通 IPv4 LAN `/1`–`/30`、网关/DNS和已知冲突，使用 iputils DAD。检查实际发送的探针数，不能把工具错误或 NOARP 的退出 0 当成空闲。
- Netplan 只改变所选接口 IPv4，保留其他接口、IPv6、全局 renderer。备份在同秒重复执行时也使用唯一目录，并隔离前一阶段继承的备份；SSH 写盘后保留 pending，控制台 try 超时/失败恢复原文件。受管 YAML 的 root:root:600 验收仍保留。
- 配置摘要、真实 SSH 地址、status、validate、NO_PROXY、UFW 和代理扫描已同步；扫描最多 256 地址，独立于真实 LAN 前缀。保持模式不清除旧静态文件或 pending 状态，也不宣称恢复 DHCP。
- README、配置示例、install-flow、host-ip-change、verification、recovery 和新增 compatibility 文档同步更新。

## 3. 实际验证

```bash
bash tests/run.sh
sudo -n bash tests/run.sh
git diff --check
```

普通用户与 root 两种运行方式结合覆盖完整框架：**48 项 Python 测试**，以及全部 Shell 测试、逐文件 `bash -n`、Python compileall 与 ShellCheck，通过。普通用户执行跳过需要文件所有权的隔离测试；root 执行补齐这些测试，普通用户远程入口测试则由普通用户执行覆盖。没有把 root-only 跳过当成系统验证。

新增 `test_docker_local.py` 的 12 项测试执行正式 helper，使用受限命令 mock 覆盖空白安装、CE/docker.io 复用、停止服务、masked/failed/不完整、CLI/rootless/远端/Desktop/Podman、来源/插件/软件源保持、两个安装顺序及重复执行。mock 拒绝未声明的副作用命令。

新增 `test_network_compat.py` 的 17 项测试覆盖 CIDR/非 /24、网卡/路由歧义、旧字段读写往返、冲突、ARP 工具错误、NOARP/未发送探针、相同配置、自身地址、待重启状态、SSH 不切换、控制台超时、生成失败/备份恢复、权限门禁及 dry-run 无系统写入。额外用系统真实 `netplan get --root-dir <临时目录>` 只读解析合并后的 YAML，确认唯一目标 IPv4、IPv6 和其他接口保留。没有执行真实 netplan generate/apply/try。

旧测试中“必须无条件 restart/docker.socket”与“所有 Netplan YAML 都 chmod”的断言已改为新契约；相应健康、文件权限、连接与回滚安全由真实调用 mock/解析器测试覆盖。其他有效安全测试保留。

## 4. 未执行的实机验收

未运行完整安装器、真实 APT 安装/卸载、Docker 容器操作、真实 ARP 探测、网络切换、服务重启或 VM 重启。两台真实 VMware VM 同 LAN/异网段、真实 Docker 安装顺序/原容器连续运行、实际 DHCP 地址保留、重启后 SSH/DNS/代理、控制台失联恢复和与 MDD Engine/TUN/NET_ADMIN 的集成仍未验证。

## 5. 操作说明

新安装：保持 `CONFIGURE_STATIC_NETWORK=false`，使用实际管理地址；在路由器按各 VM 独立 MAC 分别保留地址。`INSTALL_DOCKER=true` 可保留，已有来源自动识别，无需通过关闭它绕过冲突。

已有配置升级：完整旧地址保持原值，`--config ... --yes` 可直接兼容读取；交互保存写入 v5/CIDR，新旧冲突需先明确解决。显式静态网络必须填写管理接口、完整地址、网关和 DNS；先用 `--phase static-network --dry-run` 看计划。

重复执行：相同配置不重复生成网络条目，旧 pending 和原备份保留。SSH 下显示当前地址和待生效地址，写盘后不会声称已切换；需要撤销时使用对应 static-network 备份 ID，不能把最后一次其他阶段备份当作网络备份。只关闭静态开关或删除一个受管 YAML 都不等同于恢复 DHCP。

详细配置、两台 VM 地址规则和恢复命令见 [兼容说明](compatibility.md) 与 [恢复说明](recovery.md)。经验证推送后，远程一键入口即可获取此兼容修复。当前 VM 不重跑 bootstrap 安装器，MDD 使用自己的受管更新流程。

## 6. 剩余限制

普通 LAN 支持 `/1`–`/30`；共享/通配 Netplan match、多个定义、策略路由/on-link、runtime/vendor Netplan 定义等无法安全确定的布局会明确拒绝，由管理员消除歧义。ARP 不保证离线设备、后续 DHCP 或并发安装不冲突，地址须由用户/管理员排除动态池或保留。SSH 重启生效没有自动回滚保证。同来源 APT 升级及真实代理变更仍可能重启 daemon。没有源码阻塞项；真实 VMware 验收尚待专用环境。
