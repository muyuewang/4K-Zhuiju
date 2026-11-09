"""补传单个 release 资产（可重复执行）。

背景：v1.6.0 首次上传 APK 时 curl 报 `curl 56`（连接被对端重置），
55.6 MB 的大文件走代理容易中途断。Windows 包只有 12 MB，一次就过了。

重传整个 release 不合适：那样会删掉已成功的 zip，还得多传一次 55 MB。
这里只针对缺的那一个资产做「删同名 → 重传 → 校验字节数」，并且带重试。

用法：
    python code/tools/retry_upload.py <tag> <本地文件路径> <资产名>

为什么校验的是 size 而不是 sha：GitHub API 的资产不返回 digest，
但返回 size。字节数一致 + state=uploaded 足以判断是否传完整。
"""
import json
import os
import subprocess
import sys
import tempfile

REPO = "muyuewang/4K-Zhuiju"
ROOT = r"C:\Users\fengxin\WorkBuddy\vivos7"
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
    raw = p.stdout.decode("utf-8", "replace")
    body, _, code = raw.rpartition("\n")
    try:
        status = int(code.strip())
    except ValueError:
        status = -1
    try:
        parsed = json.loads(body) if body.strip() else None
    except json.JSONDecodeError:
        parsed = body
    return status, parsed


def upload_once(upload_url, path, name):
    url = upload_url.split("{")[0] + "?name=" + name
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
        return -1, f"curl {p.returncode}: {p.stderr.decode('utf-8', 'replace')[:200]}"
    raw = p.stdout.decode("utf-8", "replace")
    body, _, code = raw.rpartition("\n")
    try:
        status = int(code.strip())
    except ValueError:
        status = -1
    try:
        parsed = json.loads(body) if body.strip() else None
    except json.JSONDecodeError:
        parsed = body
    return status, parsed


def main():
    if len(sys.argv) < 4:
        raise SystemExit("用法: retry_upload.py <tag> <本地文件> <资产名>")
    tag, local, name = sys.argv[1], sys.argv[2], sys.argv[3]
    full = os.path.join(ROOT, local) if not os.path.isabs(local) else local
    if not os.path.exists(full):
        raise SystemExit(f"本地文件不存在: {full}")
    size = os.path.getsize(full)
    print(f"本地 {name}: {size} 字节 ({size/1048576:.2f} MB)")

    st, rel = api(f"/releases/tags/{tag}")
    if st != 200:
        raise SystemExit(f"读 release 失败: HTTP {st} {str(rel)[:200]}")
    rid = rel["id"]
    upload_url = rel["upload_url"]
    print(f"release id={rid}")

    # 已存在同名资产则先删，否则 GitHub 会返回 422
    for a in rel.get("assets", []):
        if a["name"] == name:
            print(f"删除同名旧资产 id={a['id']} (size={a['size']})")
            st2, _ = api(f"/releases/assets/{a['id']}", method="DELETE")
            print(f"  删除结果 HTTP {st2}")

    for attempt in range(1, 6):
        print(f"第 {attempt} 次上传…")
        st, res = upload_once(upload_url, full, name)
        if st in (200, 201):
            got = res.get("size", -1)
            print(f"  HTTP {st}, 远端 size={got}")
            if got == size:
                print(f"OK -> {res['browser_download_url']}")
                return
            print(f"  尺寸不一致（本地 {size}），重试")
            # 尺寸不符的资产要删掉，否则下次上传会 422
            api(f"/releases/assets/{res['id']}", method="DELETE")
        else:
            print(f"  失败 HTTP {st}: {str(res)[:200]}")

    raise SystemExit("重试 5 次仍失败")


if __name__ == "__main__":
    main()