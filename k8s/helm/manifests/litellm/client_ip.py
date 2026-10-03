"""client_ip — 让 spend log 的 requester_ip_address 记真实客户端 IP，而不是网关地址。

挂在 LiteLLM 的 `async_pre_call_hook` 上（litellm_settings.callbacks），对所有调用类型生效。

## 为什么需要

公网请求的链路是 Cloudflare 边缘 → cloudflared → Cilium Gateway（Envoy）→ LiteLLM。
LiteLLM 默认把 TCP 对端写进 `requester_ip_address`（litellm_pre_call_utils.py 的
`request.client.host`），到它这里对端已经是集群内部地址，于是所有外部调用方都记成同一个
`10.42.0.152`（k8s-node 的 CiliumInternalIP）。2026-10-03 查 7 天的 spend log，除了集群内
pod 自己的调用，没有一行是真实客户端 IP —— 「对外发了 key，看它从哪里被调用」做不到。

## 为什么读 CF-Connecting-IP，而不是开 general_settings.use_x_forwarded_for

LiteLLM 自带的开关把**整条** `X-Forwarded-For` 原样存成字符串。这条链最左边是客户端自己
可以填的（Cloudflare 只在后面追加，Envoy 的 `useRemoteAddress: true` 再追加 cloudflared
的 pod IP），所以存下来的是 `<任意伪造值>, <真实 IP>, 10.42.x.x` 这种东西，按 IP 聚合就废了。
`CF-Connecting-IP` 是 Cloudflare 边缘写的单个地址，客户端带同名头会被覆盖（上线后实测）。

## 信任边界

不经过 Cloudflare 的请求（集群内 pod 走 Service、tailnet 走 NodePort 31400）没有这个头，
保持 LiteLLM 原来记的对端地址 —— 那两条路上对端地址本来就是真的。它们理论上能自己伪造
这个头，但能走到那两条路的只有集群内负载和 tailnet 设备，不在要防的范围里。

## 失败模式

头缺失、不是合法 IP、或任何异常，都不改动请求。这层只影响记账字段，不该成为网关的新故障点。
"""

import ipaddress
from typing import Any, Optional

from litellm._logging import verbose_proxy_logger
from litellm.integrations.custom_logger import CustomLogger

CLIENT_IP_HEADER = "cf-connecting-ip"
# 不同路由把 metadata 放在不同的键下（chat 是 metadata，部分新路由是 litellm_metadata），两个都看。
METADATA_KEYS = ("metadata", "litellm_metadata")


def client_ip_from_request(data: dict) -> Optional[str]:
    """从 add_litellm_data_to_request 留下的请求快照里取 CF-Connecting-IP，规范化成 IP 字面量。"""
    snapshot = data.get("proxy_server_request")
    headers = snapshot.get("headers") if isinstance(snapshot, dict) else None
    if not isinstance(headers, dict):
        return None
    raw = next(
        (v for k, v in headers.items() if isinstance(k, str) and k.lower() == CLIENT_IP_HEADER),
        None,
    )
    if not isinstance(raw, str):
        return None
    try:
        return str(ipaddress.ip_address(raw.strip()))
    except ValueError:
        return None


class ClientIp(CustomLogger):
    """`litellm_settings.callbacks` 里注册的那个实例。

    ⚠️ 首次改写打一条 WARNING（之后不再打）：本部署的 `verbose_proxy_logger` 生效级别是
    WARNING，INFO 一律被丢掉。不打的话「这层有没有加载」只能去查库。一个 pod 一条。
    """

    def __init__(self) -> None:
        super().__init__()
        self._announced = False

    async def async_pre_call_hook(
        self,
        user_api_key_dict: Any,
        cache: Any,
        data: dict,
        call_type: str,
    ) -> Optional[dict]:
        try:
            client_ip = client_ip_from_request(data)
            if client_ip is None:
                return None
            peer = None
            for key in METADATA_KEYS:
                metadata = data.get(key)
                if isinstance(metadata, dict) and "requester_ip_address" in metadata:
                    peer = metadata["requester_ip_address"]
                    metadata["requester_ip_address"] = client_ip
        except Exception as exc:  # 记账字段不许把请求搞挂
            verbose_proxy_logger.warning("client_ip: 改写失败，保留原值: %s", exc)
            return None
        if not self._announced:
            self._announced = True
            verbose_proxy_logger.warning(
                "client_ip: 本层已生效（首次改写，后续不再打印）—— %s 的对端 %s 记为 %s",
                call_type, peer, client_ip,
            )
        return data


client_ip_handler = ClientIp()
