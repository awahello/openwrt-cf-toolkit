"""
build.py —— 在 Windows / Linux / macOS 上直接打出 luci-app-cloudflarespeedtest 的 .ipk
不需要 OpenWrt SDK，不需要 gcc，不需要 Linux。

做的事：
  1. 从 GitHub 拉取上游源码（走 jsDelivr CDN，国内可用）
  2. 用 tools/polmo.py 把 po/zh_Hans 编译成 .lmo，直接打进主包
     （这样就不用再单独装 luci-i18n-cloudflarespeedtest-zh-cn）
  3. 生成 control / postinst / conffiles
  4. 打成标准 ar 格式的 .ipk，Architecture: all（ARM / MIPS / x86 通吃）

用法：
  python build.py
"""

import io
import json
import os
import shutil
import struct
import sys
import tarfile
import time
import urllib.request

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "tools"))
import polmo

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = "stevenjoezhang/luci-app-cloudflarespeedtest"
BRANCH = "main"
PKG_NAME = "luci-app-cloudflarespeedtest"
VERSION = "1.21.1"
RELEASE = "0"

# 是否把中文 .lmo 打进主包。
# 默认关掉：官方 luci-i18n-cloudflarespeedtest-zh-cn 已经占用了
# /usr/lib/lua/luci/i18n/cloudflarespeedtest.zh-cn.lmo 这个路径，
# 主包再塞一份会触发 opkg 的 file clash，直接装不上。
INCLUDE_LMO = False
WORK = os.path.join(HERE, "work")
PKGROOT = os.path.join(WORK, "pkgroot")
DIST = os.path.join(HERE, "dist")

CDN = "https://cdn.jsdelivr.net/gh/%s@%s/" % (REPO, BRANCH)
API = "https://api.github.com/repos/%s/git/trees/%s?recursive=1" % (REPO, BRANCH)

# 打包时需要的文件（按包内路径）
WANTED = [
    "root/etc/config/cloudflarespeedtest",
    "root/etc/init.d/cloudflarespeedtest",
    "root/usr/bin/cloudflarespeedtest/aliddns.sh",
    "root/usr/bin/cloudflarespeedtest/aliddns.uc",
    "root/usr/bin/cloudflarespeedtest/astra-dns.sh",
    "root/usr/bin/cloudflarespeedtest/cloudflarespeedtest.sh",
    "root/usr/bin/cloudflarespeedtest/patch.uc",
    "root/usr/share/CloudflareSpeedTest/ip.txt",
    "root/usr/share/CloudflareSpeedTest/ipv6.txt",
    "root/usr/share/luci/menu.d/luci-app-cloudflarespeedtest.json",
    "root/usr/share/rpcd/acl.d/luci-app-cloudflarespeedtest.json",
    "root/usr/share/rpcd/ucode/cloudflarespeedtest.uc",
    "root/www/luci-static/resources/cloudflarespeedtest/chart.js",
    "root/www/luci-static/resources/cloudflarespeedtest/chartjs-adapter-date-fns.js",
    "htdocs/luci-static/resources/view/cloudflarespeedtest/general.js",
    "htdocs/luci-static/resources/view/cloudflarespeedtest/logread.js",
    "htdocs/luci-static/resources/view/cloudflarespeedtest/third-party.js",
    "po/zh_Hans/cloudflarespeedtest.po",
]

EXEC_SUFFIX = (".sh", ".uc")


def fetch(url, retries=3):
    last = None
    for i in range(retries):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "build.py"})
            with urllib.request.urlopen(req, timeout=60) as r:
                return r.read()
        except Exception as e:  # noqa: BLE001
            last = e
            time.sleep(1 + i)
    raise RuntimeError("下载失败 %s: %s" % (url, last))


def dest_path(repo_path):
    """仓库路径 -> 包内路径"""
    if repo_path.startswith("root/"):
        return repo_path[len("root/"):]
    if repo_path.startswith("htdocs/"):
        return "www/" + repo_path[len("htdocs/"):]
    return None


def download_sources():
    if os.path.isdir(PKGROOT):
        shutil.rmtree(PKGROOT)
    os.makedirs(PKGROOT, exist_ok=True)

    po_text = None
    for rp in WANTED:
        data = fetch(CDN + rp)
        if rp.endswith(".po"):
            po_text = data.decode("utf-8")
            continue
        dp = dest_path(rp)
        if dp is None:
            raise RuntimeError("不认识的路径：" + rp)
        full = os.path.join(PKGROOT, dp.replace("/", os.sep))
        os.makedirs(os.path.dirname(full), exist_ok=True)
        with open(full, "wb") as f:
            f.write(data)
        mode = 0o755 if rp.endswith(EXEC_SUFFIX) else 0o644
        os.chmod(full, mode)
        print("  + %-70s %6d B" % (dp, len(data)))

    return po_text


def build_lmo(po_text):
    out = os.path.join(PKGROOT, "usr", "lib", "lua", "luci", "i18n")
    os.makedirs(out, exist_ok=True)
    lmo = os.path.join(out, "cloudflarespeedtest.zh-cn.lmo")

    blocks = polmo.parse_po(po_text)
    n, size = polmo.compile_lmo(blocks, lmo)

    # 立刻回读校验，确保每个词条都能按 LuCI 的方式取到
    cat = polmo.read_lmo(lmo)
    bad = []
    for b in blocks:
        mid, mstr = b["msgid"] or "", b["msgstr"] or ""
        if mid and mstr and polmo.translate(cat, mid) != mstr:
            bad.append(mid)
    if bad:
        raise RuntimeError("翻译回读校验失败 %d 条，例如 %r" % (len(bad), bad[:3]))

    print("  + usr/lib/lua/luci/i18n/cloudflarespeedtest.zh-cn.lmo  "
          "%d 条词条 / %d B" % (n, size))
    return n


CONTROL = """Package: {pkg}
Version: {ver}-{rel}
Depends: libc, curl
Source: https://github.com/{repo}
SourceName: {pkg}
License: AGPL-3.0
Section: luci
SourceDateEpoch: {epoch}
Priority: optional
Maintainer: stevenjoezhang <https://github.com/{repo}>
Architecture: all
Installed-Size: {size}
Description:  LuCI support for Cloudflare Speed Test
 定时测速并自动把最快的 Cloudflare IP 应用到 SSR+ / PassWall / MosDNS 等。
 纯脚本包，Architecture: all，ARM / MIPS / x86 均可安装。
 中文界面由 luci-i18n-cloudflarespeedtest-zh-cn 提供。
"""

POSTINST = """#!/bin/sh
[ "${IPKG_NO_SCRIPT}" = "1" ] && exit 0
[ -s ${IPKG_INSTROOT}/lib/functions.sh ] || exit 0
. ${IPKG_INSTROOT}/lib/functions.sh
default_postinst $0 $@
"""

# 让简体中文出现在 LuCI 的语言列表里（等同 luci-i18n-* 包干的事）
UCI_DEFAULTS = """#!/bin/sh
[ -f /etc/config/luci ] || exit 0
uci -q get luci.languages.zh_cn >/dev/null 2>&1 || {
\tuci -q set luci.languages.zh_cn='简体中文'
\tuci -q commit luci
}
exit 0
"""

CONFFILES = "/etc/config/cloudflarespeedtest\n"


def mode_for(arcname):
    """
    按包内路径决定权限。不能依赖 os.stat，因为 Windows 上取不到执行位
    （统一返回 0666，会导致 init.d 和脚本装上去不可执行）。
    """
    p = arcname.lstrip("./")
    if p.startswith("etc/init.d/") or p.startswith("etc/uci-defaults/"):
        return 0o755
    if p.startswith("usr/bin/") and (p.endswith(".sh") or p.endswith(".uc")):
        return 0o755
    return 0o644


def tar_gz_add(tar, path, arcname, mode=None, mtime=0):
    info = tarfile.TarInfo(arcname)
    if os.path.isdir(path):
        info.type = tarfile.DIRTYPE
        info.mode = 0o755
        info.size = 0
        tar.addfile(info)
        return
    with open(path, "rb") as f:
        data = f.read()
    info.size = len(data)
    info.mode = mode if mode is not None else mode_for(arcname)
    info.mtime = mtime
    info.uid = info.gid = 0
    info.uname = info.gname = "root"
    tar.addfile(info, io.BytesIO(data))


def make_data_tar_gz():
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz", format=tarfile.GNU_FORMAT) as tar:
        for root, dirs, files in os.walk(PKGROOT):
            dirs.sort()
            rel = os.path.relpath(root, PKGROOT).replace(os.sep, "/")
            arc = "." if rel == "." else "./" + rel
            if rel != ".":
                tar_gz_add(tar, root, arc)
            for fn in sorted(files):
                full = os.path.join(root, fn)
                tar_gz_add(tar, full, (arc + "/" + fn) if arc != "." else "./" + fn)
    return buf.getvalue()


def make_control_tar_gz(installed_size):
    ctrl = os.path.join(WORK, "CONTROL")
    if os.path.isdir(ctrl):
        shutil.rmtree(ctrl)
    os.makedirs(ctrl)

    with open(os.path.join(ctrl, "control"), "w", encoding="utf-8", newline="\n") as f:
        f.write(CONTROL.format(pkg=PKG_NAME, ver=VERSION, rel=RELEASE, repo=REPO,
                               epoch=int(time.time()), size=installed_size))
    with open(os.path.join(ctrl, "postinst"), "w", encoding="utf-8", newline="\n") as f:
        f.write(POSTINST)
    with open(os.path.join(ctrl, "conffiles"), "w", encoding="utf-8", newline="\n") as f:
        f.write(CONFFILES)
    os.chmod(os.path.join(ctrl, "postinst"), 0o755)

    udir = os.path.join(ctrl, "etc", "uci-defaults")
    if INCLUDE_LMO:
        # 只有自己带翻译时才注册语言；否则交给官方 i18n 包，
        # 两边都放会撞同名文件
        os.makedirs(udir, exist_ok=True)
        with open(os.path.join(udir, "luci-app-cloudflarespeedtest-lang"), "w",
                  encoding="utf-8", newline="\n") as f:
            f.write(UCI_DEFAULTS)
        os.chmod(os.path.join(udir, "luci-app-cloudflarespeedtest-lang"), 0o755)

    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz", format=tarfile.GNU_FORMAT) as tar:
        for fn in ["control", "postinst", "conffiles"]:
            tar_gz_add(tar, os.path.join(ctrl, fn), "./" + fn,
                       mode=0o755 if fn == "postinst" else 0o644)
        if INCLUDE_LMO:
            tar_gz_add(tar, os.path.join(ctrl, "etc"), "./etc")
            tar_gz_add(tar, udir, "./etc/uci-defaults")
            tar_gz_add(tar, os.path.join(udir, "luci-app-cloudflarespeedtest-lang"),
                       "./etc/uci-defaults/luci-app-cloudflarespeedtest-lang",
                       mode=0o755)
    return buf.getvalue()


def ar_write(out_path, members):
    """members: [(name, bytes), ...]，写标准 ar 归档（GNU 风格，名字带 /）"""
    with open(out_path, "wb") as f:
        f.write(b"!<arch>\n")
        for name, data in members:
            nm = name if name.endswith("/") else name + "/"
            if len(nm) > 16:
                raise ValueError("ar 成员名过长：" + nm)
            hdr = (
                nm.ljust(16)[:16].encode()
                + str(int(time.time())).ljust(12).encode()
                + b"0".ljust(6)            # uid
                + b"0".ljust(6)            # gid
                + b"100644".ljust(8)       # mode
                + str(len(data)).ljust(10).encode()
                + b"`\n"
            )
            assert len(hdr) == 60, len(hdr)
            f.write(hdr)
            f.write(data)
            if len(data) % 2:
                f.write(b"\n")


def make_ipk_tgz(out_path, ctrl_tgz, data_tgz):
    """
    gzip 形式的 ipk：外层是 tar.gz，里面装 ./debian-binary、./data.tar.gz、./control.tar.gz。
    有些第三方固件的 opkg 只认这种，不认 ar，所以两种都出。
    """
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz", format=tarfile.GNU_FORMAT) as tar:
        for name, data in [("debian-binary", b"2.0\n"),
                           ("data.tar.gz", data_tgz),
                           ("control.tar.gz", ctrl_tgz)]:
            info = tarfile.TarInfo("./" + name)
            info.size = len(data)
            info.mode = 0o644
            info.mtime = 0
            info.uid = info.gid = 0
            info.uname = info.gname = "root"
            tar.addfile(info, io.BytesIO(data))
    with open(out_path, "wb") as f:
        f.write(buf.getvalue())


def human(n):
    for unit in ("B", "KB", "MB"):
        if n < 1024:
            return "%.1f %s" % (n, unit)
        n /= 1024.0
    return "%.1f GB" % n


def main():
    print("== 1/4 拉取上游源码 ==")
    po_text = download_sources()

    print("== 2/4 编译简体中文翻译 ==")
    if INCLUDE_LMO:
        n_entries = build_lmo(po_text)
    else:
        # 只编译到临时目录做校验，不放进包里（避免和官方 i18n 包文件冲突）
        blocks = polmo.parse_po(po_text)
        tmp_lmo = os.path.join(WORK, "check.lmo")
        n_entries, _ = polmo.compile_lmo(blocks, tmp_lmo)
        cat = polmo.read_lmo(tmp_lmo)
        bad = [b["msgid"] for b in blocks
               if (b["msgid"] or "") and (b["msgstr"] or "")
               and polmo.translate(cat, b["msgid"]) != b["msgstr"]]
        if bad:
            raise RuntimeError("翻译回读校验失败 %d 条" % len(bad))
        print("  %d 条中文翻译校验通过（不打包，由官方 i18n 包提供）" % n_entries)

    total = 0
    for root, _, files in os.walk(PKGROOT):
        for fn in files:
            total += os.path.getsize(os.path.join(root, fn))
    installed_kb = (total + 1023) // 1024

    print("== 3/4 组装 control 与 data ==")
    data_tgz = make_data_tar_gz()
    ctrl_tgz = make_control_tar_gz(installed_kb)

    os.makedirs(DIST, exist_ok=True)
    base = "%s_%s-%s_all" % (PKG_NAME, VERSION, RELEASE)
    ipk_tgz = os.path.join(DIST, base + ".ipk")
    ipk_ar = os.path.join(DIST, base + "_ar.ipk")

    # 主推：gzip 形式（与用户固件上能正常安装的包同格式）
    make_ipk_tgz(ipk_tgz, ctrl_tgz, data_tgz)

    # 备用：标准 ar 形式
    ar_write(ipk_ar, [
        ("debian-binary", b"2.0\n"),
        ("control.tar.gz", ctrl_tgz),
        ("data.tar.gz", data_tgz),
    ])

    print("== 4/4 完成 ==")
    print()
    print("  gzip 格式（推荐先试这个）: %s  %s" % (ipk_tgz, human(os.path.getsize(ipk_tgz))))
    print("  ar   格式（备用）        : %s  %s" % (ipk_ar, human(os.path.getsize(ipk_ar))))
    print("  架构   : all（ARM / MIPS / x86 通用）")
    print("  中文   : %d 条已校验%s" % (
        n_entries, "并内嵌" if INCLUDE_LMO else "（由官方 i18n 包提供，本包不含 lmo 以免文件冲突）"))
    print()


if __name__ == "__main__":
    main()
