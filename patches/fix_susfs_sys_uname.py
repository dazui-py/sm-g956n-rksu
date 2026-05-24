from pathlib import Path
import re
import sys

p = Path("kernel/sys.c")
s = p.read_text()

if "susfs_spoof_uname(&tmp);" in s:
    print("[OK] kernel/sys.c: susfs_spoof_uname already inserted")
    sys.exit(0)

m = re.search(
    r"SYSCALL_DEFINE1\s*\(\s*newuname\s*,\s*struct\s+new_utsname\s+__user\s*\*,\s*name\s*\)\s*\{",
    s
)

if not m:
    print("[FAIL] newuname function header not found")
    sys.exit(1)

start = m.end()
next_func = re.search(r"\nSYSCALL_DEFINE|^\w.*\)\s*\{", s[start:], re.M)
end = start + next_func.start() if next_func else len(s)

body = s[start:end]

lines = body.splitlines(True)
insert_pos = None
offset = start

running = start
for line in lines:
    if "memcpy" in line and "tmp" in line:
        insert_pos = running + len(line)
        break
    running += len(line)

if insert_pos is None:
    print("[FAIL] memcpy line inside newuname not found")
    print("---- newuname body preview ----")
    print(body[:1200])
    sys.exit(1)

snippet = (
    "#ifdef CONFIG_KSU_SUSFS_SPOOF_UNAME\n"
    "\tsusfs_spoof_uname(&tmp);\n"
    "#endif\n"
)

s = s[:insert_pos] + snippet + s[insert_pos:]
p.write_text(s)

print("[OK] kernel/sys.c: inserted susfs_spoof_uname(&tmp)")
