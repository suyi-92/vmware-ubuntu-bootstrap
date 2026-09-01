# 恢复与回滚

## 自动保护

- 每个会改文件的阶段先在 `/var/backups/vmware-ubuntu-bootstrap/` 建立快照。
- 当前阶段失败时，入口会尝试恢复该阶段受管文件。
- 通过 SSH 安装时只写入并校验固定网络，重启前不会改变当前连接；直接在控制台应用时使用 `netplan try --timeout 120`，未确认则自动恢复网络。
- 软件包安装本身不可通用回滚；`packages` 回滚只恢复 hostname、时间等受管配置，不自动卸载包。

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

## 网络救援

如果通过 SSH 写入固定网络后尚未重启，可以先回滚对应的 `static-network` 备份，或在确认不需要该配置后删除受管 Netplan 文件。重启后如果因为地址、网关或 DNS 设置错误而失去网络，在 VMware 控制台执行：

```bash
sudo rm -f /etc/netplan/90-vmware-ubuntu-bootstrap-static.yaml
sudo netplan generate
sudo netplan apply
ip -4 address
ip -4 route
```

如果原始 netplan 也被外部修改，使用对应备份目录的 `rootfs/etc/netplan/` 恢复，而不是猜测配置。

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
