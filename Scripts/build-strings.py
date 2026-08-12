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
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CATALOGUE = ROOT / "Resources" / "ru.lproj" / "Localizable.strings"
RETIRED_HEADER = "// ─── этих строк в коде больше нет ───"


def extract() -> dict[str, list[tuple[str, int]]]:
    """Ключ → где он встречается (файл относительно корня, строка)."""
    output = Path(tempfile.mkdtemp(prefix="cdbm-strings-"))
    try:
        build = subprocess.run(
            [
                "swift", "build",
                "-Xswiftc", "-emit-localized-strings",
                "-Xswiftc", "-emit-localized-strings-path",
                "-Xswiftc", str(output),
            ],
            cwd=ROOT, capture_output=True, text=True,
        )
        if build.returncode != 0:
            sys.stderr.write(build.stderr[-2000:])
            raise SystemExit("сборка не прошла — каталог не собран")

        found: dict[str, list[tuple[str, int]]] = {}
        for path in sorted(output.glob("*.stringsdata")):
            data = json.loads(path.read_text(encoding="utf-8"))
            source = data.get("source", "")
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
    finally:
        shutil.rmtree(output, ignore_errors=True)


def escape(text: str) -> str:
    return text.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


def unescape(text: str) -> str:
    out, index = [], 0
    while index < len(text):
        char = text[index]
        if char == "\\" and index + 1 < len(text):
            nxt = text[index + 1]
            out.append({"n": "\n", "t": "\t", '"': '"', "\\": "\\"}.get(nxt, nxt))
            index += 2
        else:
            out.append(char)
            index += 1
    return "".join(out)


LINE = re.compile(r'^\s*"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;\s*$')


def read_existing() -> dict[str, str]:
    if not CATALOGUE.exists():
        return {}
    translations: dict[str, str] = {}
    for raw in CATALOGUE.read_text(encoding="utf-8").splitlines():
        match = LINE.match(raw)
        if match:
            translations[unescape(match.group(1))] = unescape(match.group(2))
    return translations


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
        return 1 if (added or retired) else 0

    CATALOGUE.parent.mkdir(parents=True, exist_ok=True)
    CATALOGUE.write_text(text, encoding="utf-8")
    print(f"записано: {CATALOGUE.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
