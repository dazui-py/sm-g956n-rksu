#!/usr/bin/env bash
set -e

file="fs/read_write.c"

if [ ! -f "$file" ]; then
  echo "Erro: $file não existe"
  exit 1
fi

echo "[*] Procurando hooks incompatíveis..."
grep -nE "ksu_vfs_read_hook|ksu_handle_vfs_read" "$file" || {
  echo "[*] Nenhum hook incompatível encontrado."
  exit 0
}

cp "$file" "$file.bak.resukisu"

python3 <<'PY'
from pathlib import Path

p = Path("fs/read_write.c")
s = p.read_text()

lines = s.splitlines()
out = []
i = 0

while i < len(lines):
    line = lines[i]

    # Remove blocos #ifdef/#endif pequenos que contenham ksu_vfs_read_hook ou ksu_handle_vfs_read
    if line.strip().startswith("#ifdef") or line.strip().startswith("#if"):
        block = [line]
        j = i + 1
        depth = 1

        while j < len(lines):
            block.append(lines[j])
            stripped = lines[j].strip()

            if stripped.startswith("#if"):
                depth += 1
            elif stripped.startswith("#endif"):
                depth -= 1
                if depth == 0:
                    break

            j += 1

        text = "\n".join(block)
        if "ksu_vfs_read_hook" in text or "ksu_handle_vfs_read" in text:
            i = j + 1
            continue

    # Remove linhas soltas caso existam
    if "ksu_vfs_read_hook" in line or "ksu_handle_vfs_read" in line:
        i += 1
        continue

    out.append(line)
    i += 1

p.write_text("\n".join(out) + "\n")
PY

echo "[*] Resultado:"
if grep -nE "ksu_vfs_read_hook|ksu_handle_vfs_read" "$file"; then
  echo "[!] Ainda há restos. Abre manualmente o ficheiro."
  exit 1
else
  echo "[OK] Hook incompatível removido."
fi

echo "[*] Backup salvo em: $file.bak.resukisu"
