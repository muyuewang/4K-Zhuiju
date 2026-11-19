"""给已存在的 Release 补传单个资产，不重建 Release。

为什么不直接重跑 make_release.py：它开头的逻辑是「先删掉已有 release 再新建」，
重跑会把已经有人下载过的 Release（含累计下载计数、发布时间）整个清掉重来。
补传只该动资产，不该动 Release 本体。

用法：
    python code/tools/upload_asset.py dist/v1.11.13/xxx-windows-x64.zip
不带参数时补传当前版本目录下的 Windows zip。
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import make_release as mr  # noqa: E402


def main():
    if len(sys.argv) > 1:
        path = os.path.abspath(sys.argv[1])
    else:
        path = os.path.join(mr.ROOT, mr.ASSETS[1][0].replace("\\", os.sep))

    if not os.path.isfile(path):
        raise SystemExit(f"文件不存在: {path}")
    name = os.path.basename(path)

    st, rel = mr.api(f"/releases/tags/{mr.TAG}")
    if st != 200:
        raise SystemExit(f"Release {mr.TAG} 不存在（HTTP {st}），请先跑 make_release.py")

    # 同名资产不能重复上传，GitHub 会返回 422。先删旧的再传。
    for a in rel.get("assets", []):
        if a["name"] == name:
            print(f"删除旧资产 id={a['id']} ({a['size']} 字节)")
            mr.api(f"/releases/assets/{a['id']}", method="DELETE")

    mb = os.path.getsize(path) / 1048576
    print(f"上传 {name} ({mb:.2f} MB)...")
    st, res = mr.upload(rel["upload_url"], path, name)
    if st in (200, 201):
        print(f"OK -> {res['browser_download_url']}")
        print(f"当前资产列表:")
        st2, rel2 = mr.api(f"/releases/tags/{mr.TAG}")
        for a in rel2.get("assets", []):
            print(f"  {a['name']}  {a['size']/1048576:.2f} MB  下载 {a['download_count']} 次")
    else:
        raise SystemExit(f"上传失败 HTTP {st}: {str(res)[:400]}")


if __name__ == "__main__":
    main()