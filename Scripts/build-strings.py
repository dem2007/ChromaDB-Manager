#!/usr/bin/env python3
"""Собирает каталог текстов приложения — `Resources/ru.lproj/Localizable.strings`.

Ключи берутся **у компилятора**, а не разбором исходников: `String(localized:)`
и надписи SwiftUI превращаются в ключ не буквально. Интерполяция `\\(count)`
становится `%lld`, `\\(name)` — `%@`, и угадывать это по тексту значит
регулярно промахиваться там, где промах незаметен: строка просто не найдётся
в каталоге и останется английской… то есть русской, как написано в коде.
Поэтому сборка идёт с флагом `-emit-localized-strings`, а мы читаем то, что
он положил.

**Правки человека сохраняются.** Скрипт не переписывает файл с нуля: он
читает существующий, оставляет все переводы как есть, добавляет новые ключи
со значением, равным ключу, и — главное — **не выбрасывает** пропавшие.
Строка, исчезнувшая из кода, уезжает в конец файла, в раздел «этих строк
в коде больше нет»: удалить чужую правку молча нельзя (правило 1), а решить,
что с ней делать, может только человек.

    python3 Scripts/build-strings.py            # обновить каталог
    python3 Scripts/build-strings.py --check    # только сказать, что изменится
"""

import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CATALOGUE = ROOT / "Resources" / "ru.lproj" / "Localizable.strings"
RETIRED_HEADER = "// ─── этих строк в коде больше нет ───"


# Своя папка сборки и постоянный путь выгрузки. Сборка в общей `.build`
# с флагами, которых там нет, и с новым путём каждый раз перекомпилировала
# весь пакет — и следующий обычный `swift build` перекомпилировал его ещё
# раз, потому что флаги вернулись обратно.
SCRATCH = ROOT / ".build" / "strings"
OUTPUT = SCRATCH / "localized"


def extract() -> dict[str, list[tuple[str, int]]]:
    """Ключ → где он встречается (файл относительно корня, строка)."""
    OUTPUT.mkdir(parents=True, exist_ok=True)
    build = subprocess.run(
        [
            "swift", "build", "--scratch-path", str(SCRATCH),
            "-Xswiftc", "-emit-localized-strings",
            "-Xswiftc", "-emit-localized-strings-path",
            "-Xswiftc", str(OUTPUT),
        ],
        cwd=ROOT, capture_output=True, text=True,
    )
    if build.returncode != 0:
        sys.stderr.write(build.stderr[-2000:])
        raise SystemExit("сборка не прошла — каталог не собран")

    found: dict[str, list[tuple[str, int]]] = {}
    for path in sorted(OUTPUT.glob("*.stringsdata")):
        data = json.loads(path.read_text(encoding="utf-8"))
        source = data.get("source", "")
        # Выгрузка копится между запусками: сборка пересобирает только
        # изменённое, и выгрузка остальных файлов нужна как есть. Файл,
        # которого больше нет, оставил бы свои строки навсегда.
        if source and not Path(source).exists():
            continue
        try:
            source = str(Path(source).relative_to(ROOT))
        except ValueError:
            pass
        for entry in data.get("tables", {}).get("Localizable", []):
            key = entry["key"]
            # Пустые и пробельные ключи — это `Text("")` и разделители
            # вроде «\n». Переводить в них нечего, а в каталоге они только
            # мешают глазу.
            if not key.strip():
                continue
            line = entry.get("location", {}).get("startingLine", 0)
            found.setdefault(key, []).append((source, line))
    return found


def escape(text: str) -> str:
    return text.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


def read_existing() -> dict[str, str]:
    """Переводы из каталога — разобранные тем же `plutil`, что проверяет файл.

    Не построчным образцом: законная запись бывает и с комментарием в конце
    строки, и со значением на две строки, и образец такие просто не узнавал —
    а `render` затем переписывал перевод человека ключом. Раз «правки
    сохраняются», файл, который не разобрался, не перезаписывается вовсе.
    """
    if not CATALOGUE.exists():
        return {}
    parsed = subprocess.run(
        ["plutil", "-convert", "json", "-o", "-", str(CATALOGUE)],
        capture_output=True, text=True,
    )
    if parsed.returncode != 0:
        sys.stderr.write(parsed.stderr)
        raise SystemExit(f"{CATALOGUE.relative_to(ROOT)} не разобран — исправьте синтаксис, файл не тронут")
    data = json.loads(parsed.stdout)
    return {str(key): str(value) for key, value in data.items()}


def render(found: dict[str, list[tuple[str, int]]], existing: dict[str, str]) -> str:
    # Группируем по исходному файлу: текст правят экранами, а не по алфавиту.
    by_file: dict[str, list[tuple[int, str]]] = {}
    for key, places in found.items():
        source, line = sorted(places)[0]
        by_file.setdefault(source, []).append((line, key))

    lines = [
        "/* Тексты приложения — все в одном месте.",
        "",
        "   Слева — как строка написана в коде: это ключ, по нему приложение",
        "   и ищет текст. Справа — то, что видит человек. Меняйте правую",
        "   часть; левую не трогайте, иначе строка перестанет находиться.",
        "",
        "   %@ — подставляемый текст, %lld — целое число, %lf — дробное.",
        "   Их надо сохранить: без них подстановка потеряется.",
        "",
        "   Файл собирается командой:",
        "       python3 Scripts/build-strings.py",
        "   Она сохраняет ваши правки и только добавляет новые строки.",
        "",
        f"   Строк: {len(found)}",
        "*/",
        "",
    ]

    for source in sorted(by_file):
        lines.append(f"/* ── {source} ── */")
        seen: set[str] = set()
        for _, key in sorted(by_file[source]):
            if key in seen:
                continue
            seen.add(key)
            value = existing.get(key, key)
            lines.append(f'"{escape(key)}" = "{escape(value)}";')
        lines.append("")

    retired = {k: v for k, v in existing.items() if k not in found}
    if retired:
        lines += [
            RETIRED_HEADER,
            "// Строка исчезла из кода, а правка осталась. Ничего не удалено",
            "// автоматически: решите сами — убрать её отсюда или вернуть текст",
            "// в приложение.",
            "",
        ]
        for key in sorted(retired):
            lines.append(f'"{escape(key)}" = "{escape(retired[key])}";')
        lines.append("")

    return "\n".join(lines)


def main() -> int:
    check_only = "--check" in sys.argv
    found = extract()
    existing = read_existing()
    text = render(found, existing)

    added = sorted(k for k in found if k not in existing)
    retired = sorted(k for k in existing if k not in found)
    print(f"строк в коде: {len(found)}")
    print(f"новых: {len(added)}")
    print(f"исчезло из кода: {len(retired)}")
    for key in added[:5]:
        print(f"  + {key[:70]}")
    for key in retired[:5]:
        print(f"  − {key[:70]}")

    if check_only:
        # Отказ — только на **новых**: строка есть в коде, а в каталоге её нет,
        # и англоязычный человек увидит русскую фразу. Это дефект.
        #
        # «Исчезло из кода» — не дефект: такие ключи `render` в файле
        # оставляет, они никому не мешают, и их в каталоге накопилось под три
        # сотни. Роняя проверку и на них, её нельзя было бы включить сторожем
        # ни в один прогон — а без сторожа она и осталась ручной, из-за чего
        # пять строк ветки и уехали без перевода.
        if added:
            print(
                "каталог отстал от кода: запустите python3 Scripts/build-strings.py"
                " и допишите английский в Resources/en.lproj/Localizable.strings"
            )
            return 1
        return 0

    CATALOGUE.parent.mkdir(parents=True, exist_ok=True)
    CATALOGUE.write_text(text, encoding="utf-8")
    print(f"записано: {CATALOGUE.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
