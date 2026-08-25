#!/usr/bin/env python3
"""E1 — ConfigMap 里内嵌的脚本必须与同目录的源文件逐字节一致。

为什么需要这条：有些负载（cf-analytics-exporter）跑的是通用镜像 + ConfigMap 挂进去的
脚本。脚本要能被编辑器/linter 当代码看，就得有一个真的 `.py` 文件；要能被 ArgoCD 部署，
就得再有一份嵌在 YAML 里。两份副本一旦漂移，**改的是源文件、跑的是旧副本**，而且看不出
任何异常——git diff 干净、ArgoCD Synced、pod Running，只有行为是旧的。

规则：对 TARGETS 里的每一项
  a) ConfigMap 的 `data[<key>]` 必须等于源文件内容；
  b) 消费它的 Deployment 的 pod 模板注解 `checksum/<...>` 必须等于源文件的 sha256 前 16 位。

(b) 是另一半陷阱：ConfigMap 变了 **kubectl / ArgoCD 都不会重启 pod**，进程还跑着启动时
读进内存的旧脚本。git 干净、ArgoCD Synced、pod Running、行为是旧的——跟 (a) 同一种静默。
把 hash 写进 pod 模板，脚本一变模板就变，ArgoCD 自然滚动重启。

  检查:  python3 scripts/check-embedded-scripts.py
  修复:  python3 scripts/check-embedded-scripts.py --write   （= just gen-embedded-scripts）

加新目标：在 TARGETS 里加一项。要求 YAML 的 data 块只有这一个 key 且位于文件末尾
（生成器按「`key: |` 之后到文件尾」整段替换，以保住文件头的注释）。

──────────────────────────────────────────────────────────────────────
STAMP_ONLY —— 只有上面 (b) 那一半的目标。

有些内嵌内容压根没有、也不该有外部源文件：LiteLLM 的路由表就只存在于 ConfigMap 里
（抽成外部 `.yaml` 会落在 ArgoCD 的同步目录里被当成清单 apply 然后失败）。这类目标不校验
(a)「两份副本一致」，只做 (b)「hash 进 pod 模板」—— 因为让它出事的是同一个机制：
**subPath 挂载不接收 ConfigMap 更新，且进程只在启动时读配置**。

STAMP_ONLY 只读不写，所以直接用 YAML 解析器取 `data[key]`（不像 TARGETS 那样按缩进硬读
——那条路要求块在文件末尾，且对 `key: ""` 这种空标量直接失效）。因此 ConfigMap 和消费它的
Deployment 可以留在同一个文件里，不用为了加保护去拆清单。

`key` 可以是列表：一个 ConfigMap 的多个 key 合成**一个**注解（homepage 有 6 个）。
"""

from __future__ import annotations

import hashlib
import re
import sys

import yaml
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent

TARGETS = [
    {
        "src": "k8s/helm/manifests/monitoring/cf-analytics-exporter/exporter.py",
        "cm": "k8s/helm/manifests/monitoring/cf-analytics-exporter/cf-analytics-exporter-cm.yaml",
        "key": "exporter.py",
        # 写 hash 的地方：(文件, 注解名)
        "stamp": ("k8s/helm/manifests/monitoring/cf-analytics-exporter/cf-analytics-exporter.yaml",
                  "checksum/exporter-py"),
    },
]

# 只做 (b)：哈希 ConfigMap 里的内嵌块 → 写进 pod 模板注解。无外部源文件、块不必在文件末尾。
STAMP_ONLY = [
    {
        "cm": "k8s/helm/manifests/litellm/litellm.yaml",
        "key": "config.yaml",
        "stamp": ("k8s/helm/manifests/litellm/litellm.yaml", "checksum/config"),
        # 为什么需要：这是网关的整张路由表（model_name→上游、api_base、fallbacks）。
        # 2026-08-25 实际踩过：ConfigMap 同步成功、ArgoCD Synced/Healthy、pod Running，
        # 而网关按旧路由表继续跑，必须手动 rollout restart 才生效。
        "why": "LiteLLM 路由表",
    },
    {
        "cm": "cloud/oracle/manifests/homepage/homepage.yaml",
        # 一个 ConfigMap 六个块 → 一个注解。哈希覆盖全部 key（含 key 名，改名也算变）。
        "key": ["settings.yaml", "bookmarks.yaml", "services.yaml",
                "widgets.yaml", "kubernetes.yaml", "docker.yaml"],
        "stamp": ("cloud/oracle/manifests/homepage/homepage.yaml", "checksum/config"),
        # 为什么需要：六个块全是 subPath 挂载。改 services/bookmarks 之类的配置后
        # 文件不会刷新、进程也不会重启，表现就是"我改了但仪表盘没变"。
        "why": "homepage 仪表盘配置",
    },
]


def find_block(lines: list[str], key: str) -> tuple[int, str]:
    """返回 (`key: |` 所在行号, 块内缩进)。"""
    for i, line in enumerate(lines):
        stripped = line.strip()
        if stripped in (f"{key}: |", f"{key}: |-"):
            outer = len(line) - len(line.lstrip())
            return i, " " * (outer + 2)
    raise SystemExit(f"❌ 找不到 `{key}: |` 块；见 scripts/check-embedded-scripts.py 文件头的布局要求")


def embedded(lines: list[str], start: int, indent: str) -> str:
    body = []
    for line in lines[start + 1:]:
        if line.strip() and not line.startswith(indent):
            raise SystemExit(f"❌ 块后还有别的内容（第 {start + 1} 行起）——data 块必须在文件末尾")
        body.append(line[len(indent):] if line.strip() else "\n")
    return "".join(body)


def configmap_data(path: Path) -> dict[str, str]:
    """返回该文件里 ConfigMap 的 data ——**按 Kubernetes 实际看到的值**。

    STAMP_ONLY 只需要读，所以直接交给 YAML 解析器，而不是按缩进硬读 `key: |` 块。
    这不是洁癖：homepage 的 `docker.yaml: ""` 是空标量、压根没有 `|` 块，按缩进读会
    直接找不到（2026-08-25 踩到）。解析器顺带把 `|-` / `>` / 引号标量也一并处理对。
    """
    docs = [d for d in yaml.safe_load_all(path.read_text(encoding="utf-8"))
            if d and d.get("kind") == "ConfigMap"]
    if len(docs) != 1:
        raise SystemExit(f"❌ {path} 里应恰好有 1 个 ConfigMap，实际 {len(docs)} 个")
    return docs[0].get("data") or {}


def stamp(path: Path, annotation: str, digest: str, write: bool) -> bool:
    """校验/写入 pod 模板里的 checksum 注解。返回 True = 一致（或已写入）。"""
    text = path.read_text(encoding="utf-8")
    pattern = re.compile(rf'^(\s*{re.escape(annotation)}:\s*)"[^"]*"$', re.MULTILINE)
    if not pattern.search(text):
        raise SystemExit(f'❌ {path} 里找不到注解 `{annotation}: "..."`')
    if not write:
        return pattern.search(text).group(0).endswith(f'"{digest}"')
    path.write_text(pattern.sub(rf'\g<1>"{digest}"', text), encoding="utf-8")
    return True


def main() -> int:
    write = "--write" in sys.argv
    bad = 0

    for t in TARGETS:
        src, dst = REPO / t["src"], REPO / t["cm"]
        source = src.read_text(encoding="utf-8")
        digest = hashlib.sha256(source.encode()).hexdigest()[:16]
        lines = dst.read_text(encoding="utf-8").splitlines(keepends=True)
        start, indent = find_block(lines, t["key"])

        if write:
            rendered = [indent + ln if ln.strip() else "\n" for ln in source.splitlines(keepends=True)]
            dst.write_text("".join(lines[:start + 1] + rendered), encoding="utf-8")
            stamp(REPO / t["stamp"][0], t["stamp"][1], digest, True)
            print(f'✍️  {t["cm"]} ← {t["src"]}  (checksum {digest})')
            continue

        if embedded(lines, start, indent) != source:
            print(f'❌ {t["cm"]} 内嵌的 {t["key"]} 与 {t["src"]} 不一致 —— 跑 `just gen-embedded-scripts`')
            bad += 1
        if not stamp(REPO / t["stamp"][0], t["stamp"][1], digest, False):
            print(f'❌ {t["stamp"][0]} 的 {t["stamp"][1]} 不是 {digest} —— 脚本改了但 pod 不会重启，'
                  f"跑 `just gen-embedded-scripts`")
            bad += 1

    for t in STAMP_ONLY:
        keys = t["key"] if isinstance(t["key"], list) else [t["key"]]
        data = configmap_data(REPO / t["cm"])
        missing = [k for k in keys if k not in data]
        if missing:
            raise SystemExit(f'❌ {t["cm"]} 的 ConfigMap 没有 key: {missing}')
        # 哈希只覆盖值（按列表顺序、\0 分隔）。不含 key 名：重命名 key 必然同时改 pod
        # 模板里的 subPath，模板本身就变了，不需要哈希再兜一遍。
        digest = hashlib.sha256(b"\0".join(data[k].encode() for k in keys)).hexdigest()[:16]

        if write:
            stamp(REPO / t["stamp"][0], t["stamp"][1], digest, True)
            print(f'✍️  {t["stamp"][0]} 的 {t["stamp"][1]} ← {t["cm"]}:{",".join(keys)}  (checksum {digest})')
            continue

        if not stamp(REPO / t["stamp"][0], t["stamp"][1], digest, False):
            print(f'❌ {t["stamp"][0]} 的 {t["stamp"][1]} 不是 {digest} —— '
                  f'{t["why"]}改了但 pod 不会重启，跑 `just gen-embedded-scripts`')
            bad += 1

    if write:
        return 0
    if bad:
        return 1
    print(f"✅ E1: {len(TARGETS)} 处内嵌脚本与源文件一致（含 pod 模板 checksum）；"
          f"{len(STAMP_ONLY)} 处内嵌配置的 checksum 已同步")
    return 0


if __name__ == "__main__":
    sys.exit(main())
