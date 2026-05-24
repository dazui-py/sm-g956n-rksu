#!/usr/bin/env bash
set -euo pipefail

python3 <<'PY'
from pathlib import Path
import sys

path = Path("fs/proc/cmdline.c")

if not path.exists():
    print("[-] fs/proc/cmdline.c não existe. Corre isto na raiz do kernel.", file=sys.stderr)
    sys.exit(1)

data = path.read_text(errors="replace")

extern_block = '''#ifdef CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG
extern struct static_key_false susfs_is_fake_cmdline_or_bootconfig_buffer_set;
extern void susfs_spoof_cmdline_or_bootconfig(struct seq_file *m);
#endif

'''

hook_block = '''#ifdef CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG
	if (static_branch_likely(&susfs_is_fake_cmdline_or_bootconfig_buffer_set)) {
		susfs_spoof_cmdline_or_bootconfig(m);
		seq_putc(m, '\\n');
		return 0;
	}
#endif
'''

if "susfs_spoof_cmdline_or_bootconfig" not in data:
    markers = [
        "#ifdef CONFIG_INITRAMFS_IGNORE_SKIP_FLAG",
        "static int cmdline_proc_show",
    ]

    pos = -1
    for marker in markers:
        pos = data.find(marker)
        if pos != -1:
            break

    if pos == -1:
        print("[-] Não encontrei onde meter os externs em fs/proc/cmdline.c", file=sys.stderr)
        print("[*] Mostra isto: sed -n '1,80p' fs/proc/cmdline.c", file=sys.stderr)
        sys.exit(1)

    data = data[:pos] + extern_block + data[pos:]
    print("[+] fs/proc/cmdline.c: externs aplicados")
else:
    print("[+] fs/proc/cmdline.c: externs já existem, skip")

if "static_branch_likely(&susfs_is_fake_cmdline_or_bootconfig_buffer_set)" not in data:
    marker = "static int cmdline_proc_show(struct seq_file *m, void *v)\n{"
    pos = data.find(marker)

    if pos == -1:
        print("[-] Não encontrei cmdline_proc_show() no formato esperado", file=sys.stderr)
        print("[*] Mostra isto: grep -n \"cmdline_proc_show\" -A20 fs/proc/cmdline.c", file=sys.stderr)
        sys.exit(1)

    pos = pos + len(marker)
    data = data[:pos] + "\n" + hook_block + data[pos:]
    print("[+] fs/proc/cmdline.c: hook aplicado")
else:
    print("[+] fs/proc/cmdline.c: hook já existe, skip")

path.write_text(data)
PY
