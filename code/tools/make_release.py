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
TAG = "v1.7.1"
NAME = "4K追剧 v1.7.1"

ROOT = r"C:\Users\fengxin\WorkBuddy\vivos7"
ASSETS = [
    (r"dist\v1.7.1\4KZhuiju-v1.7.1-release.apk", "4KZhuiju-v1.7.1-release.apk"),
    (r"dist\v1.7.1\4KZhuiju-v1.7.1-windows-x64.zip", "4KZhuiju-v1.7.1-windows-x64.zip"),
]
NOTES = r"dist\v1.7.1\RELEASE_NOTES.md"
PROXY = "http://127.0.0.1:7897"
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


def api(path, method="GET", payload=None, timeout=180):
    url = path if path.startswith("http") else f"{API}/repos/{REPO}{path}"
    cmd = [
        "curl", "-s", "-w", "\n%{http_code}",
        "--max-time", str(timeout),
        "--proxy", PROXY,
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
        "--proxy", PROXY,
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