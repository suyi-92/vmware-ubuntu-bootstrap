# 验证清单

## 自动验证

```bash
sudo bash install.sh --phase validate
sudo bash install.sh --status
```

## 代理

```bash
curl -I https://github.com
sudo --preserve-env=http_proxy,https_proxy,HTTP_PROXY,HTTPS_PROXY,all_proxy,ALL_PROXY,no_proxy,NO_PROXY \
  curl -I https://github.com
wget -q --spider https://github.com
git config --show-origin --get http.proxy
sudo -H git config --show-origin --get http.proxy
apt-config dump | grep -i proxy
systemctl show-environment | grep -Ei '^(HTTP_PROXY|HTTPS_PROXY|ALL_PROXY|NO_PROXY)='
systemctl show docker -p Environment
python3 -m json.tool ~/.docker/config.json >/dev/null
sudo python3 -m json.tool /root/.docker/config.json >/dev/null
snap get system proxy.http 2>/dev/null || true
```

Docker 默认安装。daemon 的代理用于拉取镜像；root/普通用户的 Docker client 配置会把代理传给 `docker build` 和新建容器，因此容器内的 npm、pip、curl 等常见下载工具也能沿用代理。

Docker CE 的 service 使用 systemd socket activation，因此需要同时验证 socket、service 和 daemon API：

```bash
systemctl is-enabled docker.socket docker.service
systemctl is-active docker.socket docker.service
docker info
```

## APT 软件源与版本

```bash
grep -RHE '^(deb |URIs:)' /etc/apt/sources.list.d/{github-cli,git-core-ppa,github-git-lfs,kitware,docker}.{list,sources} 2>/dev/null
apt-cache policy gh git git-lfs cmake nodejs npm node-gyp docker-ce
gh --version
git --version
git lfs version
cmake --version
node --version
npm --version
npx --version
docker compose version
docker buildx version
apt list --upgradable
```

源文件应使用各自 `/etc/apt/keyrings/` 下的 `signed-by` 密钥，不应出现 `apt-key`。默认升级完成后，`apt list --upgradable` 通常为空；被 hold 的包或需要管理员决策的升级可能仍会保留。

## sudo 策略

```bash
sudo visudo -cf /etc/sudoers
sudo stat -c '%U:%G:%a %n' /etc/sudoers.d/90-vmware-ubuntu-bootstrap-passwordless
sudo -n true
```

启用免密 sudo 时文件应为 `root:root:440`，且 `sudo -n true` 无提示成功。关闭该选项时，本项目管理的 passwordless 文件应不存在；其他管理员自行维护的 sudoers 规则不受影响。

## 固定网络

```bash
ip -4 address show dev ens33
ip -4 route
resolvectl status ens33
sudo stat -c '%U:%G:%a %n' /etc/netplan/*.yaml
```

确认重启后仍为预期地址，且没有和网关、Windows 主机或 DHCP 设备冲突；Netplan YAML 应为 `root:root:600`。

## 电源策略

```bash
gsettings get org.gnome.desktop.session idle-delay
gsettings get org.gnome.desktop.screensaver lock-enabled
gsettings get org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type
systemctl is-enabled sleep.target suspend.target hibernate.target hybrid-sleep.target
```

## Windows / VMware 桌面复制粘贴

```bash
dpkg-query -W open-vm-tools open-vm-tools-desktop
systemctl is-active open-vm-tools
pgrep -a -u "$USER" -x vmtoolsd | grep -- '-n vmusr'
```

在 VMware Workstation 中确认 `VM > Settings > Options > Guest Isolation` 已启用复制粘贴，然后分别测试 Windows 到 Ubuntu、Ubuntu 到 Windows。`vmware-user` 只在图形桌面会话中运行；如果刚安装完成，先注销并重新登录或重启。Wayland 下仍失败时，可在登录界面选择“Ubuntu on Xorg”后复验。

## SSH

```bash
sudo /usr/sbin/sshd -t
systemctl is-active ssh.socket 2>/dev/null || systemctl is-active ssh
ss -ltn4 | grep ':22 '
ss -ltn6 | grep ':22 '
```

从 Windows 新开 PowerShell：

```powershell
ssh -p 22 suyi@192.168.1.254
```

端口、用户和地址以实际配置为准。SSH 一键安装结束但尚未重启时，原会话仍使用 DHCP 地址；执行 `sudo reboot` 后改用安装器显示的固定地址。

## Codex / CPA

```bash
codex --version
grep -E '^(model|model_provider|base_url|wire_api)' ~/.codex/config.toml
stat -c '%U:%G:%a %n' ~/.config/vmware-ubuntu-bootstrap/secrets/cpa-api-key
codex sandbox -- bash -lc 'echo sandbox-ok'
codex doctor --summary
```

`model_provider` 应为 `cpa`，sandbox 命令应输出 `sandbox-ok`，Doctor 应为 `0 warn · 0 fail`，随后直接运行 `codex`。API key 文件必须为当前用户所有且权限为 `600`。不要把 key 或 Authorization header 粘贴到诊断日志。
