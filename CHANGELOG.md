# Changelog

## v0.1.1

### Fixes
- **HashDBM in-place update & multi-byte padding accounting (`fe528af`)**: Fixed `updateRecordValueInPlace` to rewrite the magic checksum, `value_size`, `padding_size`, payload, and `PADDING_TOP_MAGIC` (`0xDD`) inside the exact `whole_size`, and fixed multi-byte `padding_size` (`>= 128`) accounting (`extra_padding_size = ps_bytes - 1`) across `readRecordHeader`, `appendRecord`, `updateRecordValueInPlace`, and sequential scans.
- **HashDBM `voidRecord` checksum & `0xDD` scanner collision (`12549ec`)**: Fixed `voidRecord` to preserve the valid 6-bit magic checksum (`>= 3`) instead of writing bare `0xC0`, removed the colliding `magic == 0xDD` skip branch in sequential scanners (which collided with valid VOID records whose checksum is 29), widened `computeMagicChecksum` accumulator to `u64`, and added varint 10-byte / overflow bounds checks.
- **Legacy `v0.1.0-zig0.17.1` file repair path**: Files written by `v0.1.0-zig0.17.1` (commit `8db376c`) or `fe528af` that performed deletes or out-of-place grows contain bare `0xC0` VOID magic bytes, which fail official `tkrzw` `Rebuild`, `ValidateRecords`, and `RestoreDatabase`. `HashDBM.rebuild()` and the sequential import/restore scanners (`importFromFileForward*`, `importFromFileBackward*`) now accept legacy bare `0xC0` VOID records and rewrite a fully compliant file; `readRecordHeader` and `validateRecords` remain strict (`(magic & 0x3F) >= 3`).
- **Reverse golden cross-implementation checks**: Extended `src/golden_reverse_writer.zig` and `tests/golden/verify_reverse.py` to test HashDBM deletes (including `0xDD` checksum-29 voids), in-place shrinks, and grow-relocates across `align_pow` 3, 4, and 10 against official `tkrzw` (`tkrzw_dbm_util inspect --validate`, `Rebuild()`, and `RestoreDatabase()`).

## v0.1.0-zig0.17.1
- Initial Zig 0.17.1 port of Tkrzw DBM formats.
