#!/usr/bin/env python3
"""OpenAI 兼容的 /v1/images/generations —— 把同步请求翻译成 mflux-server 的异步任务。

为什么有它（选型与被否决的选项 → docs/decisions/studio-image-generation.md）：
  OMLX 不做文生图；mflux 是 Apple Silicon 上原生的 Qwen-Image-2.1 实现，但只有 CLI/Python API。
  Orbiter/mflux-server 把 mflux 包成了带排队的 HTTP 服务（一次只跑一个任务，GPU 独占），
  可它的接口是异步的 `/api/generate → /api/status → /api/image`，LiteLLM 和任何 OpenAI
  客户端都接不上。本文件只做这一层翻译，不碰模型。

  POST /v1/images/generations   OpenAI Images API（只回 b64_json，见下）
  GET  /v1/models               当前上游加载的模型
  GET  /healthz                 上游 /api/ps 能答 = 200
  GET  /metrics                 Prometheus 文本格式（job mflux-mac-studio 抓它）

☠️ 只回 b64_json：上游不存图（取一次就从队列里删掉），没有可以给出去的 URL。
   请求里写 response_format=url 会被 400 拒掉，而不是悄悄换格式让客户端去解析一个不存在的字段。
☠️ 取图必须带 delete（上游默认就是）：图片以编码后的字节常驻在上游进程内存里，
   不取走就一直占着。客户端中途断开时本进程照样把任务跑完、取走、丢弃。
☠️ 失败和超时要 /api/cancel：上游的出错任务**不会自己离开队列**。
☠️ 尺寸白名单（--sizes）不是洁癖：mflux-server 进程**每遇到一个新分辨率就多常驻约 13 GB 且永不释放**
   （2026-10-03 实测，已关 qwen21 context cache；开着时是 ~26 GB）。不限尺寸，外部用户随手换几个
   尺寸就能把 128G 的机器推进 swap，生成速度掉到三分之一。白名单让最坏情况有上界。
☠️ 队列上限（--max-pending）：一次只能出一张图，1024² 约 1 分钟，而公网入口 100s 就 524。
   OpenAI SDK 对 524 默认重试 2 次，**每次重试都会再提交一张新图** —— 实测一个请求在上游堆出 3 张、
   客户端照样失败。超过上限直接 429 + Retry-After，重试就不再制造 GPU 工作。

无鉴权：只在 tailnet 上监听，与 OMLX 的推理端点同一口径（allow_unauthenticated_inference）。
只用标准库，跑在 mflux-server 的同一个 venv 里（不需要额外依赖）。
"""

import argparse
import base64
import json
import subprocess
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ARGS = None
LOCK = threading.Lock()
SUBMIT_LOCK = threading.Lock()   # 「数队列 + 提交」必须原子，否则两个请求会同时看见空位
METRICS = {
    "requests": {},            # status label -> count
    "images": 0,
    "seconds_sum": 0.0,        # 从提交到取回，含排队
    "in_flight": 0,
    "last_success": 0.0,
}


def count(status):
    with LOCK:
        METRICS["requests"][status] = METRICS["requests"].get(status, 0) + 1


def upstream(path, body=None, timeout=30):
    url = ARGS.upstream.rstrip("/") + path
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, headers={"Content-Type": "application/json"} if data else {})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.status, r.read()


class Error(Exception):
    def __init__(self, status, message, kind="invalid_request_error"):
        super().__init__(message)
        self.status, self.message, self.kind = status, message, kind


def upstream_rss_bytes():
    """mflux-server 进程的常驻内存；拿不到返回 None（指标就不出这一行）。"""
    try:
        pid = subprocess.run(["pgrep", "-f", "mflux-server/server.py"], capture_output=True,
                             text=True, timeout=5).stdout.split()[0]
        rss_kb = subprocess.run(["ps", "-o", "rss=", "-p", pid], capture_output=True,
                                text=True, timeout=5).stdout.strip()
        return int(rss_kb) * 1024
    except Exception:
        return None


def pending_tasks():
    """上游队列里还没结束的任务数（end_time 在成功和失败时都会被设置）。"""
    _, raw = upstream("/api/tasks", timeout=10)
    return sum(1 for t in json.loads(raw) if not t.get("end_time"))


def generate_one(prompt, width, height, extra):
    """提交一个任务并等到它结束，返回 base64 PNG。"""
    body = {"prompt": prompt, "width": width, "height": height, "format": "PNG", **extra}
    try:
        with SUBMIT_LOCK:
            pending = pending_tasks()
            if pending >= ARGS.max_pending:
                raise Error(429, f"image generator busy ({pending} in queue, about 1 minute each); "
                                 "retry later, one request at a time", "rate_limit_error")
            _, raw = upstream("/api/generate", body)
    except urllib.error.HTTPError as e:
        # 上游的 400 带着可读的原因（尺寸不是 16 的倍数、步数太少……），原样转给调用方。
        # flask-restx 的入参校验失败是 {"message": ..., "errors": {...}}，形状不同，一并兼容。
        raw = e.read() or b""
        try:
            detail = json.loads(raw)
            msg = detail.get("error") or detail.get("message") or ""
            if detail.get("errors"):
                msg = f"{msg} {detail['errors']}".strip()
        except ValueError:
            msg = raw.decode(errors="replace")[:300]
        raise Error(e.code, msg or f"upstream {e.code}")
    task_id = json.loads(raw)["task_id"]
    deadline = time.time() + ARGS.timeout
    try:
        while True:
            if time.time() > deadline:
                raise Error(504, f"image not ready after {ARGS.timeout}s (task {task_id})", "timeout")
            try:
                _, raw = upstream("/api/status?task_id=" + task_id)
            except urllib.error.HTTPError as e:
                raise Error(502, f"task {task_id} vanished upstream ({e.code})", "upstream_error")
            st = json.loads(raw)
            if st["status"] == "done":
                _, b64 = upstream(f"/api/image?task_id={task_id}&base64=true&delete=true", timeout=60)
                task_id = None          # 已被上游删除，finally 里不用再 cancel
                return b64.decode()
            if st["status"] == "error":
                raise Error(500, st.get("error") or "generation failed", "upstream_error")
            time.sleep(ARGS.poll)
    finally:
        if task_id:
            try:
                upstream("/api/cancel?task_id=" + task_id)
            except Exception:
                pass


class Handler(BaseHTTPRequestHandler):
    server_version = "openai-images-shim/1"

    def log_message(self, fmt, *a):      # 一行一请求，进 LaunchAgent 的日志文件
        print("%s %s" % (self.address_string(), fmt % a), flush=True)

    def reply(self, status, obj, ctype="application/json"):
        data = obj if isinstance(obj, bytes) else json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        if status == 429:
            self.send_header("Retry-After", "60")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        try:
            self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError):
            pass                         # 客户端已走；图已从上游取走，丢弃即可

    def do_GET(self):
        path = urllib.parse.urlparse(self.path).path
        if path == "/v1/models":
            try:
                _, raw = upstream("/api/ps", timeout=5)
                model = json.loads(raw)["model"]
            except Exception:
                return self.reply(502, {"error": {"message": "upstream unreachable", "type": "upstream_error"}})
            return self.reply(200, {"object": "list", "data": [
                {"id": ARGS.model_id, "object": "model", "owned_by": "mflux", "upstream_model": model}]})
        if path == "/healthz":
            try:
                upstream("/api/ps", timeout=5)
                return self.reply(200, {"ok": True})
            except Exception as e:
                return self.reply(503, {"ok": False, "error": str(e)})
        if path == "/metrics":
            try:
                upstream("/api/ps", timeout=5)
                up = 1
            except Exception:
                up = 0
            with LOCK:
                m = json.loads(json.dumps(METRICS))
            rss = upstream_rss_bytes()
            lines = [
                "# HELP mflux_upstream_up mflux-server answers /api/ps",
                "# TYPE mflux_upstream_up gauge", f"mflux_upstream_up {up}",
                "# HELP mflux_requests_total /v1/images/generations requests by outcome",
                "# TYPE mflux_requests_total counter",
                *[f'mflux_requests_total{{status="{k}"}} {v}' for k, v in sorted(m["requests"].items())],
                "# HELP mflux_images_total images returned to clients",
                "# TYPE mflux_images_total counter", f"mflux_images_total {m['images']}",
                "# HELP mflux_image_seconds_total submit-to-fetch time, queueing included",
                "# TYPE mflux_image_seconds_total counter", f"mflux_image_seconds_total {m['seconds_sum']:.3f}",
                "# HELP mflux_in_flight requests waiting on the upstream queue",
                "# TYPE mflux_in_flight gauge", f"mflux_in_flight {m['in_flight']}",
                "# HELP mflux_last_success_timestamp_seconds unix time of the last returned image",
                "# TYPE mflux_last_success_timestamp_seconds gauge",
                f"mflux_last_success_timestamp_seconds {m['last_success']:.0f}",
                "# HELP mflux_upstream_rss_bytes resident memory of the mflux-server process",
                "# TYPE mflux_upstream_rss_bytes gauge",
                *([f"mflux_upstream_rss_bytes {rss}"] if rss is not None else []),
            ]
            return self.reply(200, ("\n".join(lines) + "\n").encode(), "text/plain; version=0.0.4")
        self.reply(404, {"error": {"message": "not found", "type": "invalid_request_error"}})

    def do_POST(self):
        if urllib.parse.urlparse(self.path).path != "/v1/images/generations":
            return self.reply(404, {"error": {"message": "not found", "type": "invalid_request_error"}})
        with LOCK:
            METRICS["in_flight"] += 1
        started = time.time()
        try:
            try:
                req = json.loads(self.rfile.read(int(self.headers.get("Content-Length") or 0)) or b"{}")
            except ValueError:
                raise Error(400, "body is not JSON")
            prompt = req.get("prompt")
            if not prompt:
                raise Error(400, "prompt is required")
            if req.get("response_format", "b64_json") != "b64_json":
                raise Error(400, "only response_format=b64_json is supported (images are not stored)")
            n = int(req.get("n") or 1)
            if not 1 <= n <= ARGS.max_n:
                raise Error(400, f"n must be 1..{ARGS.max_n}")
            size = str(req.get("size") or ARGS.sizes[0]).lower()
            if size not in ARGS.sizes:
                raise Error(400, f"size {size!r} not offered; choose one of: {', '.join(ARGS.sizes)}")
            w, h = (int(x) for x in size.split("x"))
            # 非 OpenAI 字段原样透传给上游（OpenAI SDK 用 extra_body 发），其余忽略
            extra = {k: req[k] for k in ("seed", "steps", "guidance", "negative_prompt") if k in req}
            if "seed" in extra:
                # 上游把 seed 声明成字符串且开着严格校验，整数会被当成入参错误 400
                extra["seed"] = str(extra["seed"])
            data = []
            for i in range(n):
                if "seed" in extra and n > 1:
                    extra = {**extra, "seed": str(int(extra["seed"]) + i)}
                data.append({"b64_json": generate_one(prompt, w, h, extra), "revised_prompt": None})
            with LOCK:
                METRICS["images"] += n
                METRICS["seconds_sum"] += time.time() - started
                METRICS["last_success"] = time.time()
            count("ok")
            self.reply(200, {"created": int(started), "data": data})
        except Error as e:
            count(e.kind)
            self.reply(e.status, {"error": {"message": e.message, "type": e.kind}})
        except (urllib.error.URLError, ConnectionError) as e:
            count("upstream_error")
            self.reply(502, {"error": {"message": f"mflux-server unreachable: {e}", "type": "upstream_error"}})
        except Exception as e:           # 别让未预料的异常变成「连接被重置」
            count("internal_error")
            self.reply(500, {"error": {"message": f"{type(e).__name__}: {e}", "type": "internal_error"}})
        finally:
            with LOCK:
                METRICS["in_flight"] -= 1


def main():
    global ARGS
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--host", default="0.0.0.0")
    p.add_argument("--port", type=int, default=8010)
    p.add_argument("--upstream", default="http://127.0.0.1:4030")
    p.add_argument("--model-id", default="qwen-image-2.1")
    p.add_argument("--timeout", type=int, default=900, help="seconds to wait for one image, queueing included")
    p.add_argument("--poll", type=float, default=1.0)
    p.add_argument("--max-n", type=int, default=4)
    p.add_argument("--max-pending", type=int, default=2, help="429 when this many tasks are unfinished upstream")
    p.add_argument("--sizes", default="1024x1024,768x768,1280x720,720x1280",
                   help="allowed WxH, comma separated; the first is the default")
    ARGS = p.parse_args()
    ARGS.sizes = [x.strip().lower() for x in ARGS.sizes.split(",") if x.strip()]
    ThreadingHTTPServer((ARGS.host, ARGS.port), Handler).serve_forever()


if __name__ == "__main__":
    main()
