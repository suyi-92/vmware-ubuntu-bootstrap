# 验证清单

## 自动验证

```bash
sudo bash install.sh --phase validate
sudo bash install.sh --status
```

## 代理

```bash
curl -I https://github.com
sudo --preserve-env=http_proxy,https_proxy,HTTP_PROXY,HTTPS_PROXY \
  curl -I https://github.com
git config --show-origin --get http.proxy
sudo -H git config --show-origin --get http.proxy
apt-config dump | grep -i proxy
```

## 固定网络

```bash
ip -4 address show dev ens33
ip -4 route
resolvectl status ens33
```

确认重启后仍为预期地址，且没有和网关、Windows 主机或 DHCP 设备冲突。

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
systemctl is-active ssh
```

从 Windows 新开 PowerShell：

```powershell
ssh -p 22 suyi@192.168.1.254
```

## Codex / CPA

```bash
codex --version
codex-cpa --version
stat -c '%U:%G:%a %n' ~/.config/vmware-ubuntu-bootstrap/secrets/cpa-api-key
```

API key 文件必须为当前用户所有且权限为 `600`。不要把 key 或 Authorization header 粘贴到诊断日志。
