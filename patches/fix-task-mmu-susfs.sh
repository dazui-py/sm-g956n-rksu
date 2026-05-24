#!/usr/bin/env bash
set -euo pipefail

python3 <<'PY'
from pathlib import Path
import sys

path = Path("fs/proc/task_mmu.c")

if not path.exists():
    print("[-] fs/proc/task_mmu.c não existe. Corre isto na raiz do kernel.", file=sys.stderr)
    sys.exit(1)

data = path.read_text(errors="replace")

def die(msg):
    print(f"[-] {msg}", file=sys.stderr)
    sys.exit(1)

def ok(msg):
    print(f"[+] {msg}")

def insert_after_marker(data, marker, block, unique):
    if unique in data:
        ok(f"já aplicado: {unique}")
        return data

    pos = data.find(marker)
    if pos == -1:
        die(f"marker não encontrado: {marker!r}")

    pos += len(marker)
    return data[:pos] + block + data[pos:]

def insert_before_marker(data, marker, block, unique):
    if unique in data:
        ok(f"já aplicado: {unique}")
        return data

    pos = data.find(marker)
    if pos == -1:
        die(f"marker não encontrado: {marker!r}")

    return data[:pos] + block + data[pos:]

# 1. include susfs_def.h
if "#include <linux/susfs_def.h>" not in data:
    include_markers = [
        "#include <linux/ctype.h>\n",
        "#include <linux/mm_inline.h>\n",
        "#include <linux/shmem_fs.h>\n",
        "#include <linux/mm.h>\n",
    ]

    inserted = False
    for marker in include_markers:
        if marker in data:
            data = data.replace(
                marker,
                marker + """#if defined(CONFIG_KSU_SUSFS_SUS_KSTAT) || defined(CONFIG_KSU_SUSFS_SUS_MAP) || defined(CONFIG_KSU_SUSFS_OPEN_REDIRECT)
#include <linux/susfs_def.h>
#endif

""",
                1
            )
            inserted = True
            ok("include susfs_def.h aplicado")
            break

    if not inserted:
        die("não encontrei sítio para meter #include <linux/susfs_def.h>")
else:
    ok("include susfs_def.h já existe")

# 2. variável spoofed_redirected_name
data = insert_after_marker(
    data,
    "\tstruct dentry *dentry = NULL;\n",
    """#ifdef CONFIG_KSU_SUSFS_OPEN_REDIRECT
\tchar *spoofed_redirected_name = NULL;
#endif
""",
    "spoofed_redirected_name"
)

# 3. lógica depois de file_inode()
data = insert_after_marker(
    data,
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

# 4. kstat spoof + label orig_flow
data = insert_after_marker(
    data,
    "\t\tpgoff = ((loff_t)vma->vm_pgoff) << PAGE_SHIFT;\n",
    """#ifdef CONFIG_KSU_SUSFS_SUS_KSTAT
\t\tsusfs_sus_kstat_spoof_show_map_vma(inode, &dev, &ino);
#endif
#ifdef CONFIG_KSU_SUSFS_OPEN_REDIRECT
orig_flow:
#endif
""",
    "susfs_sus_kstat_spoof_show_map_vma"
)

path.write_text(data)
print("[+] fs/proc/task_mmu.c: SUSFS rejects aplicados")
PY
