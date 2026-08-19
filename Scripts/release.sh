#!/bin/bash
# Собирает релизный пакет приложения: архив, который можно приложить
# к выпуску на GitHub.
#
#     Scripts/release.sh              # собрать и упаковать
#     Scripts/release.sh --skip-build # упаковать уже собранное в dist
#
# **Про подпись.** Пакет получается ровно такой, какова подпись сборки.
# Если в системе есть сертификат Developer ID и настроенный профиль
# `notarytool`, скрипт подпишет им, отправит на нотаризацию и пришьёт
# талон. Если нет — упакует как есть и **скажет об этом прямо**: такой
# архив у скачавшего откроется только через «Открыть» из контекстного
# меню, потому что Gatekeeper снимет доверие с незнакомого разработчика.
# Молчать об этом нельзя: человек решит, что приложение сломано.
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
ARCHIVE="$ROOT/dist/ChromaDB-Manager-$VERSION.zip"

echo "==> версия $VERSION"

if [ "$SKIP_BUILD" = 0 ]; then
    echo "==> сборка приложения"
    ./Scripts/build-app.sh release > /dev/null
fi
[ -d "$APP" ] || { echo "!! нет собранного приложения: $APP" >&2; exit 1; }

# Версия в собранном бандле обязана совпасть с той, под которой пакуем:
# иначе в архив уедет вчерашняя сборка под сегодняшним именем.
BUNDLED="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || true)"
if [ "$BUNDLED" != "$VERSION" ]; then
    echo "!! в собранном приложении версия $BUNDLED, а пакуем $VERSION — пересоберите" >&2
    exit 1
fi

# MARK: подпись Developer ID, если она вообще возможна

IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | /usr/bin/awk -F'"' '/Developer ID Application/{print $2; exit}')"
NOTARISED=0

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
rm -f "$ARCHIVE"
# `ditto`, а не `zip`: он единственный сохраняет подпись бандла, права
# и символические ссылки так, чтобы приложение осталось работоспособным
# после распаковки. Обычный `zip` их портит, и подпись перестаёт сходиться.
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ARCHIVE"

if [ -n "$IDENTITY" ]; then
    if xcrun notarytool history --keychain-profile "notarytool" > /dev/null 2>&1; then
        echo "==> нотаризация"
        xcrun notarytool submit "$ARCHIVE" --keychain-profile "notarytool" --wait
        # Талон пришивается к **приложению**, а не к архиву, поэтому архив
        # после этого пересобирается: иначе скачавший получит бандл
        # без талона и проверку без сети не пройдёт.
        xcrun stapler staple "$APP"
        rm -f "$ARCHIVE"
        ditto -c -k --sequesterRsrc --keepParent "$APP" "$ARCHIVE"
        NOTARISED=1
    else
        echo "!! профиль notarytool не настроен — нотаризации не будет" >&2
        echo "   xcrun notarytool store-credentials notarytool --apple-id … --team-id … --password …" >&2
    fi
fi

# MARK: что получилось

SIZE="$(du -h "$ARCHIVE" | cut -f1 | tr -d ' ')"
SUM="$(shasum -a 256 "$ARCHIVE" | cut -d' ' -f1)"
ASSESS="$(spctl --assess --type execute --verbose=2 "$APP" 2>&1 | tail -1 || true)"

echo
echo "Пакет:      $ARCHIVE"
echo "Размер:     $SIZE"
echo "SHA-256:    $SUM"
echo "Gatekeeper: $ASSESS"
echo

if [ "$NOTARISED" = 1 ]; then
    echo "Пакет подписан и нотаризован — открывается двойным щелчком."
else
    cat <<'ПРЕДУПРЕЖДЕНИЕ'
ВНИМАНИЕ: пакет НЕ нотаризован.

У скачавшего macOS поставит на файл карантин, и приложение откажется
открываться двойным щелчком: «не удаётся проверить разработчика».
Обойти это можно — «Открыть» из контекстного меню, один раз, — но
в описании выпуска об этом надо сказать, иначе человек решит, что
приложение сломано.

Чтобы пакет открывался как положено, нужны платный аккаунт Apple
Developer, сертификат Developer ID Application и профиль notarytool.
Это пункт B1 задания, и он до сих пор отложен.
ПРЕДУПРЕЖДЕНИЕ
fi
