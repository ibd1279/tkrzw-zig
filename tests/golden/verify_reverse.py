#!/usr/bin/env python3
"""Reverse-direction check: read port-written files with OFFICIAL tkrzw.

Companion to src/golden_reverse_writer.zig (run that first). Usage:

    python3 tests/golden/verify_reverse.py [dir-containing-rev.tk*-files]
"""

import os
import sys

import tkrzw

HERE = sys.argv[1] if len(sys.argv) > 1 else "/tmp/tkrzw-revgolden"

SPECIAL_RECORDS = [
    (b"", b"value-for-empty-key"),
    (b"bin\x00key", b"bin\x00\xff\xfevalue"),
    (b"empty-value", b""),
    (b"large", b"A" * 4096 + b"B" * 123),
    ("unicode-🔑".encode("utf-8"), "valeur-ça-é🔑".encode("utf-8")),
    (b"json-doc", b'{"id": "sig-001", "ts": 1764000000.0, "text": "hello \xf0\x9f\x8c\x8d", "tags": ["queue", "memo"], "n": 42}'),
]

PROD_LIKE = [
    (b"queue.msg.000001", b'{"room": "R0ABC", "user": "U1", "text": "standup notes", "ts": 1764000100.0}'),
    (b"queue.msg.000002", b'{"room": "R0ABC", "user": "U2", "text": "deploy finished", "ts": 1764000200.0}'),
    (b"schedule.event.000001", b'{"title": "1:1", "start": 1764036000.0, "duration": 1800}'),
    (b"inbox.mail.000001", b'{"from": "a@example.com", "subject": "Re: build", "ts": 1764040000.0}'),
]


def make_records():
    out = {}
    for i in range(100):
        key = b"key_%03d" % i
        out[key] = b"val_%03d_" % i + b"x" * (i % 17)
    for k, v in PROD_LIKE + SPECIAL_RECORDS:
        out[k] = v
    return out


ORDERED = {".tkt", ".tks", ".tkmb"}


def main():
    expected = make_records()
    total_failures = 0
    for name in ["rev.tkh", "rev.tkt", "rev.tks", "rev.tkmt", "rev.tkmb", "rev.tkmc"]:
        path = os.path.join(HERE, name)
        ordered = os.path.splitext(name)[1] in ORDERED
        file_failures = 0

        dbm = tkrzw.DBM()
        status = dbm.Open(path, False)
        if not status.IsOK():
            print("FAIL open %s: %s" % (name, status))
            total_failures += 1
            continue

        count = dbm.Count()
        if count != len(expected):
            print("FAIL %s: count %d != %d" % (name, count, len(expected)))
            file_failures += 1

        # Every record byte-for-byte.
        bad = 0
        for k, v in expected.items():
            got = dbm.Get(k)
            if got != v:
                print("FAIL %s: get(%r) len %s, want len %d" % (
                    name, k[:20], len(got or b""), len(v)))
                bad += 1
                if bad >= 3:
                    break
        file_failures += bad

        # Missing key must be absent.
        if dbm.Get(b"__missing__") is not None:
            print("FAIL %s: missing key returned data" % name)
            file_failures += 1

        # Full iteration: each key exactly once, ordered files sorted.
        seen = {}
        sorted_expected = sorted(expected.keys())
        si = 0
        sort_ok = True
        iter_api = dbm.MakeIterator()
        st = iter_api.First()
        while st.IsOK():
            rec = iter_api.Get()
            if rec is None:
                break
            k, v = rec
            if k in seen:
                print("FAIL %s: duplicate key %r in iteration" % (name, k[:20]))
                file_failures += 1
                break
            seen[k] = v
            if ordered:
                if si < len(sorted_expected) and k != sorted_expected[si]:
                    sort_ok = False
                si += 1
            st = iter_api.Next()
        if len(seen) != len(expected):
            print("FAIL %s: iterated %d != %d" % (name, len(seen), len(expected)))
            file_failures += 1
        else:
            for k in seen:
                if seen[k] != expected[k]:
                    print("FAIL %s: iteration value mismatch for %r" % (name, k[:20]))
                    file_failures += 1
                    break
            if ordered and not sort_ok:
                print("FAIL %s: iteration not in sorted order" % name)
                file_failures += 1

        dbm.Close()
        if file_failures == 0:
            print("PASS %-9s count=%d gets OK iteration OK%s" % (
                name, count, " (sorted)" if ordered else ""))
        total_failures += file_failures

    sys.exit(1 if total_failures else 0)


if __name__ == "__main__":
    main()
