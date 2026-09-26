#!/usr/bin/env python3
"""Сравнивает правила «когда включать текстовую стадию» по сохранённым прогонам.

Прогон нужен, когда меняется **выдача**. Правило выбора между двумя уже
измеренными выдачами прогона не требует вовсе: в прогонах записано, чем каждый
запрос кончился с текстовой стадией и без неё, и правило только выбирает из
двух известных ответов. Так гипотеза «редкий токен» была отвергнута за минуту,
до первой строки кода.

Каждый довод — пара «прогон, вариант с текстовой стадией, вариант без неё,
коллекция»:

    python3 Scripts/compare-text-stage-rules.py \\
        "6B5662D2|Основной: приставка Qwen3, без разнообразия|Сторож: только вектор|base_docs_4b" \\
        "D72D226E|Опыт2: приставка|Опыт4: только вектор|base_docs_4b"

Разделитель — «|», а не двоеточие: имена профилей его и содержат («Опыт:
опорный»), и первый же довод развалился бы на пять частей вместо четырёх.

Эталон и оценка — те же, что у `score-evaluation.py` и у экрана
(`evaluation_common.py`): ячейки, где поиск упал, в счёт не идут.
"""

# Аннотации не вычисляются: на системном python 3.9 «str | None» иначе падает.
from __future__ import annotations

import re
import sys
from pathlib import Path

from evaluation_common import RUNS, ground_truth, grader, has_relevant, load, succeeded


def words(text: str) -> list:
    return [w.strip(".,;:!?«»()—-") for w in text.split()]


def word_count(text: str) -> int:
    """Как считает приложение (`SearchProfile.wordCount`): пунктуация не слово."""
    return len([w for w in words(text) if any(c.isalnum() for c in w)])


def has_latin(text: str) -> bool:
    return any(re.fullmatch(r"[A-Za-z][A-Za-z0-9\-]*", w) for w in words(text))


def has_caps(text: str) -> bool:
    return any(len(w) >= 2 and w.isupper() and any(c.isalpha() for c in w) for w in words(text))


def has_code(text: str) -> bool:
    return any(re.search(r"[A-Za-zА-Яа-я]-?\d", w) for w in words(text))


# Правила, которые уже проверялись. Новое дописывается сюда одной строкой —
# в этом и смысл: правило проверяется счётом, а не прогоном.
RULES = [
    ("текста нет", lambda t: False),
    ("текст всегда", lambda t: True),
    ("длина ≤ 3", lambda t: word_count(t) <= 3),
    ("длина ≤ 5", lambda t: word_count(t) <= 5),
    ("длина ≤ 7", lambda t: word_count(t) <= 7),
    ("латиница", has_latin),
    ("заглавная аббревиатура", has_caps),
    ("редкий токен", lambda t: has_latin(t) or has_caps(t) or has_code(t)),
]


def find_run(prefix: str) -> Path:
    for path in sorted(RUNS.glob("*.json")):
        if path.stem.lower().startswith(prefix.lower()):
            return path
    raise SystemExit(f"прогон «{prefix}» не найден")


def reciprocal_ranks(spec: str) -> dict:
    """Для каждого запроса: место первого релевантного с текстовой стадией и без.

    Запрос, у которого весь эталон помечен «нерелевантен», в счёт не идёт —
    попасть в него нельзя по построению (см. `score-evaluation.py`).
    """
    parts = spec.split("|")
    if len(parts) != 4:
        raise SystemExit(f"довод «{spec}»: нужно «прогон|вариант_с_текстом|вариант_без|коллекция»")
    prefix, on_name, off_name, collection = parts
    run = load(find_run(prefix))
    truth = ground_truth(run)

    ids = {}
    for variant in run.get("variants", []):
        profile = variant.get("profile", {})
        if profile.get("collectionName") != collection:
            continue
        if profile.get("name") == on_name:
            ids["on"] = variant["id"]
        if profile.get("name") == off_name:
            ids["off"] = variant["id"]
    for side, name in (("on", on_name), ("off", off_name)):
        if side not in ids:
            raise SystemExit(f"в прогоне {prefix} нет варианта «{name}» на коллекции {collection}")

    out: dict = {}
    for result in run.get("results", []):
        side = "on" if result["variantID"] == ids["on"] else (
            "off" if result["variantID"] == ids["off"] else None)
        if side is None or not succeeded(result):
            continue
        query = truth.get(result["queryID"])
        # Только запросы с «релевантным» в эталоне: ранг здесь — первого
        # «релевантного», и запрос с одними «частично» набрать не может ничего.
        if not has_relevant(query):
            continue
        grade = grader(query)
        rank = next((h["position"] for h in result["hits"] if grade(h) == "relevant"), None)
        out.setdefault(result["queryID"], {"текст": query.get("text", "")})[side] = 1 / rank if rank else 0.0
    return {k: v for k, v in out.items() if "on" in v and "off" in v}


def main() -> None:
    specs = sys.argv[1:]
    if not specs:
        raise SystemExit(__doc__)
    # Столбец — это довод целиком, а подпись у него — номер. Ключ из прогона
    # и обрезанного имени коллекции затирал второй довод первым, стоило им
    # отличаться только вариантами или хвостом имени, — и таблица выглядела
    # правдоподобно. Повтор одного и того же довода — тот же столбец.
    columns: dict = {}
    for spec in specs:
        if spec not in columns:
            columns[spec] = reciprocal_ranks(spec)
    labels = {spec: f"#{number}" for number, spec in enumerate(columns, start=1)}
    for spec, rows in columns.items():
        print(f"{labels[spec]}: {spec} — запросов {len(rows)}")
    print()
    if not any(columns.values()):
        raise SystemExit("ни в одном доводе нет запроса с «релевантным» в эталоне — считать нечего")

    width = max(len(name) for name, _ in RULES) + 2
    header = "".join(f"{labels[spec]:>10}" for spec in columns)
    print(f"{'правило':<{width}}{header}{'всего':>10}")
    for name, rule in RULES:
        cells, pooled = [], []
        for rows in columns.values():
            values = [(v["on"] if rule(v["текст"]) else v["off"]) for v in rows.values()]
            cells.append(f"{sum(values) / len(values):>10.3f}" if values else f"{'—':>10}")
            pooled += values
        print(f"{name:<{width}}{''.join(cells)}{sum(pooled) / len(pooled):>10.3f}")

    print("\nЗапросы, где текстовая стадия что-то решает:")
    for spec, rows in columns.items():
        for row in rows.values():
            if abs(row["on"] - row["off"]) < 1e-9:
                continue
            better = "текст" if row["on"] > row["off"] else "вектор"
            print(f"   [{labels[spec]}] {better:<7} {row['текст'][:60]}"
                  f"  · {word_count(row['текст'])} слов · с текстом {row['on']:.2f} / без {row['off']:.2f}")


if __name__ == "__main__":
    main()
