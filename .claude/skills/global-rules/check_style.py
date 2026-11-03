#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Mechanical checker for the agent-style ruleset.

Covers the nine rules that can be decided without a parse:

    RULE-04  filler phrases (needless words)
    RULE-05  dying metaphors and prefabricated phrases
    RULE-06  avoidable jargon and the banned AI-tell word list
    RULE-12  sentences over 30 words
    RULE-B   em and en dashes used as sentence punctuation
    RULE-C   consecutive sentences opening with the same word
    RULE-D   transition openers beyond one per paragraph
    RULE-G   headings not in title case
    RULE-I   contractions

The remaining twelve rules need judgment and are checked by reading.

Word lists are taken from the agent-style detectors (MIT).
Ruleset: The Elements of Agent Style, https://github.com/yzhao062/agent-style, CC BY 4.0.

Usage:
    python3 check_style.py FILE [FILE ...]
    cat draft.md | python3 check_style.py
    python3 check_style.py --json FILE
"""

from __future__ import annotations

import argparse
import json
import re
import sys

# --------------------------------------------------------------------------
# Word lists
# --------------------------------------------------------------------------

FILLER_PHRASES = [
    "it is important to note that", "it is important to note", "in order to",
    "due to the fact that", "at this point in time", "may potentially",
    "could possibly", "in the event that", "it may be necessary to",
    "it is worth noting that", "needless to say", "for all intents and purposes",
]

CLICHE_PHRASES = [
    "ring the changes", "take up the cudgels", "toe the line",
    "ride roughshod over", "stand shoulder to shoulder with",
    "play into the hands of", "no axe to grind", "grist to the mill",
    "fishing in troubled waters", "at the end of the day",
    "think outside the box", "level playing field", "low-hanging fruit",
    "paradigm shift", "moving the needle", "push the envelope", "circle back",
    "deep dive", "cutting-edge", "state of the art", "state-of-the-art",
    "paves the way", "pave the way", "novel approach", "novel framework",
    "novel method", "advance the state of the art", "game-changer",
    "game changer", "significant step forward", "paradigm-shifting",
    "best-in-class", "world-class", "next-generation", "next generation",
    "pushes the boundaries", "push the boundaries", "industry-leading",
    "unlock the full potential", "in today's fast-paced",
]

JARGON_WORDS = [
    "encompass", "burgeoning", "pivotal", "realm", "keen", "adept", "endeavor",
    "uphold", "imperative", "profound", "ponder", "cultivate", "hone", "delve",
    "embrace", "pave", "embark", "monumental", "scrutinize", "vast",
    "versatile", "paramount", "foster", "necessitates", "provenance",
    "multifaceted", "nuance", "obliterate", "articulate", "acquire",
    "underpin", "underscore", "harmonize", "garner", "undermine", "gauge",
    "facet", "bolster", "groundbreaking", "game-changing", "reimagine",
    "turnkey", "intricate", "trailblazing", "unprecedented",
    "leverage", "leverages", "leveraging",
    "utilize", "utilizes", "utilizing",
    "facilitate", "facilitates", "facilitating",
]

TRANSITION_OPENERS = [
    "Additionally", "Furthermore", "Moreover", "In addition",
    "What's more", "Notably",
]

TITLE_CASE_LOWER = {
    "a", "an", "the", "and", "but", "or", "nor",
    "of", "in", "on", "to", "for", "by", "at", "with",
}

QUESTION_OPENERS = {
    "how", "what", "when", "where", "which", "who", "whom", "whose", "why",
}

# --------------------------------------------------------------------------
# Patterns
# --------------------------------------------------------------------------

EM_DASH = "\u2014"
EN_DASH = "\u2013"
ANY_DASH_RE = re.compile(r"[\u2014\u2013]")
NUMERIC_EN_DASH_RE = re.compile(r"(?<=\d)\u2013(?=\d)")
LETTER_BEFORE_RE = re.compile(r"[^\W\d_]$")
LETTER_AFTER_RE = re.compile(r"^[^\W\d_]")

CONTRACTION_RE = re.compile(
    r"\b(?:(?:it|that|he|she|there|here|what|who|where|when|how|let)'s|"
    r"(?:i|you|he|she|it|we|they|that|who|what|which|why|there|where|how)'d|"
    r"[A-Za-z]+n't|[A-Za-z]+'(?:re|ll|ve|m))\b",
    re.IGNORECASE,
)

SENTENCE_SPLIT_RE = re.compile(r"(?<=[.!?])[\"')\]]*\s+")
HEADING_RE = re.compile(r"^(#{1,6})\s+(.*?)\s*#*\s*$")
LIST_MARK_RE = re.compile(r"^\s*(?:[*+-]|\d+[.)])\s+")
TOKEN_RE = re.compile(r"\.?[A-Za-z0-9](?:[A-Za-z0-9'./\\:_-]*[A-Za-z0-9])?")

RULE_TITLES = {
    "RULE-05": "cliche / prefabricated phrase",
    "RULE-06": "avoidable jargon / AI-tell word",
    "RULE-04": "filler phrase",
    "RULE-12": "sentence over 30 words",
    "RULE-B": "dash used as sentence punctuation",
    "RULE-C": "consecutive sentences with same opener",
    "RULE-D": "transition opener",
    "RULE-G": "heading not in title case",
    "RULE-I": "contraction",
}


def phrase_re(phrases):
    ordered = sorted(set(phrases), key=len, reverse=True)
    return re.compile(
        r"(?<![\w-])(?:" + "|".join(re.escape(p) for p in ordered) + r")(?![\w-])",
        re.IGNORECASE,
    )


def word_re(words):
    ordered = sorted(set(words), key=len, reverse=True)
    return re.compile(
        r"\b(?:" + "|".join(re.escape(w) for w in ordered) + r")\b",
        re.IGNORECASE,
    )


FILLER_RE = phrase_re(FILLER_PHRASES)
CLICHE_RE = phrase_re(CLICHE_PHRASES)
JARGON_RE = word_re(JARGON_WORDS)
TRANSITION_RE = re.compile(
    r"^\s*(?:[\"'(]*)(" + "|".join(re.escape(t) for t in TRANSITION_OPENERS) + r")\b",
    re.IGNORECASE,
)


# --------------------------------------------------------------------------
# Text handling
# --------------------------------------------------------------------------

class Line:
    __slots__ = ("no", "text", "in_code", "is_heading")

    def __init__(self, no, text, in_code, is_heading):
        self.no = no
        self.text = text
        self.in_code = in_code
        self.is_heading = is_heading


def scan_lines(text):
    """Return Line records with fenced-code, frontmatter, and heading state resolved."""
    out = []
    fence = False
    raw_lines = text.splitlines()
    front_end = 0
    if raw_lines and raw_lines[0].strip() == "---":
        for j in range(1, len(raw_lines)):
            if raw_lines[j].strip() == "---":
                front_end = j + 1
                break
    for i, raw in enumerate(raw_lines, start=1):
        if i <= front_end:
            out.append(Line(i, raw, True, False))
            continue
        stripped = raw.lstrip()
        if stripped.startswith("```") or stripped.startswith("~~~"):
            fence = not fence
            out.append(Line(i, raw, True, False))
            continue
        out.append(Line(i, raw, fence, bool(HEADING_RE.match(raw)) and not fence))
    return out


def in_inline_code(line, col):
    return line.count("`", 0, col) % 2 == 1


def strip_inline_code(line):
    return re.sub(r"`[^`]*`", lambda m: " " * len(m.group()), line)


def excerpt(line, start, width=110):
    a = max(0, start - 25)
    b = min(len(line), a + width)
    out = line[a:b].strip()
    if a > 0:
        out = "..." + out
    if b < len(line):
        out = out + "..."
    return out


def prose_lines(lines):
    return [ln for ln in lines if not ln.in_code and ln.text.strip()]


# --------------------------------------------------------------------------
# Detectors
# --------------------------------------------------------------------------

def find_pattern(lines, pattern, rule, label):
    hits = []
    for ln in lines:
        if ln.in_code:
            continue
        for m in pattern.finditer(ln.text):
            if in_inline_code(ln.text, m.start()):
                continue
            hits.append({
                "rule": rule, "line": ln.no, "column": m.start() + 1,
                "detail": f"{label} '{m.group()}'",
                "excerpt": excerpt(ln.text, m.start()),
            })
    return hits


def check_dashes(lines):
    hits = []
    for ln in lines:
        if ln.in_code:
            continue
        text = ln.text
        for m in ANY_DASH_RE.finditer(text):
            col = m.start()
            if in_inline_code(text, col):
                continue
            ch = m.group()
            if ch == EN_DASH:
                if NUMERIC_EN_DASH_RE.match(text, col):
                    continue
                before = text[:col].rstrip()
                after = text[col + 1:].lstrip()
                # Paired name such as Gopen-Swan: letters flush on both sides.
                if (text[col - 1:col].strip() and text[col + 1:col + 2].strip()
                        and LETTER_BEFORE_RE.search(before[-1:] or "")
                        and LETTER_AFTER_RE.match(after[:1] or "")
                        and text[col - 1] != " " and text[col + 1] != " "):
                    continue
            hits.append({
                "rule": "RULE-B", "line": ln.no, "column": col + 1,
                "detail": "em dash" if ch == EM_DASH else "en dash",
                "excerpt": excerpt(text, col),
            })
    return hits


def sentences_of(lines):
    """Yield (line_no, sentence) for prose lines, skipping code and tables."""
    for ln in prose_lines(lines):
        text = ln.text
        if ln.is_heading or text.lstrip().startswith(("|", ">")):
            continue
        body = strip_inline_code(LIST_MARK_RE.sub("", text))
        for sent in SENTENCE_SPLIT_RE.split(body):
            sent = sent.strip()
            if sent:
                yield ln.no, sent


def check_long_sentences(lines, limit=30):
    hits = []
    for line_no, sent in sentences_of(lines):
        words = [w for w in re.split(r"\s+", sent) if re.search(r"[A-Za-z0-9]", w)]
        if len(words) > limit:
            hits.append({
                "rule": "RULE-12", "line": line_no, "column": 1,
                "detail": f"{len(words)} words",
                "excerpt": excerpt(sent, 0),
            })
    return hits


def check_same_starts(lines):
    """Flag a repeated opener only within one paragraph of running prose.

    A list item, a heading, or a blank line resets the run: parallel openers
    across bullets are RULE-09 parallelism, not a RULE-C same-start.
    """
    hits = []
    prev_word = None
    prev_line = None
    for ln in lines:
        if ln.in_code or ln.is_heading or not ln.text.strip() or LIST_MARK_RE.match(ln.text):
            prev_word = None
            if ln.in_code or ln.is_heading or not ln.text.strip():
                continue
        text = ln.text
        if text.lstrip().startswith(("|", ">")):
            prev_word = None
            continue
        body = strip_inline_code(LIST_MARK_RE.sub("", text))
        for sent in SENTENCE_SPLIT_RE.split(body):
            sent = sent.strip()
            if not sent:
                continue
            line_no = ln.no
            m = re.match(r"[\"'(*_]*([A-Za-z]+)", sent)
            if not m:
                prev_word = None
                continue
            word = m.group(1).lower()
            if word == prev_word:
                hits.append({
                    "rule": "RULE-C", "line": line_no, "column": 1,
                    "detail": f"opener '{m.group(1)}' repeated from line {prev_line}",
                    "excerpt": excerpt(sent, 0),
                })
            prev_word, prev_line = word, line_no
    return hits


def check_transitions(lines):
    """Flag transition openers past the first one in each paragraph."""
    hits = []
    seen = 0
    for ln in lines:
        if ln.in_code:
            continue
        if not ln.text.strip():
            seen = 0
            continue
        body = LIST_MARK_RE.sub("", ln.text)
        parts = [body] + SENTENCE_SPLIT_RE.split(body)[1:]
        for sent in parts:
            m = TRANSITION_RE.match(sent)
            if not m:
                continue
            seen += 1
            if seen > 1:
                hits.append({
                    "rule": "RULE-D", "line": ln.no, "column": 1,
                    "detail": f"transition opener '{m.group(1)}' (#{seen} in paragraph)",
                    "excerpt": excerpt(sent.strip(), 0),
                })
    return hits


def check_contractions(lines):
    return find_pattern(lines, CONTRACTION_RE, "RULE-I", "contraction")


def title_case_ok(heading):
    tokens = TOKEN_RE.findall(heading)
    if not tokens:
        return True, ""
    first = tokens[0].lower().strip(".")
    if first in QUESTION_OPENERS or heading.rstrip().endswith("?"):
        return True, ""
    for i, tok in enumerate(tokens):
        low = tok.lower()
        if not tok[0].isalpha():
            continue
        if tok.isupper() or any(c.isupper() for c in tok[1:]):
            continue  # acronym, code token, or CamelCase
        is_edge = i == 0 or i == len(tokens) - 1
        if low in TITLE_CASE_LOWER and not is_edge:
            continue
        if not tok[0].isupper():
            return False, tok
    return True, ""


def check_headings(lines):
    hits = []
    for ln in lines:
        if ln.in_code or not ln.is_heading:
            continue
        m = HEADING_RE.match(ln.text)
        body = strip_inline_code(m.group(2))
        ok, offender = title_case_ok(body)
        if not ok:
            hits.append({
                "rule": "RULE-G", "line": ln.no, "column": 1,
                "detail": f"lowercase major word '{offender}'",
                "excerpt": m.group(2)[:110],
            })
    return hits


def review(text):
    lines = scan_lines(text)
    hits = []
    hits += find_pattern(lines, FILLER_RE, "RULE-04", "filler phrase")
    hits += find_pattern(lines, CLICHE_RE, "RULE-05", "cliche")
    hits += find_pattern(lines, JARGON_RE, "RULE-06", "jargon / AI-tell")
    hits += check_long_sentences(lines)
    hits += check_dashes(lines)
    hits += check_same_starts(lines)
    hits += check_transitions(lines)
    hits += check_headings(lines)
    hits += check_contractions(lines)
    hits.sort(key=lambda h: (h["line"], h["column"]))
    return hits


# --------------------------------------------------------------------------
# Reporting
# --------------------------------------------------------------------------

def report(name, hits, max_examples=3):
    print(f"\n{name}")
    print("-" * max(len(name), 40))
    if not hits:
        print("no mechanical violations (9 of 21 rules checked)")
        return 0
    by_rule = {}
    for h in hits:
        by_rule.setdefault(h["rule"], []).append(h)
    for rule in sorted(by_rule, key=lambda r: (-len(by_rule[r]), r)):
        group = by_rule[rule]
        label = RULE_TITLES.get(rule, rule)
        print(f"{rule:9} {label:34} {len(group):>3}")
        for h in group[:max_examples]:
            print(f"          L{h['line']}:{h['column']}  {h['detail']}")
            print(f"            {h['excerpt']}")
        if len(group) > max_examples:
            print(f"          ... {len(group) - max_examples} more")
    print(f"\ntotal: {len(hits)} across {len(by_rule)} rules "
          f"(12 judgment rules not checked here)")
    return len(hits)


def main():
    ap = argparse.ArgumentParser(description="agent-style mechanical checker")
    ap.add_argument("files", nargs="*", help="files to check; omit to read stdin")
    ap.add_argument("--json", action="store_true", help="emit JSON")
    args = ap.parse_args()

    sources = []
    if args.files:
        for path in args.files:
            try:
                with open(path, encoding="utf-8") as fh:
                    sources.append((path, fh.read()))
            except OSError as err:
                print(f"cannot read {path}: {err}", file=sys.stderr)
                return 2
    else:
        sources.append(("<stdin>", sys.stdin.read()))

    total = 0
    payload = {}
    for name, text in sources:
        hits = review(text)
        total += len(hits)
        if args.json:
            payload[name] = hits
        else:
            report(name, hits)

    if args.json:
        print(json.dumps(payload, indent=2))
    return 1 if total else 0


if __name__ == "__main__":
    sys.exit(main())
