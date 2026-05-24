#!/usr/bin/env bash
set -euo pipefail

python3 <<'PY'
from pathlib import Path
import sys

path = Path("fs/notify/fdinfo.c")

if not path.exists():
    print("[-] fs/notify/fdinfo.c não existe. Corre isto na raiz do kernel.", file=sys.stderr)
    sys.exit(1)

data = path.read_text(errors="replace")

if "mnt->mnt_id >= DEFAULT_KSU_MNT_ID" in data:
    print("[+] fs/notify/fdinfo.c: já aplicado, skip")
    sys.exit(0)

func = data.find("inotify_fdinfo")
if func == -1:
    print("[-] Não encontrei inotify_fdinfo().", file=sys.stderr)
    sys.exit(1)

igrab = data.find("inode = igrab(mark->inode);", func)
if igrab == -1:
    print("[-] Não encontrei inode = igrab(mark->inode);", file=sys.stderr)
    sys.exit(1)

if_inode = data.find("if (inode) {", igrab)
if if_inode == -1:
    print("[-] Não encontrei if (inode) {", file=sys.stderr)
    sys.exit(1)

mask = data.find("u32 mask = mark->mask & IN_ALL_EVENTS;", if_inode)
if mask == -1:
    print("[-] Não encontrei u32 mask = mark->mask & IN_ALL_EVENTS;", file=sys.stderr)
    sys.exit(1)

seq = data.find('seq_printf(m, "inotify wd:%x ino:%lx sdev:%x mask:%x ignored_mask:%x ",', mask)
if seq == -1:
    seq = data.find('seq_printf(m, "inotify wd:%x ino:%lx sdev:%x mask:%x ignored_mask:0 ",', mask)

if seq == -1:
    print("[-] Não encontrei o seq_printf do inotify.", file=sys.stderr)
    print("[*] Mostra isto:", file=sys.stderr)
    print("    sed -n '95,130p' fs/notify/fdinfo.c", file=sys.stderr)
    sys.exit(1)

block = '''#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
		mnt = real_mount(file->f_path.mnt);
		if (mnt->mnt_id >= DEFAULT_KSU_MNT_ID &&
			likely(susfs_is_current_proc_umounted()))
		{
			struct path path;
			char *pathname = kmalloc(PAGE_SIZE, GFP_KERNEL);
			char *dpath;

			if (!pathname) {
				goto orig_flow;
			}

			dpath = d_path(&file->f_path, pathname, PAGE_SIZE);
			if (IS_ERR(dpath)) {
				goto out_kfree;
			}

			if (kern_path(dpath, 0, &path)) {
				goto out_kfree;
			}

			if (!path.dentry->d_inode) {
				goto out_path_put;
			}

			seq_printf(m, "inotify wd:%x ino:%lx sdev:%x mask:%x ignored_mask:%x ",
				   inode_mark->wd,
				   path.dentry->d_inode->i_ino,
				   path.dentry->d_inode->i_sb->s_dev,
				   mask,
				   mark->ignored_mask);
			show_mark_fhandle(m, path.dentry->d_inode);
			seq_putc(m, '\\n');

			path_put(&path);
			kfree(pathname);
			iput(inode);
			return;

out_path_put:
			path_put(&path);
out_kfree:
			kfree(pathname);
		}
orig_flow:
#endif

		'''

data = data[:seq] + block + data[seq:]
path.write_text(data)

print("[+] fs/notify/fdinfo.c: bloco SUSFS aplicado")
PY
