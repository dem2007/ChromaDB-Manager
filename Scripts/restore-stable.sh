#!/bin/bash
# Возвращает работающее приложение из стабильного архива.
#
# Это самый быстрый откат: он не трогает ни код, ни git, ни настройки —
# просто кладёт на место `dist/ChromaDB Manager.app` ту сборку, которая
# работала. Нужен ровно тогда, когда «что-то пошло не так» и нужно,
# чтобы приложение снова открылось, а разбираться будем потом.
#
#     Scripts/restore-stable.sh              # последняя стабильная метка
#     Scripts/restore-stable.sh stable-20260809
#     Scripts/restore-stable.sh --list       # какие метки есть
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STABLE_ROOT="$ROOT/dist/stable"

if [ ! -d "$STABLE_ROOT" ]; then
    echo "!! стабильных сборок нет: сначала Scripts/mark-stable.sh" >&2
    exit 1
fi

if [ "${1:-}" = "--list" ]; then
    for dir in "$STABLE_ROOT"/*/; do
        [ -d "$dir" ] || continue
        echo "── $(basename "$dir")"
        sed 's/^/   /' "$dir/MANIFEST.txt" 2>/dev/null | head -4
    done
    exit 0
fi

NAME="${1:-$(ls -1t "$STABLE_ROOT" | head -1)}"
DIR="$STABLE_ROOT/$NAME"
ARCHIVE="$DIR/ChromaDB-Manager.app.tar.gz"

[ -f "$ARCHIVE" ] || { echo "!! нет архива для метки «$NAME»" >&2; exit 1; }

echo "==> метка: $NAME"
sed 's/^/    /' "$DIR/MANIFEST.txt" | head -6

# Приложение может быть запущено: подменять бандл под работающим процессом —
# верный способ получить наполовину старое, наполовину новое приложение.
if pgrep -f "ChromaDB Manager.app/Contents/MacOS/ChromaDBManager" > /dev/null; then
    echo
    echo "!! приложение запущено. Закройте его и повторите:" >&2
    echo "   osascript -e 'quit app \"ChromaDB Manager\"'" >&2
    exit 1
fi

# Текущая сборка не удаляется, а отодвигается: она может понадобиться, чтобы
# понять, что именно сломалось (правило 1 — ничего не удаляем сами).
BUNDLE="$ROOT/dist/ChromaDB Manager.app"
if [ -d "$BUNDLE" ]; then
    ASIDE="$ROOT/dist/ChromaDB Manager.app.replaced-$(date +%Y%m%d-%H%M%S)"
    mv "$BUNDLE" "$ASIDE"
    echo "==> прежняя сборка отложена: $(basename "$ASIDE")"
fi

tar -xzf "$ARCHIVE" -C "$ROOT/dist"
echo "==> восстановлено: dist/ChromaDB Manager.app"
echo
echo "Открыть:      open \"$BUNDLE\""
echo "Вернуть код:  git switch --detach $NAME"
