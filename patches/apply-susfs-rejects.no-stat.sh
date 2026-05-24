#!/usr/bin/env bash
set -euo pipefail

cd "${1:-.}"

[ -f fs/namei.c ] || {
    echo "[-] Corre isto na raiz do kernel."
    exit 1
}

python3 <<'PY'
from pathlib import Path
import sys

def die(msg):
    print(f"[-] {msg}", file=sys.stderr)
    sys.exit(1)

def ok(msg):
    print(f"[+] {msg}")

def warn(msg):
    print(f"[!] {msg}", file=sys.stderr)

def read(path):
    p = Path(path)
    if not p.exists():
        die(f"Ficheiro não encontrado: {path}")
    return p.read_text(errors="replace")

def write(path, data):
    Path(path).write_text(data)

def insert_after(path, marker, block, unique):
    data = read(path)

    if unique in data:
        ok(f"{path}: já aplicado, skip")
        return

    if marker not in data:
        die(f"{path}: marker não encontrado para insert_after: {marker!r}")

    data = data.replace(marker, marker + block, 1)
    write(path, data)
    ok(f"{path}: aplicado")

def insert_before(path, marker, block, unique):
    data = read(path)

    if unique in data:
        ok(f"{path}: já aplicado, skip")
        return

    if marker not in data:
        die(f"{path}: marker não encontrado para insert_before: {marker!r}")

    data = data.replace(marker, block + marker, 1)
    write(path, data)
    ok(f"{path}: aplicado")

def replace_once(path, old, new, unique):
    data = read(path)

    if unique in data:
        ok(f"{path}: já aplicado, skip")
        return

    if old not in data:
        die(f"{path}: bloco antigo não encontrado")

    data = data.replace(old, new, 1)
    write(path, data)
    ok(f"{path}: aplicado")

# 1. fs/namei.c include
insert_after(
    "fs/namei.c",
    "#include <asm/uaccess.h>\n",
    """#if defined(CONFIG_KSU_SUSFS_SUS_PATH) || defined(CONFIG_KSU_SUSFS_OPEN_REDIRECT)
#include <linux/susfs_def.h>
#endif
""",
    "#include <linux/susfs_def.h>"
)

# 2. fs/namespace.c include + externs + copy flag
insert_after(
    "fs/namespace.c",
    "#include <linux/task_work.h>\n",
    """#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
#include <linux/susfs_def.h>
#endif
""",
    "#include <linux/susfs_def.h>"
)

insert_before(
    "fs/namespace.c",
    "/* Maximum number of mounts in a mount namespace */",
    """#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
extern bool susfs_is_current_ksu_domain(void);
extern struct static_key_true susfs_is_sdcard_android_data_not_decrypted;

#define CL_COPY_MNT_NS BIT(25) /* used by copy_mnt_ns() */

#endif

""",
    "CL_COPY_MNT_NS BIT(25)"
)

insert_before(
    "fs/namespace.c",
    "\tnew = copy_tree(old, old->mnt.mnt_root, copy_flags);",
    """#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
\tcopy_flags |= CL_COPY_MNT_NS;
#endif
""",
    "copy_flags |= CL_COPY_MNT_NS"
)

# 3. fs/notify/fdinfo.c
# Este bloco precisa que outros hunks já tenham metido includes/externs para real_mount/susfs_is_current_proc_umounted.
insert_before(
    "fs/notify/fdinfo.c",
    "\t\tseq_printf(m, \"inotify wd:%x ino:%lx sdev:%x mask:%x ignored_mask:0 \",",
    """#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
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
\t\t\tif (!dpath) {
\t\t\t\tgoto out_kfree;
\t\t\t}
\t\t\tif (kern_path(dpath, 0, &path)) {
\t\t\t\tgoto out_kfree;
\t\t\t}
\t\t\tif (!path.dentry->d_inode) {
\t\t\t\tgoto out_path_put;
\t\t\t}
\t\t\tseq_printf(m, "inotify wd:%x ino:%lx sdev:%x mask:%x ignored_mask:0 ",
\t\t\t\t\tinode_mark->wd, path.dentry->d_inode->i_ino, path.dentry->d_inode->i_sb->s_dev,
\t\t\t\t\tinotify_mark_user_mask(mark));
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

""",
    "mnt->mnt_id >= DEFAULT_KSU_MNT_ID"
)

# 4. fs/open.c
data_open = read("fs/open.c")
if "SUSFS_IS_INODE_OPEN_REDIRECT_WITHOUT_UID_CHECK" not in data_open:
    if "is_inode_open_redirect" not in data_open or "fake_filename" not in data_open:
        die("fs/open.c: faltam variáveis is_inode_open_redirect/fake_filename. O hunk anterior do patch provavelmente não entrou bem.")

insert_after(
    "fs/open.c",
    "\tfd = get_unused_fd_flags(flags);\n",
    """#ifdef CONFIG_KSU_SUSFS_OPEN_REDIRECT
retry:
#endif
""",
    "retry:"
)

insert_after(
    "fs/open.c",
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
    "susfs_open_redirect_spoof_do_sys_openat"
)

# 5. fs/proc/base.c include
insert_after(
    "fs/proc/base.c",
    "#include <linux/cpufreq_times.h>\n",
    """#if defined(CONFIG_KSU_SUSFS_SUS_MAP) || defined(CONFIG_KSU_SUSFS_OPEN_REDIRECT)
#include <linux/susfs_def.h>
#endif
""",
    "#include <linux/susfs_def.h>"
)

# 6. fs/proc/cmdline.c
insert_after(
    "fs/proc/cmdline.c",
    "#endif\n\n",
    """#ifdef CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG
extern struct static_key_false susfs_is_fake_cmdline_or_bootconfig_buffer_set;
extern void susfs_spoof_cmdline_or_bootconfig(struct seq_file *m);
#endif

""",
    "susfs_spoof_cmdline_or_bootconfig"
)

# Corrigi aqui uma porcaria do reject original:
# ele tinha seq_printf(m, "%s\\n"); sem argumento.
# Isto é errado. Para só meter newline, usa seq_putc().
insert_after(
    "fs/proc/cmdline.c",
    "static int cmdline_proc_show(struct seq_file *m, void *v)\n{\n",
    """#ifdef CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG
\tif (static_branch_likely(&susfs_is_fake_cmdline_or_bootconfig_buffer_set)) {
\t\tsusfs_spoof_cmdline_or_bootconfig(m);
\t\tseq_putc(m, '\\n');
\t\treturn 0;
\t}
#endif
""",
    "static_branch_likely(&susfs_is_fake_cmdline_or_bootconfig_buffer_set)"
)

# 7. fs/proc/task_mmu.c
insert_after(
    "fs/proc/task_mmu.c",
    "#include <linux/ctype.h>\n",
    """#if defined(CONFIG_KSU_SUSFS_SUS_KSTAT) || defined(CONFIG_KSU_SUSFS_SUS_MAP) || defined(CONFIG_KSU_SUSFS_OPEN_REDIRECT)
#include <linux/susfs_def.h>
#endif
""",
    "#include <linux/susfs_def.h>"
)

insert_after(
    "fs/proc/task_mmu.c",
    "\tstruct dentry *dentry = NULL;\n",
    """#ifdef CONFIG_KSU_SUSFS_OPEN_REDIRECT
\tchar *spoofed_redirected_name = NULL;
#endif
""",
    "spoofed_redirected_name"
)

insert_after(
    "fs/proc/task_mmu.c",
    "\t\tstruct inode *inode = file_inode(vma->vm_file);\n",
    """#ifdef CONFIG_KSU_SUSFS_OPEN_REDIRECT
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
    "SUSFS_IS_INODE_OPEN_REDIRECT(inode)"
)

insert_after(
    "fs/proc/task_mmu.c",
    "\t\tpgoff = ((loff_t)vma->vm_pgoff) << PAGE_SHIFT;\n",
    """#ifdef CONFIG_KSU_SUSFS_SUS_KSTAT
\t\tsusfs_sus_kstat_spoof_show_map_vma(inode, &dev, &ino);
#endif
""",
    "susfs_sus_kstat_spoof_show_map_vma"
)

# 8. fs/readdir.c
insert_before(
    "fs/readdir.c",
    "\tbuf->error = verify_dirent_name(name, namlen);",
    """#ifdef CONFIG_KSU_SUSFS_SUS_PATH
\tstruct inode *inode;
#endif
""",
    "struct inode *inode;"
)

# 9. fs/stat.c
# já aplicado por fix-stat-susfs.sh

# 10. kernel/kallsyms.c include
insert_after(
    "kernel/kallsyms.c",
    "#include <linux/compiler.h>\n",
    """#ifdef CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS
#include <linux/susfs_def.h>
#endif
""",
    "#include <linux/susfs_def.h>"
)

# 11. kernel/sys.c uname spoof
insert_before(
    "kernel/sys.c",
    "SYSCALL_DEFINE1(newuname, struct new_utsname __user *, name)",
    """#ifdef CONFIG_KSU_SUSFS_SPOOF_UNAME
extern struct static_key_false susfs_is_uname_spoof_buffer_set;
extern void susfs_spoof_uname(struct new_utsname* tmp);
#endif
""",
    "susfs_spoof_uname"
)

insert_after(
    "kernel/sys.c",
    "\tmemcpy(&tmp, utsname(), sizeof(tmp));\n",
    """#ifdef CONFIG_KSU_SUSFS_SPOOF_UNAME
\tif (static_branch_likely(&susfs_is_uname_spoof_buffer_set))
\t\tsusfs_spoof_uname(&tmp);
#endif
""",
    "susfs_is_uname_spoof_buffer_set"
)

ok("Rejects SUSFS aplicados.")
PY

echo
echo "[*] A verificar rejects restantes..."
find . -name "*.rej" -print | sort || true

echo
echo "[*] A verificar diff..."
git diff --check || true

echo
echo "[*] Próximo passo:"
echo "    git diff -- fs/namei.c fs/namespace.c fs/notify/fdinfo.c fs/open.c fs/proc/base.c fs/proc/cmdline.c fs/proc/task_mmu.c fs/readdir.c fs/stat.c kernel/kallsyms.c kernel/sys.c"
