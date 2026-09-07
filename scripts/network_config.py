#!/usr/bin/env python3
"""IPv4 policy and selected-interface Netplan edits used by the installer."""
from __future__ import annotations

import copy
import fnmatch
import ipaddress as ip
import json
import pathlib
import re
import socket
import subprocess
import sys


def address(new: str, prefix: str, last: str, length: str) -> str:
    legacy = ""
    if prefix or last:
        if not prefix or not last:
            raise ValueError("旧静态地址字段不完整，请明确填写完整 IPv4/CIDR")
        legacy = str(ip.IPv4Interface(f"{prefix}.{last}/{length or '24'}"))
    if new:
        if "/" not in new:
            raise ValueError("静态地址必须包含 /前缀长度")
        new = str(ip.IPv4Interface(new))
    if new and legacy and new != legacy:
        raise ValueError("新旧静态地址字段冲突，请删除旧字段或使其一致")
    result = new or legacy
    if result:
        iface = ip.IPv4Interface(result)
        if not 1 <= iface.network.prefixlen <= 30:
            raise ValueError("普通 LAN 仅支持 IPv4 /1 至 /30；不支持 /0、/31、/32")
        valid_host(iface.ip, iface.network)
    return result


def valid_host(host, network):
    if host not in network or host in (network.network_address, network.broadcast_address):
        raise ValueError("地址必须是同网段的有效主机地址，不能是网络地址或广播地址")
    if host.is_multicast or host.is_loopback or host.is_unspecified or host.is_link_local or host.is_reserved:
        raise ValueError("不支持特殊用途主机地址")


def validate(cidr: str, gateway: str, dns: str) -> tuple[str, str, list[str]]:
    iface = ip.IPv4Interface(address(cidr, "", "", ""))
    gw = ip.IPv4Address(gateway)
    valid_host(gw, iface.network)
    if gw == iface.ip:
        raise ValueError("网关与目标地址不能相同")
    servers = [str(ip.ip_address(x)) for x in re.split(r"[\s,]+", dns.strip()) if x]
    if not servers or any(ip.ip_address(x).is_unspecified or ip.ip_address(x).is_multicast for x in servers):
        raise ValueError("至少配置一个有效 DNS 地址")
    return str(iface), str(gw), list(dict.fromkeys(servers))


def ip_json(*args):
    return json.loads(subprocess.check_output(["ip", "-j", *args], text=True, timeout=5))


def inventory():
    return ip_json("link", "show"), ip_json("-4", "addr", "show"), ip_json("-4", "route", "show", "default")


def management(links, addresses, routes, selected=""):
    eligible = {x["ifname"]: x for x in links if x.get("link_type") == "ether"
                and not x.get("linkinfo", {}).get("info_kind")
                and not re.match(r"^(lo$|docker|br-|veth|virbr|tun|tap|wg|vpn|wwan|wwp|usb|rmnet)", x["ifname"])}
    if not selected:
        if len(routes) != 1 or routes[0].get("dev") not in eligible:
            raise ValueError("管理网卡或默认路由不唯一；请明确设置 NETWORK_INTERFACE")
        selected = routes[0]["dev"]
    if selected not in eligible or not re.fullmatch(r"[A-Za-z0-9_.-]+", selected):
        raise ValueError("管理接口必须是明确的物理以太网卡；不能选择 Docker bridge、VPN 或蜂窝接口")
    own_routes = [r for r in routes if r.get("dev") == selected]
    if len(own_routes) > 1:
        raise ValueError("所选网卡存在多个默认路由，需先由管理员明确路由")
    cidrs = [f'{a["local"]}/{a["prefixlen"]}' for x in addresses if x["ifname"] == selected
             for a in x.get("addr_info", []) if a.get("family") == "inet" and a.get("scope") == "global"]
    return {"interface": selected, "cidrs": cidrs,
            "gateway": own_routes[0].get("gateway", "") if own_routes else "",
            "mac": eligible[selected].get("address", "")}


def check_conflicts(cidr, selected, addresses, proxies):
    target = str(ip.IPv4Interface(cidr).ip)
    for item in addresses:
        if item["ifname"] != selected and any(a.get("local") == target for a in item.get("addr_info", [])):
            raise ValueError("目标地址已配置在其他本机接口上")
    for proxy in filter(None, proxies):
        try:
            hosts = {str(ip.IPv4Address(proxy))}
        except ValueError:
            hosts = {x[4][0] for x in socket.getaddrinfo(proxy, None, socket.AF_INET)}
        if target in hosts:
            raise ValueError("固定 IP 不能与已知代理主机相同")


def check_vendor_netplan(directory):
    """Allow only unambiguous global NetworkManager defaults; never edit vendor files."""
    import yaml

    class VendorLoader(yaml.SafeLoader):
        def construct_mapping(self, node, deep=False):
            # SafeLoader normally overwrites duplicate keys and expands YAML merges,
            # which could hide settings that Netplan interprets differently.
            keys = set()
            for key, _ in node.value:
                if not isinstance(key, yaml.ScalarNode) or key.tag != 'tag:yaml.org,2002:str':
                    raise ValueError("仅允许字符串配置键，不支持 YAML 合并键")
                if key.value in keys:
                    raise ValueError("存在重复的 YAML 配置键")
                keys.add(key.value)
            return super().construct_mapping(node, deep=deep)

    root = pathlib.Path(directory)
    try:
        paths = sorted(path for path in root.iterdir() if path.name.endswith((".yaml", ".yml")))
    except FileNotFoundError as exc:
        if not root.is_symlink():
            return []
        raise ValueError(f"无法读取 vendor Netplan 目录：{root}") from exc
    except OSError as exc:
        raise ValueError(f"无法读取 vendor Netplan 目录：{root}") from exc

    for path in paths:
        try:
            if path.is_symlink() or not path.is_file():
                raise ValueError("拒绝符号链接或非普通文件")
            try:
                doc = yaml.load(path.read_text(encoding="utf-8"), Loader=VendorLoader)
            except yaml.YAMLError as exc:
                raise ValueError("YAML 无法安全解析") from exc
            if not isinstance(doc, dict) or set(doc) != {"network"}:
                raise ValueError("顶层必须仅包含 network 映射；空文档或未知配置不放行")
            network = doc["network"]
            if not isinstance(network, dict):
                raise ValueError("network 必须是映射")
            if set(network) - {"version", "renderer"}:
                raise ValueError("包含会影响具体网络配置的字段；仅允许全局 renderer/version")
            if network.get("renderer") != "NetworkManager":
                raise ValueError("必须明确指定 renderer: NetworkManager")
            if "version" in network and (type(network["version"]) is not int or network["version"] != 2):
                raise ValueError("version 必须是整数 2")
        except (ValueError, OSError) as exc:
            reason = "无法读取 UTF-8 YAML 文件" if isinstance(exc, (OSError, UnicodeError)) else str(exc)
            raise ValueError(f"无法安全放行 vendor Netplan 定义：{path}（{reason}）；"
                             "请管理员确认并整合后再配置静态网络。") from exc
    return paths


def netplan_changes(documents, selected, mac, cidr, gateway, dns, managed):
    """Change only selected Ethernet IPv4 fields; retain renderer/IPv6/other NICs."""
    docs = copy.deepcopy(documents)
    matching = []
    for path, doc in docs.items():
        network = doc.get("network", {})
        for name, cfg in network.get("ethernets", {}).items():
            match = cfg.get("match", {})
            matches = (name == selected and not match) or cfg.get("set-name") == selected
            if match:
                matches = (not match.get("name") or fnmatch.fnmatch(selected, match["name"])) and (
                    not match.get("macaddress") or match["macaddress"].lower() == mac.lower())
            if matches:
                if match.get("driver") or (match.get("name") and match["name"] != selected):
                    raise ValueError("Netplan 使用共享/通配 match，请先为管理接口建立独立定义")
                matching.append((path, name, cfg))
        if path == managed and set(network.get("ethernets", {})) - {x[1] for x in matching}:
            raise ValueError("已有受管文件属于其他网卡；请先显式回滚旧网络阶段")
    names = {name for _, name, _ in matching}
    if len(names) > 1:
        raise ValueError("管理网卡匹配多个 Netplan 定义，请先消除歧义")
    name = next(iter(names), selected)
    for _, _, cfg in matching:
        # Special routing needs explicit administrator handling.
        if cfg.get("routing-policy") or any(r.get("table") or r.get("on-link") for r in cfg.get("routes", [])):
            raise ValueError("不支持自动改写策略路由或 on-link 特殊配置")
        cfg["dhcp4"] = False
        cfg.pop("gateway4", None)
        if "addresses" in cfg:
            cfg["addresses"] = [a for a in cfg["addresses"] if ip.ip_interface(next(iter(a)) if isinstance(a, dict) else a).version == 6]
        if "routes" in cfg:
            cfg["routes"] = [r for r in cfg["routes"] if not (r.get("to") in ("default", "0.0.0.0/0") and ":" not in r.get("via", ""))]
        if "nameservers" in cfg and "addresses" in cfg["nameservers"]:
            cfg["nameservers"]["addresses"] = [a for a in cfg["nameservers"]["addresses"] if ip.ip_address(a).version == 6]
    target = docs.setdefault(managed, {"network": {"version": 2}})["network"].setdefault("ethernets", {}).setdefault(name, {})
    target["dhcp4"] = False
    target.setdefault("addresses", []).append(cidr)
    target.setdefault("routes", []).append({"to": "default", "via": gateway})
    current_dns = target.setdefault("nameservers", {}).setdefault("addresses", [])
    current_dns.extend(x for x in dns if x not in current_dns)
    return {path: doc for path, doc in docs.items() if documents.get(path) != doc}


def main():
    action, *args = sys.argv[1:]
    if action == "address":
        print(address(*args))
    elif action == "validate":
        cidr, gateway, servers = validate(*args)
        print(cidr, gateway, " ".join(servers), sep="\n")
    elif action == "inspect":
        item = management(*inventory(), selected=args[0] if args else "")
        print(item["interface"], " ".join(item["cidrs"]), item["gateway"], item["mac"], sep="\n")
    elif action == "conflicts":
        check_conflicts(args[0], args[1], ip_json("-4", "addr", "show"), args[2:])
    elif action == "check-vendor":
        for path in check_vendor_netplan(*args):
            print(path)
    elif action == "plan":
        import yaml
        directory, managed_name, selected, mac, cidr, gateway, dns, output = args
        root = pathlib.Path(directory)
        docs = {}
        for path in sorted([*root.glob("*.yaml"), *root.glob("*.yml")]):
            if path.is_symlink():
                raise ValueError("拒绝 Netplan 符号链接")
            docs[str(path)] = yaml.safe_load(path.read_text()) or {}
        changes = netplan_changes(docs, selected, mac, cidr, gateway, dns.split(), managed_name)
        for number, (path, doc) in enumerate(changes.items()):
            staged = pathlib.Path(output) / str(number)
            staged.write_text(yaml.safe_dump(doc, sort_keys=False))
            print(f"{path}\t{staged}")
    else:
        raise ValueError("unknown network command")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, TypeError, OSError, subprocess.SubprocessError) as exc:
        sys.exit(f"网络配置错误：{exc}")
