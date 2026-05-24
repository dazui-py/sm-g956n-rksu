from pathlib import Path
import re
import sys

def fail(msg):
    print("[FAIL]", msg)
    sys.exit(1)

def patch_task_mmu():
    p = Path("fs/proc/task_mmu.c")
    s = p.read_text()

    if "CONFIG_KSU_SUSFS_SUS_KSTAT" in s:
        print("[OK] fs/proc/task_mmu.c already patched")
        return

    snip = (
        "#ifdef CONFIG_KSU_SUSFS_SUS_KSTAT\n"
        "#include <linux/susfs_def.h>\n"
        "#endif\n"
    )

    for anchor in [
        "#include <linux/mm_inline.h>\n",
        "#include <asm/elf.h>\n",
        "#include <asm/uaccess.h>\n",
    ]:
        if anchor in s:
            s = s.replace(anchor, snip + anchor, 1)
            p.write_text(s)
            print("[OK] fs/proc/task_mmu.c patched")
            return

    fail("fs/proc/task_mmu.c: no include anchor found")

def find_func_range(lines, func):
    pat = re.compile(rf"^\s*static\s+int\s+{re.escape(func)}\s*\(")

    start = None
    for i, line in enumerate(lines):
        if pat.search(line):
            start = i
            break

    if start is None:
        print(f"[DEBUG] Could not find function {func}. Nearby symbols:")
        for i, line in enumerate(lines):
            if "filldir" in line or "verify_dirent_name" in line:
                print(f"{i+1}: {line.rstrip()}")
        fail(f"fs/readdir.c: function not found: {func}")

    end = len(lines)
    next_func = re.compile(r"^\s*static\s+int\s+\w+\s*\(")
    for j in range(start + 1, len(lines)):
        if next_func.search(lines[j]):
            end = j
            break

    return start, end

def patch_readdir_func(func):
    p = Path("fs/readdir.c")
    lines = p.read_text().splitlines(True)

    start, end = find_func_range(lines, func)

    for i in range(start, end):
        if "susfs_sus_ino_for_filldir64(ino)" in lines[i]:
            print(f"[OK] fs/readdir.c: {func} already patched")
            return

    target = None
    for i in range(start, end):
        if "buf->error = verify_dirent_name(name, namlen);" in lines[i]:
            target = i
            break

    if target is None:
        print(f"[DEBUG] Function range for {func}: lines {start+1}-{end}")
        for i in range(start, min(end, start + 80)):
            print(f"{i+1}: {lines[i].rstrip()}")
        fail(f"fs/readdir.c: verify_dirent_name anchor not found inside {func}")

    snippet = [
        "#ifdef CONFIG_KSU_SUSFS_SUS_PATH\n",
        "\tif (likely(current->susfs_task_state & TASK_STRUCT_NON_ROOT_USER_APP_PROC) && susfs_sus_ino_for_filldir64(ino)) {\n",
        "\t\treturn 0;\n",
        "\t}\n",
        "#endif\n",
    ]

    lines[target:target] = snippet
    p.write_text("".join(lines))
    print(f"[OK] fs/readdir.c: patched {func}")

def patch_sys():
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

patch_task_mmu()
patch_readdir_func("filldir")
patch_readdir_func("filldir64")
patch_sys()

print("[DONE] remaining rejects patched")
