# 恢复与回滚

## 自动保护

- 每个会改文件的阶段先在 `/var/backups/vmware-ubuntu-bootstrap/` 建立快照。
- 当前阶段失败时，入口会尝试恢复该阶段受管文件。
- 通过 SSH 安装时只写入并校验固定网络，重启前不会改变当前连接；直接在控制台应用时使用 `netplan try --timeout 120`，未确认则自动恢复网络。
- 软件包安装本身不可通用回滚；`packages` 回滚会恢复受管 APT 源、密钥、hostname 和时间配置，但不会降级或卸载已经更新的软件包，同来源升级不会自动换源；已有 Docker 源与数据不属于自动卸载/迁移对象。
- `input-method` 会快照 `.xinputrc`、Fcitx5 配置和完整 Rime 用户目录；首次接管非空目录时还会留下用户可直接读取的 `rime.bak.YYYYmmdd-HHMMSS` 副本。回滚不卸载 APT 包，也不回退作为下载缓存的 `~/plum` Git 工作树。
- `sudo-policy` 回滚会恢复执行前的受管 sudoers 文件；关闭免密 sudo 也只移除本项目管理的规则。

## 查看备份

```bash
sudo ls -1 /var/backups/vmware-ubuntu-bootstrap
sudo cat /var/lib/vmware-ubuntu-bootstrap/last-backup
```

## 回滚最后一次快照

```bash
sudo bash install.sh --rollback-last
```

回滚指定快照：

```bash
sudo bash install.sh --rollback 20260831-210000-static-network
```

回滚前会再保存一次当前状态，因此可以撤销一次误回滚。

## 已有 Docker 异常

先诊断现有安装，不默认卸载重装：

```bash
sudo systemctl status docker.service --no-pager
sudo journalctl -u docker.service -n 60 --no-pager
dpkg-query -W docker-ce docker-ce-cli docker.io containerd.io containerd
sudo env -u DOCKER_HOST -u DOCKER_CONTEXT -u DOCKER_TLS -u DOCKER_TLS_VERIFY -u DOCKER_CERT_PATH docker --host unix:///var/run/docker.sock info
```

部分 CE 安装使用 `dockerd -H fd://`，这时还需检查 `docker.socket`；其他健康布局不强制要求 socket unit。masked/failed/残留/不完整安装需管理员查明原因，安装器不会 reset-failed、unmask 或通过换包掩盖错误。正常停止的服务可由安装器有界启动。保留现有数据目录、daemon.json 和其他项目的配置。

## 输入法恢复

输入法阶段失败时入口会自动恢复执行前的 Rime、Fcitx5 和 `.xinputrc` 文件。手动回滚成功后请注销并重新登录；不要用 `fcitx5 -rd` 循环重启后台进程。如果只需要重新安装或编译雾凇拼音，可执行：

```bash
sudo bash install.sh --phase input-method
```

首次接管时生成的 `~/.local/share/fcitx5/rime.bak.*` 不应在确认输入法、用户词库和自定义短语都正常前删除。

## 网络救援

保持模式不会删除旧静态文件或旧 `pending-reboot`。需要撤销时使用**那次 static-network 阶段的备份 ID**，不能假定最后一次备份就是网络备份：

```bash
sudo ls -1 /var/backups/vmware-ubuntu-bootstrap
sudo bash install.sh --rollback <static-network备份ID>
```

SSH 回滚只恢复磁盘配置并执行语法生成，不立即 `netplan apply`，以保留当前连接。核对恢复后的文件、原地址和路由后，再由用户选择在 VMware 控制台应用或重启。控制台回滚会应用恢复后的配置。

静态地址阶段可能同时清理原 YAML 中该接口的 IPv4 地址/默认路由，以防 Netplan 合并出多个默认路由；所以**仅删除受管 YAML 并不足以恢复原网络**。回滚入口不可用时，在 VMware 控制台按目标备份的 `paths.tsv` 与 `rootfs/` 恢复所有原文件，并删除清单中标记 `absent` 的新文件。随后执行 `sudo netplan generate` 和 `sudo netplan try --timeout 120`，核对接口地址、网关与 DNS。不要猜测 DHCP 原配置。

SSH 待重启配置没有开机自动回滚保证；离线冲突、DHCP 后续分配和并发安装也可能使此前 ARP 检测失效。

## SSH 救援

在 VMware 控制台执行：

```bash
sudo /usr/sbin/sshd -t
sudo rm -f /etc/ssh/sshd_config.d/00-vmware-ubuntu-bootstrap.conf
sudo rm -f /etc/systemd/system/ssh.socket.d/00-vmware-ubuntu-bootstrap.conf
sudo systemctl daemon-reload
sudo systemctl restart ssh.socket 2>/dev/null || sudo systemctl restart ssh
```

优先使用项目回滚命令；上面的手动命令只用于回滚入口本身不可用时。
