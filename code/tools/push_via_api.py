"""用 GitHub Data API 完成 git push 的等价操作。

背景：本机 git 的 push/fetch/ls-remote 在本环境下全部静默返回 0、
无任何输出、连 GIT_TRACE 日志文件都不生成，实际远程 ref 从未更新
（API 查询 main 一直停在 4979037）。而 curl 走代理完全正常，
所以改用 Data API 手工完成同样的工作：

  blob(每个改动文件) -> tree(以远程 HEAD tree 为 base) -> commit -> 更新 ref
  再建 annotated tag 对象 + tag ref

为什么用 curl 而不是 urllib：urllib 走同一代理 POST 时报
SSL: UNEXPECTED_EOF_WHILE_READING，curl 同一请求返回 201。
"""
import datetime
import json
import os
import subprocess
import sys
import tempfile

REPO = "muyuewang/4K-Zhuiju"
ROOT = r"C:\Users\fengxin\WorkBuddy\vivos7"
PROXY = "http://127.0.0.1:7897"
TAG = "v1.5.0"
TAG_MSG = "4K追剧 v1.5.0"
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


def api(path, method="GET", payload=None):
    url = path if path.startswith("http") else f"{API}/repos/{REPO}{path}"
    cmd = [
        "curl", "-s", "-w", "\n%{http_code}",
        "--max-time", "180",
        "--proxy", PROXY,
        "--ssl-no-revoke",
        "-X", method,
        url,
        "-H", f"Authorization: Bearer {token()}",
        "-H", "Accept: application/vnd.github+json",
        "-H", "X-GitHub-Api-Version: 2022-11-28",
        "-H", "User-Agent: zhuiju-release-script",
    ]
    tmp = None
    if payload is not None:
        body = json.dumps(payload).encode("utf-8")
        fd, tmp = tempfile.mkstemp(suffix=".json")
        with os.fdopen(fd, "wb") as f:
            f.write(body)
        cmd += ["-H", "Content-Type: application/json", "--data-binary", f"@{tmp}"]
    try:
        p = subprocess.run(cmd, capture_output=True)
    finally:
        if tmp:
            os.unlink(tmp)
    raw = p.stdout.decode("utf-8", "replace")
    if p.returncode != 0:
        raise SystemExit(f"curl 失败({p.returncode}): {p.stderr.decode('utf-8', 'replace')[:300]}")
    if "\n" not in raw:
        raise SystemExit(f"响应异常: {raw[:300]}")
    body_text, _, code = raw.rpartition("\n")
    try:
        status = int(code.strip())
    except ValueError:
        raise SystemExit(f"状态码解析失败: {code!r} body={body_text[:200]}")
    try:
        parsed = json.loads(body_text) if body_text.strip() else None
    except json.JSONDecodeError:
        parsed = body_text
    return status, parsed


def git(*args, binary=False):
    p = subprocess.run(["git"] + list(args), capture_output=True, cwd=ROOT)
    if p.returncode != 0:
        raise SystemExit(f"git {' '.join(args)} 失败: {p.stderr.decode('utf-8', 'replace')}")
    return p.stdout if binary else p.stdout.decode("utf-8").strip()


def iso(epoch):
    return datetime.datetime.fromtimestamp(
        epoch, datetime.timezone.utc
    ).strftime("%Y-%m-%dT%H:%M:%SZ")


def main():
    st, ref = api("/git/ref/heads/main")
    if st != 200:
        raise SystemExit(f"读远程 main 失败: {st} {ref}")
    remote_sha = ref["object"]["sha"]
    print("远程 main:", remote_sha)

    local_head = git("rev-parse", "HEAD")
    print("本地 HEAD:", local_head)
    if remote_sha == local_head:
        print("已同步，仅需处理 tag")

    st, commit = api(f"/git/commits/{remote_sha}")
    if st != 200:
        raise SystemExit(f"读远程 commit 失败: {st}")
    base_tree = commit["tree"]["sha"]
    print("远程 tree:", base_tree)

    # 不能用 git diff <remote_sha> <local_head>：远程那个 commit 是上一次
    # 用 API 造出来的，本地对象库里根本没有它，diff 直接报 bad object。
    # 改为分别取两边的完整 tree，按「路径 -> blob sha」比对。
    # git 的 blob sha 是内容寻址的，两边算法一致，sha 不同即内容不同。
    local = {}
    raw = git("ls-tree", "-r", "-z", "HEAD", binary=True)
    for rec in raw.split(b"\0"):
        if not rec:
            continue
        meta, _, path = rec.partition(b"\t")
        mode, typ, sha = meta.split()
        local[path.decode("utf-8")] = (mode.decode(), sha.decode())

    st, rtree = api(f"/git/trees/{base_tree}?recursive=1")
    if st != 200:
        raise SystemExit(f"读远程 tree 失败: {st} {rtree}")
    if rtree.get("truncated"):
        raise SystemExit("远程 tree 被截断，不能用增量方式推送")
    remote = {
        e["path"]: e["sha"]
        for e in rtree["tree"]
        if e["type"] == "blob"
    }

    changed = [(p, m) for p, (m, s) in local.items() if remote.get(p) != s]
    deleted = [p for p in remote if p not in local]
    print(f"本地文件 {len(local)}，远程文件 {len(remote)}，"
          f"待上传 {len(changed)}，待删除 {len(deleted)}")

    tree_entries = []
    for path in sorted(deleted):
        tree_entries.append({"path": path, "mode": "100644",
                             "type": "blob", "sha": None})
        print(f"  删除 {path}")

    for path, mode in sorted(changed):
        sha = local[path][1]
        content = git("cat-file", "blob", sha, binary=True)
        st, blob = api("/git/blobs", "POST", {
            "content": __import__("base64").b64encode(content).decode("ascii"),
            "encoding": "base64",
        })
        if st not in (200, 201):
            raise SystemExit(f"blob {path} 失败: {st} {blob}")
        tree_entries.append({"path": path, "mode": mode,
                             "type": "blob", "sha": blob["sha"]})
        print(f"  blob {path} -> {blob['sha'][:8]} ({len(content)} B, {mode})")

    new_commit_sha = remote_sha
    new_tree = base_tree
    if tree_entries:
        st, tree = api("/git/trees", "POST", {"base_tree": base_tree, "tree": tree_entries})
        if st not in (200, 201):
            raise SystemExit(f"建 tree 失败: {st} {tree}")
        new_tree = tree["sha"]
        print("新 tree:", new_tree)

        msg = git("log", "-1", "--format=%B", local_head)
        payload = {
            "message": msg,
            "tree": new_tree,
            "parents": [remote_sha],
            "author": {
                "name": git("log", "-1", "--format=%an", local_head),
                "email": git("log", "-1", "--format=%ae", local_head),
                "date": iso(int(git("log", "-1", "--format=%at", local_head))),
            },
            "committer": {
                "name": git("log", "-1", "--format=%cn", local_head),
                "email": git("log", "-1", "--format=%ce", local_head),
                "date": iso(int(git("log", "-1", "--format=%ct", local_head))),
            },
        }
        st, newc = api("/git/commits", "POST", payload)
        if st not in (200, 201):
            raise SystemExit(f"建 commit 失败: {st} {newc}")
        new_commit_sha = newc["sha"]
        print("新 commit:", new_commit_sha)
        print("与本地一致:", new_commit_sha == local_head)

        st, res = api("/git/refs/heads/main", "PATCH", {"sha": new_commit_sha, "force": False})
        print("更新 main:", st, res.get("ref") if isinstance(res, dict) else str(res)[:120])
        if st not in (200, 201):
            raise SystemExit(f"更新 main 失败: {st} {res}")

    # annotated tag
    st, existing = api(f"/git/ref/tags/{TAG}")
    if st == 200:
        print(f"tag {TAG} 已存在，跳过创建")
    else:
        st, tagobj = api("/git/tags", "POST", {
            "tag": TAG, "message": TAG_MSG, "object": new_commit_sha, "type": "commit",
        })
        if st not in (200, 201):
            raise SystemExit(f"建 tag 对象失败: {st} {tagobj}")
        print("tag 对象:", tagobj["sha"])
        st, res = api("/git/refs", "POST", {"ref": f"refs/tags/{TAG}", "sha": tagobj["sha"]})
        print("建 tag ref:", st, res.get("ref") if isinstance(res, dict) else str(res)[:150])

    # 校验
    st, c = api("/commits/main")
    print("校验 main:", st, c.get("sha", "")[:12] if isinstance(c, dict) else c)
    st, t = api(f"/git/ref/tags/{TAG}")
    print("校验 tag:", st, str(t.get("object", {}).get("sha", ""))[:12] if isinstance(t, dict) else t)


if __name__ == "__main__":
    main()