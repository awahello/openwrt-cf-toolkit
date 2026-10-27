"""
polmo.py —— PO → LMO 编译器（OpenWrt LuCI 的 po2lmo 的纯 Python 移植）

用途：在没有 OpenWrt SDK、没有 gcc、没有 po2lmo 的环境里，
      也能把 .po 翻译编译成 LuCI 运行时能加载的 .lmo。

LMO 文件布局（与 luci-base/lib/lmo.c 的 lmo_open 对齐）：

    [字符串数据区，每条按 4 字节对齐]
    [索引表：N 条 × 16 字节，按 key_id 升序]
    [4 字节大端 uint32：索引表起始偏移 = 数据区长度]

索引项结构：key_id, val_id, offset, length（均为大端 uint32）
    - 普通词条：key_id = sfh_hash(msgid), val_id = 1
    - 表头词条：key_id = 0, val_id = 0，值是 Plural-Forms 那一行的内容
"""

import struct

M32 = 0xFFFFFFFF


# ----------------------------------------------------------------- 哈希

def _get16(d, i):
    """sfh_get16：小端读 16 位"""
    return d[i] | (d[i + 1] << 8)


def sfh_hash(data, init):
    """SuperFastHash 变体，与 luci-base/lib/lmo.c 完全一致"""
    ln = len(data)
    if ln <= 0 or data is None:
        return 0

    h = init & M32
    rem = ln & 3
    n = ln >> 2
    p = 0

    for _ in range(n):
        h = (h + _get16(data, p)) & M32
        tmp = ((_get16(data, p + 2) << 11) ^ h) & M32
        h = (((h << 16) & M32) ^ tmp) & M32
        p += 4
        h = (h + (h >> 11)) & M32

    if rem == 3:
        h = (h + _get16(data, p)) & M32
        h = (h ^ ((h << 16) & M32)) & M32
        sc = data[p + 2] - 256 if data[p + 2] > 127 else data[p + 2]
        h = (h ^ ((sc << 18) & M32)) & M32
        h = (h + (h >> 11)) & M32
    elif rem == 2:
        h = (h + _get16(data, p)) & M32
        h = (h ^ ((h << 11) & M32)) & M32
        h = (h + (h >> 17)) & M32
    elif rem == 1:
        sc = data[p] - 256 if data[p] > 127 else data[p]
        h = (h + sc) & M32
        h = (h ^ ((h << 10) & M32)) & M32
        h = (h + (h >> 1)) & M32

    h = (h ^ ((h << 3) & M32)) & M32
    h = (h + (h >> 5)) & M32
    h = (h ^ ((h << 4) & M32)) & M32
    h = (h + (h >> 17)) & M32
    h = (h ^ ((h << 25) & M32)) & M32
    h = (h + (h >> 6)) & M32

    return h & M32


# ----------------------------------------------------------------- PO 解析

def _extract_string(line):
    """
    复刻 po2lmo 的 extract_string()：
      - 只取第一个双引号内的内容，到下一个双引号结束
      - \\"  -> "
      - \\\\  -> \\
      - \\n  -> 保留字面的反斜杠 + n（是的，po2lmo 就是这么干的）
    """
    if line.startswith('#'):
        return None

    started = False
    esc = False
    out = []

    for ch in line:
        if not started:
            if ch == '"':
                started = True
            continue

        if esc:
            if ch in ('"', '\\'):
                out.append(ch)
            else:
                out.append('\\')
                out.append(ch)
            esc = False
        elif ch == '\\':
            esc = True
        elif ch != '"':
            out.append(ch)
        else:
            break

    return ''.join(out) if started else None


def parse_po(text):
    """返回 [{'msgid': ..., 'msgstr': ...}, ...]，保持文件中的顺序"""
    blocks = []
    cur = {'msgid': None, 'msgstr': None}
    target = None

    for raw in text.splitlines():
        line = raw.rstrip('\r\n')

        if line.startswith('msgid "'):
            if cur['msgid'] is not None:
                blocks.append(cur)
            cur = {'msgid': _extract_string(line) or '', 'msgstr': None}
            target = 'msgid'
        elif line.startswith('msgstr "'):
            cur['msgstr'] = _extract_string(line) or ''
            target = 'msgstr'
        elif line.startswith('msgstr['):
            raise ValueError('暂不支持复数形式：' + line)
        elif line.startswith('msgid_plural'):
            raise ValueError('暂不支持复数形式：' + line)
        elif line.startswith('msgctxt'):
            raise ValueError('暂不支持 msgctxt：' + line)
        elif line.startswith('"'):
            s = _extract_string(line) or ''
            if target == 'msgid':
                cur['msgid'] += s
            elif target == 'msgstr':
                cur['msgstr'] = (cur['msgstr'] or '') + s
        # 其余行（注释、空行）忽略

    if cur['msgid'] is not None:
        blocks.append(cur)

    return blocks


def _find_plural_forms(header):
    """表头里找 Plural-Forms 那一行的值"""
    for part in header.split('\\n'):
        if part[:14].lower() == 'plural-forms: ':
            return part[14:]
    return None


# ----------------------------------------------------------------- 编译

def compile_lmo(blocks, out_path):
    """
    把 parse_po() 的结果编译成 .lmo，返回 (词条数, 字节数)
    """
    data = bytearray()
    index = []

    for b in blocks:
        mid = b['msgid'] or ''
        mstr = b['msgstr'] or ''
        if not mstr:
            continue

        if mid == '':
            # 表头：只取 Plural-Forms 那一行，key_id/val_id 都是 0，
            # 注意这里不能套用下面"key_id == val_id 就跳过"的判断（0 == 0 会误杀）
            pf = _find_plural_forms(mstr)
            if pf is None:
                continue
            key_id, val_id, val = 0, 0, pf
        else:
            kb = mid.encode('utf-8')
            key_id = sfh_hash(kb, len(kb))
            val_id = 1
            val = mstr
            if key_id == val_id:
                continue

        vb = val.encode('utf-8')

        index.append((key_id, val_id, len(data), len(vb)))
        data += vb
        data += b'\x00' * ((4 - (len(vb) % 4)) % 4)

    index.sort(key=lambda e: e[0])

    buf = bytearray(data)
    for e in index:
        buf += struct.pack('>IIII', *e)
    buf += struct.pack('>I', len(data))

    with open(out_path, 'wb') as f:
        f.write(bytes(buf))

    return len(index), len(buf)


# ----------------------------------------------------------------- 校验

def read_lmo(path):
    """把 .lmo 读回来，返回 {(key_id, val_id): 文本}，用于自检"""
    with open(path, 'rb') as f:
        buf = f.read()

    if len(buf) < 4:
        raise ValueError('文件太短')

    idx_off = struct.unpack('>I', buf[-4:])[0]
    if idx_off >= len(buf):
        raise ValueError('索引偏移非法：%d >= %d' % (idx_off, len(buf)))

    n = (len(buf) - idx_off - 4) // 16
    out = {}
    for i in range(n):
        base = idx_off + i * 16
        kid, vid, off, ln = struct.unpack('>IIII', buf[base:base + 16])
        out[(kid, vid)] = buf[off:off + ln].decode('utf-8')
    return out


def translate(catalog, key):
    """按 LuCI 的查找方式取翻译"""
    kb = key.encode('utf-8')
    return catalog.get((sfh_hash(kb, len(kb)), 1))
