#!/usr/bin/env bash
set -e

file="drivers/input/input.c"

if [ ! -f "$file" ]; then
  echo "Erro: $file não existe"
  exit 1
fi

echo "[*] Procurando hook incompatível em $file..."
grep -nE "ksu_input_hook|ksu_handle_input_handle_event" "$file" || {
  echo "[*] Nenhum hook incompatível encontrado."
  exit 0
}

cp "$file" "$file.bak.resukisu"

python3 <<'PY'
from pathlib import Path

p = Path("drivers/input/input.c")
lines = p.read_text().splitlines()
out = []
i = 0

targets = [
    "ksu_input_hook",
    "ksu_handle_input_handle_event",
]

while i < len(lines):
    line = lines[i]

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

        if any(t in text for t in targets):
            i = j + 1
            continue

    if any(t in line for t in targets):
        i += 1
        continue

    out.append(line)
    i += 1

p.write_text("\n".join(out) + "\n")
PY

echo "[*] Verificação final:"
if grep -nE "ksu_input_hook|ksu_handle_input_handle_event" "$file"; then
  echo "[!] Ainda há restos. Remove manualmente."
  exit 1
else
  echo "[OK] Hook incompatível removido."
fi

echo "[*] Backup: $file.bak.resukisu"
