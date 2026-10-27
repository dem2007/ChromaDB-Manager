#!/bin/bash
# Собирает релизный пакет приложения: архив, который можно приложить
# к выпуску на GitHub.
#
#     Scripts/release.sh              # собрать и упаковать
#     Scripts/release.sh --skip-build # упаковать уже собранное в dist
#                                     # (под его архитектуру)
#
# **Два архива, по одному на процессор**: `…-apple-silicon.zip`
# и `…-intel.zip`. Универсальная сборка весила вдвое больше, а каждому Маку
# нужна одна половина. Под эту машину собирается последней — в `dist`
# остаётся приложение, которое здесь же и запускается.
#
# **Про подпись.** Пакет получается ровно такой, какова подпись сборки.
# Если в системе есть сертификат Developer ID и настроенный профиль
# `notarytool`, скрипт подпишет им, отправит на нотаризацию и пришьёт
# талон. Если нет — упакует как есть и **скажет об этом прямо**: такой
# архив у скачавшего откроется только после ручного разрешения, потому что
# Gatekeeper снимет доверие с незнакомого разработчика. Путь к разрешению
# зависит от версии macOS: на 14 — «Открыть» из контекстного меню, с 15 этот
# обход убран, и остаётся «Системные настройки → Конфиденциальность
# и безопасность → Всё равно открыть». Молчать об этом нельзя: человек
# решит, что приложение сломано.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SKIP_BUILD=0
for argument in "$@"; do
    case "$argument" in
        --skip-build) SKIP_BUILD=1 ;;
        *) echo "неизвестный ключ: $argument" >&2; exit 2 ;;
    esac
done

# Версия берётся из того же места и тем же способом, что у publish.sh:
# два способа читать одно число разошлись бы в первый же выпуск.
VERSION="$(/usr/bin/awk '/CFBundleShortVersionString/{getline; gsub(/[^0-9.]/,""); print; exit}' Resources/Info.plist)"
[ -n "$VERSION" ] || { echo "!! не удалось прочитать версию из Info.plist" >&2; exit 1; }

APP="$ROOT/dist/ChromaDB Manager.app"

echo "==> версия $VERSION"

NATIVE="$(uname -m)"
if [ "$SKIP_BUILD" = 1 ]; then
    # Уже собранное пакуется под ту архитектуру, под которую оно собрано,
    # а не под эту машину: `build-app.sh release x86_64` на Apple Silicon —
    # законная сборка для Intel.
    [ -x "$APP/Contents/MacOS/ChromaDBManager" ] || { echo "!! нет собранного приложения: $APP" >&2; exit 1; }
    BUILT="$(lipo -archs "$APP/Contents/MacOS/ChromaDBManager")"
    case "$BUILT" in
        arm64|x86_64) ARCHS=("$BUILT") ;;
        *) echo "!! приложение в dist собрано под «$BUILT» — архивы делаются под одну архитектуру, пересоберите" >&2; exit 1 ;;
    esac
elif [ "$NATIVE" = arm64 ]; then
    ARCHS=(x86_64 arm64)
else
    ARCHS=(arm64 x86_64)
fi

# Имя архива — по процессору, словами, которые человек знает про свой Мак.
archive_label() {
    case "$1" in
        arm64) echo "apple-silicon" ;;
        x86_64) echo "intel" ;;
    esac
}

IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | /usr/bin/awk -F'"' '/Developer ID Application/{print $2; exit}')"
NOTARISED=0
ARCHIVES=()
# Вердикт Gatekeeper — по каждому архиву, пока его приложение ещё в dist:
# следующий проход собирает поверх, и проверять потом было бы нечего.
ASSESSMENTS=()

package() {
    local arch="$1"
    local archive="$ROOT/dist/ChromaDB-Manager-$VERSION-$(archive_label "$arch").zip"
    echo
    echo "==> $arch → $(basename "$archive")"

    if [ "$SKIP_BUILD" = 0 ]; then
        echo "==> сборка приложения"
        ./Scripts/build-app.sh release "$arch" > /dev/null
    fi
    [ -d "$APP" ] || { echo "!! нет собранного приложения: $APP" >&2; exit 1; }

    # Версия в собранном бандле обязана совпасть с той, под которой пакуем:
    # иначе в архив уедет вчерашняя сборка под сегодняшним именем.
    BUNDLED="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || true)"
    if [ "$BUNDLED" != "$VERSION" ]; then
        echo "!! в собранном приложении версия $BUNDLED, а пакуем $VERSION — пересоберите" >&2
        exit 1
    fi
    # И архитектура — та, что в имени архива.
    for binary in "$APP"/Contents/MacOS/*; do
        if [ "$(lipo -archs "$binary")" != "$arch" ]; then
            echo "!! $(basename "$binary") собран под $(lipo -archs "$binary"), а архив — для $arch" >&2
            exit 1
        fi
    done

    # MARK: чистота бандла

    # Приложение уходит в сеть так же, как репозиторий, и несёт то, что в него
    # вкомпилировано: пути машины сборки и строковые константы кода. До 0.4.0
    # каждый выпуск нёс сотни путей «/Users/<логин>/…», а в 0.4.0 — номер
    # договора из описания инструмента MCP. Проверяется весь бандл, бинарники
    # тоже; список слов — тот же, что у publish.sh, и только на этой машине.
    echo "==> проверка бандла на личное"
    DENYLIST="$ROOT/docs/local/publish-denylist.txt"
    if [ ! -f "$DENYLIST" ]; then
        echo "!! нет списка запрещённых слов: $DENYLIST" >&2
        echo "   Он хранится только на машине автора. Собираете у себя — заведите" >&2
        echo "   пустой файл: пути машины сборки проверятся и без него." >&2
        exit 1
    fi
    TERMS="$(mktemp)"
    # Регистр кириллицы `grep -i` не сводит: в локали C не умеет вовсе, а в UTF-8
    # не находит кириллицу в бинарниках (латиницу находит). Поэтому каждое слово
    # ищется побайтно в нескольких написаниях, а `-i` остаётся для латиницы.
    python3 - "$DENYLIST" > "$TERMS" <<'PY'
import sys
for line in open(sys.argv[1], encoding="utf-8"):
    term = line.strip()
    if term and not term.startswith("#"):
        for variant in sorted({term, term.lower(), term.upper(), term.capitalize(), term.title()}):
            print(variant)
PY
    printf '%s\n' "/Users/" >> "$TERMS"
    LEAKS="$(LC_ALL=C grep -rlaiF -f "$TERMS" "$APP" 2>/dev/null || true)"
    if [ -n "$LEAKS" ]; then
        echo "!! в приложении пути машины сборки или слова из рабочих документов:" >&2
        while IFS= read -r leak; do
            echo "   ${leak#"$APP"/}: $(LC_ALL=C grep -aoiF -f "$TERMS" "$leak" | sort -u | head -5 | paste -sd, -)" >&2
        done <<< "$LEAKS"
        rm -f "$TERMS"
        exit 1
    fi
    rm -f "$TERMS"
    echo "    чисто: ни путей машины, ни слов из документов"

    if [ -n "$IDENTITY" ]; then
        echo "==> подпись Developer ID: $IDENTITY"
        codesign --force --deep --options runtime --timestamp \
            --entitlements Resources/ChromaDBManager.entitlements \
            --sign "$IDENTITY" "$APP"
        codesign --verify --deep --strict --verbose=2 "$APP"
    else
        echo "==> подписи Developer ID в системе нет — пакуем как собрано (ad-hoc)"
    fi

    # MARK: архив

    echo "==> архив"
    rm -f "$archive"
    # `ditto`, а не `zip`: он единственный сохраняет подпись бандла, права
    # и символические ссылки так, чтобы приложение осталось работоспособным
    # после распаковки. Обычный `zip` их портит, и подпись перестаёт сходиться.
    ditto -c -k --sequesterRsrc --keepParent "$APP" "$archive"

    if [ -n "$IDENTITY" ]; then
        if xcrun notarytool history --keychain-profile "notarytool" > /dev/null 2>&1; then
            echo "==> нотаризация"
            xcrun notarytool submit "$archive" --keychain-profile "notarytool" --wait
            # Талон пришивается к **приложению**, а не к архиву, поэтому архив
            # после этого пересобирается: иначе скачавший получит бандл
            # без талона и проверку без сети не пройдёт.
            xcrun stapler staple "$APP"
            rm -f "$archive"
            ditto -c -k --sequesterRsrc --keepParent "$APP" "$archive"
            NOTARISED=1
        else
            echo "!! профиль notarytool не настроен — нотаризации не будет" >&2
            echo "   xcrun notarytool store-credentials notarytool --apple-id … --team-id … --password …" >&2
        fi
    fi
    ARCHIVES+=("$archive")
    ASSESSMENTS+=("$(spctl --assess --type execute --verbose=2 "$APP" 2>&1 | tail -1 || true)")
}

for arch in "${ARCHS[@]}"; do package "$arch"; done

# MARK: что получилось

echo
for index in "${!ARCHIVES[@]}"; do
    archive="${ARCHIVES[$index]}"
    echo "Пакет:      $archive"
    echo "Размер:     $(du -h "$archive" | cut -f1 | tr -d ' ')"
    echo "SHA-256:    $(shasum -a 256 "$archive" | cut -d' ' -f1)"
    echo "Gatekeeper: ${ASSESSMENTS[$index]#"$APP": }"
    echo
done

if [ "$NOTARISED" = 1 ]; then
    echo "Пакет подписан и нотаризован — открывается двойным щелчком."
else
    cat <<'ПРЕДУПРЕЖДЕНИЕ'
ВНИМАНИЕ: пакет НЕ нотаризован.

У скачавшего macOS поставит на файл карантин, и приложение откажется
открываться двойным щелчком: «не удаётся проверить разработчика».
Обойти это можно один раз, но путь зависит от версии системы:

  macOS 14:    «Открыть» из контекстного меню приложения;
  macOS 15+:   запустить один раз, затем «Системные настройки →
               Конфиденциальность и безопасность → Всё равно открыть».
               Обход через контекстное меню в macOS 15 убран.

В описании выпуска надо назвать оба пути, иначе человек решит, что
приложение сломано.

Чтобы пакет открывался как положено, нужны платный аккаунт Apple
Developer, сертификат Developer ID Application и профиль notarytool.
Это пункт B1 задания, и он до сих пор отложен.
ПРЕДУПРЕЖДЕНИЕ
fi
