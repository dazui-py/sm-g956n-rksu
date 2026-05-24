#!/usr/bin/env bash
set -euo pipefail

# Unified SUSFS reject/fixup patcher for your SM-G965N-rksu style tree.
#
# Usage:
#   ./apply-susfs-unified.sh [kernel_root] [optional_base_patch]
#
# Examples:
#   ./apply-susfs-unified.sh
#   ./apply-susfs-unified.sh . patches/susfs_patch_to_4.9.patch
#
# If optional_base_patch is provided, this first tries: patch -p1 -N < patch.
# Rejects are allowed, then the adaptive fixups are applied.

ROOT="${1:-.}"
BASE_PATCH="${2:-}"

cd "$ROOT"

fail() {
    echo "[-] $*" >&2
    exit 1
}

ok() {
    echo "[+] $*"
}

warn() {
    echo "[!] $*" >&2
}

need_file() {
    [ -f "$1" ] || fail "Ficheiro não encontrado: $1"
}

[ -f Makefile ] || fail "Isto não parece a raiz do kernel: falta Makefile"
need_file fs/namei.c
need_file fs/namespace.c
need_file fs/open.c
need_file fs/proc/base.c
need_file fs/proc/cmdline.c
need_file fs/proc/task_mmu.c
need_file fs/readdir.c
need_file fs/stat.c
need_file kernel/kallsyms.c
need_file kernel/sys.c

if [ -n "$BASE_PATCH" ]; then
    [ -f "$BASE_PATCH" ] || fail "Patch base não encontrado: $BASE_PATCH"
    echo "[*] A aplicar patch base: $BASE_PATCH"
    if patch -p1 -N < "$BASE_PATCH"; then
        ok "Patch base aplicado sem rejects"
    else
        warn "Patch base teve rejects ou partes já aplicadas. Vou continuar com os fixups adaptativos."
    fi
fi

python3 <<'PY'
from pathlib import Path
import re
import sys


def die(msg):
    print(f"[-] {msg}", file=sys.stderr)
    sys.exit(1)


def ok(msg):
    print(f"[+] {msg}")


def read(path: str) -> str:
    p = Path(path)
    if not p.exists():
        die(f"Ficheiro não encontrado: {path}")
    return p.read_text(errors="replace")


def write(path: str, data: str) -> None:
    Path(path).write_text(data)


def insert_after_any(path, markers, block, unique):
    data = read(path)

    if unique in data:
        ok(f"{path}: já aplicado, skip")
        return

    if isinstance(markers, str):
        markers = [markers]

    for marker in markers:
        pos = data.find(marker)
        if pos != -1:
            pos += len(marker)
            data = data[:pos] + block + data[pos:]
            write(path, data)
            ok(f"{path}: aplicado")
            return

    die(f"{path}: nenhum marker encontrado para insert_after: {markers!r}")


def insert_before_any(path, markers, block, unique):
    data = read(path)

    if unique in data:
        ok(f"{path}: já aplicado, skip")
        return

    if isinstance(markers, str):
        markers = [markers]

    for marker in markers:
        pos = data.find(marker)
        if pos != -1:
            data = data[:pos] + block + data[pos:]
            write(path, data)
            ok(f"{path}: aplicado")
            return

    die(f"{path}: nenhum marker encontrado para insert_before: {markers!r}")


def find_function_span(data: str, name: str):
    pos = data.find(name)
    if pos == -1:
        return None

    brace = data.find("{", pos)
    if brace == -1:
        return None

    depth = 0
    for i in range(brace, len(data)):
        if data[i] == "{":
            depth += 1
        elif data[i] == "}":
            depth -= 1
            if depth == 0:
                return pos, i + 1

    return None


def patch_namei():
    insert_after_any(
        "fs/namei.c",
        "#include <asm/uaccess.h>\n",
        """#if defined(CONFIG_KSU_SUSFS_SUS_PATH) || defined(CONFIG_KSU_SUSFS_OPEN_REDIRECT)
#include <linux/susfs_def.h>
#endif
""",
        "#include <linux/susfs_def.h>",
    )


def patch_namespace():
    insert_after_any(
        "fs/namespace.c",
        "#include <linux/task_work.h>\n",
        """#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
#include <linux/susfs_def.h>
#endif
""",
        "#include <linux/susfs_def.h>",
    )

    insert_before_any(
        "fs/namespace.c",
        "/* Maximum number of mounts in a mount namespace */",
        """#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
extern bool susfs_is_current_ksu_domain(void);
extern struct static_key_true susfs_is_sdcard_android_data_not_decrypted;

#define CL_COPY_MNT_NS BIT(25) /* used by copy_mnt_ns() */

#endif

""",
        "CL_COPY_MNT_NS BIT(25)",
    )

    insert_before_any(
        "fs/namespace.c",
        "\tnew = copy_tree(old, old->mnt.mnt_root, copy_flags);",
        """#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
\tcopy_flags |= CL_COPY_MNT_NS;
#endif
""",
        "copy_flags |= CL_COPY_MNT_NS",
    )


def patch_fdinfo():
    path = "fs/notify/fdinfo.c"
    data = read(path)

    if "mnt->mnt_id >= DEFAULT_KSU_MNT_ID" in data:
        ok(f"{path}: já aplicado, skip")
        return

    func = data.find("inotify_fdinfo")
    if func == -1:
        die(f"{path}: não encontrei inotify_fdinfo()")

    end_hint = data.find("inotify_show_fdinfo", func)
    view = data[func:end_hint if end_hint != -1 else len(data)]
    if "struct file *file" not in view:
        die(f"{path}: inotify_fdinfo() ainda não recebe struct file *file. Aplica primeiro o patch base SUSFS.")

    igrab = data.find("inode = igrab(mark->inode);", func)
    if igrab == -1:
        die(f"{path}: não encontrei inode = igrab(mark->inode);")

    struct_inode = data.find("struct inode *inode;", func, igrab)
    if struct_inode != -1 and "struct mount *mnt" not in data[func:igrab]:
        pos = struct_inode + len("struct inode *inode;")
        data = data[:pos] + """
#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
\tstruct mount *mnt = NULL;
#endif
""" + data[pos:]
        write(path, data)
        data = read(path)
        ok(f"{path}: struct mount *mnt aplicado")
        func = data.find("inotify_fdinfo")
        igrab = data.find("inode = igrab(mark->inode);", func)

    if_inode = data.find("if (inode) {", igrab)
    if if_inode == -1:
        die(f"{path}: não encontrei if (inode) {{")

    mask = data.find("u32 mask = mark->mask & IN_ALL_EVENTS;", if_inode)
    if mask == -1:
        die(f"{path}: não encontrei u32 mask = mark->mask & IN_ALL_EVENTS;")

    seq_candidates = [
        'seq_printf(m, "inotify wd:%x ino:%lx sdev:%x mask:%x ignored_mask:%x ",',
        'seq_printf(m, "inotify wd:%x ino:%lx sdev:%x mask:%x ignored_mask:0 ",',
    ]

    seq = -1
    for candidate in seq_candidates:
        seq = data.find(candidate, mask)
        if seq != -1:
            break

    if seq == -1:
        die(f"{path}: não encontrei o seq_printf do inotify")

    block = """#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
\t\tmnt = real_mount(file->f_path.mnt);
\t\tif (mnt->mnt_id >= DEFAULT_KSU_MNT_ID &&
\t\t\tlikely(susfs_is_current_proc_umounted()))
\t\t{
\t\t\tstruct path path;
\t\t\tchar *pathname = kmalloc(PAGE_SIZE, GFP_KERNEL);
\t\t\tchar *dpath;

\t\t\tif (!pathname) {
\t\t\t\tgoto orig_flow;
\t\t\t}

\t\t\tdpath = d_path(&file->f_path, pathname, PAGE_SIZE);
\t\t\tif (IS_ERR(dpath)) {
\t\t\t\tgoto out_kfree;
\t\t\t}

\t\t\tif (kern_path(dpath, 0, &path)) {
\t\t\t\tgoto out_kfree;
\t\t\t}

\t\t\tif (!path.dentry->d_inode) {
\t\t\t\tgoto out_path_put;
\t\t\t}

\t\t\tseq_printf(m, "inotify wd:%x ino:%lx sdev:%x mask:%x ignored_mask:%x ",
\t\t\t\t   inode_mark->wd,
\t\t\t\t   path.dentry->d_inode->i_ino,
\t\t\t\t   path.dentry->d_inode->i_sb->s_dev,
\t\t\t\t   mask,
\t\t\t\t   mark->ignored_mask);
\t\t\tshow_mark_fhandle(m, path.dentry->d_inode);
\t\t\tseq_putc(m, '\\n');

\t\t\tpath_put(&path);
\t\t\tkfree(pathname);
\t\t\tiput(inode);
\t\t\treturn;

out_path_put:
\t\t\tpath_put(&path);
out_kfree:
\t\t\tkfree(pathname);
\t\t}
orig_flow:
#endif

\t\t"""

    data = data[:seq] + block + data[seq:]
    write(path, data)
    ok(f"{path}: aplicado")


def patch_open():
    path = "fs/open.c"
    data = read(path)

    if "SUSFS_IS_INODE_OPEN_REDIRECT_WITHOUT_UID_CHECK" not in data:
        if "is_inode_open_redirect" not in data or "fake_filename" not in data:
            die(f"{path}: faltam is_inode_open_redirect/fake_filename. O patch base SUSFS não entrou o suficiente.")

    insert_after_any(
        path,
        "\tfd = get_unused_fd_flags(flags);\n",
        """#ifdef CONFIG_KSU_SUSFS_OPEN_REDIRECT
retry:
#endif
""",
        "retry:",
    )

    insert_after_any(
        path,
        "\t\tstruct file *f = do_filp_open(dfd, tmp, &op);\n",
        """#ifdef CONFIG_KSU_SUSFS_OPEN_REDIRECT
\t\tif (!is_inode_open_redirect && f && !IS_ERR(f)) {
\t\t\tstruct inode *inode = file_inode(f);
\t\t\tif (SUSFS_IS_INODE_OPEN_REDIRECT_WITHOUT_UID_CHECK(inode)) {
\t\t\t\tfake_filename = susfs_open_redirect_spoof_do_sys_openat(inode);
\t\t\t\tif (fake_filename && !IS_ERR(fake_filename)) {
\t\t\t\t\tis_inode_open_redirect = true;
\t\t\t\t\tfilp_close(f, NULL);
\t\t\t\t\tputname(tmp);
\t\t\t\t\ttmp = fake_filename;
\t\t\t\t\tgoto retry;
\t\t\t\t}
\t\t\t}
\t\t}
#endif
""",
        "susfs_open_redirect_spoof_do_sys_openat",
    )


def patch_proc_base():
    insert_after_any(
        "fs/proc/base.c",
        "#include <linux/cpufreq_times.h>\n",
        """#if defined(CONFIG_KSU_SUSFS_SUS_MAP) || defined(CONFIG_KSU_SUSFS_OPEN_REDIRECT)
#include <linux/susfs_def.h>
#endif
""",
        "#include <linux/susfs_def.h>",
    )


def patch_cmdline():
    path = "fs/proc/cmdline.c"
    data = read(path)

    extern_block = """#ifdef CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG
extern struct static_key_false susfs_is_fake_cmdline_or_bootconfig_buffer_set;
extern void susfs_spoof_cmdline_or_bootconfig(struct seq_file *m);
#endif

"""

    hook_block = """#ifdef CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG
\tif (static_branch_likely(&susfs_is_fake_cmdline_or_bootconfig_buffer_set)) {
\t\tsusfs_spoof_cmdline_or_bootconfig(m);
\t\tseq_putc(m, '\\n');
\t\treturn 0;
\t}
#endif
"""

    if "susfs_spoof_cmdline_or_bootconfig" not in data:
        markers = [
            "#ifdef CONFIG_INITRAMFS_IGNORE_SKIP_FLAG",
            "static int cmdline_proc_show",
        ]
        for marker in markers:
            pos = data.find(marker)
            if pos != -1:
                data = data[:pos] + extern_block + data[pos:]
                ok(f"{path}: externs aplicados")
                break
        else:
            die(f"{path}: não encontrei onde meter os externs")
    else:
        ok(f"{path}: externs já existem, skip")

    if "static_branch_likely(&susfs_is_fake_cmdline_or_bootconfig_buffer_set)" not in data:
        marker = "static int cmdline_proc_show(struct seq_file *m, void *v)\n{"
        pos = data.find(marker)
        if pos == -1:
            die(f"{path}: não encontrei cmdline_proc_show() no formato esperado")
        pos += len(marker)
        data = data[:pos] + "\n" + hook_block + data[pos:]
        ok(f"{path}: hook aplicado")
    else:
        ok(f"{path}: hook já existe, skip")

    write(path, data)


def patch_task_mmu():
    path = "fs/proc/task_mmu.c"
    data = read(path)

    if "#include <linux/susfs_def.h>" not in data:
        include_markers = [
            "#include <linux/ctype.h>\n",
            "#include <linux/mm_inline.h>\n",
            "#include <linux/shmem_fs.h>\n",
            "#include <linux/mm.h>\n",
        ]
        for marker in include_markers:
            if marker in data:
                data = data.replace(
                    marker,
                    marker + """#if defined(CONFIG_KSU_SUSFS_SUS_KSTAT) || defined(CONFIG_KSU_SUSFS_SUS_MAP) || defined(CONFIG_KSU_SUSFS_OPEN_REDIRECT)
#include <linux/susfs_def.h>
#endif

""",
                    1,
                )
                ok(f"{path}: include susfs_def.h aplicado")
                break
        else:
            die(f"{path}: não encontrei sítio para meter susfs_def.h")
    else:
        ok(f"{path}: include susfs_def.h já existe, skip")

    if "spoofed_redirected_name" not in data:
        marker = "\tstruct dentry *dentry = NULL;\n"
        if marker not in data:
            die(f"{path}: não encontrei struct dentry *dentry = NULL;")
        data = data.replace(
            marker,
            marker + """#ifdef CONFIG_KSU_SUSFS_OPEN_REDIRECT
\tchar *spoofed_redirected_name = NULL;
#endif
""",
            1,
        )
        ok(f"{path}: spoofed_redirected_name aplicado")
    else:
        ok(f"{path}: spoofed_redirected_name já existe, skip")

    if "SUSFS_IS_INODE_OPEN_REDIRECT(inode)" not in data:
        marker = "\t\tstruct inode *inode = file_inode(vma->vm_file);\n"
        if marker not in data:
            die(f"{path}: não encontrei file_inode(vma->vm_file)")
        data = data.replace(
            marker,
            marker + """#ifdef CONFIG_KSU_SUSFS_OPEN_REDIRECT
\t\tif (SUSFS_IS_INODE_OPEN_REDIRECT(inode)) {
\t\t\tif (!susfs_open_redirect_spoof_show_map_vma(inode, &ino, &dev, spoofed_redirected_name)) {
\t\t\t\tpgoff = ((loff_t)vma->vm_pgoff) << PAGE_SHIFT;
\t\t\t\tgoto orig_flow;
\t\t\t}
\t\t}
#endif
#ifdef CONFIG_KSU_SUSFS_SUS_MAP
\t\tif (SUSFS_IS_INODE_SUS_MAP(inode))
\t\t\treturn;
#endif
""",
            1,
        )
        ok(f"{path}: open_redirect/sus_map aplicado")
    else:
        ok(f"{path}: open_redirect/sus_map já existe, skip")

    if "susfs_sus_kstat_spoof_show_map_vma" not in data:
        marker = "\t\tpgoff = ((loff_t)vma->vm_pgoff) << PAGE_SHIFT;\n"
        if marker not in data:
            die(f"{path}: não encontrei pgoff = ...")
        data = data.replace(
            marker,
            marker + """#ifdef CONFIG_KSU_SUSFS_SUS_KSTAT
\t\tsusfs_sus_kstat_spoof_show_map_vma(inode, &dev, &ino);
#endif
""",
            1,
        )
        ok(f"{path}: sus_kstat show_map_vma aplicado")
    else:
        ok(f"{path}: sus_kstat show_map_vma já existe, skip")

    if "goto orig_flow;" in data and "orig_flow:" not in data:
        markers = [
            "\t\tdentry = file->f_path.dentry;",
            "\t\tif (dentry) {",
        ]
        for marker in markers:
            pos = data.find(marker)
            if pos != -1:
                data = data[:pos] + """#ifdef CONFIG_KSU_SUSFS_OPEN_REDIRECT
orig_flow:
#endif
""" + data[pos:]
                ok(f"{path}: orig_flow label aplicado")
                break
        else:
            die(f"{path}: há goto orig_flow, mas não encontrei onde meter a label")

    write(path, data)


def patch_readdir():
    insert_before_any(
        "fs/readdir.c",
        "\tbuf->error = verify_dirent_name(name, namlen);",
        """#ifdef CONFIG_KSU_SUSFS_SUS_PATH
\tstruct inode *inode;
#endif
""",
        "struct inode *inode;",
    )


def patch_stat():
    path = "fs/stat.c"
    data = read(path)

    if "susfs_sus_kstat_spoof_generic_fillattr(inode, stat)" not in data:
        marker = "\tstat->blocks = inode->i_blocks;\n"
        if marker not in data:
            die(f"{path}: não encontrei stat->blocks = inode->i_blocks;")
        data = data.replace(
            marker,
            marker + """#ifdef CONFIG_KSU_SUSFS_SUS_KSTAT
\tsusfs_sus_kstat_spoof_generic_fillattr(inode, stat);
#endif
""",
            1,
        )
        ok(f"{path}: generic_fillattr hook aplicado")
    else:
        ok(f"{path}: generic_fillattr hook já existe, skip")

    write(path, data)
    data = read(path)

    if "int err = inode->i_op->getattr" in data:
        ok(f"{path}: vfs_getattr_nosec hook já existe, skip")
        return

    span = find_function_span(data, "vfs_getattr_nosec")
    if not span:
        die(f"{path}: não encontrei vfs_getattr_nosec()")

    func_pos, end_pos = span
    func = data[func_pos:end_pos]

    m = re.search(
        r'(?P<ifindent>[ \t]*)if\s*\(\s*inode->i_op->getattr\s*\)\s*\n'
        r'(?P<retindent>[ \t]*)return\s+inode->i_op->getattr\s*\(',
        func,
    )

    if not m:
        die(f"{path}: não encontrei padrão if (inode->i_op->getattr) return inode->i_op->getattr(...)")

    call_start = m.start()
    ret_start = m.start("retindent")
    paren_start = func.find("(", m.end() - 1)

    depth = 0
    semi_pos = None
    for i in range(paren_start, len(func)):
        ch = func[i]
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
        elif ch == ";" and depth == 0:
            semi_pos = i
            break

    if semi_pos is None:
        die(f"{path}: não consegui encontrar fim da chamada inode->i_op->getattr(...)")

    ret_text = func[ret_start:semi_pos + 1]
    call_expr = re.sub(r'^[ \t]*return\s+', '', ret_text).rstrip(";").strip()

    ifindent = m.group("ifindent")
    retindent = m.group("retindent")

    new_block = f"""{ifindent}if (inode->i_op->getattr)
#ifdef CONFIG_KSU_SUSFS_SUS_KSTAT
{ifindent}{{
{retindent}int err = {call_expr};
{retindent}if (!err)
{retindent}\tsusfs_sus_kstat_spoof_generic_fillattr(inode, stat);
{retindent}return err;
{ifindent}}}
#else
{retindent}return {call_expr};
#endif"""

    new_func = func[:call_start] + new_block + func[semi_pos + 1:]
    data = data[:func_pos] + new_func + data[end_pos:]

    write(path, data)
    ok(f"{path}: vfs_getattr_nosec hook aplicado")


def patch_kallsyms():
    insert_after_any(
        "kernel/kallsyms.c",
        "#include <linux/compiler.h>\n",
        """#ifdef CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS
#include <linux/susfs_def.h>
#endif
""",
        "#include <linux/susfs_def.h>",
    )


def patch_sys_uname():
    path = "kernel/sys.c"
    data = read(path)

    newuname_pos = data.find("SYSCALL_DEFINE1(newuname")
    if newuname_pos == -1:
        die(f"{path}: não encontrei SYSCALL_DEFINE1(newuname)")

    extern_block = """#ifdef CONFIG_KSU_SUSFS_SPOOF_UNAME
extern struct static_key_false susfs_is_uname_spoof_buffer_set;
extern void susfs_spoof_uname(struct new_utsname* tmp);
#endif
"""

    if "extern void susfs_spoof_uname" not in data:
        data = data[:newuname_pos] + extern_block + data[newuname_pos:]
        write(path, data)
        data = read(path)
        ok(f"{path}: externs uname aplicados")
    else:
        ok(f"{path}: externs uname já existem, skip")

    if "susfs_spoof_uname(&tmp)" in data:
        ok(f"{path}: uname hook já existe, skip")
        return

    newuname_pos = data.find("SYSCALL_DEFINE1(newuname")
    sub = data[newuname_pos:]
    span = find_function_span(sub, "SYSCALL_DEFINE1(newuname")
    if not span:
        die(f"{path}: não consegui extrair newuname()")

    local_start, local_end = span
    func_pos = newuname_pos + local_start
    end_pos = newuname_pos + local_end
    func = data[func_pos:end_pos]

    if "memcpy(&tmp, utsname()" in func:
        marker = "\tmemcpy(&tmp, utsname(), sizeof(tmp));\n"
        if marker not in func:
            die(f"{path}: tem memcpy(&tmp, utsname()), mas não no formato esperado")
        hook = """#ifdef CONFIG_KSU_SUSFS_SPOOF_UNAME
\tif (static_branch_likely(&susfs_is_uname_spoof_buffer_set))
\t\tsusfs_spoof_uname(&tmp);
#endif
"""
        func = func.replace(marker, marker + hook, 1)
        data = data[:func_pos] + func + data[end_pos:]
        write(path, data)
        ok(f"{path}: uname hook aplicado no modelo memcpy")
        return

    func2 = re.sub(
        r'(\n[ \t]*int errno = 0;\n)',
        r'''\1#ifdef CONFIG_KSU_SUSFS_SPOOF_UNAME
\tstruct new_utsname tmp;
#endif
''',
        func,
        count=1,
    )

    if func2 == func:
        die(f"{path}: não consegui inserir struct new_utsname tmp em newuname()")

    func = func2

    old = re.compile(
        r'(?P<indent>[ \t]*)down_read\(&uts_sem\);\n'
        r'(?P=indent)if \(copy_to_user\(name, utsname\(\), sizeof \*name\)\)\n'
        r'(?P<body>[ \t]*errno = -EFAULT;\n)'
        r'(?P=indent)up_read\(&uts_sem\);',
        re.M,
    )

    m = old.search(func)
    if not m:
        die(f"{path}: não encontrei bloco down_read/copy_to_user/up_read no formato esperado")

    indent = m.group("indent")
    body = m.group("body")

    new = f'''{indent}down_read(&uts_sem);
#ifdef CONFIG_KSU_SUSFS_SPOOF_UNAME
{indent}memcpy(&tmp, utsname(), sizeof(tmp));
{indent}if (static_branch_likely(&susfs_is_uname_spoof_buffer_set))
{indent}\tsusfs_spoof_uname(&tmp);
{indent}if (copy_to_user(name, &tmp, sizeof(tmp)))
{body}#else
{indent}if (copy_to_user(name, utsname(), sizeof *name))
{body}#endif
{indent}up_read(&uts_sem);'''

    func = old.sub(new, func, count=1)
    data = data[:func_pos] + func + data[end_pos:]

    write(path, data)
    ok(f"{path}: uname hook aplicado no modelo copy_to_user direto")


def main():
    patch_namei()
    patch_namespace()
    patch_fdinfo()
    patch_open()
    patch_proc_base()
    patch_cmdline()
    patch_task_mmu()
    patch_readdir()
    patch_stat()
    patch_kallsyms()
    patch_sys_uname()
    ok("SUSFS fixups unificados aplicados.")


main()
PY

echo
echo "[*] Verificação rápida:"
echo "    find . -name '*.rej' -print | sort"
find . -name "*.rej" -print | sort || true

echo
echo "    git diff --check"
git diff --check || true

echo
echo "    grep -R '^<<<<<<< \|^>>>>>>> ' -n ."
grep -R "^<<<<<<< \|^>>>>>>> " -n . || true

echo
echo "[*] Quando estiver vazio/limpo, compila:"
echo "    ./build_kernel.sh 2>&1 | tee build.log"
echo "    grep -n 'error:\|undefined reference\|implicit declaration\|undeclared' build.log | head -120"
