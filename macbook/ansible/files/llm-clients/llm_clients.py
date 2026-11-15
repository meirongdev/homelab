#!/usr/bin/env python3
"""三台 Mac 的 Qwen Code 与 codex 客户端配置统一：自建模型一律经 LiteLLM 网关。

由 playbooks/llm-clients.yaml 用 ansible.builtin.script 在每台上执行（解释器是 Homebrew 的
python3，要 tomllib，≥3.11）。也能在本机直接跑：python3 llm_clients.py [--dry-run]

只改「模型 / 网关」那部分，工具自己写回的状态原样保留（qwen 的 ui / ide / hooks，codex 的项目信任、
tui、hooks.state、插件）。改之前备份，没变化就不写。最后一行输出 JSON：{"changed": bool, "actions": [...]}。

为什么不整份下发文件：codex 会把项目信任等状态写回**当前用的那份** profile 文件，整份覆盖 =
每跑一次就要重新点一遍信任。所以 codex 的文件只管顶部那段带标记的托管区，标记以下不碰。
"""
from __future__ import annotations

import json
import os
import re
import shutil
import sys
import time
import tomllib
from pathlib import Path

GATEWAY = "https://llm.meirong.dev/v1"
KEY_ENV = "LITELLM_VK"  # 三台由 chezmoi 写进 ~/.secrets.sh，同一把虚拟 key；不往配置文件里写密钥
CTX = 262144

# 三台完全一致。第一条是默认：网关上的自动降级别名（DGX → Studio → M2），另两条是指名某台。
MODELS = [
    ("DeepSeek-V4.1-Flash-1017", "DeepSeek-V4.1-Flash-1017（网关：DGX → Studio → M2 自动降级）"),
    ("studio/qwen3.8-27b", "Qwen3.8-27B（网关，指名 Mac Studio）"),
    ("mac/ornith", "Ornith-1.5-35B-A3B（网关，指名 M2）"),
]
# 网关自己会降级，客户端没必要再重试 8 次：上游真全挂时，8 次指数退避会让每个请求先卡约 35 秒才报错。
QWEN_GEN = {"contextWindowSize": CTX, "timeout": 300000, "maxRetries": 3}

# codex：默认仍走 ChatGPT 登录（2026-11-15 用户定），自建模型用 -p <profile>
CODEX_BASE_KEYS = {"model": '"gpt-6-luna"', "model_reasoning_effort": '"xhigh"'}
CODEX_PROFILES = {  # profile 名 → (网关别名, reasoning_effort)
    "litellm": ("DeepSeek-V4.1-Flash-1017", "high"),
    "studio": ("studio/qwen3.8-27b", "high"),
    "mac": ("mac/ornith", "high"),
}
# 直连上游的旧 profile：DGX 直连、DGX 单机实验端点、M2 直连、本机 OMLX。信任记录并进 litellm。
CODEX_RETIRED_PROFILES = ["dgx", "fndgx", "m2", "local"]

BEGIN = "# >>> homelab llm-clients >>>"
END = "# <<< homelab llm-clients <<<"
NOTE = ("# 由 homelab 仓库 macbook/ansible/playbooks/llm-clients.yaml 管理（just llm-clients），"
        "这段会被下次运行覆盖；标记以下归 codex 自己写。")

HOME = Path.home()
STAMP = time.strftime("%Y%m%d-%H%M%S")
DRY = "--dry-run" in sys.argv
actions: list[str] = []


def backup(path: Path, root: Path) -> None:
    dest = root / f"backup-llm-clients-{STAMP}"
    if not DRY:
        dest.mkdir(parents=True, exist_ok=True)
        shutil.copy2(path, dest / path.name)


def write(path: Path, text: str, root: Path) -> None:
    old = path.read_text() if path.exists() else None
    if old == text:
        return
    if old is not None:
        backup(path, root)
    if not DRY:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
    actions.append(f"wrote {path}")


def retire(path: Path, root: Path) -> None:
    if not path.exists():
        return
    backup(path, root)
    if not DRY:
        path.unlink()
    actions.append(f"removed {path} (backed up)")


# ── Qwen Code ──────────────────────────────────────────────────────────────────
def qwen() -> None:
    path = HOME / ".qwen" / "settings.json"
    d = json.loads(path.read_text()) if path.exists() else {"$version": 4}
    before = json.dumps(d, sort_keys=True)

    d.setdefault("modelProviders", {})["openai"] = [
        {"id": mid, "name": name, "baseUrl": GATEWAY, "envKey": KEY_ENV, "generationConfig": dict(QWEN_GEN)}
        for mid, name in MODELS
    ]
    d["model"] = {"name": MODELS[0][0], "baseUrl": GATEWAY, "generationConfig": dict(QWEN_GEN)}
    # 启动时真正决定打哪的是 security.auth.baseUrl，不是 model.baseUrl
    auth = d.setdefault("security", {}).setdefault("auth", {})
    auth["selectedType"] = "openai"
    auth["baseUrl"] = GATEWAY
    auth.pop("apiKey", None)  # 占位 key 会盖过 envKey（401）；真 key 也不该躺在这里

    env = d.get("env", {})
    for k in [k for k, v in env.items() if v == "dummy" or k == KEY_ENV]:
        env.pop(k)  # 占位 key 都已无条目引用；LITELLM_VK 从 ~/.secrets.sh 来，不留文件副本
    if "env" in d and not env:
        d.pop("env")

    servers = d.get("mcpServers", {})
    for name in [n for n, s in servers.items() if s.get("cwd") and not Path(s["cwd"]).is_dir()]:
        servers.pop(name)  # cwd 已不存在的 MCP 每次启动都报失败
        actions.append(f"qwen: dropped MCP server {name!r} (cwd gone)")
    if "mcpServers" in d and not servers:
        d.pop("mcpServers")

    if json.dumps(d, sort_keys=True) != before:
        write(path, json.dumps(d, ensure_ascii=False, indent=2) + "\n", path.parent)


# ── codex（TOML 按文本处理，写回前用 tomllib 校验）─────────────────────────────
HEADER = re.compile(r"^\[\[?\s*([^\]]+?)\s*\]\]?\s*(#.*)?$")


def strip_managed(text: str) -> str:
    return re.sub(rf"(?s){re.escape(BEGIN)}.*?{re.escape(END)}\n?", "", text)


def split(text: str) -> tuple[list[str], list[tuple[str, list[str]]]]:
    """(顶层行, [(表名, 表的全部行)])；表名按原文去掉方括号。"""
    pre: list[str] = []
    tables: list[tuple[str, list[str]]] = []
    for line in text.splitlines():
        m = HEADER.match(line)
        if m:
            tables.append((m.group(1), [line]))
        elif tables:
            tables[-1][1].append(line)
        else:
            pre.append(line)
    return pre, tables


def join(tables: list[tuple[str, list[str]]]) -> str:
    return "\n".join(line for _, lines in tables for line in lines).strip("\n")  # 原样保留表间空行


def under(name: str, prefix: str) -> bool:
    return name == prefix or name.startswith(prefix + ".")


def assemble(managed: str, rest: str) -> str:
    text = managed.rstrip("\n") + "\n"
    if rest.strip():
        text += "\n" + rest.strip("\n") + "\n"
    tomllib.loads(text)  # 不合法就在这里抛错，文件不会被写
    return text


def codex_profile_block(model: str, effort: str) -> str:
    return "\n".join([
        BEGIN, NOTE,
        f'model = "{model}"',
        'model_provider = "litellm"',
        f'model_reasoning_effort = "{effort}"',
        f"model_context_window = {CTX}",
        # 没有 catalog 时自动压缩靠这个阈值，别让长会话撞到网关上游的 262k 被拒收
        "model_auto_compact_token_limit = 200000",
        'web_search = "disabled"',  # OpenAI 托管的工具，自建上游不认
        "",
        "[model_providers.litellm]",
        'name = "LiteLLM (llm.meirong.dev)"',
        f'base_url = "{GATEWAY}"',
        f'env_key = "{KEY_ENV}"',
        'wire_api = "responses"',
        "",
        "[features]",
        "apps = false  # ChatGPT 的 apps/connectors，换了 provider 就用不了",
        END,
    ])


def codex() -> None:
    root = HOME / ".codex"  # 还没跑过 codex 的机器（Studio）也先把配置放好，首次启动就是对的

    # 1) 收集要退役的 profile 的信任记录与它们引用的 catalog
    migrated: dict[str, list[str]] = {}
    catalogs: set[Path] = set()
    for name in CODEX_RETIRED_PROFILES:
        p = root / f"{name}.config.toml"
        if not p.exists():
            continue
        data = tomllib.loads(p.read_text())
        if data.get("model_catalog_json"):
            catalogs.add(Path(os.path.expanduser(data["model_catalog_json"])))
        _, tables = split(p.read_text())
        for tname, lines in tables:
            if under(tname, "projects"):
                migrated.setdefault(tname, lines)

    # 2) 基础配置：默认模型（ChatGPT）进托管区；网关 provider 挪进各 profile；清掉坏掉的 MCP
    base = root / "config.toml"
    text = strip_managed(base.read_text()) if base.exists() else ""
    data = tomllib.loads(text) if text else {}
    dead_mcp = {n for n, s in data.get("mcp_servers", {}).items()
                if isinstance(s, dict) and s.get("cwd") and not Path(os.path.expanduser(s["cwd"])).is_dir()}
    pre, tables = split(text)
    kept_pre = [l for l in pre
                if l.strip() and not l.lstrip().startswith("#") and l.split("=")[0].strip() not in CODEX_BASE_KEYS]
    keep = []
    for tname, lines in tables:
        if under(tname, "model_providers.litellm"):
            continue
        if any(under(tname.replace('"', ""), f"mcp_servers.{n}") for n in dead_mcp):
            continue
        keep.append((tname, lines))
    for n in dead_mcp:
        actions.append(f"codex: dropped MCP server {n!r} (cwd gone)")
    managed = "\n".join([BEGIN, NOTE, *(f"{k} = {v}" for k, v in CODEX_BASE_KEYS.items()), END])
    if kept_pre:
        managed += "\n" + "\n".join(kept_pre)
    write(base, assemble(managed, join(keep)), root)

    # 3) 网关 profile：托管区 + 保留 codex 写的表（项目信任、tui、hooks.state）
    for name, (model, effort) in CODEX_PROFILES.items():
        p = root / f"{name}.config.toml"
        text = strip_managed(p.read_text()) if p.exists() else ""
        _, tables = split(text)  # 顶层行全部由托管区接管
        keep = [(t, l) for t, l in tables if not (under(t, "model_providers") or under(t, "features"))]
        if name == "litellm":
            have = {t for t, _ in keep}
            keep += [(t, l) for t, l in migrated.items() if t not in have]
        write(p, assemble(codex_profile_block(model, effort), join(keep)), root)

    # 4) 退役直连 profile 与它们的 catalog（都先备份）
    for name in CODEX_RETIRED_PROFILES:
        retire(root / f"{name}.config.toml", root)
    for c in catalogs:
        if c.parent == root:
            retire(c, root)


if __name__ == "__main__":
    qwen()
    codex()
    print(json.dumps({"changed": bool(actions), "dry_run": DRY, "actions": actions}, ensure_ascii=False))
