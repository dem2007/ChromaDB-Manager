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

# Дописанная метка — та, у которой есть и архив, и отпечаток: mark-stable
# пишет отпечаток последним. Оборванная на полпути метка без него — не
# стабильная сборка, и выбирать её по умолчанию нельзя.
complete() {
    [ -f "$1/ChromaDB-Manager.app.tar.gz" ] && [ -f "$1/MANIFEST.txt" ]
}

if [ "${1:-}" = "--list" ]; then
    for dir in "$STABLE_ROOT"/*/; do
        [ -d "$dir" ] || continue
        echo "── $(basename "$dir")"
        if complete "$dir"; then
            head -4 "$dir/MANIFEST.txt" | sed 's/^/   /'
        else
            echo "   (метка не дописана — архива или отпечатка нет)"
        fi
    done
    exit 0
fi

if [ -n "${1:-}" ]; then
    NAME="$1"
else
    NAME=""
    while IFS= read -r candidate; do
        if complete "$STABLE_ROOT/$candidate"; then NAME="$candidate"; break; fi
    done < <(ls -1t "$STABLE_ROOT")
    [ -n "$NAME" ] || { echo "!! ни одной дописанной стабильной метки нет" >&2; exit 1; }
fi
DIR="$STABLE_ROOT/$NAME"
ARCHIVE="$DIR/ChromaDB-Manager.app.tar.gz"

complete "$DIR" || { echo "!! метка «$NAME» не дописана — архива или отпечатка нет" >&2; exit 1; }

echo "==> метка: $NAME"
head -6 "$DIR/MANIFEST.txt" | sed 's/^/    /'

# Архив проверяется **до** того, как текущая сборка отодвигается: обрезанный
# архив иначе оставлял на месте приложения пустоту.
EXPECTED="$(sed -n 's/^sha256 архива: //p' "$DIR/MANIFEST.txt")"
if [ -n "$EXPECTED" ] && [ "$(shasum -a 256 "$ARCHIVE" | cut -d' ' -f1)" != "$EXPECTED" ]; then
    echo "!! архив метки «$NAME» не совпадает с отпечатком — повреждён" >&2
    exit 1
fi

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

# Распаковка — сперва рядом, потом на место: сбой посреди `tar` не должен
# оставить половину приложения там, где его будут запускать.
STAGING="$(mktemp -d "$ROOT/dist/.restore-XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
if ! tar -xzf "$ARCHIVE" -C "$STAGING"; then
    [ -n "${ASIDE:-}" ] && mv "$ASIDE" "$BUNDLE"
    echo "!! архив не распаковался — прежняя сборка возвращена на место" >&2
    exit 1
fi
mv "$STAGING/ChromaDB Manager.app" "$BUNDLE"
echo "==> восстановлено: dist/ChromaDB Manager.app"
echo
echo "Открыть:      open \"$BUNDLE\""
echo "Вернуть код:  git switch --detach $NAME"
