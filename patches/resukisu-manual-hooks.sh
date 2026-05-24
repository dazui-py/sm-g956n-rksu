#!/usr/bin/env bash
set -euo pipefail

# apply_resukisu_manual_hooks_menu.sh
# Idempotent ReSukiSU / KernelSU manual hook applier with CLI + interactive menu.
#
# Examples:
#   ./apply_resukisu_manual_hooks_menu.sh --interactive
#   ./apply_resukisu_manual_hooks_menu.sh --root . --kernel-version 4.14
#   ./apply_resukisu_manual_hooks_menu.sh . --profile 4.19-6.7 --disable exports,input
#   ./apply_resukisu_manual_hooks_menu.sh . --dry-run --list-options

ROOT="."
INTERACTIVE=0
PROFILE="auto"
KERNEL_VERSION=""
NO_BACKUP="${NO_BACKUP:-0}"
DRY_RUN="${DRY_RUN:-0}"

EXEC_STYLE="auto"       # auto | execveat | execve
REBOOT_STYLE="auto"     # auto | reboot.c | sys.c
SETUID_STYLE="auto"     # auto | __sys_setresuid | setresuid
FACCESS_STYLE="auto"    # auto | new | old
READ_STYLE="auto"       # auto | ksys_read | inline_read

EXEC_STYLE_EXPLICIT=0
REBOOT_STYLE_EXPLICIT=0
SETUID_STYLE_EXPLICIT=0
FACCESS_STYLE_EXPLICIT=0
READ_STYLE_EXPLICIT=0
PROFILE_EXPLICIT=0

VALID_HOOKS=(stat exec faccessat reboot input setuid read exports)
declare -A HOOK_ENABLED
for h in "${VALID_HOOKS[@]}"; do HOOK_ENABLED["$h"]=1; done

usage() {
  cat <<'EOF'
Usage:
  ./apply_resukisu_manual_hooks_menu.sh [kernel-root] [options]

Main options:
  -r, --root DIR                 Kernel source root. Default: .
  -i, --interactive              Open menu mode.
  --kernel-version X.Y           Derive valid hook styles from kernel version, e.g. 3.10, 3.18, 4.14, 4.19, 5.10, 6.1, 6.8.
  --profile PROFILE              Use a version bucket. Run --list-options to see valid values.
  --dry-run                      Show what would change, but do not write files.
  --no-backup                    Do not create .bak.ksu-hooks.* backups.

Hook selection:
  --only LIST                    Enable only comma-separated hooks.
  --enable LIST                  Enable comma-separated hooks.
  --disable LIST                 Disable comma-separated hooks.

  Valid hooks:
    stat, exec, faccessat, reboot, input, setuid, read, exports

Manual style overrides:
  --exec-style STYLE             auto | execveat | execve
  --reboot-style STYLE           auto | reboot.c | sys.c
  --setuid-style STYLE           auto | __sys_setresuid | setresuid
  --faccess-style STYLE          auto | new | old
  --read-style STYLE             auto | ksys_read | inline_read

Info:
  -h, --help                     Show this help.
  --list-options                 Show profiles, valid styles, and what they mean.

Environment alternatives:
  NO_BACKUP=1 ./apply_resukisu_manual_hooks_menu.sh .
  DRY_RUN=1   ./apply_resukisu_manual_hooks_menu.sh .
EOF
}

list_options() {
  cat <<'EOF'
Valid profiles:
  auto          Detect from source code. Safest default when you do not know.
  pre-3.11      reboot syscall is usually in kernel/sys.c; old execve path.
  3.11-3.13     reboot in kernel/reboot.c; old execve path.
  3.14-4.16     execveat-style do_execve; old setresuid/read/faccess style.
  4.17-4.18     __sys_setresuid exists; read/faccess still old-style on many trees.
  4.19-6.7      modern faccess/read wrappers; execveat; reboot.c; __sys_setresuid.
  6.8+          same source placement as modern kernels; setuid/read hooks may matter more depending on ReSukiSU config.

Kernel-version examples:
  --kernel-version 3.10  => profile pre-3.11
  --kernel-version 3.18  => profile 3.14-4.16
  --kernel-version 4.14  => profile 3.14-4.16
  --kernel-version 4.17  => profile 4.17-4.18
  --kernel-version 4.19  => profile 4.19-6.7
  --kernel-version 5.10  => profile 4.19-6.7
  --kernel-version 6.1   => profile 4.19-6.7
  --kernel-version 6.8   => profile 6.8+

Valid style values:
  --exec-style:
    auto        Detect do_execve form from fs/exec.c.
    execveat    Use ksu_handle_execveat, for 3.14+ style trees.
    execve      Use ksu_handle_execve, for pre-3.14 style trees.

  --reboot-style:
    auto        Prefer kernel/reboot.c if it contains SYSCALL_DEFINE4(reboot), else kernel/sys.c.
    reboot.c    Force kernel/reboot.c.
    sys.c       Force kernel/sys.c.

  --setuid-style:
    auto              Detect __sys_setresuid if present, else setresuid syscall.
    __sys_setresuid   Force 4.17+ style.
    setresuid         Force pre-4.17 style.

  --faccess-style:
    auto        Detect by source anchors. The inserted hook call is equivalent for both styles.
    new         4.19+ documentation style.
    old         pre-4.19 documentation style.

  --read-style:
    auto        Detect by source anchors.
    ksys_read   4.19+ documentation style.
    inline_read pre-4.19 documentation style.

Hook list values:
  stat, exec, faccessat, reboot, input, setuid, read, exports

Examples:
  ./apply_resukisu_manual_hooks_menu.sh --interactive
  ./apply_resukisu_manual_hooks_menu.sh . --kernel-version 4.14
  ./apply_resukisu_manual_hooks_menu.sh . --profile 4.19-6.7 --disable input,exports
  ./apply_resukisu_manual_hooks_menu.sh . --only stat,exec,faccessat,reboot,setuid,read
EOF
}

die() { echo "[ERR] $*" >&2; exit 2; }

is_valid_hook() {
  local needle="$1"
  for h in "${VALID_HOOKS[@]}"; do [[ "$h" == "$needle" ]] && return 0; done
  return 1
}

set_hooks_csv() {
  local csv="$1" value="$2" item
  [[ -n "$csv" ]] || die "empty hook list"
  IFS=',' read -r -a items <<< "$csv"
  for item in "${items[@]}"; do
    item="${item//[[:space:]]/}"
    [[ -n "$item" ]] || continue
    if [[ "$item" == "all" ]]; then
      for h in "${VALID_HOOKS[@]}"; do HOOK_ENABLED["$h"]="$value"; done
      continue
    fi
    is_valid_hook "$item" || die "invalid hook: $item. Run --list-options."
    HOOK_ENABLED["$item"]="$value"
  done
}

only_hooks_csv() {
  local csv="$1"
  for h in "${VALID_HOOKS[@]}"; do HOOK_ENABLED["$h"]=0; done
  set_hooks_csv "$csv" 1
}

validate_choice() {
  local name="$1" value="$2" valid="$3"
  case " $valid " in
    *" $value "*) ;;
    *) die "invalid $name: $value. Valid: $valid" ;;
  esac
}

profile_from_version() {
  local ver="$1" major minor rest
  [[ "$ver" =~ ^[0-9]+\.[0-9]+ ]] || die "invalid kernel version: $ver. Use X.Y, e.g. 4.14 or 5.10."
  major="${ver%%.*}"
  rest="${ver#*.}"
  minor="${rest%%[^0-9]*}"

  if (( major < 3 || (major == 3 && minor <= 10) )); then
    echo "pre-3.11"
  elif (( major == 3 && minor <= 13 )); then
    echo "3.11-3.13"
  elif (( major < 4 || (major == 4 && minor <= 16) )); then
    echo "3.14-4.16"
  elif (( major == 4 && minor <= 18 )); then
    echo "4.17-4.18"
  elif (( major < 6 || (major == 6 && minor <= 7) )); then
    echo "4.19-6.7"
  else
    echo "6.8+"
  fi
}

apply_profile_defaults() {
  local p="$1"
  validate_choice "profile" "$p" "auto pre-3.11 3.11-3.13 3.14-4.16 4.17-4.18 4.19-6.7 6.8+"
  [[ "$p" == "auto" ]] && return 0

  case "$p" in
    pre-3.11)
      (( EXEC_STYLE_EXPLICIT == 0 )) && EXEC_STYLE="execve"
      (( REBOOT_STYLE_EXPLICIT == 0 )) && REBOOT_STYLE="sys.c"
      (( SETUID_STYLE_EXPLICIT == 0 )) && SETUID_STYLE="setresuid"
      (( FACCESS_STYLE_EXPLICIT == 0 )) && FACCESS_STYLE="old"
      (( READ_STYLE_EXPLICIT == 0 )) && READ_STYLE="inline_read"
      ;;
    3.11-3.13)
      (( EXEC_STYLE_EXPLICIT == 0 )) && EXEC_STYLE="execve"
      (( REBOOT_STYLE_EXPLICIT == 0 )) && REBOOT_STYLE="reboot.c"
      (( SETUID_STYLE_EXPLICIT == 0 )) && SETUID_STYLE="setresuid"
      (( FACCESS_STYLE_EXPLICIT == 0 )) && FACCESS_STYLE="old"
      (( READ_STYLE_EXPLICIT == 0 )) && READ_STYLE="inline_read"
      ;;
    3.14-4.16)
      (( EXEC_STYLE_EXPLICIT == 0 )) && EXEC_STYLE="execveat"
      (( REBOOT_STYLE_EXPLICIT == 0 )) && REBOOT_STYLE="reboot.c"
      (( SETUID_STYLE_EXPLICIT == 0 )) && SETUID_STYLE="setresuid"
      (( FACCESS_STYLE_EXPLICIT == 0 )) && FACCESS_STYLE="old"
      (( READ_STYLE_EXPLICIT == 0 )) && READ_STYLE="inline_read"
      ;;
    4.17-4.18)
      (( EXEC_STYLE_EXPLICIT == 0 )) && EXEC_STYLE="execveat"
      (( REBOOT_STYLE_EXPLICIT == 0 )) && REBOOT_STYLE="reboot.c"
      (( SETUID_STYLE_EXPLICIT == 0 )) && SETUID_STYLE="__sys_setresuid"
      (( FACCESS_STYLE_EXPLICIT == 0 )) && FACCESS_STYLE="old"
      (( READ_STYLE_EXPLICIT == 0 )) && READ_STYLE="inline_read"
      ;;
    4.19-6.7|6.8+)
      (( EXEC_STYLE_EXPLICIT == 0 )) && EXEC_STYLE="execveat"
      (( REBOOT_STYLE_EXPLICIT == 0 )) && REBOOT_STYLE="reboot.c"
      (( SETUID_STYLE_EXPLICIT == 0 )) && SETUID_STYLE="__sys_setresuid"
      (( FACCESS_STYLE_EXPLICIT == 0 )) && FACCESS_STYLE="new"
      (( READ_STYLE_EXPLICIT == 0 )) && READ_STYLE="ksys_read"
      ;;
  esac
}

ask() {
  local prompt="$1" default="$2" answer
  if [[ -n "$default" ]]; then
    read -r -p "$prompt [$default]: " answer || true
    echo "${answer:-$default}"
  else
    read -r -p "$prompt: " answer || true
    echo "$answer"
  fi
}

ask_yes_no() {
  local prompt="$1" default="$2" answer d
  d="$default"
  while true; do
    answer="$(ask "$prompt (y/n)" "$d")"
    case "${answer,,}" in
      y|yes|s|sim) return 0 ;;
      n|no|nao|não) return 1 ;;
      *) echo "Resposta inválida. Usa y/n." >&2 ;;
    esac
  done
}

interactive_menu() {
  echo "== ReSukiSU manual hooks menu =="
  ROOT="$(ask "Kernel root" "$ROOT")"
  echo
  echo "Perfil de versão:"
  echo "  1) auto"
  echo "  2) pre-3.11"
  echo "  3) 3.11-3.13"
  echo "  4) 3.14-4.16"
  echo "  5) 4.17-4.18"
  echo "  6) 4.19-6.7"
  echo "  7) 6.8+"
  echo "  8) escrever versão do kernel, tipo 4.14 / 5.10 / 6.1"
  local choice
  choice="$(ask "Escolha" "1")"
  case "$choice" in
    1|auto|"") PROFILE="auto" ;;
    2|pre-3.11) PROFILE="pre-3.11" ;;
    3|3.11-3.13) PROFILE="3.11-3.13" ;;
    4|3.14-4.16) PROFILE="3.14-4.16" ;;
    5|4.17-4.18) PROFILE="4.17-4.18" ;;
    6|4.19-6.7) PROFILE="4.19-6.7" ;;
    7|6.8+) PROFILE="6.8+" ;;
    8)
      KERNEL_VERSION="$(ask "Versão do kernel X.Y" "4.14")"
      PROFILE="$(profile_from_version "$KERNEL_VERSION")"
      echo "Perfil calculado: $PROFILE"
      ;;
    [0-9]*.[0-9]*)
      KERNEL_VERSION="$choice"
      PROFILE="$(profile_from_version "$KERNEL_VERSION")"
      echo "Perfil calculado: $PROFILE"
      ;;
    *) die "escolha inválida: $choice. Usa 1-8, um profile válido, ou uma versão tipo 4.9." ;;
  esac

  echo
  if ask_yes_no "Aplicar hook input_event? Normalmente é opcional se AUTO_INPUT_HOOK funcionar" "y"; then
    HOOK_ENABLED[input]=1
  else
    HOOK_ENABLED[input]=0
  fi

  if ask_yes_no "Aplicar exports opcionais SELinux? policy_rwlock/selinux_ops/sel_mutex" "y"; then
    HOOK_ENABLED[exports]=1
  else
    HOOK_ENABLED[exports]=0
  fi

  if ask_yes_no "Criar backups .bak antes de editar?" "y"; then
    NO_BACKUP=0
  else
    NO_BACKUP=1
  fi

  if ask_yes_no "Dry-run sem escrever ficheiros?" "n"; then
    DRY_RUN=1
  else
    DRY_RUN=0
  fi
}

POSITIONAL_ROOT_SET=0
while (($#)); do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --list-options) list_options; exit 0 ;;
    -i|--interactive) INTERACTIVE=1; shift ;;
    -r|--root) [[ $# -ge 2 ]] || die "--root needs DIR"; ROOT="$2"; shift 2 ;;
    --kernel-version) [[ $# -ge 2 ]] || die "--kernel-version needs X.Y"; KERNEL_VERSION="$2"; PROFILE="$(profile_from_version "$2")"; shift 2 ;;
    --profile) [[ $# -ge 2 ]] || die "--profile needs value"; PROFILE="$2"; PROFILE_EXPLICIT=1; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --no-backup) NO_BACKUP=1; shift ;;
    --only) [[ $# -ge 2 ]] || die "--only needs LIST"; only_hooks_csv "$2"; shift 2 ;;
    --enable) [[ $# -ge 2 ]] || die "--enable needs LIST"; set_hooks_csv "$2" 1; shift 2 ;;
    --disable) [[ $# -ge 2 ]] || die "--disable needs LIST"; set_hooks_csv "$2" 0; shift 2 ;;
    --exec-style) [[ $# -ge 2 ]] || die "--exec-style needs STYLE"; EXEC_STYLE="$2"; EXEC_STYLE_EXPLICIT=1; shift 2 ;;
    --reboot-style) [[ $# -ge 2 ]] || die "--reboot-style needs STYLE"; REBOOT_STYLE="$2"; REBOOT_STYLE_EXPLICIT=1; shift 2 ;;
    --setuid-style) [[ $# -ge 2 ]] || die "--setuid-style needs STYLE"; SETUID_STYLE="$2"; SETUID_STYLE_EXPLICIT=1; shift 2 ;;
    --faccess-style) [[ $# -ge 2 ]] || die "--faccess-style needs STYLE"; FACCESS_STYLE="$2"; FACCESS_STYLE_EXPLICIT=1; shift 2 ;;
    --read-style) [[ $# -ge 2 ]] || die "--read-style needs STYLE"; READ_STYLE="$2"; READ_STYLE_EXPLICIT=1; shift 2 ;;
    --) shift; break ;;
    -*) die "unknown option: $1" ;;
    *)
      if (( POSITIONAL_ROOT_SET == 0 )); then
        ROOT="$1"; POSITIONAL_ROOT_SET=1; shift
      else
        die "unexpected positional argument: $1"
      fi
      ;;
  esac
done

if (( INTERACTIVE == 1 )); then
  interactive_menu
fi

apply_profile_defaults "$PROFILE"

validate_choice "exec-style" "$EXEC_STYLE" "auto execveat execve"
validate_choice "reboot-style" "$REBOOT_STYLE" "auto reboot.c sys.c"
validate_choice "setuid-style" "$SETUID_STYLE" "auto __sys_setresuid setresuid"
validate_choice "faccess-style" "$FACCESS_STYLE" "auto new old"
validate_choice "read-style" "$READ_STYLE" "auto ksys_read inline_read"

[[ -d "$ROOT" ]] || die "Kernel root not found: $ROOT"
cd "$ROOT"

HOOKS_CSV=""
for h in "${VALID_HOOKS[@]}"; do
  if [[ "${HOOK_ENABLED[$h]}" == "1" ]]; then
    if [[ -z "$HOOKS_CSV" ]]; then HOOKS_CSV="$h"; else HOOKS_CSV+=",$h"; fi
  fi
done

export NO_BACKUP DRY_RUN PROFILE KERNEL_VERSION
export KSU_HOOKS="$HOOKS_CSV"
export KSU_EXEC_STYLE="$EXEC_STYLE"
export KSU_REBOOT_STYLE="$REBOOT_STYLE"
export KSU_SETUID_STYLE="$SETUID_STYLE"
export KSU_FACCESS_STYLE="$FACCESS_STYLE"
export KSU_READ_STYLE="$READ_STYLE"

printf '[INFO] root=%s\n' "$(pwd)"
printf '[INFO] profile=%s kernel_version=%s\n' "$PROFILE" "${KERNEL_VERSION:-n/a}"
printf '[INFO] styles: exec=%s reboot=%s setuid=%s faccess=%s read=%s\n' "$EXEC_STYLE" "$REBOOT_STYLE" "$SETUID_STYLE" "$FACCESS_STYLE" "$READ_STYLE"
printf '[INFO] enabled hooks=%s\n' "${HOOKS_CSV:-none}"
printf '[INFO] backup=%s dry_run=%s\n' "$([[ "$NO_BACKUP" == 1 ]] && echo no || echo yes)" "$([[ "$DRY_RUN" == 1 ]] && echo yes || echo no)"

python3 <<'PY'
from __future__ import annotations

import os
import re
import sys
import time
from pathlib import Path

TS = time.strftime("%Y%m%d-%H%M%S")
NO_BACKUP = os.environ.get("NO_BACKUP") == "1"
DRY_RUN = os.environ.get("DRY_RUN") == "1"
PROFILE = os.environ.get("PROFILE", "auto")
KERNEL_VERSION = os.environ.get("KERNEL_VERSION", "")
HOOKS = {x.strip() for x in os.environ.get("KSU_HOOKS", "stat,exec,faccessat,reboot,input,setuid,read,exports").split(",") if x.strip()}
EXEC_STYLE = os.environ.get("KSU_EXEC_STYLE", "auto")
REBOOT_STYLE = os.environ.get("KSU_REBOOT_STYLE", "auto")
SETUID_STYLE = os.environ.get("KSU_SETUID_STYLE", "auto")
FACCESS_STYLE = os.environ.get("KSU_FACCESS_STYLE", "auto")
READ_STYLE = os.environ.get("KSU_READ_STYLE", "auto")

changed_files: set[Path] = set()
changed_actions: list[str] = []
skipped_actions: list[str] = []
missing_actions: list[str] = []
warn_actions: list[str] = []


def log_changed(msg: str) -> None:
    changed_actions.append(msg)


def log_skip(msg: str) -> None:
    skipped_actions.append(msg)


def log_missing(msg: str) -> None:
    missing_actions.append(msg)


def log_warn(msg: str) -> None:
    warn_actions.append(msg)


def exists(path: str) -> bool:
    return Path(path).is_file()


def read(path: str, quiet: bool = False) -> str | None:
    p = Path(path)
    if not p.is_file():
        if not quiet:
            log_missing(f"missing file: {path}")
        return None
    return p.read_text(errors="surrogateescape")


def write_if_changed(path: str, old: str, new: str) -> None:
    if old == new:
        return
    p = Path(path)
    changed_files.add(p)
    if DRY_RUN:
        return
    if not NO_BACKUP:
        bak = p.with_name(p.name + f".bak.ksu-hooks.{TS}")
        if not bak.exists():
            bak.write_text(old, errors="surrogateescape")
    p.write_text(new, errors="surrogateescape")


def replace_once(text: str, old: str, new: str) -> tuple[str, bool]:
    if old not in text:
        return text, False
    return text.replace(old, new, 1), True


def re_replace_once(text: str, pattern: str, repl: str, flags: int = 0) -> tuple[str, bool]:
    new, n = re.subn(pattern, repl, text, count=1, flags=flags)
    return new, n > 0


def find_func_span(text: str, sig_pattern: str) -> tuple[int, int, int] | None:
    m = re.search(sig_pattern, text, re.M | re.S)
    if not m:
        return None
    brace = text.find("{", m.end())
    if brace < 0:
        return None
    depth = 0
    i = brace
    n = len(text)
    in_sl = False
    in_ml = False
    in_str: str | None = None
    esc = False
    while i < n:
        c = text[i]
        nxt = text[i + 1] if i + 1 < n else ""
        if in_sl:
            if c == "\n":
                in_sl = False
        elif in_ml:
            if c == "*" and nxt == "/":
                in_ml = False
                i += 1
        elif in_str:
            if esc:
                esc = False
            elif c == "\\":
                esc = True
            elif c == in_str:
                in_str = None
        else:
            if c == "/" and nxt == "/":
                in_sl = True
                i += 1
            elif c == "/" and nxt == "*":
                in_ml = True
                i += 1
            elif c in ('"', "'"):
                in_str = c
            elif c == "{":
                depth += 1
            elif c == "}":
                depth -= 1
                if depth == 0:
                    return (m.start(), brace, i)
        i += 1
    return None


def body_contains(text: str, span: tuple[int, int, int] | None, needle: str) -> bool:
    if not span:
        return False
    _, open_b, close_b = span
    return needle in text[open_b:close_b]


def insert_before_index(text: str, idx: int, block: str) -> str:
    if idx > 0 and text[idx - 1] != "\n":
        block = "\n" + block
    if not block.endswith("\n"):
        block += "\n"
    return text[:idx] + block + text[idx:]


def insert_after_line_containing(text: str, start: int, end: int, pattern: str, block: str) -> tuple[str, bool]:
    sub = text[start:end]
    m = re.search(pattern, sub, re.M)
    if not m:
        return text, False
    line_end = sub.find("\n", m.end())
    if line_end < 0:
        line_end = len(sub)
    idx = start + line_end + 1
    if not block.endswith("\n"):
        block += "\n"
    return text[:idx] + block + text[idx:], True


def insert_after_open_brace(text: str, span: tuple[int, int, int], block: str) -> str:
    _, open_b, _ = span
    idx = open_b + 1
    if idx < len(text) and text[idx] == "\n":
        idx += 1
    if not block.endswith("\n"):
        block += "\n"
    return text[:idx] + block + text[idx:]


def insert_before_return(text: str, span: tuple[int, int, int], return_regex: str, block: str) -> tuple[str, bool]:
    _, open_b, close_b = span
    sub = text[open_b:close_b]
    matches = list(re.finditer(return_regex, sub, re.M))
    if not matches:
        return text, False
    m = matches[-1]
    idx = open_b + m.start()
    if not block.endswith("\n"):
        block += "\n"
    return text[:idx] + block + text[idx:], True


def has_extern_for(text: str, symbol: str) -> bool:
    return re.search(r"\bextern\b[\s\S]{0,300}\b" + re.escape(symbol) + r"\b", text) is not None


def insert_prototype_before(text: str, marker_regex: str, block: str, hook_symbol: str) -> tuple[str, bool]:
    if has_extern_for(text, hook_symbol):
        return text, False
    m = re.search(marker_regex, text, re.M | re.S)
    if not m:
        return text, False
    return insert_before_index(text, m.start(), block + "\n"), True


def add_call_after_decl(path: str, text: str, sig: str, hook_symbol: str, decl_regex: str, block: str, desc: str) -> str:
    span = find_func_span(text, sig)
    if not span:
        log_missing(f"{path}: function not found for {desc}")
        return text
    if body_contains(text, span, hook_symbol):
        log_skip(f"{path}: {desc} already present")
        return text
    _, open_b, close_b = span
    new, ok = insert_after_line_containing(text, open_b, close_b, decl_regex, block)
    if ok:
        log_changed(f"{path}: added {desc}")
        return new
    log_warn(f"{path}: declaration anchor not found for {desc}; inserted after opening brace")
    log_changed(f"{path}: added {desc}")
    return insert_after_open_brace(text, span, block)


def add_call_before_return(path: str, text: str, sig: str, hook_symbol: str, return_regex: str, block: str, desc: str) -> str:
    span = find_func_span(text, sig)
    if not span:
        log_missing(f"{path}: function not found for {desc}")
        return text
    if body_contains(text, span, hook_symbol):
        log_skip(f"{path}: {desc} already present")
        return text
    new, ok = insert_before_return(text, span, return_regex, block)
    if not ok:
        log_missing(f"{path}: return anchor not found for {desc}")
        return text
    log_changed(f"{path}: added {desc}")
    return new


def apply_stat() -> None:
    path = "fs/stat.c"
    old = read(path)
    if old is None:
        return
    text = old

    proto = """#ifdef CONFIG_KSU_MANUAL_HOOK
__attribute__((hot))
extern int ksu_handle_stat(int *dfd, const char __user **filename_user,
				int *flags);
extern void ksu_handle_newfstat_ret(unsigned int *fd, struct stat __user **statbuf_ptr);
#if defined(__ARCH_WANT_STAT64) || defined(__ARCH_WANT_COMPAT_STAT64)
extern void ksu_handle_fstat64_ret(unsigned long *fd, struct stat64 __user **statbuf_ptr);
#endif
#endif
"""
    text2, ok = insert_prototype_before(
        text,
        r"#if\s+!defined\(__ARCH_WANT_STAT64\)|SYSCALL_DEFINE4\s*\(\s*newfstatat\b",
        proto,
        "ksu_handle_stat",
    )
    if ok:
        log_changed(f"{path}: added stat extern prototypes")
        text = text2
    elif "ksu_handle_stat" in text:
        log_skip(f"{path}: stat extern prototypes already present")
    else:
        log_missing(f"{path}: anchor not found for stat extern prototypes")

    call_stat = """#ifdef CONFIG_KSU_MANUAL_HOOK
	ksu_handle_stat(&dfd, &filename, &flag);
#endif
"""
    text = add_call_after_decl(
        path, text,
        r"SYSCALL_DEFINE4\s*\(\s*newfstatat\b",
        "ksu_handle_stat(&dfd, &filename, &flag)",
        r"^\s*int\s+error\s*;\s*$",
        call_stat,
        "newfstatat stat hook",
    )

    if re.search(r"SYSCALL_DEFINE4\s*\(\s*fstatat64\b", text, re.S):
        text = add_call_after_decl(
            path, text,
            r"SYSCALL_DEFINE4\s*\(\s*fstatat64\b",
            "ksu_handle_stat(&dfd, &filename, &flag)",
            r"^\s*int\s+error\s*;\s*$",
            call_stat,
            "fstatat64 stat hook",
        )
    else:
        log_skip(f"{path}: fstatat64 not present, skipped")

    call_newfstat_ret = """#ifdef CONFIG_KSU_MANUAL_HOOK
	ksu_handle_newfstat_ret(&fd, &statbuf);
#endif
"""
    text = add_call_before_return(
        path, text,
        r"SYSCALL_DEFINE2\s*\(\s*newfstat\b",
        "ksu_handle_newfstat_ret",
        r"^\s*return\s+error\s*;",
        call_newfstat_ret,
        "newfstat return hook",
    )

    if re.search(r"SYSCALL_DEFINE2\s*\(\s*fstat64\b", text, re.S):
        call_fstat64_ret = """#ifdef CONFIG_KSU_MANUAL_HOOK
	ksu_handle_fstat64_ret(&fd, &statbuf);
#endif
"""
        text = add_call_before_return(
            path, text,
            r"SYSCALL_DEFINE2\s*\(\s*fstat64\b",
            "ksu_handle_fstat64_ret",
            r"^\s*return\s+error\s*;",
            call_fstat64_ret,
            "fstat64 return hook",
        )
    else:
        log_skip(f"{path}: fstat64 not present, skipped")

    write_if_changed(path, old, text)


def apply_exec() -> None:
    path = "fs/exec.c"
    old = read(path)
    if old is None:
        return
    text = old

    auto_new = "do_execveat_common" in text and re.search(r"\bint\s+do_execve\s*\(\s*struct\s+filename\s*\*\s*filename", text, re.S) is not None
    if EXEC_STYLE == "execveat":
        is_new = True
    elif EXEC_STYLE == "execve":
        is_new = False
    else:
        is_new = auto_new

    if is_new:
        proto = """#ifdef CONFIG_KSU_MANUAL_HOOK
__attribute__((hot))
extern int ksu_handle_execveat(int *fd, struct filename **filename_ptr,
				void *argv, void *envp, int *flags);
#endif
"""
        text2, ok = insert_prototype_before(text, r"\bint\s+do_execve\s*\(", proto, "ksu_handle_execveat")
        if ok:
            log_changed(f"{path}: added execveat extern prototype")
            text = text2
        elif "ksu_handle_execveat" in text:
            log_skip(f"{path}: execveat extern prototype already present")
        else:
            log_missing(f"{path}: anchor not found for execveat extern prototype")

        call = """#ifdef CONFIG_KSU_MANUAL_HOOK
	ksu_handle_execveat((int *)AT_FDCWD, &filename, &argv, &envp, 0);
#endif
"""
        text = add_call_before_return(
            path, text,
            r"\bint\s+do_execve\s*\(\s*struct\s+filename\s*\*\s*filename",
            "ksu_handle_execveat",
            r"^\s*return\s+do_execveat_common\s*\(",
            call,
            "do_execve execveat hook",
        )
        if re.search(r"\bcompat_do_execve\s*\(", text):
            text = add_call_before_return(
                path, text,
                r"\b(?:static\s+)?int\s+compat_do_execve\s*\(",
                "ksu_handle_execveat",
                r"^\s*return\s+do_execveat_common\s*\(",
                call,
                "compat_do_execve execveat hook",
            )
        else:
            log_skip(f"{path}: compat_do_execve not present, skipped")
    else:
        proto = """#ifdef CONFIG_KSU_MANUAL_HOOK
__attribute__((hot))
extern int ksu_handle_execve(int *fd, const char *filename,
				void *argv, void *envp, int *flags);
#endif
"""
        text2, ok = insert_prototype_before(text, r"\bint\s+do_execve\s*\(", proto, "ksu_handle_execve")
        if ok:
            log_changed(f"{path}: added execve extern prototype")
            text = text2
        elif "ksu_handle_execve" in text:
            log_skip(f"{path}: execve extern prototype already present")
        else:
            log_missing(f"{path}: anchor not found for execve extern prototype")

        call = """#ifdef CONFIG_KSU_MANUAL_HOOK
	ksu_handle_execve((int *)AT_FDCWD, filename, &argv, &envp, 0);
#endif
"""
        text = add_call_before_return(
            path, text,
            r"\bint\s+do_execve\s*\(",
            "ksu_handle_execve",
            r"^\s*return\s+do_execve_common\s*\(",
            call,
            "do_execve execve hook",
        )
        if re.search(r"\bcompat_do_execve\s*\(", text):
            text = add_call_before_return(
                path, text,
                r"\b(?:static\s+)?int\s+compat_do_execve\s*\(",
                "ksu_handle_execve",
                r"^\s*return\s+do_execve_common\s*\(",
                call,
                "compat_do_execve execve hook",
            )
        else:
            log_skip(f"{path}: compat_do_execve not present, skipped")

    write_if_changed(path, old, text)


def apply_faccessat() -> None:
    path = "fs/open.c"
    old = read(path)
    if old is None:
        return
    text = old
    if FACCESS_STYLE != "auto":
        log_skip(f"{path}: faccess style selected: {FACCESS_STYLE}")
    proto = """#ifdef CONFIG_KSU_MANUAL_HOOK
__attribute__((hot))
extern int ksu_handle_faccessat(int *dfd, const char __user **filename_user,
				int *mode, int *flags);
#endif
"""
    text2, ok = insert_prototype_before(text, r"SYSCALL_DEFINE3\s*\(\s*faccessat\b", proto, "ksu_handle_faccessat")
    if ok:
        log_changed(f"{path}: added faccessat extern prototype")
        text = text2
    elif "ksu_handle_faccessat" in text:
        log_skip(f"{path}: faccessat extern prototype already present")
    else:
        log_missing(f"{path}: anchor not found for faccessat extern prototype")

    call = """#ifdef CONFIG_KSU_MANUAL_HOOK
	ksu_handle_faccessat(&dfd, &filename, &mode, NULL);
#endif
"""
    span = find_func_span(text, r"SYSCALL_DEFINE3\s*\(\s*faccessat\b")
    if not span:
        log_missing(f"{path}: faccessat syscall not found")
    elif body_contains(text, span, "ksu_handle_faccessat"):
        log_skip(f"{path}: faccessat hook already present")
    else:
        _, open_b, close_b = span
        for anchor in (
            r"^\s*unsigned\s+int\s+lookup_flags\s*=.*;\s*$",
            r"^\s*int\s+res\s*;\s*$",
        ):
            text2, ok = insert_after_line_containing(text, open_b, close_b, anchor, call)
            if ok:
                text = text2
                log_changed(f"{path}: added faccessat hook")
                break
        else:
            text = insert_after_open_brace(text, span, call)
            log_changed(f"{path}: added faccessat hook")

    write_if_changed(path, old, text)


def choose_reboot_path() -> str:
    if REBOOT_STYLE == "reboot.c":
        return "kernel/reboot.c"
    if REBOOT_STYLE == "sys.c":
        return "kernel/sys.c"
    reboot_text = read("kernel/reboot.c", quiet=True)
    if reboot_text is not None and re.search(r"SYSCALL_DEFINE4\s*\(\s*reboot\b", reboot_text):
        return "kernel/reboot.c"
    return "kernel/sys.c"


def apply_reboot() -> None:
    path = choose_reboot_path()
    old = read(path)
    if old is None:
        return
    text = old

    proto = """#ifdef CONFIG_KSU_MANUAL_HOOK
extern int ksu_handle_sys_reboot(int magic1, int magic2, unsigned int cmd, void __user **arg);
#endif
"""
    text2, ok = insert_prototype_before(text, r"SYSCALL_DEFINE4\s*\(\s*reboot\b", proto, "ksu_handle_sys_reboot")
    if ok:
        log_changed(f"{path}: added reboot extern prototype")
        text = text2
    elif "ksu_handle_sys_reboot" in text:
        log_skip(f"{path}: reboot extern prototype already present")
    else:
        log_missing(f"{path}: anchor not found for reboot extern prototype")

    call = """#ifdef CONFIG_KSU_MANUAL_HOOK
	ksu_handle_sys_reboot(magic1, magic2, cmd, &arg);
#endif
"""
    text = add_call_after_decl(
        path, text,
        r"SYSCALL_DEFINE4\s*\(\s*reboot\b",
        "ksu_handle_sys_reboot",
        r"^\s*int\s+ret\s*=\s*0\s*;\s*$",
        call,
        "reboot syscall hook",
    )

    write_if_changed(path, old, text)


def apply_input() -> None:
    path = "drivers/input/input.c"
    old = read(path)
    if old is None:
        return
    text = old

    proto = """#ifdef CONFIG_KSU_MANUAL_HOOK
extern bool ksu_input_hook __read_mostly;
extern __attribute__((cold)) int ksu_handle_input_handle_event(
			unsigned int *type, unsigned int *code, int *value);
#endif
"""
    text2, ok = insert_prototype_before(text, r"\bvoid\s+input_event\s*\(", proto, "ksu_handle_input_handle_event")
    if ok:
        log_changed(f"{path}: added input extern prototypes")
        text = text2
    elif "ksu_handle_input_handle_event" in text:
        log_skip(f"{path}: input extern prototypes already present")
    else:
        log_missing(f"{path}: anchor not found for input extern prototypes")

    call = """#ifdef CONFIG_KSU_MANUAL_HOOK
	if (unlikely(ksu_input_hook))
		ksu_handle_input_handle_event(&type, &code, &value);
#endif
"""
    text = add_call_after_decl(
        path, text,
        r"\bvoid\s+input_event\s*\(",
        "ksu_handle_input_handle_event",
        r"^\s*unsigned\s+long\s+flags\s*;\s*$",
        call,
        "input_event hook",
    )

    write_if_changed(path, old, text)


def apply_setuid() -> None:
    path = "kernel/sys.c"
    old = read(path)
    if old is None:
        return
    text = old
    proto = """#ifdef CONFIG_KSU_MANUAL_HOOK
extern int ksu_handle_setresuid(uid_t ruid, uid_t euid, uid_t suid);
#endif
"""

    auto_new = re.search(r"\blong\s+__sys_setresuid\s*\(", text) is not None
    if SETUID_STYLE == "__sys_setresuid":
        has_new = True
    elif SETUID_STYLE == "setresuid":
        has_new = False
    else:
        has_new = auto_new

    if has_new:
        text2, ok = insert_prototype_before(text, r"\blong\s+__sys_setresuid\s*\(", proto, "ksu_handle_setresuid")
        if ok:
            log_changed(f"{path}: added setresuid extern prototype")
            text = text2
        elif "ksu_handle_setresuid" in text:
            log_skip(f"{path}: setresuid extern prototype already present")
        else:
            log_missing(f"{path}: anchor not found for setresuid extern prototype")
        call = """#ifdef CONFIG_KSU_MANUAL_HOOK
	(void)ksu_handle_setresuid(ruid, euid, suid);
#endif
"""
        text = add_call_after_decl(
            path, text,
            r"\blong\s+__sys_setresuid\s*\(",
            "ksu_handle_setresuid",
            r"^\s*bool\s+ruid_new\s*,\s*euid_new\s*,\s*suid_new\s*;\s*$",
            call,
            "__sys_setresuid hook",
        )
    else:
        text2, ok = insert_prototype_before(text, r"SYSCALL_DEFINE3\s*\(\s*setresuid\b", proto, "ksu_handle_setresuid")
        if ok:
            log_changed(f"{path}: added setresuid extern prototype")
            text = text2
        elif "ksu_handle_setresuid" in text:
            log_skip(f"{path}: setresuid extern prototype already present")
        else:
            log_missing(f"{path}: anchor not found for setresuid extern prototype")
        call = """#ifdef CONFIG_KSU_MANUAL_HOOK
	(void)ksu_handle_setresuid(ruid, euid, suid);
#endif
"""
        text = add_call_after_decl(
            path, text,
            r"SYSCALL_DEFINE3\s*\(\s*setresuid\b",
            "ksu_handle_setresuid",
            r"^\s*kuid_t\s+kruid\s*,\s*keuid\s*,\s*ksuid\s*;\s*$",
            call,
            "setresuid hook",
        )

    write_if_changed(path, old, text)


def apply_read() -> None:
    path = "fs/read_write.c"
    old = read(path)
    if old is None:
        return
    text = old
    if READ_STYLE != "auto":
        log_skip(f"{path}: read style selected: {READ_STYLE}")
    proto = """#ifdef CONFIG_KSU_MANUAL_HOOK
extern bool ksu_init_rc_hook __read_mostly;
extern __attribute__((cold)) int ksu_handle_sys_read(unsigned int fd,
				char __user **buf_ptr, size_t *count_ptr);
#endif
"""
    text2, ok = insert_prototype_before(text, r"SYSCALL_DEFINE3\s*\(\s*read\b", proto, "ksu_handle_sys_read")
    if ok:
        log_changed(f"{path}: added read extern prototypes")
        text = text2
    elif "ksu_handle_sys_read" in text:
        log_skip(f"{path}: read extern prototypes already present")
    else:
        log_missing(f"{path}: anchor not found for read extern prototypes")

    call = """#ifdef CONFIG_KSU_MANUAL_HOOK
	if (unlikely(ksu_init_rc_hook))
		ksu_handle_sys_read(fd, &buf, &count);
#endif
"""
    span = find_func_span(text, r"SYSCALL_DEFINE3\s*\(\s*read\b")
    if not span:
        log_missing(f"{path}: read syscall not found")
    elif body_contains(text, span, "ksu_handle_sys_read"):
        log_skip(f"{path}: read hook already present")
    else:
        _, open_b, close_b = span
        for anchor in (
            r"^\s*ssize_t\s+ret\s*=\s*-EBADF\s*;\s*$",
            r"^\s*struct\s+fd\s+f\s*=.*;\s*$",
        ):
            text2, ok = insert_after_line_containing(text, open_b, close_b, anchor, call)
            if ok:
                text = text2
                log_changed(f"{path}: added read hook")
                break
        else:
            text = insert_after_open_brace(text, span, call)
            log_changed(f"{path}: added read hook")

    write_if_changed(path, old, text)


def apply_exports() -> None:
    path = "security/selinux/ss/services.c"
    old = read(path, quiet=True) if exists(path) else None
    if old is not None:
        text = old
        text2, ok = replace_once(text, "static DEFINE_RWLOCK(policy_rwlock);", "DEFINE_RWLOCK(policy_rwlock);")
        if ok:
            text = text2
            log_changed(f"{path}: exported policy_rwlock")
        elif "DEFINE_RWLOCK(policy_rwlock);" in text:
            log_skip(f"{path}: policy_rwlock already exported or non-static")
        else:
            log_skip(f"{path}: policy_rwlock definition not found, skipped")
        write_if_changed(path, old, text)

    path = "security/selinux/hooks.c"
    old = read(path, quiet=True) if exists(path) else None
    if old is not None:
        text = old
        text2, ok = re_replace_once(
            text,
            r"static\s+struct\s+security_operations\s+selinux_ops\s*=",
            "struct security_operations selinux_ops =",
            flags=re.M,
        )
        if ok:
            text = text2
            log_changed(f"{path}: exported selinux_ops")
        elif re.search(r"\bstruct\s+security_operations\s+selinux_ops\s*=", text):
            log_skip(f"{path}: selinux_ops already exported or non-static")
        else:
            log_skip(f"{path}: selinux_ops definition not found, skipped")
        write_if_changed(path, old, text)

    path = "security/selinux/selinuxfs.c"
    old = read(path, quiet=True) if exists(path) else None
    if old is not None:
        text = old
        text2, ok = replace_once(text, "static DEFINE_MUTEX(sel_mutex);", "DEFINE_MUTEX(sel_mutex);")
        if ok:
            text = text2
            log_changed(f"{path}: exported sel_mutex")
        elif "DEFINE_MUTEX(sel_mutex);" in text:
            log_skip(f"{path}: sel_mutex already exported or non-static")
        else:
            log_skip(f"{path}: sel_mutex definition not found, skipped")
        write_if_changed(path, old, text)


def main() -> int:
    required_dirs = ["fs", "kernel"]
    if not all(Path(d).is_dir() for d in required_dirs):
        print("[ERR] This does not look like a kernel source root. Run from kernel root or pass --root.", file=sys.stderr)
        return 2

    dispatch = [
        ("stat", apply_stat),
        ("exec", apply_exec),
        ("faccessat", apply_faccessat),
        ("reboot", apply_reboot),
        ("input", apply_input),
        ("setuid", apply_setuid),
        ("read", apply_read),
        ("exports", apply_exports),
    ]

    for name, fn in dispatch:
        if name in HOOKS:
            fn()
        else:
            log_skip(f"{name}: disabled by user")

    print("\n== ReSukiSU manual hook apply report ==")
    print(f"Profile: {PROFILE}" + (f" from kernel {KERNEL_VERSION}" if KERNEL_VERSION else ""))
    print(f"Styles: exec={EXEC_STYLE}, reboot={REBOOT_STYLE}, setuid={SETUID_STYLE}, faccess={FACCESS_STYLE}, read={READ_STYLE}")
    print(f"Enabled hooks: {', '.join(sorted(HOOKS)) if HOOKS else 'none'}")
    if DRY_RUN:
        print("Mode: dry-run, no files written")

    if changed_actions:
        print("\n[CHANGED]" if not DRY_RUN else "\n[WOULD CHANGE]")
        for x in changed_actions:
            print(f"  + {x}")
    else:
        print("\n[CHANGED]\n  none")

    if skipped_actions:
        print("\n[SKIPPED / ALREADY OK]")
        for x in skipped_actions:
            print(f"  = {x}")

    if warn_actions:
        print("\n[WARN]")
        for x in warn_actions:
            print(f"  ! {x}")

    if missing_actions:
        print("\n[MISSING / CHECK MANUALLY]")
        for x in missing_actions:
            print(f"  - {x}")

    if changed_files:
        print("\nChanged files:" if not DRY_RUN else "\nFiles that would change:")
        for p in sorted(changed_files):
            print(f"  {p}")

    print("\nNext checks:")
    print("  grep -RsnE 'ksu_handle_(stat|newfstat|fstat64|execve|execveat|faccessat|sys_reboot|input_handle_event|setresuid|sys_read)|ksu_input_hook|ksu_init_rc_hook' fs kernel drivers/input security | head -200")
    print("  git diff -- fs/stat.c fs/exec.c fs/open.c fs/read_write.c kernel/reboot.c kernel/sys.c drivers/input/input.c security/selinux")
    print("  make olddefconfig >/dev/null || true")

    optional_patterns = (
        "fstatat64 not present", "fstat64 not present", "compat_do_execve not present",
        "policy_rwlock", "selinux_ops", "sel_mutex",
    )
    hard_missing = [x for x in missing_actions if not any(opt in x for opt in optional_patterns)]
    return 1 if hard_missing else 0


if __name__ == "__main__":
    raise SystemExit(main())
PY
