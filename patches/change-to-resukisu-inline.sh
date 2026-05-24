#!/usr/bin/env bash
set -euo pipefail

# change-to-resukisu-inline.sh
#
# Converts an already-patched kernel tree from old KernelSU manual hooks
# to ReSukiSU/SUSFS inline-hook mode by removing incompatible manual hook
# glue from kernel source files.
#
# Run this AFTER applying your KSU/SUSFS patches and BEFORE build_kernel.sh.
#
# Usage:
#   ./change-to-resukisu-inline.sh [kernel_root]
#   ./change-to-resukisu-inline.sh [kernel_root] --disable-bad-patches
#
# Notes:
#   - This does NOT remove SUSFS code.
#   - This only removes old manual ksu_*_hook / ksu_handle_* glue.
#   - Backups are saved under .inline-hook-backup/<timestamp>/.

ROOT="."
DISABLE_BAD_PATCHES=0

for arg in "$@"; do
    case "$arg" in
        --disable-bad-patches)
            DISABLE_BAD_PATCHES=1
            ;;
        -h|--help)
            sed -n '1,35p' "$0"
            exit 0
            ;;
        *)
            ROOT="$arg"
            ;;
    esac
done

cd "$ROOT"

fail() {
    echo "[-] $*" >&2
    exit 1
}

ok() {
    echo "[+] $*"
}

warn() {
    echo "[!] $*" >&2
}

[ -f Makefile ] || fail "Isto não parece a raiz do kernel: falta Makefile"
command -v python3 >/dev/null 2>&1 || fail "python3 não encontrado"

TS="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR=".inline-hook-backup/$TS"
mkdir -p "$BACKUP_DIR"

BAD_EGREP='CONFIG_KSU_MANUAL_HOOK|ksu_(input|vfs_read|execveat|faccessat|stat|sys_reboot|prctl|sucompat).*hook|ksu_handle_(input_handle_event|vfs_read|execveat|execveat_sucompat|faccessat|stat|sys_reboot|prctl|setuid|setgid|setresuid|setresgid|setreuid|setregid)'

SOURCE_FILES=(
    drivers/input/input.c
    fs/read_write.c
    fs/exec.c
    fs/open.c
    fs/stat.c
    kernel/reboot.c
    kernel/sys.c
    security/selinux/hooks.c
)

ok "Modo alvo: ReSukiSU/SUSFS Inline hook"
warn "Vou remover só glue manual incompatível. SUSFS fica intacto."

# Backup only existing source files.
for f in "${SOURCE_FILES[@]}"; do
    if [ -f "$f" ]; then
        mkdir -p "$BACKUP_DIR/$(dirname "$f")"
        cp -a "$f" "$BACKUP_DIR/$f"
    fi
done
ok "Backup dos ficheiros existentes salvo em: $BACKUP_DIR"

python3 <<'PY'
from pathlib import Path
import re
import sys

BAD_TOKENS = [
    "CONFIG_KSU_MANUAL_HOOK",
    "ksu_input_hook",
    "ksu_vfs_read_hook",
    "ksu_execveat_hook",
    "ksu_faccessat_hook",
    "ksu_stat_hook",
    "ksu_sys_reboot_hook",
    "ksu_prctl_hook",
    "ksu_sucompat_hook",
    "ksu_handle_input_handle_event",
    "ksu_handle_vfs_read",
    "ksu_handle_execveat",
    "ksu_handle_execveat_sucompat",
    "ksu_handle_faccessat",
    "ksu_handle_stat",
    "ksu_handle_sys_reboot",
    "ksu_handle_prctl",
    "ksu_handle_setuid",
    "ksu_handle_setgid",
    "ksu_handle_setresuid",
    "ksu_handle_setresgid",
    "ksu_handle_setreuid",
    "ksu_handle_setregid",
]

FILES = [
    "drivers/input/input.c",
    "fs/read_write.c",
    "fs/exec.c",
    "fs/open.c",
    "fs/stat.c",
    "kernel/reboot.c",
    "kernel/sys.c",
    "security/selinux/hooks.c",
]

IF_RE = re.compile(r"^\s*#\s*(if|ifdef|ifndef)\b")
ENDIF_RE = re.compile(r"^\s*#\s*endif\b")


def has_bad(text: str) -> bool:
    return any(tok in text for tok in BAD_TOKENS)


def collect_if_block(lines, i):
    block = []
    depth = 0
    j = i
    while j < len(lines):
        line = lines[j]
        if IF_RE.match(line):
            depth += 1
        if depth > 0:
            block.append(line)
        if ENDIF_RE.match(line):
            depth -= 1
            if depth == 0:
                return block, j
        j += 1
    return [lines[i]], i


def skip_bad_statement(lines, i):
    """Skip a standalone extern/call/if statement containing a bad token."""
    line = lines[i]
    stripped = line.strip()

    # extern declarations may span multiple lines until semicolon.
    if "extern" in stripped:
        j = i
        while j < len(lines):
            if ";" in lines[j]:
                return j + 1
            j += 1
        return j

    # if (bad_hook) { ... }
    if stripped.startswith("if") or stripped.startswith("else if"):
        # Multiline condition/body without braces: skip until first semicolon.
        if "{" not in line:
            j = i
            while j < len(lines):
                if ";" in lines[j]:
                    return j + 1
                if "{" in lines[j]:
                    break
                j += 1
            if j >= len(lines):
                return j
            # falls through to brace skip when the brace appears later
            i = j
            line = lines[i]

        depth = 0
        j = i
        started = False
        while j < len(lines):
            depth += lines[j].count("{")
            depth -= lines[j].count("}")
            if "{" in lines[j]:
                started = True
            if started and depth <= 0:
                return j + 1
            j += 1
        return j

    # Plain function call or assignment line.
    j = i
    while j < len(lines):
        if ";" in lines[j]:
            return j + 1
        j += 1
    return j


def clean_lines(lines):
    removed_blocks = 0
    removed_statements = 0

    # First pass: remove complete preprocessor blocks that contain bad tokens.
    out = []
    i = 0
    while i < len(lines):
        if IF_RE.match(lines[i]):
            block, end = collect_if_block(lines, i)
            text = "\n".join(block)
            if has_bad(text):
                removed_blocks += 1
                i = end + 1
                continue
        out.append(lines[i])
        i += 1

    lines = out

    # Second pass: remove loose externs/calls that were not inside #ifdef blocks.
    out = []
    i = 0
    while i < len(lines):
        if has_bad(lines[i]):
            # Remove preceding GCC attribute if it only decorated the bad extern.
            if out and "__attribute__((hot))" in out[-1]:
                out.pop()
            new_i = skip_bad_statement(lines, i)
            removed_statements += max(1, new_i - i)
            i = new_i
            continue
        out.append(lines[i])
        i += 1

    # Third pass: remove empty leftover KSU manual preprocessor shells.
    cleaned = "\n".join(out) + "\n"
    cleaned = re.sub(
        r"\n\s*#\s*ifdef\s+CONFIG_KSU(?:_MANUAL_HOOK)?\s*\n\s*#\s*endif\s*/?.*?\n",
        "\n",
        cleaned,
        flags=re.S,
    )

    return cleaned.splitlines(), removed_blocks, removed_statements


total_blocks = 0
total_statements = 0
changed_files = []

for rel in FILES:
    p = Path(rel)
    if not p.exists():
        print(f"[!] {rel}: não existe, skip", file=sys.stderr)
        continue

    old = p.read_text(errors="replace")
    lines = old.splitlines()
    new_lines, blocks, statements = clean_lines(lines)
    new = "\n".join(new_lines) + "\n"

    if new != old:
        p.write_text(new)
        changed_files.append(rel)
        print(f"[+] {rel}: removidos {blocks} blocos #if e {statements} linhas/declarações soltas")
    else:
        print(f"[+] {rel}: nada a mudar")

    total_blocks += blocks
    total_statements += statements

print(f"[+] Total: {total_blocks} blocos #if removidos, {total_statements} linhas/declarações removidas")
if changed_files:
    print("[+] Ficheiros alterados:")
    for f in changed_files:
        print(f"    {f}")
PY

# Verify source tree only. Do not scan KernelSU itself, because handlers can legitimately exist there.
echo
echo "[*] Verificação nos ficheiros fonte principais..."
VERIFY_FILES=()
for f in "${SOURCE_FILES[@]}"; do
    [ -f "$f" ] && VERIFY_FILES+=("$f")
done

if [ "${#VERIFY_FILES[@]}" -gt 0 ] && grep -RsnE "$BAD_EGREP" "${VERIFY_FILES[@]}"; then
    fail "Ainda existem hooks manuais incompatíveis nos ficheiros acima. Remove manualmente esses restos."
else
    ok "Nenhum hook manual incompatível ficou nos ficheiros fonte principais."
fi

# Optional: disable old patch files that would reintroduce bad manual hooks.
if [ -d patches ]; then
    echo
    echo "[*] A procurar patches que ainda contêm hooks manuais antigos..."
    mapfile -t BAD_PATCHES < <(
        find patches -type f \( -name '*.patch' -o -name '*.diff' -o -name '*.txt' -o -name '*.rej' \) \
            ! -path '*/_disabled_inline_hooks/*' \
            ! -name '999-resukisu-inline-cleanup.patch' \
            -print0 | xargs -0 -r grep -lE "$BAD_EGREP" | sort
    )

    if [ "${#BAD_PATCHES[@]}" -eq 0 ]; then
        ok "Nenhum patch ativo suspeito encontrado."
    else
        warn "Patches suspeitos encontrados:"
        printf '    %s\n' "${BAD_PATCHES[@]}"

        if [ "$DISABLE_BAD_PATCHES" -eq 1 ]; then
            DISABLED_DIR="patches/_disabled_inline_hooks/$TS"
            mkdir -p "$DISABLED_DIR"
            for p in "${BAD_PATCHES[@]}"; do
                mkdir -p "$DISABLED_DIR/$(dirname "$p")"
                mv "$p" "$DISABLED_DIR/$p"
            done
            ok "Patches suspeitos movidos para: $DISABLED_DIR"
        else
            warn "Não movi patches. Se o workflow aplicar esses patches DEPOIS deste script, o erro volta."
            warn "Para desativá-los automaticamente, usa: ./change-to-resukisu-inline.sh . --disable-bad-patches"
        fi
    fi
fi

# Generate cleanup patch for CI reuse when repository is git.
if command -v git >/dev/null 2>&1 && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    mkdir -p patches
    CLEANUP_PATCH="patches/999-resukisu-inline-cleanup.patch"
    git diff -- "${SOURCE_FILES[@]}" > "$CLEANUP_PATCH" || true
    if [ -s "$CLEANUP_PATCH" ]; then
        ok "Patch de limpeza gerado: $CLEANUP_PATCH"
    else
        rm -f "$CLEANUP_PATCH"
        ok "Sem diff de limpeza para gerar."
    fi
fi

echo
echo "[*] Check rápido de conflitos e whitespace:"
find . -name '*.rej' -print | sort || true
git diff --check || true
grep -RsnE '^<<<<<<< |^=======$|^>>>>>>> ' -- . ':!KernelSU' ':!.git' ':!.inline-hook-backup' 2>/dev/null || true

echo
echo "[OK] Conversão para ReSukiSU/SUSFS inline feita. Agora compila:"
echo "    ./build_kernel.sh 2>&1 | tee build.log"
echo "Depois confirma se o checker já não acusa ksu_*_hook incompatível."
