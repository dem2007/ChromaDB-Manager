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
        "6B5662D2|Основной: приставка Qwen3, без разнообразия|Сторож: только вектор|base_adaptive_geaorge_4b" \\
        "D72D226E|Опыт2: приставка|Опыт4: только вектор|base_adaptive_geaorge_4b"

Разделитель — «|», а не двоеточие: имена профилей его и содержат («Опыт:
опорный»), и первый же довод развалился бы на пять частей вместо четырёх.

Разметка берётся из текущего набора запросов, как и в `score-evaluation.py`:
эталон живёт в наборе и работает для всех прогонов сразу.
"""

# Аннотации не вычисляются: на системном python 3.9 «str | None» иначе падает.
from __future__ import annotations

import json
import re
import sys
import unicodedata
from pathlib import Path

SUPPORT = Path.home() / "Library/Application Support/ChromaDBManager"
RUNS = SUPPORT / "evaluation-runs"
SETS = SUPPORT / "query-sets.json"
STRENGTH = {"relevant": 2, "partial": 1, "irrelevant": 0}


def normalised(text: str) -> str:
    """То же приведение, что у эталона в приложении (`QuerySet.normalised`)."""
    collapsed = " ".join((text or "").split()).lower()
    return "".join(
        c for c in unicodedata.normalize("NFD", collapsed)
        if unicodedata.category(c) != "Mn"
    )


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


def query_set(run: dict) -> dict:
    if not SETS.exists():
        return {"queries": []}
    data = json.loads(SETS.read_text(encoding="utf-8"))
    sets = data if isinstance(data, list) else data.get("sets", [])
    for candidate in sets:
        if candidate.get("id") == run.get("querySetID"):
            return candidate
    return {"queries": []}


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
    run = json.loads(find_run(prefix).read_text(encoding="utf-8"))
    truth = {q["id"]: q for q in query_set(run).get("queries", [])}

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

    def grade(query: dict, hit: dict) -> str | None:
        document = normalised(hit.get("text") or "")
        best = None
        for fragment in query.get("fragments", []):
            value = fragment.get("grade")
            if not fragment.get("fragment") or value not in STRENGTH:
                continue
            if normalised(fragment["fragment"]) in document:
                if best is None or STRENGTH[value] > STRENGTH[best]:
                    best = value
        return best

    out: dict = {}
    for result in run.get("results", []):
        side = "on" if result["variantID"] == ids["on"] else (
            "off" if result["variantID"] == ids["off"] else None)
        if side is None:
            continue
        query = truth.get(result["queryID"])
        if query is None or not any(f.get("grade") != "irrelevant" for f in query.get("fragments", [])):
            continue
        rank = next((h["position"] for h in result["hits"] if grade(query, h) == "relevant"), None)
        out.setdefault(result["queryID"], {"текст": query["text"]})[side] = 1 / rank if rank else 0.0
    return {k: v for k, v in out.items() if "on" in v and "off" in v}


def main() -> None:
    specs = sys.argv[1:]
    if not specs:
        raise SystemExit(__doc__)
    # Ключ — прогон **и** коллекция: один прогон часто несёт варианты обеих
    # коллекций, и ключа по одному идентификатору не хватало — второй довод
    # молча затирал первый, а таблица выглядела правдоподобно.
    columns = {}
    for spec in specs:
        parts = spec.split("|")
        label = f"{parts[0]} · {parts[-1][:18]}" if len(parts) == 4 else parts[0]
        columns[label] = reciprocal_ranks
    for name, rows in columns.items():
        print(f"{name}: запросов {len(rows)}")
    print()

    width = max(len(name) for name, _ in RULES) + 2
    header = "".join(f"{name[-13:]:>15}" for name in columns)
    print(f"{'правило':<{width}}{header}{'всего':>10}")
    for name, rule in RULES:
        cells, pooled = [], []
        for rows in columns.values():
            values = [(v["on"] if rule(v["текст"]) else v["off"]) for v in rows.values()]
            cells.append(sum(values) / len(values) if values else 0.0)
            pooled += values
        line = "".join(f"{value:>15.3f}" for value in cells)
        print(f"{name:<{width}}{line}{sum(pooled) / len(pooled):>10.3f}")

    print("\nЗапросы, где текстовая стадия что-то решает:")
    for name, rows in columns.items():
        for row in rows.values():
            if abs(row["on"] - row["off"]) < 1e-9:
                continue
            better = "текст" if row["on"] > row["off"] else "вектор"
            print(f"   [{name}] {better:<7} {row['текст'][:60]}"
                  f"  · {word_count(row['текст'])} слов · с текстом {row['on']:.2f} / без {row['off']:.2f}")


if __name__ == "__main__":
    main()
