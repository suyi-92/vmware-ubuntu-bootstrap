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
