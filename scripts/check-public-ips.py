#!/usr/bin/env python3
"""禁止仓库提交任何属于本基础设施的公网 IP。

为什么需要它：oracle-k3s 节点的 OCI 公网地址曾散落在 15 处（inventory、AppProject
destination、5 篇文档），而 OCI Security List 把 6443/443/80 开给 0.0.0.0/0——
公开仓库里的一个公网 IP 等于直接给出扫描目标。2026-08-10 全部清掉，改走 Tailscale
（100.64.0.0/10 是 RFC 6598 共享地址空间，公网不可路由）。

判据：git 跟踪的文本文件里出现的 IPv4 字面量，凡是**全球可路由**的一律报错，
除非命中 THIRD_PARTY_ANYCAST（第三方公共服务，不暴露自己）或行内写了豁免标记。

豁免：在同一行任意位置写 `public-ip-ok`（后面接理由）。例：
    ssh user@203.0.113.9  # public-ip-ok: 供应商跳板，非本方资产

⚠️ 只查 IPv4。IPv6 没查是刻意的：能匹配 `2606:4700::1111` 的正则同样会匹配
`10:30:01` 这类时间戳，误报成本高于收益。当前全仓唯一的公网 IPv6 是
Cloudflare DNS 的 `2606:4700:4700::1111`，属于第三方 anycast。

用法：python3 scripts/check-public-ips.py   （只用标准库；CI 每次 PR/push 跑）
"""

import ipaddress
import re
import subprocess
import sys

REPO_ROOT = subprocess.run(
    ["git", "rev-parse", "--show-toplevel"],
    capture_output=True, text=True, check=True,
).stdout.strip()

# 非公网段：出现这些不算违规。
# 注意不要依赖 ipaddress 的 is_private/is_global——100.64.0.0/10（Tailscale 用的
# RFC 6598 共享地址空间）在不同 Python 版本上的归类改过，这里显式列出不赌。
NON_PUBLIC = [
    ipaddress.ip_network(n) for n in (
        "0.0.0.0/8",          # "本网络" / 通配监听地址
        "10.0.0.0/8",         # RFC1918（homelab 10.10.10.10、oracle 10.0.0.26、pod/svc CIDR）
        "100.64.0.0/10",      # RFC6598 共享地址空间 —— Tailscale tailnet
        "127.0.0.0/8",        # loopback
        "169.254.0.0/16",     # link-local（含 OCI metadata 169.254.169.254）
        "172.16.0.0/12",      # RFC1918
        "192.168.0.0/16",     # RFC1918（LAN 192.168.50.0/24）
        "198.18.0.0/15",      # RFC2544 benchmark
        "192.0.2.0/24",       # RFC5737 TEST-NET-1（文档示例）
        "198.51.100.0/24",    # RFC5737 TEST-NET-2
        "203.0.113.0/24",     # RFC5737 TEST-NET-3
        "224.0.0.0/4",        # multicast
        "240.0.0.0/4",        # reserved（含 255.255.255.255）
    )
]

# 第三方公共 anycast 服务：是公网 IP，但指向别人家的服务，不构成本方资产暴露，
# 且换成域名会引入「DNS 挂了修不了 DNS」的循环依赖（正是 2026-08-01 那次故障）。
THIRD_PARTY_ANYCAST = {
    "1.1.1.1": "Cloudflare DNS",
    "1.0.0.1": "Cloudflare DNS (secondary)",
    "8.8.8.8": "Google DNS",
    "8.8.4.4": "Google DNS (secondary)",
    "9.9.9.9": "Quad9 DNS",
    "223.5.5.5": "AliDNS",
    "223.6.6.6": "AliDNS (secondary)",
}

EXEMPT_MARKER = "public-ip-ok"

# 前后不能紧邻数字或点，避免把 1.2.3.4.5 / 版本号切成 IP
IPV4_RE = re.compile(r"(?<![\d.])(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})(?![\d.])")


def tracked_files():
    out = subprocess.run(
        ["git", "-C", REPO_ROOT, "ls-files", "-z"],
        capture_output=True, text=True, check=True,
    ).stdout
    return [p for p in out.split("\0") if p]


def main():
    violations = []
    scanned = 0

    for rel in tracked_files():
        try:
            with open(f"{REPO_ROOT}/{rel}", encoding="utf-8") as fh:
                lines = fh.readlines()
        except (UnicodeDecodeError, IsADirectoryError, FileNotFoundError):
            continue  # 二进制 / 软链 / 子模块
        scanned += 1

        for lineno, line in enumerate(lines, 1):
            if EXEMPT_MARKER in line:
                continue
            for match in IPV4_RE.finditer(line):
                text = match.group(1)
                try:
                    addr = ipaddress.IPv4Address(text)
                except ipaddress.AddressValueError:
                    continue  # 形如 999.1.1.1，不是 IP
                if any(addr in net for net in NON_PUBLIC):
                    continue
                if text in THIRD_PARTY_ANYCAST:
                    continue
                violations.append((rel, lineno, text, line.strip()[:120]))

    if violations:
        print(f"❌ 发现 {len(violations)} 处公网 IP（扫描 {scanned} 个文本文件）\n")
        for rel, lineno, text, snippet in violations:
            print(f"  {rel}:{lineno}: {text}")
            print(f"      {snippet}")
        print(
            "\n本仓库不提交任何公网 IP。修法（按优先级）：\n"
            "  1. 换成 Tailscale 地址（100.64.0.0/10）或内网地址 —— 绝大多数情况都能这么改；\n"
            "  2. 文档里换成占位符 `<ORACLE_PUBLIC_IP>`，并写明去哪儿取"
            "（`cd cloud/oracle/terraform && terraform output -raw instance_public_ip`）；\n"
            "  3. 确属第三方 anycast 服务 → 加进本脚本的 THIRD_PARTY_ANYCAST；\n"
            f"  4. 实在需要保留 → 行内加 `{EXEMPT_MARKER}: <理由>`。"
        )
        return 1

    print(f"✅ 无公网 IP 泄露（扫描 {scanned} 个文本文件）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
