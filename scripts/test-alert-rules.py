#!/usr/bin/env python3
"""告警规则单元测试：对 PrometheusRule 清单跑 `promtool check rules` + `promtool test rules`。

为什么要有它（2026-11-22）：告警规则错了的典型外观是「不响」，和「没出事」一模一样。
apiserver-alerts.yaml 上线时手写了 23 组合成序列并做了变异验证，但那些测试只存在于临时目录，
之后没人能复现「测试通过」这句话。本脚本让测试跟着规则进仓库。

约定：
  · 测试放 scripts/alert-rule-tests/<name>.test.yaml，格式就是 promtool 的测试文件，
    外加一个顶层键 `source:`（PrometheusRule 清单的仓库相对路径）。
  · 本脚本把清单的 spec.groups 抽成 promtool 认的规则文件，替换掉测试里的 rule_files，再交给 promtool。
  · 跑测试时**去掉 annotations**：测试只断言 expr / for / labels 的语义；annotation 的模板语法由
    `promtool check rules`（带 annotations 的完整版）把关。
  · ☠️ 测试文件**不能**放进 k8s/helm/manifests/ 下面：monitoring-dashboards 等 App 递归同步目录，
    测试 YAML 会被当成清单去 apply。

promtool 版本：钉在现网 Prometheus 的版本（`prometheus_build_info`）。升 kube-prometheus-stack 后
同步改 PROMTOOL_IMAGE，并重跑一遍。优先用 docker；没有 docker 时退回本机 promtool。

用法：
  uv run --with pyyaml python scripts/test-alert-rules.py            # 缺 docker/promtool 时跳过（exit 0）
  uv run --with pyyaml python scripts/test-alert-rules.py --require  # CI：缺运行环境即失败
"""
import copy
import glob
import os
import shutil
import subprocess
import sys
import tempfile

import yaml

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TEST_DIR = os.path.join(ROOT, "scripts", "alert-rule-tests")
PROMTOOL_IMAGE = "prom/prometheus:v3.13.0"


def runner():
    """返回一个把 promtool 子命令跑在 workdir 里的函数；没有可用环境时返回 None。"""
    if shutil.which("docker") and subprocess.run(["docker", "info"], capture_output=True).returncode == 0:
        def run(workdir, args):
            return subprocess.run(["docker", "run", "--rm", "-v", f"{workdir}:/t", "-w", "/t",
                                   "--entrypoint", "promtool", PROMTOOL_IMAGE, *args],
                                  capture_output=True, text=True)
        return run, f"docker {PROMTOOL_IMAGE}"
    if shutil.which("promtool"):
        def run(workdir, args):
            return subprocess.run(["promtool", *args], cwd=workdir, capture_output=True, text=True)
        return run, "本机 promtool（版本未核对，CI 用钉死的镜像）"
    return None, None


def main():
    require = "--require" in sys.argv[1:]
    tests = sorted(glob.glob(os.path.join(TEST_DIR, "*.test.yaml")))
    if not tests:
        print("⚠️ 没有找到测试文件：", TEST_DIR)
        return 1 if require else 0
    run, how = runner()
    if run is None:
        msg = "未找到 docker 或 promtool，跳过告警规则测试（CI 仍会跑）"
        print(("❌ " if require else "   ⚠️ ") + msg)
        return 1 if require else 0

    fail = 0
    work = tempfile.mkdtemp(prefix="alert-rule-tests-")
    # ☠️ mkdtemp 建出来是 0700：prom/prometheus 镜像以 nobody 运行，进不了这个目录，promtool 报
    #   `stat …: permission denied`。macOS 上 OrbStack 的文件共享会映射权限，本地照样通过，只有
    #   Linux runner 上才炸（2026-11-22 CI 首跑实测）。文件权限也显式设，不赌 umask。
    os.chmod(work, 0o755)
    try:
        for path in tests:
            name = os.path.basename(path)[: -len(".test.yaml")]
            spec = yaml.safe_load(open(path, encoding="utf-8"))
            src = spec.pop("source", None)
            if not src:
                print(f"❌ {name}: 测试文件缺少顶层 `source:`")
                fail = 1
                continue
            crd = yaml.safe_load(open(os.path.join(ROOT, src), encoding="utf-8"))
            groups = crd["spec"]["groups"]
            full, stripped = f"{name}.full.yaml", f"{name}.rules.yaml"
            yaml.safe_dump({"groups": groups}, open(os.path.join(work, full), "w"), allow_unicode=True, width=10000)
            g2 = copy.deepcopy(groups)
            for g in g2:
                for r in g.get("rules", []):
                    r.pop("annotations", None)
            yaml.safe_dump({"groups": g2}, open(os.path.join(work, stripped), "w"), allow_unicode=True, width=10000)
            spec["rule_files"] = [stripped]
            yaml.safe_dump(spec, open(os.path.join(work, f"{name}.test.yaml"), "w"),
                           allow_unicode=True, width=10000, sort_keys=False)

            for fn in (full, stripped, f"{name}.test.yaml"):
                os.chmod(os.path.join(work, fn), 0o644)
            chk = run(work, ["check", "rules", full])
            tst = run(work, ["test", "rules", f"{name}.test.yaml"])
            n = len(spec.get("tests", []))
            if chk.returncode == 0 and tst.returncode == 0:
                print(f"✅ {name}: {n} 组测试通过（{src}）")
            else:
                fail = 1
                print(f"❌ {name}（{src}）")
                for label, res in (("check rules", chk), ("test rules", tst)):
                    if res.returncode != 0:
                        print(f"   ── promtool {label}:")
                        print("   " + (res.stdout + res.stderr).strip().replace("\n", "\n   "))
    finally:
        shutil.rmtree(work, ignore_errors=True)
    print(f"   运行环境：{how}")
    return fail


if __name__ == "__main__":
    sys.exit(main())
