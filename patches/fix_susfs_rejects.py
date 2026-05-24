from pathlib import Path
import re
import sys

def read(path):
    return Path(path).read_text()

def write(path, data):
    Path(path).write_text(data)

def fail(msg):
    print(f"[FAIL] {msg}")
    sys.exit(1)

def ok(msg):
    print(f"[OK] {msg}")

def insert_after_literal(path, anchor, snippet, marker):
    s = read(path)
    if marker in s:
        ok(f"{path}: already has {marker}")
        return
    if anchor not in s:
        fail(f"{path}: anchor not found: {anchor!r}")
    s = s.replace(anchor, anchor + snippet, 1)
    write(path, s)
    ok(f"{path}: inserted {marker}")

def insert_before_literal(path, anchor, snippet, marker):
    s = read(path)
    if marker in s:
        ok(f"{path}: already has {marker}")
        return
    if anchor not in s:
        fail(f"{path}: anchor not found: {anchor!r}")
    s = s.replace(anchor, snippet + anchor, 1)
    write(path, s)
    ok(f"{path}: inserted {marker}")

def regex_insert_after(path, pattern, snippet, marker):
    s = read(path)
    if marker in s:
        ok(f"{path}: already has {marker}")
        return
    m = re.search(pattern, s, re.S)
    if not m:
        fail(f"{path}: regex anchor not found for {marker}")
    s = s[:m.end()] + snippet + s[m.end():]
    write(path, s)
    ok(f"{path}: inserted {marker}")

def regex_insert_before(path, pattern, snippet, marker):
    s = read(path)
    if marker in s:
        ok(f"{path}: already has {marker}")
        return
    m = re.search(pattern, s, re.S)
    if not m:
        fail(f"{path}: regex anchor not found for {marker}")
    s = s[:m.start()] + snippet + s[m.start():]
    write(path, s)
    ok(f"{path}: inserted {marker}")

# fs/namei.c include
insert_after_literal(
    "fs/namei.c",
    "#include <asm/uaccess.h>\n",
    "#if defined(CONFIG_KSU_SUSFS_SUS_PATH) || defined(CONFIG_KSU_SUSFS_OPEN_REDIRECT)\n"
    "#include <linux/susfs_def.h>\n"
    "#endif\n",
    "susfs_def.h"
)

# fs/namei.c may_create_in_sticky
regex_insert_after(
    "fs/namei.c",
    r"static int may_create_in_sticky\s*\(\s*umode_t dir_mode,\s*kuid_t dir_uid,\s*\n\s*struct inode \* const inode\s*\)\s*\{\n",
    "#ifdef CONFIG_KSU_SUSFS_SUS_PATH\n"
    "\tif (unlikely(inode->i_state & INODE_STATE_SUS_PATH) && likely(current->susfs_task_state & TASK_STRUCT_NON_ROOT_USER_APP_PROC)) {\n"
    "\t\treturn -ENOENT;\n"
    "\t}\n"
    "#endif\n",
    "INODE_STATE_SUS_PATH"
)

# fs/namespace.c include + globals
insert_after_literal(
    "fs/namespace.c",
    "#include <linux/task_work.h>\n",
    "#if defined(CONFIG_KSU_SUSFS_SUS_MOUNT) || defined(CONFIG_KSU_SUSFS_TRY_UMOUNT)\n"
    "#include <linux/susfs_def.h>\n"
    "#endif\n",
    "susfs_def.h"
)

insert_before_literal(
    "fs/namespace.c",
    "/* Maximum number of mounts in a mount namespace */",
    "#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\n"
    "extern bool susfs_is_current_ksu_domain(void);\n"
    "extern bool susfs_is_current_zygote_domain(void);\n"
    "\n"
    "static DEFINE_IDA(susfs_mnt_id_ida);\n"
    "static DEFINE_IDA(susfs_mnt_group_ida);\n"
    "static int susfs_mnt_id_start = DEFAULT_SUS_MNT_ID;\n"
    "static int susfs_mnt_group_start = DEFAULT_SUS_MNT_GROUP_ID;\n"
    "\n"
    "#define CL_ZYGOTE_COPY_MNT_NS BIT(24) /* used by copy_mnt_ns() */\n"
    "#define CL_COPY_MNT_NS BIT(25) /* used by copy_mnt_ns() */\n"
    "#endif\n"
    "\n"
    "#ifdef CONFIG_KSU_SUSFS_AUTO_ADD_SUS_KSU_DEFAULT_MOUNT\n"
    "extern void susfs_auto_add_sus_ksu_default_mount(const char __user *to_pathname);\n"
    "bool susfs_is_auto_add_sus_ksu_default_mount_enabled = true;\n"
    "#endif\n"
    "#ifdef CONFIG_KSU_SUSFS_AUTO_ADD_SUS_BIND_MOUNT\n"
    "extern int susfs_auto_add_sus_bind_mount(const char *pathname, struct path *path_target);\n"
    "bool susfs_is_auto_add_sus_bind_mount_enabled = true;\n"
    "#endif\n"
    "#ifdef CONFIG_KSU_SUSFS_AUTO_ADD_TRY_UMOUNT_FOR_BIND_MOUNT\n"
    "extern void susfs_auto_add_try_umount_for_bind_mount(struct path *path);\n"
    "bool susfs_is_auto_add_try_umount_for_bind_mount_enabled = true;\n"
    "#endif\n"
    "\n",
    "susfs_mnt_id_ida"
)

# fs/namespace.c clone_mnt
s = read("fs/namespace.c")
if "bypass_orig_flow:" not in s:
    pattern = r"(\n[ \t]*mnt = alloc_vfsmnt\(old->mnt_devname\);\n)"
    replacement = (
        "#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\n"
        "\tbool is_current_ksu_domain = susfs_is_current_ksu_domain();\n"
        "\tbool is_current_zygote_domain = susfs_is_current_zygote_domain();\n"
        "\n"
        "\tif (unlikely(is_current_ksu_domain)) {\n"
        "\t\tif (!(flag & CL_COPY_MNT_NS)) {\n"
        "\t\t\tmnt = alloc_vfsmnt(old->mnt_devname, true, 0);\n"
        "\t\t\tgoto bypass_orig_flow;\n"
        "\t\t}\n"
        "\t\tmnt = alloc_vfsmnt(old->mnt_devname, true, old->mnt_id);\n"
        "\t\tif (mnt) {\n"
        "\t\t\tmnt->mnt.susfs_mnt_id_backup = DEFAULT_SUS_MNT_ID_FOR_KSU_PROC_UNSHARE;\n"
        "\t\t}\n"
        "\t\tgoto bypass_orig_flow;\n"
        "\t}\n"
        "\tif (likely(is_current_zygote_domain) && (old->mnt_id >= DEFAULT_SUS_MNT_ID)) {\n"
        "\t\tmnt = alloc_vfsmnt(old->mnt_devname, true, 0);\n"
        "\t\tgoto bypass_orig_flow;\n"
        "\t}\n"
        "\tif ((flag & CL_COPY_MNT_NS) && (old->mnt_id >= DEFAULT_SUS_MNT_ID)) {\n"
        "\t\tmnt = alloc_vfsmnt(old->mnt_devname, true, 0);\n"
        "\t\tgoto bypass_orig_flow;\n"
        "\t}\n"
        "\tmnt = alloc_vfsmnt(old->mnt_devname, false, 0);\n"
        "bypass_orig_flow:\n"
        "#else\n"
        "\tmnt = alloc_vfsmnt(old->mnt_devname);\n"
        "#endif\n"
    )
    s2, n = re.subn(pattern, "\n" + replacement, s, count=1)
    if n != 1:
        fail("fs/namespace.c: could not replace clone_mnt alloc_vfsmnt")
    write("fs/namespace.c", s2)
    ok("fs/namespace.c: patched clone_mnt")
else:
    ok("fs/namespace.c: clone_mnt already patched")

# fs/namespace.c do_mount before dput_out:
regex_insert_before(
    "fs/namespace.c",
    r"\n[ \t]*dput_out:",
    "\n#ifdef CONFIG_KSU_SUSFS_AUTO_ADD_SUS_KSU_DEFAULT_MOUNT\n"
    "\t/* For both Legacy and Magic Mount KernelSU */\n"
    "\tif (!retval && susfs_is_auto_add_sus_ksu_default_mount_enabled &&\n"
    "\t\t\t(!(flags & (MS_REMOUNT | MS_BIND | MS_SHARED | MS_PRIVATE | MS_SLAVE | MS_UNBINDABLE)))) {\n"
    "\t\tif (susfs_is_current_ksu_domain()) {\n"
    "\t\t\tsusfs_auto_add_sus_ksu_default_mount(dir_name);\n"
    "\t\t}\n"
    "\t}\n"
    "#endif\n",
    "susfs_auto_add_sus_ksu_default_mount(dir_name)"
)

# fs/namespace.c copy_mnt_ns copy flags
s = read("fs/namespace.c")
if "copy_flags |= CL_COPY_MNT_NS;" not in s:
    old = (
        "\tif (user_ns != ns->user_ns)\n"
        "\t\tcopy_flags |= CL_SHARED_TO_SLAVE | CL_UNPRIVILEGED;\n"
    )
    new = old + (
        "#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\n"
        "\t/* Always let clone_mnt() in copy_tree() know it is from copy_mnt_ns() */\n"
        "\tcopy_flags |= CL_COPY_MNT_NS;\n"
        "\tif (is_zygote_pid) {\n"
        "\t\t/* Let clone_mnt() in copy_tree() know copy_mnt_ns() is run by zygote process */\n"
        "\t\tcopy_flags |= CL_ZYGOTE_COPY_MNT_NS;\n"
        "\t}\n"
        "#endif\n"
    )
    if old not in s:
        fail("fs/namespace.c: copy_mnt_ns anchor not found")
    s = s.replace(old, new, 1)
    write("fs/namespace.c", s)
    ok("fs/namespace.c: patched copy_mnt_ns flags")
else:
    ok("fs/namespace.c: copy_mnt_ns already patched")

# fs/proc/task_mmu.c include
insert_after_literal(
    "fs/proc/task_mmu.c",
    "#include <linux/mm_inline.h>\n",
    "#ifdef CONFIG_KSU_SUSFS_SUS_KSTAT\n"
    "#include <linux/susfs_def.h>\n"
    "#endif\n",
    "susfs_def.h"
)

# fs/readdir.c filldir + filldir64
def patch_readdir_func(func):
    path = "fs/readdir.c"
    s = read(path)
    marker = f"susfs_sus_ino_for_filldir64(ino)"
    # allow two insertions, so do not skip globally
    pattern = rf"(static int {func}\s*\([^)]*\)\s*\{{.*?)(\n[ \t]*buf->error = verify_dirent_name\(name, namlen\);)"
    m = re.search(pattern, s, re.S)
    if not m:
        fail(f"{path}: function anchor not found for {func}")
    body_before = m.group(1)
    if marker in body_before[-600:]:
        ok(f"{path}: {func} already patched")
        return
    snippet = (
        "\n#ifdef CONFIG_KSU_SUSFS_SUS_PATH\n"
        "\tif (likely(current->susfs_task_state & TASK_STRUCT_NON_ROOT_USER_APP_PROC) && susfs_sus_ino_for_filldir64(ino)) {\n"
        "\t\treturn 0;\n"
        "\t}\n"
        "#endif"
    )
    s = s[:m.start(2)] + snippet + s[m.start(2):]
    write(path, s)
    ok(f"{path}: patched {func}")

patch_readdir_func("filldir")
patch_readdir_func("filldir64")

# kernel/sys.c extern + newuname call
insert_before_literal(
    "kernel/sys.c",
    "SYSCALL_DEFINE1(newuname, struct new_utsname __user *, name)",
    "#ifdef CONFIG_KSU_SUSFS_SPOOF_UNAME\n"
    "extern void susfs_spoof_uname(struct new_utsname* tmp);\n"
    "#endif\n",
    "susfs_spoof_uname"
)

s = read("kernel/sys.c")
if "susfs_spoof_uname(&tmp);" not in s:
    old = "\tmemcpy(&tmp, utsname(), sizeof(tmp));\n"
    new = old + (
        "#ifdef CONFIG_KSU_SUSFS_SPOOF_UNAME\n"
        "\tsusfs_spoof_uname(&tmp);\n"
        "#endif\n"
    )
    if old not in s:
        fail("kernel/sys.c: memcpy uname anchor not found")
    s = s.replace(old, new, 1)
    write("kernel/sys.c", s)
    ok("kernel/sys.c: patched newuname")
else:
    ok("kernel/sys.c: newuname already patched")

print("\n[DONE] SUSFS reject mini-port finished. Now inspect diff and compile.")
