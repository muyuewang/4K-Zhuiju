"""检查 zhuiju.exe 是否还具备"创建子进程"的能力。

误报的直接诱因是 Process.run('reg', ...)。改成原生 RegGetValueW 后，
exe 的导入表里应该完全看不到 CreateProcess/WinExec/ShellExecute。
"""
import struct
import zipfile


def sections(data):
    e = struct.unpack_from('<I', data, 0x3C)[0]
    coff = e + 4
    machine, nsec = struct.unpack_from('<HH', data, coff)
    opt = coff + 20
    magic = struct.unpack_from('<H', data, opt)[0]
    is64 = magic == 0x20b
    dd = opt + (112 if is64 else 96)
    st = opt + (240 if is64 else 224)
    secs = []
    for i in range(nsec):
        o = st + i * 40
        name = data[o:o + 8].rstrip(b'\0').decode('ascii', 'replace')
        vsize, vaddr, rawsize, rawptr = struct.unpack_from('<IIII', data, o + 8)
        secs.append((name, vaddr, vsize, rawptr, rawsize))
    return secs, dd, is64


def rva2off(secs, rva):
    for name, va, vs, rp, rs in secs:
        if va <= rva < va + max(vs, rs):
            return rp + (rva - va)
    return None


def imports(data, secs, dd, is64):
    rva, size = struct.unpack_from('<II', data, dd + 8)
    if not size:
        return []
    off = rva2off(secs, rva)
    out = []
    thunk = 8 if is64 else 4
    flag = (1 << 63) if is64 else (1 << 31)
    while True:
        oft, tds, fc, name_rva, ft = struct.unpack_from('<IIIII', data, off)
        if name_rva == 0:
            break
        no = rva2off(secs, name_rva)
        dll = data[no:data.index(b'\0', no)].decode('ascii', 'replace')
        funcs = []
        t = rva2off(secs, oft or ft)
        if t:
            while True:
                v = struct.unpack_from('<Q' if is64 else '<I', data, t)[0]
                if v == 0:
                    break
                if not (v & flag):
                    fo = rva2off(secs, v & 0x7fffffff)
                    if fo:
                        funcs.append(data[fo + 2:data.index(b'\0', fo + 2)]
                                     .decode('ascii', 'replace'))
                t += thunk
        out.append((dll, funcs))
        off += 20
    return out


SPAWN = ['CreateProcessW', 'CreateProcessA', 'WinExec', 'ShellExecuteW',
         'ShellExecuteA', 'CreateProcessAsUserW']


def probe(data, label):
    secs, dd, is64 = sections(data)
    imps = imports(data, secs, dd, is64)
    allfn = {f for _, fs in imps for f in fs}
    print(f'=== {label}（{len(data):,} B）===')
    hit = [s for s in SPAWN if s in allfn]
    print(f'  创建子进程类 API : {hit if hit else "无"}')
    reg = sorted(f for f in allfn if f.startswith('Reg'))
    print(f'  注册表 API       : {reg if reg else "无"}')
    inject = [f for f in allfn if f in
              ('WriteProcessMemory', 'CreateRemoteThread', 'VirtualAllocEx',
               'SetWindowsHookExW', 'QueueUserAPC')]
    print(f'  注入类 API       : {inject if inject else "无"}')
    print(f'  依赖 DLL         : {sorted({d for d, _ in imps})}')
    return hit


NEW = (r'C:\Users\fengxin\WorkBuddy\vivos7\code\flutter_app'
       r'\build\windows\x64\runner\Release\zhuiju.exe')
OLD_ZIP = (r'C:\Users\fengxin\WorkBuddy\vivos7\dist\v1.10.2'
           r'\4KZhuiju-v1.10.2-windows-x64.zip')

print('---------- 修复前（v1.10.2 已发布产物）----------')
old_hit = probe(zipfile.ZipFile(OLD_ZIP).read('zhuiju.exe'), '旧 exe')

print('\n---------- 修复后（本轮构建）----------')
new_hit = probe(open(NEW, 'rb').read(), '新 exe')

print()
if new_hit:
    print(f'警告：新 exe 仍引用子进程 API {new_hit}')
else:
    print('结论：新 exe 已完全不含创建子进程的 API 引用。')