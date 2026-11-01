"""本机测试服务：照线上的路径摆，/tengchao/ = 誊抄僧，/pabiao/ = 渡表僧（只读，用它的模型），/luruseng/key.html 给个占位。
另带一个假谷歌：/v1beta/models/<模型>:generateContent?key=<钥匙>，按钥匙开头决定怎么回（照渡表僧 run_e2e 的路子）。"""
import json
import re
import threading
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

ROOT = Path(__file__).resolve().parents[1]
PABIAO = ROOT.parent / "扒表僧"
FAKE = {"calls": {}, "text": "11月1日 各线产量\nA线早班 1,280件\nB线早班 960件", "text2": None}
lock = threading.Lock()


def gemini_ok(text):
    return 200, {"candidates": [{"content": {"parts": [{"text": json.dumps({"text": text}, ensure_ascii=False)}], "role": "model"}, "finishReason": "STOP"}]}


def err(code, status, msg, details=None):
    e = {"code": code, "message": msg, "status": status}
    if details:
        e["details"] = details
    return code, {"error": e}


def quota(per):
    qid = f"GenerateRequestsPer{per}PerProjectPerModel-FreeTier"
    det = [{"@type": "type.googleapis.com/google.rpc.QuotaFailure", "violations": [{"quotaId": qid}]}]
    if per == "Minute":
        det.append({"@type": "type.googleapis.com/google.rpc.RetryInfo", "retryDelay": "2s"})
    return err(429, "RESOURCE_EXHAUSTED", "You exceeded your current quota, please check your plan and billing details.", det)


def fake(model, key):
    if model == "gemini-nope":
        return err(404, "NOT_FOUND", f"models/{model} is not found for API version v1beta, or is not supported for generateContent.")
    with lock:
        n = FAKE["calls"][key] = FAKE["calls"].get(key, 0) + 1
    kind = key.split("_")[0]
    if kind == "bad":
        return err(400, "INVALID_ARGUMENT", "API key not valid. Please pass a valid API key.",
                   [{"@type": "type.googleapis.com/google.rpc.ErrorInfo", "reason": "API_KEY_INVALID"}])
    if kind == "html":
        return 200, "<html><body><h1>502 Bad Gateway</h1></body></html>"
    if kind == "minute" and n == 1:
        return quota("Minute")
    if kind == "day":
        return quota("Day")
    if kind == "split" and n % 2 == 0 and FAKE["text2"]:
        return gemini_ok(FAKE["text2"])
    return gemini_ok(FAKE["text"])


class Handler(SimpleHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def end_headers(self):
        self.send_header("Cache-Control", "no-store")
        super().end_headers()

    def translate_path(self, path):
        p = urlparse(path).path
        if p.startswith("/pabiao/"):
            return str(PABIAO / p[len("/pabiao/"):])
        if p.startswith("/tengchao/"):
            return str(ROOT / p[len("/tengchao/"):])
        if p == "/luruseng/key.html":
            return str(ROOT / "tests" / "key_placeholder.html")
        return str(ROOT / "tests" / "nothing")

    def do_POST(self):
        u = urlparse(self.path)
        m = re.match(r"^/v1beta/models/([^/:]+):generateContent$", u.path)
        self.rfile.read(int(self.headers.get("Content-Length") or 0))
        if not m:
            self.send_error(404)
            return
        if "x-goog-api-key" in {k.lower() for k in self.headers.keys()}:
            self.send_error(400, "钥匙只许走 ?key=")
            return
        code, out = fake(m.group(1), parse_qs(u.query).get("key", [""])[0])
        data = out.encode() if isinstance(out, str) else json.dumps(out, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", "text/html" if isinstance(out, str) else "application/json; charset=UTF-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


def serve():
    srv = ThreadingHTTPServer(("127.0.0.1", 0), partial(Handler, directory=str(ROOT)))
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv, srv.server_address[1]
