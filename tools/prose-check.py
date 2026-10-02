#!/usr/bin/env python3
"""Measure prose against the rules in CONTRIBUTING.md, under "Writing".

    python3 tools/prose-check.py FILE...           one row per file, missed targets listed
    python3 tools/prose-check.py --show FILE...    also print every line that needs work

Markdown only. Code blocks, inline code, link targets, tables, headings and blockquotes are left
out, so the numbers measure the sentences a person reads. Blockquotes are skipped because that is
where a doc quotes someone else. A file passes when every target holds. The exit code is 0 when
every file passes, 1 when any fails and 2 when no file is given.
The numbers find the problems; they do not fix them. CONTRIBUTING.md says how.
"""
import re, sys

# Words that praise the text instead of informing. Chosen by comparison with the docs of other
# projects (ripgrep, bat, bubblewrap, bash-completion, cryfs, composefs): these words are common in
# self-praising text and absent from those references. "just", "simply" and "robust" are left out
# because the references use them as often.
CLAIM = r"\b(honest(ly)?|truthful(ly)?|genuine(ly)?|precisely|deliberately|on purpose|by design|plain words)\b"
# Fine in moderation, a tell in bulk, so it has a rate limit instead of a ban.
EXACTLY = r"\bexactly\b"
HISTORY = r"\b(used to|no longer|any ?more|once (?:ran|reached|was|lived)|an earlier version|previously|originally)\b"
NEGATION = r"\b(not|never|rather than|instead of|nor)\b|n't\b"
CHAIN = r"\b(which is why|that is why|this is why|which means|so that)\b"
DASHES = "—–"

# Limits sit at the edge of what the reference docs above do, so ordinary good writing meets every
# one. History words are reported by --show but have no limit: a changelog uses "no longer"
# correctly, so the count cannot tell narration from fact.
TARGETS = [  # (label, key, limit, unit)
    ("avg sentence", "avg", 18, "words"),
    ("long sentences", "long", 12, "% over 30 words"),
    ("asides ' - '", "aside", 3, "per 1000 words"),
    ("negations", "neg", 12, "per 1000 words"),
    ("claim words", "claim", 0, "hits"),
    ("'exactly'", "exactly", 0.5, "per 1000 words"),
    ("em/en dashes", "dash", 0, "hits"),
]

def prose_lines(text):
    """(line number, text) for every line a reader reads as prose."""
    out, fence = [], False
    for n, line in enumerate(text.splitlines(), 1):
        if line.lstrip().startswith("```"):
            fence = not fence
            continue
        if fence or line.lstrip().startswith(("|", "#", "<!--", "![", ">")):
            continue
        line = re.sub(r"`[^`]*`", "CODE", line)
        line = re.sub(r"\]\([^)]*\)", "]", line)
        line = re.sub(r"https?://\S+", "URL", line)
        out.append((n, line))
    return out

def blocks(lines):
    """Paragraphs and list items, each joined into one string with its first line number."""
    cur, start = [], None
    for n, line in lines:
        item = re.match(r"\s*([-*+]|\d+\.)\s+", line)
        if not line.strip() or item:
            if cur:
                yield start, " ".join(cur)
            cur, start = ([], None) if not line.strip() else ([line[item.end():]], n)
            continue
        if not cur:
            start = n
        cur.append(line.strip())
    if cur:
        yield start, " ".join(cur)

def sentences(block):
    parts = re.split(r"(?<=[.!?])\s+(?=[A-Z\"'(*CODE])", block)
    return [p for p in parts if len(p.split()) >= 3]

def measure(path, show):
    text = open(path, encoding="utf-8").read()
    lines = prose_lines(text)
    body = " ".join(l for _, l in lines)
    words = max(len(body.split()), 1)
    sents, flagged = [], []
    for start, b in blocks(lines):
        for s in sentences(b):
            sents.append(len(s.split()))
            if len(s.split()) > 30:
                flagged.append((start, f"{len(s.split())} words", s))
        if len(re.findall(r"\s-\s", b)) > 1:
            flagged.append((start, "asides", b[:160] + ("..." if len(b) > 160 else "")))
    hits = lambda pat: [(n, m.group(0)) for n, l in lines for m in re.finditer(pat, l, re.I)]
    claim, hist = hits(CLAIM), hits(HISTORY)
    dash = [(n, c) for n, l in lines for c in l if c in DASHES]
    m = {
        "words": words,
        "avg": sum(sents) / len(sents) if sents else 0,
        "long": 100 * sum(x > 30 for x in sents) / len(sents) if sents else 0,
        "aside": 1000 * len(re.findall(r"\w\s-\s\w", body)) / words,
        "neg": 1000 * len(re.findall(NEGATION, body, re.I)) / words,
        "claim": len(claim), "hist": len(hist), "dash": len(dash),
        "exactly": 1000 * len(re.findall(EXACTLY, body, re.I)) / words,
        "chain": 1000 * len(re.findall(CHAIN, body, re.I)) / words,
    }
    if show:
        for n, what in claim: flagged.append((n, "claim", what))
        for n, what in hist: flagged.append((n, "history", what))
        for n, what in dash: flagged.append((n, "dash", repr(what)))
    return m, sorted(flagged)

def main(argv):
    show = "--show" in argv
    files = [a for a in argv if not a.startswith("--")]
    if not files:
        print(__doc__.strip()); return 2
    failed = 0
    for f in files:
        m, flagged = measure(f, show)
        over = [(label, m[k], lim, unit) for label, k, lim, unit in TARGETS if m[k] > lim]
        print(f"{f}: {m['words']} words, {m['avg']:.0f} per sentence, "
              + ("PASS" if not over else f"FAIL, {len(over)} target(s) missed"))
        for label, v, lim, unit in over:
            print(f"    {label:16} {v:6.1f}   target <= {lim} {unit}")
        if show:
            for n, kind, text in flagged:
                print(f"    {f}:{n}  [{kind}]  {text}")
        failed += bool(over)
    return 1 if failed else 0

if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
