"""Общее для скриптов оценки: где лежат прогоны, как читается эталон, как
ставится оценка результату.

Одно место на все скрипты, и правила — те же, что у экрана
(`EvaluationMetrics`, `QuerySet`). Пока каждый скрипт держал свою копию,
копии разошлись и с приложением, и между собой: упавший поиск считался
промахом, эталон по идентификаторам не читался вовсе, а приведение текста
в одном из скриптов было другим.

Импортируется просто по имени: папка запущенного скрипта уже стоит в
`sys.path`.
"""

# Аннотации не вычисляются: на системном python 3.9 «str | None» иначе падает.
from __future__ import annotations

import json
import unicodedata
from pathlib import Path

SUPPORT = Path.home() / "Library/Application Support/ChromaDBManager"
RUNS = SUPPORT / "evaluation-runs"
SETS = SUPPORT / "query-sets.json"
# Куда скрипты пишут свои выгрузки: запросы и гипотезы — данные человека,
# им место рядом с остальными живыми замерами, вне git.
LOCAL = Path(__file__).resolve().parent.parent / "docs/local"

# Насколько «сильна» оценка: у результата, совпавшего с двумя фрагментами,
# побеждает старшая (`RelevanceGrade.gain`).
STRENGTH = {"relevant": 2, "partial": 1, "irrelevant": 0}
HIT = ("relevant", "partial")


def normalised(text: str) -> str:
    """То же приведение, что у эталона в приложении (`ExpectedFragment.normalised`):
    пробелы схлопнуты, регистр и диакритика сняты, форма — составная."""
    collapsed = " ".join((text or "").split()).lower()
    stripped = "".join(
        c for c in unicodedata.normalize("NFD", collapsed)
        if unicodedata.category(c) != "Mn"
    )
    return unicodedata.normalize("NFC", stripped)


def load(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def query_set(run: dict) -> dict | None:
    if not SETS.exists():
        return None
    data = load(SETS)
    sets = data if isinstance(data, list) else data.get("sets", [])
    return next((s for s in sets if s.get("id") == run.get("querySetID")), None)


def ground_truth(run: dict) -> dict:
    """Эталон на **сейчас**, а не на время прогона (`EvaluationMetrics.groundTruth`).

    Основа — снимок запросов в самом прогоне; поверх — нынешние запросы набора
    с теми же идентификаторами. Удалённый набор или запрос не стирает прогону
    его чисел: остаётся снимок.
    """
    truth = {query["id"]: query for query in run.get("queries", [])}
    for query in (query_set(run) or {}).get("queries", []):
        if query.get("id") in truth:
            truth[query["id"]] = query
    return truth


def fragments(query: dict) -> list:
    """Фрагменты эталона в приведённом виде; незнакомая градация отбрасывается,
    а не роняет разбор."""
    return [
        (normalised(f["fragment"]), f["grade"])
        for f in query.get("fragments", [])
        if f.get("fragment") and f.get("grade") in STRENGTH and normalised(f["fragment"])
    ]


def documents(query: dict) -> dict:
    """Эталон по идентификаторам: его пишет разметка, когда у результата нет текста."""
    result = {}
    for document in query.get("documents", []):
        if document.get("id") and document.get("grade") in STRENGTH:
            result.setdefault(document["id"], document["grade"])
    return result


def is_marked(query: dict | None) -> bool:
    return bool(query) and bool(fragments(query) or documents(query))


def is_answerable(query: dict | None) -> bool:
    """`hasRelevantGroundTruth`: в эталоне есть хоть что-то «релевантное» или «частично»."""
    if not query:
        return False
    grades = [g for _, g in fragments(query)] + list(documents(query).values())
    return any(g in HIT for g in grades)


def has_relevant(query: dict | None) -> bool:
    """Есть ли в эталоне «релевантное» — только на таких запросах MRR(Р) вообще
    может быть больше нуля."""
    if not query:
        return False
    grades = [g for _, g in fragments(query)] + list(documents(query).values())
    return "relevant" in grades


def grader(query: dict | None):
    """Оценка результата: по тексту, а если текст ни с чем не совпал — по
    идентификатору (`GradeIndex.grade`)."""
    needles = fragments(query) if query else []
    by_id = documents(query) if query else {}

    def grade(hit: dict) -> str | None:
        best = None
        if needles and hit.get("text"):
            document = normalised(hit["text"])
            for needle, value in needles:
                if needle in document and (best is None or STRENGTH[value] > STRENGTH[best]):
                    best = value
        return best if best is not None else by_id.get(hit.get("id"))

    return grade


def succeeded(result: dict) -> bool:
    """Поиск, который упал, — не «ничего не нашёл», а «не отвечал»: экран такие
    ячейки из метрик исключает (`results.filter(\\.succeeded)`)."""
    return not result.get("failure")
