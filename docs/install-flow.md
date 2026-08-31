# 安装流程

## 1. 手动准备临时代理

在 VMware 控制台进入 Ubuntu，确认 Windows 代理已开启 `Allow LAN` 和 `7890`：

```bash
PROXY_HOST="192.168.1.100"
PROXY_URL="http://${PROXY_HOST}:7890"
export http_proxy="$PROXY_URL" https_proxy="$PROXY_URL"
export HTTP_PROXY="$PROXY_URL" HTTPS_PROXY="$PROXY_URL"
```

安装克隆所需的最小依赖：

```bash
sudo apt-get \
  -o Acquire::http::Proxy="${PROXY_URL}/" \
  -o Acquire::https::Proxy="${PROXY_URL}/" update
sudo apt-get \
  -o Acquire::http::Proxy="${PROXY_URL}/" \
  -o Acquire::https::Proxy="${PROXY_URL}/" \
  install -y git curl ca-certificates python3
```

## 2. 克隆并运行

```bash
git -c http.proxy="$PROXY_URL" -c https.proxy="$PROXY_URL" \
  clone https://github.com/suyi-92/vmware-ubuntu-bootstrap.git
cd vmware-ubuntu-bootstrap
sudo --preserve-env=http_proxy,https_proxy,HTTP_PROXY,HTTPS_PROXY \
  bash install.sh
```

脚本会从 `/dev/tty` 逐项询问配置，API key 不回显。固定 IP 切换必须在 VMware 控制台确认 `netplan try`，否则 120 秒后自动回滚。

安装会包含 `open-vm-tools` 和 `open-vm-tools-desktop`。首次重启并登录 Ubuntu 图形桌面后，确认 VMware Workstation 的 `VM > Settings > Options > Guest Isolation` 已允许复制粘贴；该宿主机设置不能由虚拟机内脚本修改。

## 3. 分阶段运行

```bash
sudo bash install.sh --phase preflight
sudo bash install.sh --phase proxy
sudo bash install.sh --phase packages
sudo bash install.sh --phase static-network
sudo bash install.sh --phase power
sudo bash install.sh --phase ssh
sudo bash install.sh --phase codex
sudo bash install.sh --phase validate
```

查看状态不修改系统：

```bash
sudo bash install.sh --status
sudo bash install.sh --phase proxy-status
```

关闭本项目管理的代理：

```bash
sudo bash install.sh --phase proxy-off
```

## 4. 完成门槛

首次全流程结束时状态为 `configured-pending-reboot`。重启 Ubuntu 后再次运行：

```bash
sudo bash install.sh --phase validate
```

只有重启后全部验证仍通过，状态才是 `complete`。
