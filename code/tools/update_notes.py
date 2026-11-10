"""更新已发布 release 的发版说明。

为什么不走 /releases/tags/{tag}：那个端点只支持 GET，
PATCH 必须用数字 id，否则返回 404。踩过一次。

用法：python code/tools/update_notes.py <release_id> <说明文件路径>
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


def token():
    p = subprocess.run(
        ["git", "credential", "fill"],
        input="protocol=https\nhost=github.com\n\n",
        capture_output=True,
        text=True,
        cwd=ROOT,
    )
    for line in p.stdout.splitlines():
        if line.startswith("password="):
            return line[len("password="):].strip()
    raise SystemExit("凭据里没有 password")


def main():
    if len(sys.argv) < 3:
        raise SystemExit(__doc__)
    rid, notes_path = sys.argv[1], sys.argv[2]

    with open(os.path.join(ROOT, notes_path), "r", encoding="utf-8") as f:
        body = f.read()
    print(f"新说明 {len(body)} 字符")

    fd, tmp = tempfile.mkstemp(suffix=".json")
    with os.fdopen(fd, "wb") as f:
        f.write(json.dumps({"body": body}).encode("utf-8"))

    cmd = [
        "curl", "-s", "-w", "\n%{http_code}",
        "--max-time", "120",
        "--proxy", PROXY,
        "--ssl-no-revoke",
        "-X", "PATCH", f"{API}/repos/{REPO}/releases/{rid}",
        "-H", f"Authorization: Bearer {token()}",
        "-H", "Accept: application/vnd.github+json",
        "-H", "Content-Type: application/json",
        "-H", "User-Agent: zhuiju-release-script",
        "--data-binary", f"@{tmp}",
    ]
    try:
        p = subprocess.run(cmd, capture_output=True)
    finally:
        os.unlink(tmp)

    raw = p.stdout.decode("utf-8", "replace")
    payload, _, code = raw.rpartition("\n")
    status = int(code.strip())
    print(f"HTTP {status}")
    if status != 200:
        print(str(payload)[:400])
        raise SystemExit(1)

    d = json.loads(payload)
    got = d.get("body") or ""
    print(f"远端 body 长度: {len(got)} 字符")
    print(f"是否仍含「没有出 Windows 包」: {'没有出 Windows 包' in got}")
    print(f"是否含 Windows 下载行: {'windows-x64.zip' in got}")
    print(f"链接: {d.get('html_url')}")


if __name__ == "__main__":
    main()