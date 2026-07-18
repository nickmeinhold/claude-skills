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
# colliding coordinators ("and but", "but and"): a self-repair collision where
# only the SECOND conjunction is the intended one. Immediate same-word repeats
# ("and and") are already collapsed by the repeat rule below.
CONJUNCTIONS = {"and", "but"}
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
        if (core in CONJUNCTIONS and prev in CONJUNCTIONS and out
                and re.fullmatch(r"[A-Za-z']+,?", out[-1])):
            out[-1] = tok  # "and but" -> "but": keep the self-repair
            prev = core
            continue
        out.append(tok)
        prev = core
    s = " ".join(out)
    s = re.sub(r"\s+([.,!?])", r"\1", s)
    s = re.sub(r"\s{2,}", " ", s).strip()
    s = re.sub(r"^[,.\s]+", "", s)
    return s
