"""Token-overlap query clustering for autohelp gap analysis."""
from __future__ import annotations
import re

_STOPWORDS = {
    "how", "do", "i", "the", "a", "an", "to", "in", "is", "it",
    "what", "can", "my", "me", "you", "for", "are", "was", "be",
    "this", "that", "with", "from", "at", "by", "or", "and",
}


def _stem(word: str) -> str:
    """Minimal suffix stripping so 'earning'/'earn', 'fights'/'fight' cluster together."""
    if len(word) > 5 and word.endswith("ing"):
        return word[:-3]
    if len(word) > 4 and word.endswith("ed"):
        return word[:-2]
    if len(word) > 3 and word.endswith("s") and not word.endswith("ss"):
        return word[:-1]
    return word


def tokenize(text: str) -> set[str]:
    text = text.lower()
    text = re.sub(r"[^\w\s]", " ", text)
    return {_stem(t) for t in text.split() if len(t) > 2 and t not in _STOPWORDS}


def cluster_queries(queries: list[dict], min_overlap: float = 0.3) -> list[dict]:
    if not queries:
        return []

    items = [(q["query"], q["count"], tokenize(q["query"])) for q in queries]
    assigned = [False] * len(items)
    clusters = []

    for i, (q1, c1, t1) in enumerate(items):
        if assigned[i]:
            continue
        cluster_members = [(q1, c1)]
        assigned[i] = True

        for j, (q2, c2, t2) in enumerate(items):
            if assigned[j] or i == j:
                continue
            if not t1 or not t2:
                continue
            union = t1 | t2
            if not union:
                continue
            jaccard = len(t1 & t2) / len(union)
            if jaccard >= min_overlap:
                cluster_members.append((q2, c2))
                assigned[j] = True

        total = sum(c for _, c in cluster_members)
        representative = max(cluster_members, key=lambda x: x[1])[0]
        clusters.append({
            "queries": [q for q, _ in cluster_members],
            "total_count": total,
            "representative": representative,
        })

    return sorted(clusters, key=lambda x: x["total_count"], reverse=True)
