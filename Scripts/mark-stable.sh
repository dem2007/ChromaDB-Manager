#!/bin/bash
# Помечает текущее состояние как стабильное: тег на код и архив собранного
# приложения.
#
# Тег отвечает на вопрос «какой код это был», архив — на вопрос «дайте
# работающее приложение прямо сейчас». Второе без первого бесполезно через
# месяц, первое без второго требует пересборки — а пересборка это минуты и
# работающий Swift, которого в тот момент может не оказаться под рукой.
#
#     Scripts/mark-stable.sh            # пометить как stable-<дата>
#     Scripts/mark-stable.sh имя-метки  # пометить своим именем
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

NAME="${1:-stable-$(date +%Y%m%d)}"
STABLE_DIR="$ROOT/dist/stable/$NAME"
BUNDLE="$ROOT/dist/ChromaDB Manager.app"

# 1. Незакоммиченные правки. Метка на грязное дерево — это метка, по которой
#    нельзя вернуться: половина состояния останется только на этой машине.
if [ -n "$(git status --porcelain)" ]; then
    echo "!! есть незакоммиченные изменения — метка была бы неполной:" >&2
    git status --short >&2
    exit 1
fi

# 2. Тесты. Стабильной называется сборка, о которой это проверено, а не
#    объявлено.
echo "==> тесты"
# Итог ищется по строке XCTest «Executed N tests … with 0 failures», а не
# в хвосте вывода: после неё swift-testing печатает свой собственный итог
# («Test run with 0 tests in 0 suites passed»), в котором слова «failures»
# нет вовсе — и хвост выглядел бы как провал при зелёных тестах.
TEST_LOG="$(mktemp)"
trap 'rm -f "$TEST_LOG"' EXIT
if ! swift test > "$TEST_LOG" 2>&1; then
    tail -20 "$TEST_LOG" >&2
    echo "!! тесты не прошли — сборка не может считаться стабильной" >&2
    exit 1
fi
if ! grep -qE "Executed [0-9]+ tests?.*with 0 failures" "$TEST_LOG"; then
    tail -20 "$TEST_LOG" >&2
    echo "!! не нашёл итога тестов — не считаю сборку проверенной" >&2
    exit 1
fi
echo "    $(grep -oE "Executed [0-9]+ tests?[^)]*failures \(0 unexpected\)" "$TEST_LOG" | tail -1)"

# 3. Свежая сборка из этого же кода: приложение в dist могло остаться от
#    прошлой попытки.
echo "==> сборка"
"$ROOT/Scripts/build-app.sh" > /dev/null
[ -d "$BUNDLE" ] || { echo "!! приложение не собралось" >&2; exit 1; }

COMMIT="$(git rev-parse HEAD)"
SHORT="$(git rev-parse --short HEAD)"

# 4. Тег на код — аннотированный: у него есть дата, автор и текст.
if git rev-parse "$NAME" > /dev/null 2>&1; then
    echo "!! метка $NAME уже есть — выберите другое имя" >&2
    exit 1
fi
git tag -a "$NAME" -m "Стабильная сборка $NAME

Тесты пройдены, приложение собрано и проверено живьём.
Архив собранного приложения: dist/stable/$NAME/"

# 5. Архив приложения. В git он не идёт — 37 МБ двоичного кода в истории
#    не нужны никому; лежит рядом, под dist/, который git не отслеживает.
echo "==> архив приложения"
mkdir -p "$STABLE_DIR"
tar -czf "$STABLE_DIR/ChromaDB-Manager.app.tar.gz" -C "$ROOT/dist" "ChromaDB Manager.app"

# 6. Отпечаток: по нему видно, та ли это сборка, не распаковывая архив.
{
    echo "метка:      $NAME"
    echo "коммит:     $COMMIT"
    echo "дата:       $(date '+%Y-%m-%d %H:%M:%S %z')"
    echo "версия:     $(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$BUNDLE/Contents/Info.plist" 2>/dev/null || echo '—')"
    echo "swift:      $(swift --version 2>/dev/null | head -1)"
    echo "macOS:      $(sw_vers -productVersion)"
    echo "тестов:     $(swift test --list-tests 2>/dev/null | wc -l | tr -d ' ')"
    echo "sha256 архива: $(shasum -a 256 "$STABLE_DIR/ChromaDB-Manager.app.tar.gz" | cut -d' ' -f1)"
    echo
    echo "Вернуть приложение:  Scripts/restore-stable.sh $NAME"
    echo "Вернуть код:         git switch --detach $NAME"
} > "$STABLE_DIR/MANIFEST.txt"

echo
echo "Готово."
echo "  метка кода:  $NAME → $SHORT"
echo "  архив:       dist/stable/$NAME/ChromaDB-Manager.app.tar.gz"
echo "  отпечаток:   dist/stable/$NAME/MANIFEST.txt"
