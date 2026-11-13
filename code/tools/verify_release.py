"""核验 v1.11.4 Release 的远程资产与本地是否一致。

为什么单独写一个：直接 curl 会失败，报 SSL 校验或代理握手问题 ——
`make_release.py` 里带了 `--ssl-no-revoke` 才通。与其重写一遍调用细节，
不如复用它的 `api()`，顺带保证「发版」和「验版」走的是同一条通路。
"""
import hashlib
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from make_release import TAG, ROOT, api, ASSETS  # noqa: E402


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def main():
    status, rel = api(f"/releases/tags/{TAG}")
    if status != 200:
        raise SystemExit(f"取 Release 失败: HTTP {status}")

    print(f"tag        : {rel['tag_name']}")
    print(f"draft      : {rel['draft']} / prerelease: {rel['prerelease']}")
    print(f"published  : {rel['published_at']}")
    print("")

    remote = {a["name"]: a for a in rel["assets"]}
    ok = True
    for rel_path, name in ASSETS:
        local = os.path.join(ROOT, rel_path)
        if not os.path.exists(local):
            print(f"MISSING 本地不存在: {local}")
            ok = False
            continue
        a = remote.get(name)
        if not a:
            print(f"MISSING 远程缺资产: {name}")
            ok = False
            continue
        lsize = os.path.getsize(local)
        digest = a.get("digest") or ""
        local_sha = sha256(local)
        size_ok = lsize == a["size"]
        # digest 形如 "sha256:xxxx"，老仓库可能为空，空则只比大小
        sha_ok = digest == f"sha256:{local_sha}" if digest else None
        flag = "OK  " if size_ok and (sha_ok is not False) else "FAIL"
        if flag == "FAIL":
            ok = False
        print(f"{flag} {name}")
        print(f"       大小 本地={lsize:,} 远程={a['size']:,}")
        print(f"       sha256 本地={local_sha[:16]}…")
        if digest:
            print(f"       sha256 远程={digest[7:23]}…  {'一致' if sha_ok else '不一致'}")

    print("")
    print("全部一致" if ok else "存在不一致，需处理")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())