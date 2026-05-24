from pathlib import Path
import re
import sys

def fail(msg):
    print("[FAIL]", msg)
    sys.exit(1)

def patch_readdir_func(func):
    path = Path("fs/readdir.c")
    s = path.read_text()

    pattern = rf"(static int {func}\s*\([^)]*\)\s*\{{.*?)(\n[ \t]*buf->error = verify_dirent_name\(name, namlen\);)"
    m = re.search(pattern, s, re.S)
    if not m:
        fail(f"fs/readdir.c: function anchor not found for {func}")

    if "susfs_sus_ino_for_filldir64(ino)" in m.group(1)[-700:]:
        print(f"[OK] fs/readdir.c: {func} already patched")
        return

    snippet = (
        "\n#ifdef CONFIG_KSU_SUSFS_SUS_PATH\n"
        "\tif (likely(current->susfs_task_state & TASK_STRUCT_NON_ROOT_USER_APP_PROC) && susfs_sus_ino_for_filldir64(ino)) {\n"
        "\t\treturn 0;\n"
        "\t}\n"
        "#endif"
    )

    s = s[:m.start(2)] + snippet + s[m.start(2):]
    path.write_text(s)
    print(f"[OK] fs/readdir.c: patched {func}")

patch_readdir_func("filldir")
patch_readdir_func("filldir64")

p = Path("kernel/sys.c")
s = p.read_text()

extern = (
    "#ifdef CONFIG_KSU_SUSFS_SPOOF_UNAME\n"
    "extern void susfs_spoof_uname(struct new_utsname* tmp);\n"
    "#endif\n"
)

if "extern void susfs_spoof_uname" not in s:
    anchor = "SYSCALL_DEFINE1(newuname, struct new_utsname __user *, name)"
    if anchor not in s:
        fail("kernel/sys.c: newuname anchor not found")
    s = s.replace(anchor, extern + anchor, 1)
    print("[OK] kernel/sys.c: inserted extern")
else:
    print("[OK] kernel/sys.c: extern already present")

if "susfs_spoof_uname(&tmp);" not in s:
    anchor = "\tmemcpy(&tmp, utsname(), sizeof(tmp));\n"
    if anchor not in s:
        fail("kernel/sys.c: memcpy uname anchor not found")
    s = s.replace(
        anchor,
        anchor +
        "#ifdef CONFIG_KSU_SUSFS_SPOOF_UNAME\n"
        "\tsusfs_spoof_uname(&tmp);\n"
        "#endif\n",
        1
    )
    print("[OK] kernel/sys.c: patched newuname")
else:
    print("[OK] kernel/sys.c: newuname already patched")

p.write_text(s)
