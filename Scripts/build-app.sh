#!/bin/bash
# Builds ChromaDBManager.app from the Swift package.
#
# Xcode is not required: the SwiftPM binary is wrapped into a regular .app
# bundle with Resources/Info.plist and ad-hoc signed so macOS lets it run.
#
# Usage: Scripts/build-app.sh [debug|release] [arm64|x86_64]
#        (default: release, architecture of this Mac)

set -euo pipefail

CONFIG="${1:-release}"
# Конфигурация — первым аргументом, архитектура — вторым. Перепутанный
# порядок («build-app.sh x86_64») иначе доходил до SwiftPM ошибкой разбора
# ключа `-c`, из которой не понять, что не так.
case "$CONFIG" in
    debug|release) ;;
    *) echo "неизвестная конфигурация: $CONFIG (нужна debug или release; архитектура — вторым аргументом)" >&2; exit 2 ;;
esac
# Архитектура сборки. Под каждый процессор — своё приложение:
# универсальное весило вдвое больше (31 МБ архива против 16), а каждому
# Маку из двух половин нужна одна. По умолчанию — под эту машину.
ARCH="${2:-$(uname -m)}"
case "$ARCH" in
    arm64|x86_64) ;;
    *) echo "неизвестная архитектура: $ARCH (нужна arm64 или x86_64)" >&2; exit 2 ;;
esac
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="ChromaDB Manager"
BUNDLE="$ROOT/dist/$APP_NAME.app"

cd "$ROOT"

# Пути к исходникам компилятор зашивает в бинарник — для сообщений об ошибках
# и `#file`. Без подмены в каждом выпуске стояли сотни путей вида
# «/Users/<логин>/…/ChromaDBManager/Sources/…»: имя пользователя и раскладка
# папок машины сборки. Подмена делает их путями от корня проекта.
# Компоновщик пишет в отладочную карту пути к объектным файлам в `.build` —
# их отрезает `-oso_prefix`.
SWIFT_FLAGS=(-Xswiftc -file-prefix-map -Xswiftc "$ROOT=/ChromaDBManager" -Xlinker -oso_prefix -Xlinker "$ROOT/")

# Вспомогательный файл MCP-сервера: его запускает агентское приложение,
# путь к нему приложение выдаёт в готовой конфигурации, поэтому он обязан
# лежать в бандле — иначе выданная конфигурация указывает в пустоту.
PRODUCTS=(ChromaDBManager chromadb-mcp)
for product in "${PRODUCTS[@]}"; do
    echo "==> swift build -c $CONFIG --arch $ARCH --product $product"
    swift build -c "$CONFIG" --arch "$ARCH" "${SWIFT_FLAGS[@]}" --product "$product"
done

BIN_DIR="$(swift build -c "$CONFIG" --arch "$ARCH" "${SWIFT_FLAGS[@]}" --product ChromaDBManager --show-bin-path)"
BIN="$BIN_DIR/ChromaDBManager"
for product in "${PRODUCTS[@]}"; do
    if [[ ! -x "$BIN_DIR/$product" ]]; then
        echo "Build product not found at $BIN_DIR/$product" >&2
        exit 1
    fi
done

ICON="$ROOT/Resources/AppIcon.icns"
if [[ ! -f "$ICON" ]]; then
    echo "==> AppIcon.icns missing, generating it"
    swift "$ROOT/Scripts/generate-app-icon.swift"
fi

echo "==> assembling $BUNDLE"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
for product in "${PRODUCTS[@]}"; do
    cp "$BIN_DIR/$product" "$BUNDLE/Contents/MacOS/$product"
    # Архитектура проверяется, а не предполагается: архив не под тот
    # процессор не запустится у человека — молча, перечёркнутым значком.
    if [[ "$(lipo -archs "$BUNDLE/Contents/MacOS/$product")" != "$ARCH" ]]; then
        echo "!! $product собран не под $ARCH: $(lipo -archs "$BUNDLE/Contents/MacOS/$product")" >&2
        exit 1
    fi
done
echo "==> архитектура: $ARCH"
cp "$ROOT/Resources/Info.plist" "$BUNDLE/Contents/Info.plist"
cp "$ICON" "$BUNDLE/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$BUNDLE/Contents/PkgInfo"

# Скилл агента внутри бандла. Две причины держать его здесь, а не
# только в репозитории: кнопка «поставить скилл» ставит именно этот файл, и
# человек, которому кнопка не подошла, находит его руками — Contents/
# Resources/Skills/chromadb-manager/. Русский вариант лежит рядом.
SKILL_DIR="$BUNDLE/Contents/Resources/Skills/chromadb-manager"
mkdir -p "$SKILL_DIR"
cp "$ROOT/docs/hermes/chromadb-manager-SKILL.md" "$SKILL_DIR/SKILL.md"
cp "$ROOT/docs/hermes/chromadb-manager-SKILL.ru.md" "$SKILL_DIR/SKILL.ru.md"
echo "==> скилл агента: $(wc -l < "$SKILL_DIR/SKILL.md" | tr -d ' ') строк"

# Каталог текстов. Кладётся в бандл приложения, а не в ресурсы пакета:
# `String(localized:)` и надписи SwiftUI ищут в главном бандле, и это ровно
# бандл приложения — что для кода из ChromaCore, что для кода экранов.
# Значит переводы находятся сами, без единой правки в вызовах.
for lproj in "$ROOT/Resources"/*.lproj; do
    [ -d "$lproj" ] || continue
    cp -R "$lproj" "$BUNDLE/Contents/Resources/"
    name="$(basename "$lproj")"
    strings_file="$BUNDLE/Contents/Resources/$name/Localizable.strings"
    if [ -f "$strings_file" ]; then
        # plutil читает .strings как plist и падает на неверном синтаксисе:
        # опечатка в каталоге не должна доехать до собранного приложения
        # молча — там она выглядит как «часть надписей пропала».
        if ! plutil -lint "$strings_file" > /dev/null; then
            echo "!! $name/Localizable.strings не разобран — исправьте синтаксис" >&2
            exit 1
        fi
        echo "==> тексты: $name ($(grep -c '^"' "$strings_file" | tr -d ' ') строк)"
    fi
done

# H3. Метаданные App Intents. Без них Shortcuts не видит интентов вовсе:
# приложение их не объявляет, а объявляет вот этот бандл.
#
# В Xcode это отдельная фаза сборки; здесь она выполняется руками, потому
# что проект собирается SwiftPM. Xcode для неё обязателен — без него
# приложение соберётся и будет работать, но без интентов, и об этом
# говорится вслух, а не молчится.
#
# Константы извлекаются вызовом фронтенда с `-primary-file`: у драйвера
# в режиме целого модуля `-emit-const-values-path` молча не создаёт файл,
# и это стоило часа поисков.
TOOLCHAIN="$(xcode-select -p 2>/dev/null)/Toolchains/XcodeDefault.xctoolchain"
PROCESSOR="$TOOLCHAIN/usr/bin/appintentsmetadataprocessor"
PROTOCOLS="$TOOLCHAIN/usr/share/swift/SwiftConstantValues/AppIntents.json"
APP_SOURCES="$ROOT/Sources/ChromaDBManagerApp"
INTENTS_SOURCE="$APP_SOURCES/App/AppIntents.swift"

# Цель сборки — та же, что у SwiftPM выше: архитектура сборки, а не
# «arm64» из головы, и минимальная система из Info.plist (её с Package.swift
# сверяет BundleManifestTests). С прибитыми числами на Intel-маке или после
# подъёма минимальной версии модули пакета не импортировались, и приложение
# уезжало без интентов под одно лишь предупреждение.
MIN_OS="$(/usr/libexec/PlistBuddy -c 'Print LSMinimumSystemVersion' "$ROOT/Resources/Info.plist" 2>/dev/null || echo 14.0)"
TRIPLE="$ARCH-apple-macos$MIN_OS"

# Шаг — «по возможности»: не вышло — предупреждение, и сборка идёт дальше
# к подписи. Поэтому каждая команда, способная упасть, охраняется здесь
# явно: под `set -e` любая из них иначе обрывала скрипт на полпути —
# с пересобранным, но не подписанным бандлом.
intents_warning() {
    echo "warning: $1 — интентов в Shortcuts не будет" >&2
}

if [[ -x "$PROCESSOR" && -f "$PROTOCOLS" ]]; then
    echo "==> App Intents: сборка Metadata.appintents ($TRIPLE)"
    WORK="$(mktemp -d)"
    trap 'rm -rf "$WORK"' EXIT
    SDK="$(xcrun --sdk macosx --show-sdk-path 2>/dev/null || true)"
    MODULES="$(dirname "$BIN")/Modules"
    OTHER_SOURCES=()
    while IFS= read -r file; do OTHER_SOURCES+=("$file"); done \
        < <(find "$APP_SOURCES" -name '*.swift' ! -name 'AppIntents.swift')

    # Обработчику нужен список протоколов простым массивом, а в тулчейне
    # он лежит объектом с версией — перекладываем.
    if [[ -z "$SDK" ]]; then
        intents_warning "не найден SDK macOS"
    elif ! /usr/bin/python3 -c "import json,sys; json.dump(json.load(open(sys.argv[1]))['constValueProtocols'], open(sys.argv[2],'w'))" \
        "$PROTOCOLS" "$WORK/protocols.json" 2>"$WORK/python.log"; then
        intents_warning "список протоколов в тулчейне другого вида ($(head -1 "$WORK/python.log"))"
    elif ! swiftc -frontend -c -primary-file "$INTENTS_SOURCE" "${OTHER_SOURCES[@]}" \
        -module-name ChromaDBManagerApp -target "$TRIPLE" -sdk "$SDK" \
        -I "$MODULES" \
        -emit-const-values-path "$WORK/consts.swiftconstvalues" \
        -const-gather-protocols-file "$WORK/protocols.json" \
        -o "$WORK/intents.o" >"$WORK/swiftc.log" 2>&1 \
        || [[ ! -s "$WORK/consts.swiftconstvalues" ]]; then
        intents_warning "не удалось извлечь константы интентов"
        sed -n '1,5p' "$WORK/swiftc.log" >&2 || true
    else
        echo "$INTENTS_SOURCE" > "$WORK/sources.txt"
        echo "$WORK/consts.swiftconstvalues" > "$WORK/consts.txt"
        mkdir -p "$WORK/out"
        XCODE_BUILD="$( (xcodebuild -version 2>/dev/null || true) | sed -n 2p | awk '{print $3}')"
        if "$PROCESSOR" --output "$WORK/out" --toolchain-dir "$TOOLCHAIN" \
            --module-name ChromaDBManagerApp --sdk-root "$SDK" \
            --xcode-version "${XCODE_BUILD:-0}" \
            --platform-family macOS --deployment-target "$MIN_OS" \
            --target-triple "$TRIPLE" \
            --source-file-list "$WORK/sources.txt" \
            --swift-const-vals-list "$WORK/consts.txt" --force >/dev/null 2>&1 \
            && [[ -d "$WORK/out/Metadata.appintents" ]]; then
            cp -R "$WORK/out/Metadata.appintents" "$BUNDLE/Contents/Resources/"
            echo "    интентов в бандле: $(ls "$BUNDLE/Contents/Resources/Metadata.appintents" | wc -l | tr -d ' ') файла"
        else
            intents_warning "обработчик App Intents отработал вхолостую"
        fi
    fi
else
    echo "warning: Xcode не найден — приложение собрано без интентов Shortcuts" >&2
fi

echo "==> codesign (hardened runtime, ad-hoc identity)"
# Вспомогательный бинарник — своей подписью, до бандла. Компоновщик
# подписывает сам только arm64; собранный под x86_64 не подписан, а подпись
# бандла требует, чтобы всё вложенное было уже подписано: иначе «code object
# is not signed at all».
#
# Провал подписи — провал сборки: неподписанный бинарник на Apple Silicon
# не запускается, и предупреждение в конце вывода этого не спасало. А вывод
# удачной подписи («replacing existing signature») не печатается: его не ждёт
# ни человек, ни release.sh, где он выглядел предупреждением.
sign() {
    local output
    if ! output="$(codesign --force --sign - --options runtime --timestamp=none "$@" 2>&1)"; then
        echo "!! подпись не удалась: $output" >&2
        exit 1
    fi
}
sign "$BUNDLE/Contents/MacOS/chromadb-mcp"
sign --entitlements "$ROOT/Resources/ChromaDBManager.entitlements" "$BUNDLE"
codesign --verify --deep --strict "$BUNDLE"

echo "Done: $BUNDLE"
echo "Run it with:  open \"$BUNDLE\""
