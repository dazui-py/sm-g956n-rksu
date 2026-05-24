#!/usr/bin/env bash
set -euo pipefail

python3 <<'PY'
from pathlib import Path
import re
import sys

path = Path("fs/stat.c")

if not path.exists():
    print("[-] fs/stat.c não existe. Corre isto na raiz do kernel.", file=sys.stderr)
    sys.exit(1)

data = path.read_text(errors="replace")

def die(msg):
    print(f"[-] {msg}", file=sys.stderr)
    sys.exit(1)

def ok(msg):
    print(f"[+] {msg}")

# 1. Garante o hook em generic_fillattr()
if "susfs_sus_kstat_spoof_generic_fillattr(inode, stat)" not in data:
    marker = "\tstat->blocks = inode->i_blocks;\n"
    if marker not in data:
        die("não encontrei stat->blocks = inode->i_blocks; em generic_fillattr()")

    data = data.replace(
        marker,
        marker + """#ifdef CONFIG_KSU_SUSFS_SUS_KSTAT
\tsusfs_sus_kstat_spoof_generic_fillattr(inode, stat);
#endif
""",
        1
    )
    ok("generic_fillattr hook aplicado")
else:
    ok("generic_fillattr hook já existe")

# 2. Envolve inode->i_op->getattr() em vfs_getattr_nosec()
if "int err = inode->i_op->getattr" in data:
    ok("vfs_getattr_nosec getattr hook já existe")
    path.write_text(data)
    sys.exit(0)

func_pos = data.find("vfs_getattr_nosec")
if func_pos == -1:
    die("não encontrei vfs_getattr_nosec()")

brace_pos = data.find("{", func_pos)
if brace_pos == -1:
    die("não encontrei abertura de vfs_getattr_nosec()")

depth = 0
end_pos = None
for i in range(brace_pos, len(data)):
    if data[i] == "{":
        depth += 1
    elif data[i] == "}":
        depth -= 1
        if depth == 0:
            end_pos = i + 1
            break

if end_pos is None:
    die("não consegui encontrar o fim de vfs_getattr_nosec()")

func = data[func_pos:end_pos]

m = re.search(
    r'(?P<ifindent>[ \t]*)if\s*\(\s*inode->i_op->getattr\s*\)\s*\n'
    r'(?P<retindent>[ \t]*)return\s+inode->i_op->getattr\s*\(',
    func
)

if not m:
    die("não encontrei o padrão: if (inode->i_op->getattr) return inode->i_op->getattr(...)")

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
    die("não consegui encontrar o fim da chamada inode->i_op->getattr(...)")

old_block = func[call_start:semi_pos + 1]

# Extrai só a chamada, sem "return " e sem ";"
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

path.write_text(data)
ok("vfs_getattr_nosec getattr hook aplicado")
PY
