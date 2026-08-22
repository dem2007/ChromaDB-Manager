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


def names(run: dict) -> dict:
    """Имя варианта — такое, чтобы два варианта нельзя было перепутать.

    Один и тот же профиль часто гоняется по двум коллекциям: «нарезка» — это
    как раз такой опыт. В отчёте оба варианта звались одинаково, и две строки
    сводки отличались только числами — прочитать, какая из них чья, было
    нельзя. Коллекция дописывается **только** к повторяющимся именам: у
    остальных она в имени лишняя.
    """
    plain = {}
    for variant in run.get("variants", []):
        plain[variant["id"]] = variant.get("profile", {}).get("name") or variant.get("name", "—")
    seen = {}
    for name in plain.values():
        seen[name] = seen.get(name, 0) + 1
    result = {}
    for variant in run.get("variants", []):
        name = plain[variant["id"]]
        if seen[name] > 1:
            collection = variant.get("profile", {}).get("collectionName", "")
            name = f"{name} · {collection}" if collection else name
        result[variant["id"]] = name
    return result


def pairwise(titles: dict, variants: dict, ranks: dict, base_id: str) -> None:
    """Счёт по запросам: сколько улучшилось, сколько ухудшилось.

    Среднее на восемнадцати запросах двигает **один** запрос, съехавший с
    первого места на второе: разница в 0.04 MRR и есть такой запрос. Поэтому
    после сводки всегда смотрится счёт — рычаг, который поднял четыре запроса
    и уронил один, и рычаг, который поднял один, дают одинаковое среднее и
    разные основания ему верить.
    """
    print(f"\nСчёт по запросам против «{variants[base_id]}»")
    for variant_id, name in variants.items():
        if variant_id == base_id:
            continue
        better, worse, same = [], [], 0
        for query_id in titles:
            was = ranks.get((query_id, base_id))
            now = ranks.get((query_id, variant_id))
            if was is None and now is None:
                continue
            if (now or 0) > (was or 0):
                better.append(query_id)
            elif (now or 0) < (was or 0):
                worse.append(query_id)
            else:
                same += 1
        print(f"   {name}: лучше {len(better)}, хуже {len(worse)}, без изменений {same}")
        for query_id in better:
            print(f"      ↑ {titles[query_id][:64]}")
        for query_id in worse:
            print(f"      ↓ {titles[query_id][:64]}")


def report(path: Path) -> None:
    run = json.loads(path.read_text(encoding="utf-8"))
    marks = {
        # Отметка с незнакомой градацией отбрасывается, а не роняет разбор:
        # иначе один странный фрагмент уносит с собой весь отчёт по прогону.
        query["id"]: [
            (normalised(f["fragment"]), f.get("grade"))
            for f in query.get("fragments", [])
            if f.get("fragment") and f.get("grade") in STRENGTH
        ]
        for query in query_set(run).get("queries", [])
    }
    titles = {q["id"]: q.get("text", "") for q in run.get("queries", [])}
    variants = names(run)

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
    # Запрос, у которого весь эталон помечен «нерелевантен», — это вопрос,
    # ответа на который в базе нет. Такие заводятся нарочно: они проверяют,
    # умеет ли поиск отдать пустоту вместо правдоподобной ерунды. Попадание на
    # них невозможно по построению, и считать их промахом значило бы наказывать
    # поиск за разметку — приложение их из MRR и hit@k исключает, и здесь то же
    # правило. В «мусоре@3» они, наоборот, самое ценное, поэтому он по всем.
    answerable = {
        query_id for query_id, fragments in marks.items()
        if any(grade != "irrelevant" for _, grade in fragments)
    }
    # Вклад каждого запроса — он же и есть материал для счёта «лучше/хуже».
    ranks: dict = {}
    for variant_id, name in variants.items():
        counted = scored = mrr = hit1 = hit3 = junk = short = unknown = 0
        for query_id in titles:
            if not marks.get(query_id):
                continue  # запрос без единой отметки в счёт не идёт
            grades = rows.get((query_id, variant_id), [])
            counted += 1
            junk += sum(1 for g in grades[:3] if g == "irrelevant")
            short += sum(1 for length in lengths.get((query_id, variant_id), [])[:5] if length < SHORT)
            unknown += sum(1 for g in grades if g is None)
            if query_id not in answerable:
                continue
            scored += 1
            first = next((i + 1 for i, g in enumerate(grades) if g == "relevant"), None)
            ranks[(query_id, variant_id)] = 1 / first if first else 0
            mrr += 1 / first if first else 0
            hit1 += 1 if grades[:1] and grades[0] in ("relevant", "partial") else 0
            hit3 += 1 if any(g in ("relevant", "partial") for g in grades[:3]) else 0
        if counted == 0:
            print(f"{name:<{width}}  — ни один запрос не размечен")
            continue
        if scored == 0:
            print(f"{name:<{width}}  — ни у одного запроса нет релевантного эталона")
            continue
        print(f"{name:<{width}} {mrr / scored:7.3f} {hit1 / scored:6.2f} {hit3 / scored:6.2f} "
              f"{junk / counted:8.2f} {short / counted:11.2f} {unknown / counted:13.1f}")

    if len(variants) > 1:
        pairwise(titles, variants, ranks, next(iter(variants)))

    unmarked = [titles[q] for q in titles if not marks.get(q)]
    if unmarked:
        print(f"\nбез единой отметки и потому вне счёта: {', '.join(unmarked)}")
    noanswer = [titles[q] for q in titles if marks.get(q) and q not in answerable]
    if noanswer:
        print(f"\nответа в базе нет — вне MRR и hit@k, но в «мусоре@3»: {', '.join(noanswer)}")
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
