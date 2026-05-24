#!/usr/bin/env bash
set -euo pipefail

python3 <<'PY'
from pathlib import Path
import re
import sys

path = Path("kernel/sys.c")
data = path.read_text(errors="replace")

if "susfs_spoof_uname(&tmp)" in data:
    print("[+] kernel/sys.c: uname hook já existe, skip")
    sys.exit(0)

# Garante que os externs existem
newuname_pos = data.find("SYSCALL_DEFINE1(newuname")
if newuname_pos == -1:
    print("[-] Não encontrei SYSCALL_DEFINE1(newuname)", file=sys.stderr)
    sys.exit(1)

extern_block = """#ifdef CONFIG_KSU_SUSFS_SPOOF_UNAME
extern struct static_key_false susfs_is_uname_spoof_buffer_set;
extern void susfs_spoof_uname(struct new_utsname* tmp);
#endif
"""

if "extern void susfs_spoof_uname" not in data:
    data = data[:newuname_pos] + extern_block + data[newuname_pos:]
    newuname_pos += len(extern_block)
    print("[+] externs aplicados")
else:
    print("[+] externs já existem")

# Extrai função newuname
newuname_pos = data.find("SYSCALL_DEFINE1(newuname")
brace = data.find("{", newuname_pos)
if brace == -1:
    print("[-] Não encontrei abertura de newuname()", file=sys.stderr)
    sys.exit(1)

depth = 0
end = None
for i in range(brace, len(data)):
    if data[i] == "{":
        depth += 1
    elif data[i] == "}":
        depth -= 1
        if depth == 0:
            end = i + 1
            break

if end is None:
    print("[-] Não encontrei fim de newuname()", file=sys.stderr)
    sys.exit(1)

func = data[newuname_pos:end]

# Adiciona struct tmp depois de int errno = 0;
func2 = re.sub(
    r'(\n[ \t]*int errno = 0;\n)',
    r'''\1#ifdef CONFIG_KSU_SUSFS_SPOOF_UNAME
	struct new_utsname tmp;
#endif
''',
    func,
    count=1
)

if func2 == func:
    print("[-] Não consegui inserir struct new_utsname tmp", file=sys.stderr)
    sys.exit(1)

func = func2

old = re.compile(
    r'(?P<indent>[ \t]*)down_read\(&uts_sem\);\n'
    r'(?P=indent)if \(copy_to_user\(name, utsname\(\), sizeof \*name\)\)\n'
    r'(?P<body>[ \t]*errno = -EFAULT;\n)'
    r'(?P=indent)up_read\(&uts_sem\);',
    re.M
)

m = old.search(func)
if not m:
    print("[-] Não encontrei bloco down_read/copy_to_user/up_read no formato esperado", file=sys.stderr)
    print("[*] Mostra: grep -n \"SYSCALL_DEFINE1(newuname\" -A25 -B5 kernel/sys.c", file=sys.stderr)
    sys.exit(1)

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

data = data[:newuname_pos] + func + data[end:]
path.write_text(data)

print("[+] kernel/sys.c: uname spoof hook aplicado")
PY
