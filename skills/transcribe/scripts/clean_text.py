#!/usr/bin/env python3
"""Deterministic transcript cleanup: filler words + immediate word repeats.

Conservative -- never changes meaning. Removes standalone disfluencies and
collapses a word immediately repeated ("it's it's" -> "it's").
"""
import re

FILLERS = {
    "um", "umm", "ummm", "uh", "uhh", "uhhh", "er", "err", "erm", "hmm", "hmmm",
    "mm", "mmm", "mhm", "mmhm", "uh-huh", "mm-hmm", "ah", "ahh", "eh",
}
_word_re = re.compile(r"[A-Za-z']+")


def _core(tok):
    m = _word_re.search(tok)
    return m.group(0).lower() if m else None


def clean(text):
    out, prev = [], None
    for tok in text.split():
        core = _core(tok)
        if core in FILLERS and re.fullmatch(r"[A-Za-z'-]+[.,!?]?", tok):
            continue
        if core is not None and core == prev:
            if len(tok) > len(out[-1]):
                out[-1] = tok
            continue
        out.append(tok)
        prev = core
    s = " ".join(out)
    s = re.sub(r"\s+([.,!?])", r"\1", s)
    s = re.sub(r"\s{2,}", " ", s).strip()
    s = re.sub(r"^[,.\s]+", "", s)
    return s
