#!/usr/bin/env python3
"""Считает по сохранённому прогону стенда те же числа, что показывает экран.

Экран удобнее для разметки, скрипт — для разбора и для писем: он печатает
выдачу построчно, буквой на результат, и сводку по вариантам. Порядок работы
и смысл чисел — в `docs/EVALUATION.md`.

    python3 Scripts/score-evaluation.py            # последний прогон
    python3 Scripts/score-evaluation.py latest     # то же самое
    python3 Scripts/score-evaluation.py 61F82624   # прогон по началу идентификатора
    python3 Scripts/score-evaluation.py --list     # какие прогоны есть

Разметка берётся из набора запросов, а не из прогона: эталон живёт в наборе
и работает для всех прогонов сразу. Совпадение фрагмента с текстом результата
считается так же, как в приложении, — по приведённому виду (пробелы схлопнуты,
регистр и диакритика сняты).
"""

# Аннотации не вычисляются: на системном python 3.9 «str | None» иначе падает.
from __future__ import annotations

import json
import sys
import unicodedata
from pathlib import Path

SUPPORT = Path.home() / "Library/Application Support/ChromaDBManager"
RUNS = SUPPORT / "evaluation-runs"
SETS = SUPPORT / "query-sets.json"

# Насколько «сильна» оценка: у фрагмента, совпавшего дважды, побеждает старшая.
STRENGTH = {"relevant": 2, "partial": 1, "irrelevant": 0}
SYMBOL = {"relevant": "Р", "partial": "ч", "irrelevant": "·", None: "?"}
# Ниже этой длины чанк считается коротким — та самая проверка «мера сработала?».
SHORT = 150


def normalised(text: str) -> str:
    """То же приведение, что у эталона в приложении (`QuerySet.normalised`)."""
    collapsed = " ".join((text or "").split()).lower()
    return "".join(
        c for c in unicodedata.normalize("NFD", collapsed)
        if unicodedata.category(c) != "Mn"
    )


def runs() -> list[Path]:
    return sorted(RUNS.glob("*.json"), key=lambda p: p.stat().st_mtime, reverse=True)


def pick(argument: str | None) -> Path:
    available = runs()
    if not available:
        raise SystemExit(f"прогонов нет: {RUNS}")
    if argument in (None, "latest"):
        return available[0]
    for path in available:
        if path.stem.lower().startswith(argument.lower()):
            return path
    raise SystemExit(f"прогон «{argument}» не найден; посмотрите --list")


def query_set(run: dict) -> dict:
    if not SETS.exists():
        return {"queries": []}
    data = json.loads(SETS.read_text(encoding="utf-8"))
    sets = data if isinstance(data, list) else data.get("sets", [])
    for candidate in sets:
        if candidate.get("id") == run.get("querySetID"):
            return candidate
    return {"queries": []}


def report(path: Path) -> None:
    run = json.loads(path.read_text(encoding="utf-8"))
    marks = {
        query["id"]: [
            (normalised(f["fragment"]), f.get("grade"))
            for f in query.get("fragments", []) if f.get("fragment")
        ]
        for query in query_set(run).get("queries", [])
    }
    titles = {q["id"]: q.get("text", "") for q in run.get("queries", [])}
    variants = {v["id"]: v.get("profile", {}).get("name") or v.get("name", "—")
                for v in run.get("variants", [])}

    def grade(text: str, query_id: str) -> str | None:
        document = normalised(text)
        best = None
        for fragment, value in marks.get(query_id, []):
            if fragment in document and (best is None or STRENGTH[value] > STRENGTH[best]):
                best = value
        return best

    rows: dict[tuple[str, str], list] = {}
    lengths: dict[tuple[str, str], list] = {}
    for result in run.get("results", []):
        key = (result["queryID"], result["variantID"])
        rows[key] = [grade(hit.get("text") or "", result["queryID"]) for hit in result["hits"]]
        lengths[key] = [len(hit.get("text") or "") for hit in result["hits"]]

    print(f"### {run.get('name')} — набор «{run.get('querySetName')}»")
    print(f"    {len(run.get('queries', []))} запросов, {len(variants)} вариантов, файл {path.name}\n")
    print("Р — релевантен, ч — частично, · — нерелевантен, ? — не размечено\n")

    width = max((len(name) for name in variants.values()), default=10)
    for query_id, title in titles.items():
        marked = len(marks.get(query_id, []))
        print(f"«{title}» (отметок в эталоне: {marked})")
        for variant_id, name in variants.items():
            grades = rows.get((query_id, variant_id), [])
            line = "".join(SYMBOL[g] for g in grades)
            first = next((i + 1 for i, g in enumerate(grades) if g == "relevant"), None)
            short = sum(1 for length in lengths.get((query_id, variant_id), [])[:5] if length < SHORT)
            print(f"   {name:<{width}}  {line}  первый релевантный: {first or '—':>2}  "
                  f"коротких в топ-5: {short}")
        print()

    print(f"{'вариант':<{width}} {'MRR(Р)':>7} {'hit@1':>6} {'hit@3':>6} "
          f"{'мусор@3':>8} {'коротких@5':>11} {'не размечено':>13}")
    for variant_id, name in variants.items():
        counted = mrr = hit1 = hit3 = junk = short = unknown = 0
        for query_id in titles:
            if not marks.get(query_id):
                continue  # запрос без единой отметки в счёт не идёт
            grades = rows.get((query_id, variant_id), [])
            counted += 1
            first = next((i + 1 for i, g in enumerate(grades) if g == "relevant"), None)
            mrr += 1 / first if first else 0
            hit1 += 1 if grades[:1] and grades[0] in ("relevant", "partial") else 0
            hit3 += 1 if any(g in ("relevant", "partial") for g in grades[:3]) else 0
            junk += sum(1 for g in grades[:3] if g == "irrelevant")
            short += sum(1 for length in lengths.get((query_id, variant_id), [])[:5] if length < SHORT)
            unknown += sum(1 for g in grades if g is None)
        if counted == 0:
            print(f"{name:<{width}}  — ни один запрос не размечен")
            continue
        print(f"{name:<{width}} {mrr / counted:7.3f} {hit1 / counted:6.2f} {hit3 / counted:6.2f} "
              f"{junk / counted:8.2f} {short / counted:11.2f} {unknown / counted:13.1f}")

    unmarked = [titles[q] for q in titles if not marks.get(q)]
    if unmarked:
        print(f"\nбез единой отметки и потому вне счёта: {', '.join(unmarked)}")
    print("\nСовпали ли списки двух вариантов до последнего идентификатора — "
          "значит мера не сработала, а не «не помогла» (docs/EVALUATION.md, раздел 6).")


def main() -> None:
    argument = sys.argv[1] if len(sys.argv) > 1 else None
    if argument == "--list":
        for path in runs():
            run = json.loads(path.read_text(encoding="utf-8"))
            print(f"{path.stem}  {run.get('name')}  — набор «{run.get('querySetName')}», "
                  f"вариантов {len(run.get('variants', []))}")
        return
    report(pick(argument))


if __name__ == "__main__":
    main()
