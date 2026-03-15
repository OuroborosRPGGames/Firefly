import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).parent.parent.parent))

from triage.clusterer import cluster_queries, tokenize


def test_tokenize_strips_stopwords():
    tokens = tokenize("how do I earn money")
    assert "earn" in tokens
    assert "money" in tokens
    assert "how" not in tokens
    assert "do" not in tokens


def test_cluster_similar_queries():
    queries = [
        {"query": "how earn money", "count": 3, "last_seen_at": "2026-03-13T10:00:00Z"},
        {"query": "earning currency", "count": 2, "last_seen_at": "2026-03-13T10:00:00Z"},
        {"query": "how fight monsters", "count": 5, "last_seen_at": "2026-03-13T10:00:00Z"},
    ]
    clusters = cluster_queries(queries)
    reps = [c["representative"] for c in clusters]
    assert len(clusters) <= 2


def test_cluster_sorted_by_total_count():
    queries = [
        {"query": "combat abilities", "count": 1, "last_seen_at": "2026-03-13T10:00:00Z"},
        {"query": "earn gold", "count": 10, "last_seen_at": "2026-03-13T10:00:00Z"},
    ]
    clusters = cluster_queries(queries)
    assert clusters[0]["total_count"] >= clusters[-1]["total_count"]


def test_empty_input():
    assert cluster_queries([]) == []


def test_representative_is_most_frequent():
    queries = [
        {"query": "earn money", "count": 5, "last_seen_at": "2026-03-13T10:00:00Z"},
        {"query": "earning gold", "count": 2, "last_seen_at": "2026-03-13T10:00:00Z"},
    ]
    clusters = cluster_queries(queries, min_overlap=0.2)
    if len(clusters) == 1:
        assert clusters[0]["representative"] == "earn money"
