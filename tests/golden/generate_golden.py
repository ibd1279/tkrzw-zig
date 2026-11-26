#!/usr/bin/env python3
"""Generate golden test databases for tkrzw-zig cross-implementation tests.

Uses the OFFICIAL tkrzw Python bindings to create one small database per
backend format (.tkh, .tkt, .tks, .tkmt, .tkmb, .tkmc) with a deterministic
dataset. The Zig test in src/golden_compat_test.zig re-derives the same
dataset and verifies it can read every file.

If the record schema changes, update BOTH this script and
src/golden_compat_test.zig, then re-run:

    python3 tests/golden/generate_golden.py
"""

import hashlib
import os
import sys

import tkrzw

HERE = os.path.dirname(os.path.abspath(__file__))

# Special (non-bulk) records, inserted with overwrite in arbitrary order.
SPECIAL_RECORDS = [
    (b"", b"value-for-empty-key"),
    (b"bin\x00key", b"bin\x00\xff\xfevalue"),
    (b"empty-value", b""),
    (b"large", b"A" * 4096 + b"B" * 123),
    ("unicode-🔑".encode("utf-8"), "valeur-ça-é🔑".encode("utf-8")),
    # A JSON document shaped like the production store values.
    (b"json-doc", b'{"id": "sig-001", "ts": 1764000000.0, "text": "hello \xf0\x9f\x8c\x8d", "tags": ["queue", "memo"], "n": 42}'),
]

# A production-like store: values are JSON, keys are dotted identifiers.
PROD_LIKE = [
    (b"queue.msg.000001", b'{"room": "R0ABC", "user": "U1", "text": "standup notes", "ts": 1764000100.0}'),
    (b"queue.msg.000002", b'{"room": "R0ABC", "user": "U2", "text": "deploy finished", "ts": 1764000200.0}'),
    (b"schedule.event.000001", b'{"title": "1:1", "start": 1764036000.0, "duration": 1800}'),
    (b"inbox.mail.000001", b'{"from": "a@example.com", "subject": "Re: build", "ts": 1764040000.0}'),
]


def make_records():
    """Deterministic record set shared with golden_compat_test.zig."""
    records = []
    # Bulk keys: key_000 .. key_099 with varying value lengths.
    for i in range(100):
        key = b"key_%03d" % i
        pad = b"x" * (i % 17)
        value = b"val_%03d_" % i + pad
        records.append((key, value))
    records.extend(PROD_LIKE)
    records.extend(SPECIAL_RECORDS)
    # Deduplicate, keeping last write (Set with overwrite does the same).
    out = {}
    for k, v in records:
        out[k] = v
    return out


def main():
    records = make_records()
    # NOTE: the tkrzw 1.0.34 python bindings reject tuning parameters on
    # Open (INVALID_ARGUMENT_ERROR), so every file below is generated with
    # DEFAULT tuning — which is exactly the production profile this port
    # must read (see the golden.tkh size pin in golden_compat_test.zig).
    files = [
        "golden.tkh",
        "golden.tkt",
        "golden.tks",
        "golden.tkmt",
        "golden.tkmb",
        "golden.tkmc",
    ]
    for name in files:
        path = os.path.join(HERE, name)
        dbm = tkrzw.DBM()
        status = dbm.Open(path, True, truncate=True)
        if not status.IsOK():
            print("FAIL open %s: %s" % (name, status), file=sys.stderr)
            sys.exit(1)
        for k, v in records.items():
            st = dbm.Set(k, v, True)
            if not st.IsOK():
                print("FAIL set %r in %s: %s" % (k, name, st), file=sys.stderr)
                sys.exit(1)
        # SkipDBM in tkrzw 1.0.34 does not flush its write buffer on Close
        # alone; an explicit Synchronize is required for every backend.
        st = dbm.Synchronize(False)
        if not st.IsOK():
            print("FAIL sync %s: %s" % (name, st), file=sys.stderr)
            sys.exit(1)
        count = dbm.Count()
        st = dbm.Close()
        if not st.IsOK():
            print("FAIL close %s: %s" % (name, st), file=sys.stderr)
            sys.exit(1)
        with open(path, "rb") as f:
            digest = hashlib.sha256(f.read()).hexdigest()
        size = os.path.getsize(path)
        print("%-12s count=%d size=%d sha256=%s" % (name, count, size, digest[:16]))

    # Cross-check: read back with the official library and verify.
    expected_count = len(records)
    for name in files:
        path = os.path.join(HERE, name)
        dbm = tkrzw.DBM()
        if not dbm.Open(path, False).IsOK():
            print("FAIL reopen %s" % name, file=sys.stderr)
            sys.exit(1)
        if dbm.Count() != expected_count:
            print("FAIL count %s: %d != %d" % (name, dbm.Count(), expected_count), file=sys.stderr)
            sys.exit(1)
        dbm.Close()
    print("OK: %d records per file, verified with official tkrzw" % expected_count)


if __name__ == "__main__":
    main()
