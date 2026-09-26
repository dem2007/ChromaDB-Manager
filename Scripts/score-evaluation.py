#!/usr/bin/env python3
"""Считает по сохранённому прогону стенда те же числа, что показывает экран.

Экран удобнее для разметки, скрипт — для разбора и для писем: он печатает
выдачу построчно, буквой на результат, и сводку по вариантам. Порядок работы
и смысл чисел — в `docs/EVALUATION.md`.

    python3 Scripts/score-evaluation.py            # последний прогон
    python3 Scripts/score-evaluation.py latest     # то же самое
    python3 Scripts/score-evaluation.py 61F82624   # прогон по началу идентификатора
    python3 Scripts/score-evaluation.py --list     # какие прогоны есть

Эталон — как у экрана (`EvaluationMetrics.groundTruth`): нынешняя разметка
набора поверх снимка запросов в самом прогоне, так что удалённый набор не
стирает прогону его чисел. Оценка результата — по фрагменту текста, а если
ни один не совпал, по идентификатору документа. Ячейки, где поиск упал или
которых нет, в счёт не идут. Правила общие для скриптов оценки и лежат
в `evaluation_common.py`.
"""

# Аннотации не вычисляются: на системном python 3.9 «str | None» иначе падает.
from __future__ import annotations

import sys
from pathlib import Path

from evaluation_common import (
    RUNS, ground_truth, grader, has_relevant, is_answerable, is_marked, load, succeeded,
)

SYMBOL = {"relevant": "Р", "partial": "ч", "irrelevant": "·", None: "?"}
# Ниже этой длины чанк считается коротким — та самая проверка «мера сработала?».
SHORT = 150


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
            # Сравнивать есть что, только когда ответили оба: сбой одной
            # стороны — не «лучше» и не «хуже».
            if was is None or now is None:
                continue
            if now > was:
                better.append(query_id)
            elif now < was:
                worse.append(query_id)
            else:
                same += 1
        print(f"   {name}: лучше {len(better)}, хуже {len(worse)}, без изменений {same}")
        for query_id in better:
            print(f"      ↑ {titles[query_id][:64]}")
        for query_id in worse:
            print(f"      ↓ {titles[query_id][:64]}")


def report(path: Path) -> None:
    run = load(path)
    truth = ground_truth(run)
    titles = {q["id"]: q.get("text", "") for q in run.get("queries", [])}
    variants = names(run)

    # Только ячейки, где поиск ответил. Упавшая ячейка — не «ничего не
    # нашёл»: считать её промахом значило бы объявить вариант хуже там, где
    # он просто не отвечал. Ячейка, которой нет (прогон остановили), не
    # считается тем более.
    rows: dict[tuple[str, str], list] = {}
    lengths: dict[tuple[str, str], list] = {}
    failed: set[tuple[str, str]] = set()
    for result in run.get("results", []):
        key = (result["queryID"], result["variantID"])
        if not succeeded(result):
            failed.add(key)
            continue
        grade = grader(truth.get(result["queryID"]))
        rows[key] = [grade(hit) for hit in result["hits"]]
        lengths[key] = [len(hit.get("text") or "") for hit in result["hits"]]

    print(f"### {run.get('name')} — набор «{run.get('querySetName')}»")
    print(f"    {len(run.get('queries', []))} запросов, {len(variants)} вариантов, файл {path.name}\n")
    print("Р — релевантен, ч — частично, · — нерелевантен, ? — не размечено\n")

    width = max((len(name) for name in variants.values()), default=10)
    for query_id, title in titles.items():
        query = truth.get(query_id) or {}
        marked = len(query.get("fragments", [])) + len(query.get("documents", []))
        print(f"«{title}» (отметок в эталоне: {marked})")
        for variant_id, name in variants.items():
            key = (query_id, variant_id)
            if key in failed:
                print(f"   {name:<{width}}  поиск не ответил — вне счёта")
                continue
            if key not in rows:
                print(f"   {name:<{width}}  ячейки нет — вне счёта")
                continue
            grades = rows[key]
            line = "".join(SYMBOL[g] for g in grades)
            first = next((i + 1 for i, g in enumerate(grades) if g == "relevant"), None)
            short = sum(1 for length in lengths.get(key, [])[:5] if length < SHORT)
            print(f"   {name:<{width}}  {line}  первый релевантный: {first or '—':>2}  "
                  f"коротких в топ-5: {short}")
        print()

    print(f"{'вариант':<{width}} {'MRR':>6} {'MRR(Р)':>7} {'hit@1':>6} {'hit@3':>6} "
          f"{'мусор@3':>8} {'коротких@5':>11} {'не размечено':>13} {'сбоев':>6}")
    # Запрос, у которого весь эталон помечен «нерелевантен», — это вопрос,
    # ответа на который в базе нет. Такие заводятся нарочно: они проверяют,
    # умеет ли поиск отдать пустоту вместо правдоподобной ерунды. Попадание на
    # них невозможно по построению, и считать их промахом значило бы наказывать
    # поиск за разметку — приложение их из MRR и hit@k исключает, и здесь то же
    # правило. В «мусоре@3» они, наоборот, самое ценное, поэтому он по всем.
    #
    # MRR — как на экране: первое место «релевантного» или «частичного».
    # MRR(Р) — строже, только «релевантное», и по тому же правилу знаменатель —
    # только запросы, где «релевантное» в эталоне вообще есть: запрос с одними
    # «частично» не может в нём набрать ничего.
    ranks: dict = {}
    for variant_id, name in variants.items():
        counted = scored = strict = mrr = mrr_strict = hit1 = hit3 = junk = short = unknown = 0
        errors = sum(1 for key in failed if key[1] == variant_id)
        for query_id in titles:
            query = truth.get(query_id)
            key = (query_id, variant_id)
            if not is_marked(query) or key not in rows:
                continue  # запрос без отметок или без ответа в счёт не идёт
            grades = rows[key]
            counted += 1
            junk += sum(1 for g in grades[:3] if g == "irrelevant")
            short += sum(1 for length in lengths.get(key, [])[:5] if length < SHORT)
            unknown += sum(1 for g in grades if g is None)
            if is_answerable(query):
                scored += 1
                first = next((i + 1 for i, g in enumerate(grades) if g in ("relevant", "partial")), None)
                mrr += 1 / first if first else 0
                hit1 += 1 if grades[:1] and grades[0] in ("relevant", "partial") else 0
                hit3 += 1 if any(g in ("relevant", "partial") for g in grades[:3]) else 0
            if has_relevant(query):
                strict += 1
                first = next((i + 1 for i, g in enumerate(grades) if g == "relevant"), None)
                ranks[key] = 1 / first if first else 0
                mrr_strict += 1 / first if first else 0
        if counted == 0:
            print(f"{name:<{width}}  — ни один запрос не размечен (сбоев: {errors})")
            continue
        if scored == 0:
            print(f"{name:<{width}}  — ни у одного запроса нет релевантного эталона (сбоев: {errors})")
            continue
        strict_text = f"{mrr_strict / strict:7.3f}" if strict else f"{'—':>7}"
        print(f"{name:<{width}} {mrr / scored:6.3f} {strict_text} {hit1 / scored:6.2f} {hit3 / scored:6.2f} "
              f"{junk / counted:8.2f} {short / counted:11.2f} {unknown / counted:13.1f} {errors:>6}")

    if len(variants) > 1:
        pairwise(titles, variants, ranks, next(iter(variants)))

    unmarked = [titles[q] for q in titles if not is_marked(truth.get(q))]
    if unmarked:
        print(f"\nбез единой отметки и потому вне счёта: {', '.join(unmarked)}")
    noanswer = [titles[q] for q in titles if is_marked(truth.get(q)) and not is_answerable(truth.get(q))]
    if noanswer:
        print(f"\nответа в базе нет — вне MRR и hit@k, но в «мусоре@3»: {', '.join(noanswer)}")
    partial_only = [titles[q] for q in titles if is_answerable(truth.get(q)) and not has_relevant(truth.get(q))]
    if partial_only:
        print(f"\nв эталоне только «частично» — вне MRR(Р) и счёта по запросам: {', '.join(partial_only)}")
    print("\nСовпали ли списки двух вариантов до последнего идентификатора — "
          "значит мера не сработала, а не «не помогла» (docs/EVALUATION.md, раздел 6).")


def main() -> None:
    argument = sys.argv[1] if len(sys.argv) > 1 else None
    if argument == "--list":
        for path in runs():
            run = load(path)
            print(f"{path.stem}  {run.get('name')}  — набор «{run.get('querySetName')}», "
                  f"вариантов {len(run.get('variants', []))}")
        return
    report(pick(argument))


if __name__ == "__main__":
    main()
