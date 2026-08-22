#!/usr/bin/env python3
"""Проверка HyDE (предложение E7) без единой строки в приложении.

Считает то же, что считала бы стадия 0: просит у чат-модели гипотетический
абзац-ответ, берёт с него вектор, ищет вторым списком и сливает с обычным
через RRF — ровно как требует E7.3. Оценка — по тому же эталону, что у стенда.

**Это не стенд.** Здесь чистый векторный поиск, без штрафа за длину,
текстовой стадии и пометок: сравнивать эти числа с числами прогонов нельзя.
Сравнивать между собой — можно: обе стороны идут по одному пути и отличаются
только гипотезой.

Запуск требует поднятой ChromaDB (`CHROMA` ниже) и LM Studio. Приложение при
этом закрыто, поэтому сервер поднимается отдельно:

    "$HOME/Library/Application Support/ChromaDBManager/bin/chroma" run probe.yaml
    python3 Scripts/measure-hyde.py

Результат замера 21 августа 2026: +0.041 на двенадцати запросах, 8.8 с
медианы на вызов чат-модели. Подробности —.
"""
import json, os, time, unicodedata, urllib.request, sqlite3, sys

SUPPORT = os.path.expanduser('~/Library/Application Support/ChromaDBManager')
CHROMA = "http://127.0.0.1:51987"
LMS = "http://127.0.0.1:1234"
EMBED_MODEL = "text-embedding-qwen3-embedding-4b"
CHAT_MODEL = "qwen/qwen3-4b"
COLLECTION = "base_adaptive_geaorge_4b"
SET_NAME = "База: проверка порога"
PREFIX = "Instruct: Given a web search query, retrieve relevant passages that answer the query\nQuery: "
POOL = 20          # сколько кандидатов берём в каждый список
RRF_K = 60         # та же константа, что в профиле
TARGET_CHARS = 967 # медианная длина чанка этой коллекции

def post(url, body, timeout=300):
    req = urllib.request.Request(url, data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.load(r)

def norm(t):
    t = " ".join((t or "").split()).lower()
    return "".join(c for c in unicodedata.normalize("NFD", t) if not unicodedata.combining(c))

cid = sqlite3.connect(f"file:{os.path.join(SUPPORT,'chroma_data/chroma.sqlite3')}?mode=ro", uri=True)\
    .execute("SELECT id FROM collections WHERE name=?", (COLLECTION,)).fetchone()[0]

def embed(text):
    return post(f"{LMS}/v1/embeddings", {"model": EMBED_MODEL, "input": text})["data"][0]["embedding"]

def search(vector, n=POOL):
    answer = post(f"{CHROMA}/api/v2/tenants/default_tenant/databases/default_database/collections/{cid}/query",
                  {"query_embeddings": [vector], "n_results": n, "include": ["documents"]})
    return list(zip(answer["ids"][0], answer["documents"][0]))

def hypothesis(query):
    """Промпт по E7.6: один абзац, язык запроса, длина под чанки коллекции."""
    prompt = (
        f"Ты пишешь фрагмент документа по теме запроса. Напиши один связный абзац "
        f"примерно на {TARGET_CHARS} знаков, как он выглядел бы в техническом задании "
        f"или договоре на русском языке. Без преамбулы, без списка, без оговорок о том, "
        f"что это предположение. Только текст абзаца.\n\nЗапрос: {query}"
    )
    answer = post(f"{LMS}/v1/chat/completions", {
        "model": CHAT_MODEL, "messages": [{"role": "user", "content": prompt}],
        "temperature": 0, "seed": 20260821, "max_tokens": 700,
    })
    text = answer["choices"][0]["message"]["content"]
    # Модель может думать вслух: берём то, что после блока рассуждений.
    if "</think>" in text:
        text = text.split("</think>", 1)[1]
    return " ".join(text.split())

def rrf(*lists):
    score = {}
    keep = {}
    for lst in lists:
        for position, (doc_id, text) in enumerate(lst, start=1):
            score[doc_id] = score.get(doc_id, 0.0) + 1.0 / (RRF_K + position)
            keep[doc_id] = text
    order = sorted(score, key=lambda d: -score[d])
    return [(d, keep[d]) for d in order]

sets = json.load(open(os.path.join(SUPPORT, 'query-sets.json'), encoding='utf-8'))
queries = next(s for s in sets if s['name'] == SET_NAME)['queries']
S = {"relevant": 2, "partial": 1, "irrelevant": 0}

def first_relevant(query, hits):
    for position, (_, text) in enumerate(hits[:10], start=1):
        doc = norm(text)
        for f in query.get('fragments', []):
            if f['grade'] == 'relevant' and f['fragment'] and norm(f['fragment']) in doc:
                return position
    return None

rows = []
for q in queries:
    if not any(f['grade'] == 'relevant' for f in q['fragments']):
        continue  # вечный ноль у всех вариантов — из счёта вон
    base = search(embed(PREFIX + q['text']))
    started = time.time()
    hypo = hypothesis(q['text'])
    chat_seconds = time.time() - started
    as_query = search(embed(PREFIX + hypo))
    as_passage = search(embed(hypo))
    rows.append({
        "текст": q['text'],
        "слов": len([w for w in q['text'].split() if any(c.isalnum() for c in w)]),
        "гипотеза": hypo,
        "секунд": chat_seconds,
        "опорный": first_relevant(q, base),
        "HyDE (с приставкой)": first_relevant(q, rrf(base, as_query)),
        "HyDE (без приставки)": first_relevant(q, rrf(base, as_passage)),
        "одна гипотеза": first_relevant(q, as_passage),
    })
    print(".", end="", flush=True)
print()
json.dump(rows, open("hyde-rows.json", "w"), ensure_ascii=False, indent=1)

def mrr(key, subset=None):
    use = [r for r in rows if subset is None or subset(r)]
    return sum(1 / r[key] if r[key] else 0 for r in use) / max(1, len(use))

print("\nзапросов в счёте: %d, чат-модель: %s, медиана вызова %.1f с"
      % (len(rows), CHAT_MODEL, sorted(r["секунд"] for r in rows)[len(rows)//2]))
print("\n%-24s %8s %8s %8s" % ("вариант", "все", "≤2 слов", "≥6 слов"))
for key in ["опорный", "HyDE (с приставкой)", "HyDE (без приставки)", "одна гипотеза"]:
    print("%-24s %8.3f %8.3f %8.3f" % (
        key, mrr(key), mrr(key, lambda r: r["слов"] <= 2), mrr(key, lambda r: r["слов"] >= 6)))
