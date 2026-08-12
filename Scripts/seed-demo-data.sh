#!/bin/bash
# Fills a running ChromaDB with a small DEMO collection over the HTTP API v2.
#
# This exists so the app can be tested against data it did not create itself —
# the common real-world case of "I already have a database, show me what's in
# it". The collection carries no _cdbm_* metadata on purpose, so the app treats
# it as a foreign collection and asks you to bind a model by hand.
#
# The vectors are deterministic pseudo-random numbers, not real embeddings:
# nothing here needs LM Studio. Pick a dimension that matches the embedding
# model you intend to bind later (nomic-embed-text → 768, MiniLM → 384),
# otherwise the app will refuse the binding — which is also worth seeing once.
#
# Usage:
#   Scripts/seed-demo-data.sh [--host localhost] [--port 8000] \
#       [--collection cdbm_demo] [--dim 768] [--tenant default_tenant] \
#       [--database default_database] [--token TOKEN]

set -euo pipefail

HOST="localhost"
PORT="8000"
COLLECTION="cdbm_demo"
DIM="768"
TENANT="default_tenant"
DATABASE="default_database"
TOKEN=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --host) HOST="$2"; shift 2 ;;
        --port) PORT="$2"; shift 2 ;;
        --collection) COLLECTION="$2"; shift 2 ;;
        --dim) DIM="$2"; shift 2 ;;
        --tenant) TENANT="$2"; shift 2 ;;
        --database) DATABASE="$2"; shift 2 ;;
        --token) TOKEN="$2"; shift 2 ;;
        -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

BASE="http://${HOST}:${PORT}/api/v2"
COLLECTIONS="${BASE}/tenants/${TENANT}/databases/${DATABASE}/collections"
# A helper instead of an array: macOS still ships bash 3.2, where expanding an
# empty array under `set -u` is an error.
curl_api() {
    if [[ -n "$TOKEN" ]]; then
        curl -H "Authorization: Bearer ${TOKEN}" "$@"
    else
        curl "$@"
    fi
}

echo "==> checking ${BASE}/healthcheck"
if ! curl_api -fsS "${BASE}/healthcheck" >/dev/null; then
    echo "ChromaDB is not answering at ${BASE}." >&2
    echo "Start it first, e.g.: chroma run --path ./demo-db --host ${HOST} --port ${PORT}" >&2
    exit 1
fi

echo "==> creating collection ${COLLECTION} (demo)"
CREATE_RESPONSE=$(curl_api -fsS -X POST "${COLLECTIONS}" \
    -H 'Content-Type: application/json' \
    -d "{\"name\":\"${COLLECTION}\",\"get_or_create\":true,\"metadata\":{\"demo\":true,\"created_by\":\"seed-demo-data.sh\"}}")

COLLECTION_ID=$(printf '%s' "$CREATE_RESPONSE" | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')
echo "    id: ${COLLECTION_ID}"

echo "==> building ${DIM}-dimensional demo vectors"
PAYLOAD=$(DIM="$DIM" python3 <<'PY'
import json, math, os

dim = int(os.environ["DIM"])

documents = [
    ("demo-1", "ChromaDB хранит документы вместе с их векторными представлениями.",
     {"topic": "chromadb", "language": "ru", "source": "demo"}),
    ("demo-2", "Векторный поиск находит документы по смыслу, а не по точному совпадению слов.",
     {"topic": "search", "language": "ru", "source": "demo"}),
    ("demo-3", "Эмбеддинги, посчитанные разными моделями, несравнимы между собой.",
     {"topic": "embeddings", "language": "ru", "source": "demo"}),
    ("demo-4", "A collection fixes its vector dimension with the very first record.",
     {"topic": "chromadb", "language": "en", "source": "demo"}),
    ("demo-5", "Metadata values may only be strings, numbers or booleans.",
     {"topic": "metadata", "language": "en", "source": "demo"}),
]

def vector(seed: int) -> list:
    # Deterministic, smooth, and unit-ish: good enough to make nearest-neighbour
    # results stable and reproducible across machines.
    values = [math.sin((seed + 1) * 0.7 + i * 0.013) for i in range(dim)]
    norm = math.sqrt(sum(v * v for v in values)) or 1.0
    return [round(v / norm, 6) for v in values]

print(json.dumps({
    "ids": [d[0] for d in documents],
    "documents": [d[1] for d in documents],
    "metadatas": [d[2] for d in documents],
    "embeddings": [vector(i) for i in range(len(documents))],
}))
PY
)

echo "==> upserting ${COLLECTION}"
printf '%s' "$PAYLOAD" | curl_api -fsS -X POST "${COLLECTIONS}/${COLLECTION_ID}/upsert" \
    -H 'Content-Type: application/json' --data-binary @- >/dev/null

COUNT=$(curl_api -fsS "${COLLECTIONS}/${COLLECTION_ID}/count")
echo
echo "Done. Collection '${COLLECTION}' now holds ${COUNT} demo documents (dimension ${DIM})."
echo "In the app: open the collection, press «Указать модель» and pick a ${DIM}-dimensional model."
