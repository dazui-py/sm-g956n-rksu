from pathlib import Path
import re
import sys

p = Path("kernel/sys.c")
s = p.read_text()

# Garante o extern antes da syscall
extern = (
    "#ifdef CONFIG_KSU_SUSFS_SPOOF_UNAME\n"
    "extern void susfs_spoof_uname(struct new_utsname* tmp);\n"
    "#endif\n"
)

if "extern void susfs_spoof_uname" not in s:
    anchor = "SYSCALL_DEFINE1(newuname, struct new_utsname __user *, name)"
    if anchor not in s:
        print("[FAIL] newuname anchor not found")
        sys.exit(1)
    s = s.replace(anchor, extern + anchor, 1)
    print("[OK] inserted extern")
else:
    print("[OK] extern already exists")

pattern = re.compile(
    r"SYSCALL_DEFINE1\(newuname,\s*struct new_utsname __user \*,\s*name\)\s*\{.*?\n\}",
    re.S
)

new_func = '''SYSCALL_DEFINE1(newuname, struct new_utsname __user *, name)
{
\tint errno = 0;
\tstruct new_utsname tmp;

\tdown_read(&uts_sem);
\tmemcpy(&tmp, utsname(), sizeof(tmp));
#ifdef CONFIG_KSU_SUSFS_SPOOF_UNAME
\tsusfs_spoof_uname(&tmp);
#endif
\tup_read(&uts_sem);

\tif (copy_to_user(name, &tmp, sizeof(tmp)))
\t\terrno = -EFAULT;

\tif (!errno && override_release(name->release, sizeof(name->release)))
\t\terrno = -EFAULT;
\tif (!errno && override_architecture(name))
\t\terrno = -EFAULT;
\treturn errno;
}'''

s2, n = pattern.subn(new_func, s, count=1)

if n != 1:
    print("[FAIL] could not replace newuname function")
    sys.exit(1)

p.write_text(s2)
print("[OK] kernel/sys.c: rewrote newuname with SUSFS spoof tmp")
