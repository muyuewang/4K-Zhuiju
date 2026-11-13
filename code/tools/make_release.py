"""创建 GitHub Release 并上传产物。

为什么用 curl 而不是 urllib：本环境 urllib 走代理 POST 会报
SSL: UNEXPECTED_EOF_WHILE_READING，curl 同一请求正常返回。
为什么不用 gh CLI：本机没有装。
"""
import json
import os
import subprocess
import tempfile

REPO = "muyuewang/4K-Zhuiju"

ROOT = r"C:\Users\fengxin\WorkBuddy\vivos7"

# 版本号从 pubspec.yaml 读，不再硬编码。
# 之前这里是手写的 TAG / NAME / ASSETS / NOTES，升版本时靠人记得来改；
# 漏改的后果很隐蔽：脚本会把新产物按旧 tag 发上去，或者在 dist/v旧版本/
# 目录里找不到文件而报「asset 不存在」，看着像打包失败，其实是路径过期。
def _read_version():
    import re

    pubspec = os.path.join(ROOT, "code", "flutter_app", "pubspec.yaml")
    with open(pubspec, encoding="utf-8") as f:
        for line in f:
            m = re.match(r"^version:\s*([0-9][^\s+]*)\+(\d+)", line)
            if m:
                return m.group(1), m.group(2)
    raise SystemExit(f"无法从 {pubspec} 读取版本号")


VERSION, BUILD = _read_version()
TAG = f"v{VERSION}"
NAME = f"4K追剧 v{VERSION}"

ASSETS = [
    (
        rf"dist\{TAG}\4KZhuiju-{TAG}-release.apk",
        f"4KZhuiju-{TAG}-release.apk",
    ),
    (
        rf"dist\{TAG}\4KZhuiju-{TAG}-windows-x64.zip",
        f"4KZhuiju-{TAG}-windows-x64.zip",
    ),
]
NOTES = rf"dist\{TAG}\RELEASE_NOTES.md"

# 代理端口别写死：本机在不同网络环境下换过 7897 / 13153 等端口，
# 写死会让脚本在换环境后直接连不上而报「curl 失败」，看起来像 GitHub 挂了。
# 依次取 HTTPS_PROXY / HTTP_PROXY，都没有就走直连（PROXY=None）。
def _detect_proxy():
    for k in ("HTTPS_PROXY", "https_proxy", "HTTP_PROXY", "http_proxy"):
        v = os.environ.get(k, "").strip()
        if v:
            return v
    return None


PROXY = _detect_proxy()
API = "https://api.github.com"

_tok = None


def token():
    global _tok
    if _tok:
        return _tok
    p = subprocess.run(
        ["git", "credential", "fill"],
        input="protocol=https\nhost=github.com\n\n",
        capture_output=True,
        text=True,
        cwd=ROOT,
    )
    for line in p.stdout.splitlines():
        if line.startswith("password="):
            _tok = line[len("password="):]
            return _tok
    raise SystemExit("凭据里没有 password")


def _proxy_args():
    """PROXY 为 None 时必须整个省略 --proxy，否则 curl 会拿到字符串 "None"。"""
    return ["--proxy", PROXY] if PROXY else []


def api(path, method="GET", payload=None, timeout=180):
    url = path if path.startswith("http") else f"{API}/repos/{REPO}{path}"
    cmd = [
        "curl", "-s", "-w", "\n%{http_code}",
        "--max-time", str(timeout),
        *_proxy_args(),
        "--ssl-no-revoke",
        "-X", method, url,
        "-H", f"Authorization: Bearer {token()}",
        "-H", "Accept: application/vnd.github+json",
        "-H", "X-GitHub-Api-Version: 2022-11-28",
        "-H", "User-Agent: zhuiju-release-script",
    ]
    tmp = None
    if payload is not None:
        fd, tmp = tempfile.mkstemp(suffix=".json")
        with os.fdopen(fd, "wb") as f:
            f.write(json.dumps(payload).encode("utf-8"))
        cmd += ["-H", "Content-Type: application/json", "--data-binary", f"@{tmp}"]
    try:
        p = subprocess.run(cmd, capture_output=True)
    finally:
        if tmp:
            os.unlink(tmp)
    if p.returncode != 0:
        raise SystemExit(f"curl 失败({p.returncode}): {p.stderr.decode('utf-8','replace')[:300]}")
    raw = p.stdout.decode("utf-8", "replace")
    body, _, code = raw.rpartition("\n")
    status = int(code.strip())
    try:
        parsed = json.loads(body) if body.strip() else None
    except json.JSONDecodeError:
        parsed = body
    return status, parsed


def upload(upload_url, path, name):
    """uploads.github.com 上传资产，不设 Content-Type（让 GitHub 自行判断）。"""
    url = upload_url.split("{")[0] + "?name=" + __import__("urllib.parse", fromlist=["quote"]).quote(name)
    size = os.path.getsize(path)
    cmd = [
        "curl", "-s", "-w", "\n%{http_code}",
        "--max-time", "900",
        *_proxy_args(),
        "--ssl-no-revoke",
        "-X", "POST", url,
        "-H", f"Authorization: Bearer {token()}",
        "-H", "Accept: application/vnd.github+json",
        "-H", "Content-Type: application/octet-stream",
        "-H", "User-Agent: zhuiju-release-script",
        "--data-binary", f"@{path}",
    ]
    p = subprocess.run(cmd, capture_output=True)
    if p.returncode != 0:
        return -1, f"curl {p.returncode}: {p.stderr.decode('utf-8','replace')[:300]}"
    raw = p.stdout.decode("utf-8", "replace")
    body, _, code = raw.rpartition("\n")
    status = int(code.strip())
    try:
        parsed = json.loads(body) if body.strip() else None
    except json.JSONDecodeError:
        parsed = body
    print(f"    上传 {size} 字节 -> HTTP {status}")
    return status, parsed


def main():
    with open(os.path.join(ROOT, NOTES), "r", encoding="utf-8") as f:
        body = f.read()
    print(f"发布说明 {len(body)} 字符")

    st, existing = api(f"/releases/tags/{TAG}")
    if st == 200:
        rid = existing["id"]
        print(f"已存在 release id={rid}，先删除")
        api(f"/releases/{rid}", method="DELETE")

    payload = {
        "tag_name": TAG,
        "name": NAME,
        "body": body,
        "draft": False,
        "prerelease": False,
    }
    st, rel = api("/releases", method="POST", payload=payload)
    if st not in (200, 201):
        raise SystemExit(f"创建 release 失败: HTTP {st}\n{rel}")
    print(f"release 创建成功: {rel['html_url']}")

    for rel_path, name in ASSETS:
        full = os.path.join(ROOT, rel_path)
        if not os.path.exists(full):
            print(f"跳过（不存在）: {name}")
            continue
        mb = os.path.getsize(full) / 1048576
        print(f"上传 {name} ({mb:.1f} MB)...")
        st, res = upload(rel["upload_url"], full, name)
        if st in (200, 201):
            print(f"  OK -> {res['browser_download_url']}")
        else:
            print(f"  失败 HTTP {st}: {str(res)[:300]}")

    print(f"\n完成: {rel['html_url']}")


if __name__ == "__main__":
    main()