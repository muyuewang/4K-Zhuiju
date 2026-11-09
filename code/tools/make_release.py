"""创建 GitHub Release 并上传产物。

为什么不用 gh CLI：本机没有装。
为什么用 urllib 而不是 curl：curl 在 Windows schannel 下会遇到证书吊销检查
离线（CRYPT_E_REVOCATION_OFFLINE），需要 --ssl-no-revoke；Python 的 ssl 默认
不做吊销检查，反而更省事。
"""
import json
import os
import subprocess
import ssl
import sys
import urllib.error
import urllib.parse
import urllib.request

REPO = "muyuewang/4K-Zhuiju"
TAG = "v1.3.0"
NAME = "4K追剧 v1.3.0"

ROOT = r"C:\Users\fengxin\WorkBuddy\vivos7"
ASSETS = [
    (r"dist\v1.3.0\4KZhuiju-v1.3.0-release.apk", "4KZhuiju-v1.3.0-release.apk"),
    (r"dist\v1.3.0\4KZhuiju-v1.3.0-windows-x64.zip", "4KZhuiju-v1.3.0-windows-x64.zip"),
]
NOTES = r"dist\v1.3.0\RELEASE_NOTES.md"


def get_token():
    """从 git 凭据管理器取 GitHub token（与 git push 用的是同一份）。"""
    p = subprocess.run(
        ["git", "credential", "fill"],
        input="protocol=https\nhost=github.com\n\n",
        capture_output=True,
        text=True,
        cwd=ROOT,
    )
    for line in p.stdout.splitlines():
        if line.startswith("password="):
            return line[len("password="):]
    raise SystemExit("凭据里没有 password，无法取得 token")


def api(url, token, method="GET", payload=None):
    data = None
    headers = {
        "Authorization": f"Bearer {token}",
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
        "User-Agent": "zhuiju-release-script",
    }
    if payload is not None:
        data = json.dumps(payload).encode("utf-8")
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    try:
        with urllib.request.urlopen(req, context=ctx, timeout=120) as r:
            body = r.read()
            return r.status, (json.loads(body) if body else None)
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "replace")


def upload(upload_url, token, path, name):
    """用 uploads.github.com 的 upload_url 上传单个资产（流式，避免大文件占内存）。"""
    url = upload_url.split("{")[0] + f"?name={urllib.parse.quote(name)}"
    size = os.path.getsize(path)
    with open(path, "rb") as f:
        data = f.read()
    headers = {
        "Authorization": f"Bearer {token}",
        "Accept": "application/vnd.github+json",
        "Content-Type": "application/octet-stream",
        "Content-Length": str(size),
        "User-Agent": "zhuiju-release-script",
    }
    req = urllib.request.Request(url, data=data, headers=headers, method="POST")
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    try:
        with urllib.request.urlopen(req, context=ctx, timeout=600) as r:
            return r.status, json.loads(r.read())
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "replace")


def main():
    token = get_token()
    print(f"token 已取到（长度 {len(token)}）")

    with open(os.path.join(ROOT, NOTES), "r", encoding="utf-8") as f:
        body = f.read()

    # 已存在就先删掉，保证可重复执行
    status, existing = api(
        f"https://api.github.com/repos/{REPO}/releases/tags/{TAG}", token
    )
    if status == 200:
        rid = existing["id"]
        print(f"发现已存在的 release id={rid}，先删除")
        api(f"https://api.github.com/repos/{REPO}/releases/{rid}", token, method="DELETE")

    payload = {
        "tag_name": TAG,
        "name": NAME,
        "body": body,
        "draft": False,
        "prerelease": False,
    }
    status, rel = api(
        f"https://api.github.com/repos/{REPO}/releases", token, method="POST", payload=payload
    )
    if status not in (200, 201):
        raise SystemExit(f"创建 release 失败: HTTP {status}\n{rel}")
    print(f"release 创建成功: {rel['html_url']}")

    for rel_path, name in ASSETS:
        full = os.path.join(ROOT, rel_path)
        if not os.path.exists(full):
            print(f"跳过（文件不存在）: {name}")
            continue
        mb = os.path.getsize(full) / 1048576
        print(f"上传 {name} ({mb:.1f} MB)...")
        st, res = upload(rel["upload_url"], token, full, name)
        if st in (200, 201):
            print(f"  OK -> {res['browser_download_url']}")
        else:
            print(f"  失败 HTTP {st}: {res}")

    print(f"\n完成: {rel['html_url']}")


if __name__ == "__main__":
    main()