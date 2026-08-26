#!/usr/bin/env python3
"""Reconcile freshly regenerated results with the committed ones.

    python3 tools/check_drift.py json COMMITTED FRESH   # analysis_result.json
    python3 tools/check_drift.py text COMMITTED FRESH   # verification_output.txt

"Reproduced by CI on every push" is only a claim about agreement if something
actually measures the agreement; this does. JSON mode walks both documents
together and requires the same shape, the same strings, and numerically equal
numbers (exact for integers, relative 1e-6 for floats). Text mode requires
the same lines with the same numbers, skipping lines tagged [timing], which
are machine-dependent by design. Exit 0 on agreement, 1 on drift.
"""
import json
import re
import sys

RTOL = 1e-6
_drift = []


def note(path, msg):
    if len(_drift) < 25:
        _drift.append(f"{path}: {msg}")


def close(a, b):
    if isinstance(a, bool) or isinstance(b, bool):
        return a is b
    if isinstance(a, int) and isinstance(b, int):
        return a == b
    fa, fb = float(a), float(b)
    if fa != fa and fb != fb:            # both NaN
        return True
    return abs(fa - fb) <= 1e-9 + RTOL * max(abs(fa), abs(fb))


def walk(a, b, path="$"):
    if type(a) is not type(b) and not (isinstance(a, (int, float)) and isinstance(b, (int, float))):
        note(path, f"type {type(a).__name__} vs {type(b).__name__}")
    elif isinstance(a, dict):
        for k in a.keys() | b.keys():
            if k not in a or k not in b:
                note(f"{path}.{k}", "present on one side only")
            else:
                walk(a[k], b[k], f"{path}.{k}")
    elif isinstance(a, list):
        if len(a) != len(b):
            note(path, f"length {len(a)} vs {len(b)}")
        for i, (x, y) in enumerate(zip(a, b)):
            walk(x, y, f"{path}[{i}]")
    elif isinstance(a, (int, float)):
        if not close(a, b):
            note(path, f"{a} vs {b}")
    elif a != b:
        note(path, f"{a!r} vs {b!r}")


NUM = re.compile(r"-?(?:\d[\d,]*\.\d+(?:[eE][+-]?\d+)?|\d[\d,]*|\.\d+)")


def text_lines(path):
    return [ln.rstrip() for ln in open(path, encoding="utf-8")
            if "[timing]" not in ln and "[env]" not in ln]


def compare_text(committed, fresh):
    a, b = text_lines(committed), text_lines(fresh)
    if len(a) != len(b):
        note("lines", f"{len(a)} committed vs {len(b)} fresh")
    for i, (la, lb) in enumerate(zip(a, b), 1):
        na, nb = NUM.findall(la), NUM.findall(lb)
        if NUM.sub("<n>", la) != NUM.sub("<n>", lb):
            note(f"line {i}", f"structure changed\n  - {la}\n  + {lb}")
        elif len(na) != len(nb) or any(not close(_coerce(x), _coerce(y)) for x, y in zip(na, nb)):
            note(f"line {i}", f"numbers drifted\n  - {la}\n  + {lb}")


def _coerce(tok):
    tok = tok.replace(",", "")
    return int(tok) if re.fullmatch(r"-?\d+", tok) else float(tok)


def main():
    if len(sys.argv) != 4 or sys.argv[1] not in ("json", "text"):
        print(__doc__)
        return 2
    mode, committed, fresh = sys.argv[1:4]
    if mode == "json":
        walk(json.load(open(committed)), json.load(open(fresh)))
    else:
        compare_text(committed, fresh)
    if _drift:
        print(f"drift against the committed artifact ({committed}):")
        print("\n".join(_drift))
        return 1
    print(f"{fresh} agrees with the committed artifact")
    return 0


if __name__ == "__main__":
    sys.exit(main())
