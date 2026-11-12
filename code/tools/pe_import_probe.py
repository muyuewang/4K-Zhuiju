"""导出指定 DLL 的完整导入函数表，用于确认 CreateProcess 等敏感 API 归属。"""
import zipfile
import struct


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


z = zipfile.ZipFile(r'C:\Users\fengxin\WorkBuddy\vivos7\dist\v1.10.2\4KZhuiju-v1.10.2-windows-x64.zip')
data = z.read('flutter_windows.dll')
secs, dd, is64 = sections(data)
imps = imports(data, secs, dd, is64)
print('=== flutter_windows.dll 关注的 KERNEL32 导入 ===')
watch = ('createprocess', 'winexec', 'shellexecute', 'loadlibrary', 'getprocaddress',
         'createtoolhelp32snapshot', 'openprocess', 'virtualalloc', 'writeprocessmemory',
         'createremotethread', 'wsastartup', 'gethostbyname', 'connect', 'bind', 'listen')
for dll, fns in imps:
    hit = [f for f in fns if f.lower() in watch or f.lower().startswith('createprocess')]
    if hit:
        print(f'  {dll}:')
        for f in sorted(set(hit)):
            print(f'      {f}')

allnames = {f for _, fs in imps for f in fs}
print('\n=== 关键结论 ===')
for probe in ['CreateProcessW', 'CreateProcessA', 'WinExec', 'ShellExecuteW']:
    print(f'  {probe}: {"命中" if probe in allnames else "无"}')