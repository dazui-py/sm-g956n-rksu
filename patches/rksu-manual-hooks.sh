#!/usr/bin/env bash
set -euo pipefail

ROOT="${1:-.}"
FORCE="${FORCE:-0}"

cd "$ROOT"

die() {
    echo "[-] $*" >&2
    exit 1
}

warn() {
    echo "[!] $*" >&2
}

ok() {
    echo "[+] $*"
}

need_file() {
    [ -f "$1" ] || die "Ficheiro não encontrado: $1"
}

has_symbol() {
    local sym="$1"
    grep -Rqw --include="*.c" --include="*.h" "$sym" drivers/kernelsu 2>/dev/null
}

check_symbol() {
    local sym="$1"

    if has_symbol "$sym"; then
        ok "Símbolo encontrado: $sym"
        return 0
    fi

    if [ "$FORCE" = "1" ]; then
        warn "Símbolo não encontrado, mas FORCE=1: $sym"
        return 0
    fi

    die "Símbolo não encontrado em drivers/kernelsu: $sym"
}

echo "[*] RKSU manual hook patcher"
echo "[*] Root: $(pwd)"
echo

[ -d drivers/kernelsu ] || die "drivers/kernelsu não existe. Corre isto na raiz do kernel."

need_file drivers/input/input.c
need_file fs/exec.c
need_file fs/open.c
need_file fs/read_write.c
need_file fs/stat.c
need_file kernel/reboot.c
need_file security/selinux/hooks.c

echo "[*] A verificar símbolos RKSU..."
check_symbol ksu_handle_execveat
check_symbol ksu_handle_execveat_sucompat
check_symbol ksu_handle_faccessat
check_symbol ksu_handle_vfs_read
check_symbol ksu_handle_stat
check_symbol ksu_handle_sys_reboot
check_symbol is_ksu_transition
check_symbol ksu_execveat_hook
check_symbol ksu_vfs_read_hook

INPUT_HOOK_AVAILABLE=1
if ! has_symbol ksu_input_hook || ! has_symbol ksu_handle_input_handle_event; then
    INPUT_HOOK_AVAILABLE=0
    warn "Input hook não encontrado. Vou saltar drivers/input/input.c."
    warn "Para forçar também o input hook: FORCE=1 ./apply-rksu-manual-hooks.sh"
fi

if [ "$FORCE" = "1" ]; then
    INPUT_HOOK_AVAILABLE=1
fi

echo

python3 <<'PY'
from pathlib import Path
import sys

def fail(msg):
    print(f"[-] {msg}", file=sys.stderr)
    sys.exit(1)

def ok(msg):
    print(f"[+] {msg}")

def warn(msg):
    print(f"[!] {msg}", file=sys.stderr)

def read(path):
    p = Path(path)
    if not p.exists():
        fail(f"Ficheiro não existe: {path}")
    return p.read_text(errors="replace")

def write(path, data):
    Path(path).write_text(data)

def insert_before(path, marker, block, unique):
    data = read(path)

    if unique in data:
        ok(f"{path}: já contém {unique}, skip")
        return

    if marker not in data:
        fail(f"{path}: marker não encontrado para insert_before: {marker!r}")

    data = data.replace(marker, block + marker, 1)
    write(path, data)
    ok(f"{path}: patch aplicado")

def insert_after(path, marker, block, unique):
    data = read(path)

    if unique in data:
        ok(f"{path}: já contém {unique}, skip")
        return

    if marker not in data:
        fail(f"{path}: marker não encontrado para insert_after: {marker!r}")

    data = data.replace(marker, marker + block, 1)
    write(path, data)
    ok(f"{path}: patch aplicado")

def patch_input():
    path = "drivers/input/input.c"

    extern_block = """#ifdef CONFIG_KSU
extern bool ksu_input_hook __read_mostly;
extern int ksu_handle_input_handle_event(unsigned int *type, unsigned int *code, int *value);
#endif
"""

    hook_block = """
#ifdef CONFIG_KSU
\tif (unlikely(ksu_input_hook))
\t\tksu_handle_input_handle_event(&type, &code, &value);
#endif
"""

    insert_before(
        path,
        "static void input_handle_event(struct input_dev *dev,",
        extern_block,
        "ksu_handle_input_handle_event(unsigned int *type"
    )

    insert_before(
        path,
        "\tif (disposition != INPUT_IGNORE_EVENT && type != EV_SYN)",
        hook_block,
        "ksu_handle_input_handle_event(&type, &code, &value)"
    )

def patch_exec():
    path = "fs/exec.c"

    extern_block = """#ifdef CONFIG_KSU
extern bool ksu_execveat_hook __read_mostly;
extern int ksu_handle_execveat(int *fd, struct filename **filename_ptr, void *argv,
\t\t\tvoid *envp, int *flags);
extern int ksu_handle_execveat_sucompat(int *fd, struct filename **filename_ptr,
\t\t\t\t void *argv, void *envp, int *flags);
#endif
"""

    hook_block = """
#ifdef CONFIG_KSU
\tif (unlikely(ksu_execveat_hook))
\t\tksu_handle_execveat(&fd, &filename, &argv, &envp, &flags);
\telse
\t\tksu_handle_execveat_sucompat(&fd, &filename, &argv, &envp, &flags);
#endif

"""

    insert_before(
        path,
        "static int do_execveat_common(int fd, struct filename *filename,",
        extern_block,
        "ksu_execveat_hook __read_mostly"
    )

    insert_before(
        path,
        "\tif (IS_ERR(filename))",
        hook_block,
        "ksu_handle_execveat(&fd, &filename, &argv, &envp, &flags)"
    )

def patch_open():
    path = "fs/open.c"

    extern_block = """#ifdef CONFIG_KSU
extern int ksu_handle_faccessat(int *dfd, const char __user **filename_user, int *mode,
\t\t\t int *flags);
#endif
"""

    hook_block = """#ifdef CONFIG_KSU
\tksu_handle_faccessat(&dfd, &filename, &mode, NULL);
#endif

"""

    insert_before(
        path,
        "SYSCALL_DEFINE3(faccessat, int, dfd, const char __user *, filename, int, mode)",
        extern_block,
        "ksu_handle_faccessat(int *dfd"
    )

    insert_before(
        path,
        "\tif (mode & ~S_IRWXO)",
        hook_block,
        "ksu_handle_faccessat(&dfd, &filename, &mode, NULL)"
    )

def patch_read_write():
    path = "fs/read_write.c"

    extern_block = """#ifdef CONFIG_KSU
extern bool ksu_vfs_read_hook __read_mostly;
extern int ksu_handle_vfs_read(struct file **file_ptr, char __user **buf_ptr,
\t\t\tsize_t *count_ptr, loff_t **pos);
#endif
"""

    hook_block = """
#ifdef CONFIG_KSU
\tif (unlikely(ksu_vfs_read_hook))
\t\tksu_handle_vfs_read(&file, &buf, &count, &pos);
#endif
"""

    insert_before(
        path,
        "ssize_t vfs_read(struct file *file, char __user *buf, size_t count, loff_t *pos)",
        extern_block,
        "ksu_vfs_read_hook __read_mostly"
    )

    insert_before(
        path,
        "\tif (!(file->f_mode & FMODE_READ))",
        hook_block,
        "ksu_handle_vfs_read(&file, &buf, &count, &pos)"
    )

def patch_stat():
    path = "fs/stat.c"

    extern_block = """#ifdef CONFIG_KSU
extern int ksu_handle_stat(int *dfd, const char __user **filename_user, int *flags);
#endif
"""

    hook_block = """
#ifdef CONFIG_KSU
\tksu_handle_stat(&dfd, &filename, &flag);
#endif
"""

    insert_after(
        path,
        "EXPORT_SYMBOL(vfs_fstat);\n",
        "\n" + extern_block,
        "ksu_handle_stat(int *dfd"
    )

    insert_before(
        path,
        "\tif ((flag & ~(AT_SYMLINK_NOFOLLOW | AT_NO_AUTOMOUNT |",
        hook_block,
        "ksu_handle_stat(&dfd, &filename, &flag)"
    )

def patch_reboot():
    path = "kernel/reboot.c"

    extern_block = """#ifdef CONFIG_KSU
extern int ksu_handle_sys_reboot(int magic1, int magic2, unsigned int cmd, void __user **arg);
#endif
"""

    hook_block = """
#ifdef CONFIG_KSU
\tksu_handle_sys_reboot(magic1, magic2, cmd, &arg);
#endif

"""

    insert_before(
        path,
        "SYSCALL_DEFINE4(reboot, int, magic1, int, magic2, unsigned int, cmd,",
        extern_block,
        "ksu_handle_sys_reboot(int magic1"
    )

    insert_before(
        path,
        "\t/* We only trust the superuser with rebooting the system. */",
        hook_block,
        "ksu_handle_sys_reboot(magic1, magic2, cmd, &arg)"
    )

def patch_selinux():
    path = "security/selinux/hooks.c"

    extern_block = """#ifdef CONFIG_KSU
extern bool is_ksu_transition(const struct task_security_struct *old_tsec,
\t\t\t      const struct task_security_struct *new_tsec);
#endif
"""

    hook_block = """
#ifdef CONFIG_KSU
\tif (is_ksu_transition(old_tsec, new_tsec))
\t\treturn 0;
#endif

"""

    insert_before(
        path,
        "static int check_nnp_nosuid(const struct linux_binprm *bprm,",
        extern_block,
        "is_ksu_transition(const struct task_security_struct"
    )

    insert_after(
        path,
        "\tif (new_tsec->sid == old_tsec->sid)\n\t\treturn 0; /* No change in credentials */\n",
        hook_block,
        "is_ksu_transition(old_tsec, new_tsec)"
    )

patch_exec()
patch_open()
patch_read_write()
patch_stat()
patch_reboot()
patch_selinux()

# input.c é tratado pelo bash antes de chamar este script?
# Não. O Python não lê variáveis bash diretamente aqui.
# Então vamos usar ficheiro temporário simples.
PY

if [ "$INPUT_HOOK_AVAILABLE" = "1" ]; then
python3 <<'PY'
from pathlib import Path
import sys

def fail(msg):
    print(f"[-] {msg}", file=sys.stderr)
    sys.exit(1)

def ok(msg):
    print(f"[+] {msg}")

def read(path):
    return Path(path).read_text(errors="replace")

def write(path, data):
    Path(path).write_text(data)

def insert_before(path, marker, block, unique):
    data = read(path)

    if unique in data:
        ok(f"{path}: já contém {unique}, skip")
        return

    if marker not in data:
        fail(f"{path}: marker não encontrado: {marker!r}")

    data = data.replace(marker, block + marker, 1)
    write(path, data)
    ok(f"{path}: patch aplicado")

path = "drivers/input/input.c"

extern_block = """#ifdef CONFIG_KSU
extern bool ksu_input_hook __read_mostly;
extern int ksu_handle_input_handle_event(unsigned int *type, unsigned int *code, int *value);
#endif
"""

hook_block = """
#ifdef CONFIG_KSU
\tif (unlikely(ksu_input_hook))
\t\tksu_handle_input_handle_event(&type, &code, &value);
#endif
"""

insert_before(
    path,
    "static void input_handle_event(struct input_dev *dev,",
    extern_block,
    "ksu_handle_input_handle_event(unsigned int *type"
)

insert_before(
    path,
    "\tif (disposition != INPUT_IGNORE_EVENT && type != EV_SYN)",
    hook_block,
    "ksu_handle_input_handle_event(&type, &code, &value)"
)
PY
fi

echo
ok "Feito."
echo
echo "[*] Verifica agora:"
echo "    git diff -- drivers/input/input.c fs/exec.c fs/open.c fs/read_write.c fs/stat.c kernel/reboot.c security/selinux/hooks.c"
echo
echo "[*] Se quiseres testar se compila:"
echo "    make olddefconfig"
echo "    make -j\$(nproc)"
