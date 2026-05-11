/*
 * tkrzw.h - C API for tkrzw-zig PolyDBM
 *
 * ============================================================================
 * Overview
 * ============================================================================
 * This header exposes the tkrzw-zig PolyDBM (poly-database manager) to C
 * callers. PolyDBM dispatches at open-time to one of several backends
 * (HashDBM, TreeDBM, SkipDBM, TinyDBM, BabyDBM, CacheDBM) based on file
 * extension or an explicit option. All operations are routed through this
 * single C API surface; the concrete backend is opaque to the caller.
 *
 * The API closely mirrors the C++ tkrzw library: open/close, single-key
 * CRUD, scalar queries, maintenance, multi-key batch ops, atomic ops,
 * cursor iteration, and callback-driven record processing.
 *
 * ============================================================================
 * Lifecycle
 * ============================================================================
 *   tkrzw_init()           - call once before any other tkrzw_* function
 *   tkrzw_open()           - open one or more databases
 *   tkrzw_get/set/...      - perform operations
 *   tkrzw_close()          - close each database
 *   tkrzw_deinit()         - call once after all databases are closed
 *
 * init/deinit are ref-counted, so nested calls are tolerated, but they are
 * NOT designed for concurrent invocation; serialize them in the caller.
 *
 * ============================================================================
 * Memory model
 * ============================================================================
 * All "out" pointer values produced by this API (e.g. the value buffer
 * returned by tkrzw_get, key/value buffers from tkrzw_cursor_get) are
 * allocated with the system allocator (malloc). The caller is responsible
 * for releasing each one with free(). The library never returns pointers
 * into Zig-owned storage.
 *
 * Inputs (keys, values, paths) are read-only borrows; the library copies
 * any bytes it needs to retain.
 *
 * ============================================================================
 * Thread safety
 * ============================================================================
 * - tkrzw_init / tkrzw_deinit must not be called concurrently. Initialise
 *   from one thread before spawning workers and tear down after they join.
 * - Operations on distinct TkrzwDBM/TkrzwCursor handles are independent.
 * - Operations on the same handle must be externally synchronised by the
 *   caller.
 *
 * ============================================================================
 * Null-pointer policy
 * ============================================================================
 * Passing NULL for a required handle (TkrzwDBM*, TkrzwCursor*) or for a
 * required out-pointer returns TKRZW_STATUS_INVALID_ARGUMENT_ERROR.
 * Scalar getters (tkrzw_count, tkrzw_is_open, ...) tolerate a NULL handle
 * and return a defined sentinel (0 / false) rather than crashing.
 *
 * ============================================================================
 * Status codes
 * ============================================================================
 * Functions that report success/failure return an int32_t status code
 * (one of the TKRZW_STATUS_* constants). Use tkrzw_status_name() to obtain
 * a human-readable name.
 *
 * ============================================================================
 * Example
 * ============================================================================
 *   #include "tkrzw.h"
 *   #include <stdio.h>
 *   #include <stdlib.h>
 *   #include <string.h>
 *
 *   int main(void) {
 *       tkrzw_init();
 *
 *       TkrzwOpenOptions opts = { .writable = true, .truncate = true };
 *       TkrzwDBM *db = tkrzw_open("data.tkmt", &opts);
 *       if (!db) { tkrzw_deinit(); return 1; }
 *
 *       const char *key = "hello";
 *       const char *val = "world";
 *       tkrzw_set(db, key, strlen(key), val, strlen(val), true);
 *
 *       char *out = NULL;
 *       size_t out_len = 0;
 *       int32_t st = tkrzw_get(db, key, strlen(key), &out, &out_len);
 *       if (st == TKRZW_STATUS_SUCCESS) {
 *           fwrite(out, 1, out_len, stdout);
 *           free(out);
 *       }
 *
 *       tkrzw_close(db);
 *       tkrzw_deinit();
 *       return 0;
 *   }
 */

#ifndef TKRZW_H
#define TKRZW_H

#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ===========================================================================
 * Status codes (mirror tkrzw::Status::Code / src/lib_common.zig Code)
 * =========================================================================== */
#define TKRZW_STATUS_SUCCESS                 0
#define TKRZW_STATUS_UNKNOWN_ERROR           1
#define TKRZW_STATUS_SYSTEM_ERROR            2
#define TKRZW_STATUS_NOT_IMPLEMENTED_ERROR   3
#define TKRZW_STATUS_PRECONDITION_ERROR      4
#define TKRZW_STATUS_INVALID_ARGUMENT_ERROR  5
#define TKRZW_STATUS_CANCELED_ERROR          6
#define TKRZW_STATUS_NOT_FOUND_ERROR         7
#define TKRZW_STATUS_PERMISSION_ERROR        8
#define TKRZW_STATUS_INFEASIBLE_ERROR        9
#define TKRZW_STATUS_DUPLICATION_ERROR      10
#define TKRZW_STATUS_BROKEN_DATA_ERROR      11
#define TKRZW_STATUS_NETWORK_ERROR          12
#define TKRZW_STATUS_APPLICATION_ERROR      13

/* ===========================================================================
 * Compare-and-exchange enums
 * =========================================================================== */

/**
 * Expected-state selector for tkrzw_compare_exchange:
 *   ABSENT - the record must NOT exist
 *   ANY    - any current state matches (no precondition)
 *   EXACT  - the record must equal the bytes given by expected_value /
 *            expected_value_len
 */
typedef enum {
    TKRZW_EXPECTED_ABSENT = 0,
    TKRZW_EXPECTED_ANY    = 1,
    TKRZW_EXPECTED_EXACT  = 2
} TkrzwExpected;

/**
 * Desired-action selector for tkrzw_compare_exchange:
 *   REMOVE - delete the record
 *   NOOP   - leave the record unchanged
 *   SET    - write the bytes given by desired_value / desired_value_len
 */
typedef enum {
    TKRZW_DESIRED_REMOVE = 0,
    TKRZW_DESIRED_NOOP   = 1,
    TKRZW_DESIRED_SET    = 2
} TkrzwDesired;

/* ===========================================================================
 * Open options
 * =========================================================================== */

/**
 * Flags passed to tkrzw_open. Mirrors OpenOptionsPoly + file.OpenOptions
 * (src/dbm_poly.zig, src/file.zig) collapsed to a single flat C struct.
 *
 *   writable    - open for reads and writes (false = read-only)
 *   truncate    - truncate the file to zero length on open
 *   no_create   - fail if the file does not already exist
 *   no_wait     - non-blocking lock attempt; returns INFEASIBLE_ERROR if
 *                 the lock is held by another process
 *   no_lock     - skip advisory file locking entirely (caller assumes
 *                 responsibility for exclusivity)
 *   sync_hard   - perform a hard fsync at close/synchronize
 */
typedef struct TkrzwOpenOptions {
    bool writable;
    bool truncate;
    bool no_create;
    bool no_wait;
    bool no_lock;
    bool sync_hard;
} TkrzwOpenOptions;

/* ===========================================================================
 * Opaque handles
 * =========================================================================== */
typedef struct TkrzwDBM    TkrzwDBM;
typedef struct TkrzwCursor TkrzwCursor;

/* ===========================================================================
 * Record processor callback
 * =========================================================================== */

/**
 * Callback type for tkrzw_process_each / tkrzw_process / tkrzw_process_first.
 *
 * Arguments:
 *   key, key_len           - current record key (always valid; not NUL-
 *                            terminated, length is key_len)
 *   value, value_len       - current record value, OR (NULL, 0) when the
 *                            callback is invoked for an absent key (used
 *                            by tkrzw_process on a missing key)
 *   user_data              - opaque pointer passed straight through from
 *                            the call site
 *   new_value_out          - on a SET return, the callback must set
 *                            *new_value_out to point to the bytes to write
 *   new_value_len_out      - on a SET return, set *new_value_len_out to
 *                            the length of those bytes
 *
 * Return values:
 *   0 = NOOP    - leave the record unchanged
 *   1 = REMOVE  - delete the record
 *   2 = SET     - replace the record with (*new_value_out,
 *                 *new_value_len_out)
 *   any other value is treated as NOOP.
 *
 * Lifetime: for SET returns, *new_value_out is read by the library and
 * copied before the callback returns; the bytes therefore only need to
 * live until the callback returns. Pointing at stack memory is allowed.
 *
 * Re-entrancy: the callback must NOT invoke any tkrzw_* function on the
 * same DBM (or on a cursor over the same DBM); the resulting behaviour
 * is undefined.
 *
 * Size limit: SET values larger than 64 MiB are silently downgraded to NOOP
 * by the library. Out-of-memory during the internal copy of a SET value is
 * also silently downgraded to NOOP; the overall processEach/process call
 * still returns SUCCESS in both cases. Callers relying on SET for every
 * record should verify results independently if OOM is a concern.
 *
 * Sentinel guarantee: the callback is invoked exactly once per real record.
 * The underlying Zig layer emits batch-boundary events (empty-key processEmpty
 * calls) before and after iteration, but the C wrapper absorbs these and never
 * forwards them to user code.
 *
 * Empty-key limitation: because the sentinel filter keys on an empty key
 * string, calling tkrzw_process() on a record whose key is literally ""
 * (zero-length) when that record is absent will suppress the absent-key
 * callback. A stored key="" record is unaffected (visited normally via the
 * real-record callback path during processEach).
 */

typedef int32_t (*TkrzwRecordProcessor)(
    const char *key, size_t key_len,
    const char *value, size_t value_len,
    void *user_data,
    const char **new_value_out, size_t *new_value_len_out);

/* ===========================================================================
 * Lifecycle
 * =========================================================================== */

/**
 * Initialise the tkrzw library. Must be called before any other tkrzw_*
 * function. Ref-counted: pair every successful tkrzw_init() with exactly
 * one tkrzw_deinit().
 *
 * Returns TKRZW_STATUS_SUCCESS on success, or a SYSTEM_ERROR / UNKNOWN_ERROR
 * code on failure to initialise the underlying I/O subsystem.
 *
 * Not thread-safe with respect to tkrzw_deinit; serialise in caller.
 */
int32_t tkrzw_init(void);

/**
 * Release library resources held by tkrzw_init. Must be called once for
 * each successful tkrzw_init. Calling tkrzw_deinit while DBM or cursor
 * handles are still open is undefined behaviour.
 *
 * Returns TKRZW_STATUS_SUCCESS, or PRECONDITION_ERROR if called more
 * times than tkrzw_init.
 */
int32_t tkrzw_deinit(void);

/**
 * Return a static, NUL-terminated name for a status code (e.g.
 * "NOT_FOUND_ERROR" for 7). Returns "UNKNOWN" for out-of-range values.
 * The returned pointer is owned by the library and must not be freed.
 */
const char *tkrzw_status_name(int32_t code);

/* ===========================================================================
 * Database open / close
 * =========================================================================== */

/**
 * Open a database.
 *
 *   path     - file path (NUL-terminated). The extension (.tkh / .tkt /
 *              .tks / .tkmt / .tkmb / .tkmc) selects the backend.
 *   options  - non-NULL pointer to a TkrzwOpenOptions. The struct is
 *              read only during this call.
 *
 * Returns a non-NULL TkrzwDBM handle on success, NULL on failure (out of
 * memory, invalid arguments, unknown extension, or backend open failure).
 * The returned handle must be released with tkrzw_close.
 */
TkrzwDBM *tkrzw_open(const char *path, const TkrzwOpenOptions *options);

/**
 * Close a database opened with tkrzw_open and release the handle.
 *
 * The handle is invalid after this call returns regardless of the status
 * code. The caller should NULL its local pointer; double-close is
 * undefined behaviour.
 *
 * Returns the close status (SUCCESS or a backend-specific error). Passing
 * NULL returns INVALID_ARGUMENT_ERROR.
 */
int32_t tkrzw_close(TkrzwDBM *db);

/* ===========================================================================
 * Single-key CRUD
 * =========================================================================== */

/**
 * Retrieve a record by key.
 *
 *   value_out, value_len_out - on SUCCESS, *value_out is a malloc'd buffer
 *     holding the record bytes (NOT NUL-terminated) and *value_len_out is
 *     its length. The caller must free(*value_out).
 *   On NOT_FOUND_ERROR or any other failure, *value_out is set to NULL
 *   and *value_len_out to 0.
 *
 * Returns SUCCESS, NOT_FOUND_ERROR, INVALID_ARGUMENT_ERROR, or other.
 */
int32_t tkrzw_get(TkrzwDBM *db,
                  const char *key, size_t key_len,
                  char **value_out, size_t *value_len_out);

/**
 * Store a record.
 *
 *   overwrite - if false and the key already exists, DUPLICATION_ERROR is
 *               returned and the existing record is preserved.
 *
 * Returns SUCCESS, DUPLICATION_ERROR, INVALID_ARGUMENT_ERROR, or other.
 */
int32_t tkrzw_set(TkrzwDBM *db,
                  const char *key, size_t key_len,
                  const char *value, size_t value_len,
                  bool overwrite);

/**
 * Remove a record by key. Returns NOT_FOUND_ERROR if the key is absent.
 */
int32_t tkrzw_remove(TkrzwDBM *db, const char *key, size_t key_len);

/**
 * Append bytes to an existing record. If the record does not exist it is
 * created with just the appended value.
 *
 *   delim, delim_len - delimiter inserted between the existing value and
 *                      the appended value. Pass (NULL, 0) for no
 *                      delimiter.
 */
int32_t tkrzw_append(TkrzwDBM *db,
                     const char *key, size_t key_len,
                     const char *value, size_t value_len,
                     const char *delim, size_t delim_len);

/* ===========================================================================
 * Scalar queries
 *
 * All of these accept a NULL handle and return a defined sentinel rather
 * than crashing:
 *   tkrzw_count        -> 0
 *   tkrzw_file_size    -> 0
 *   tkrzw_timestamp    -> 0.0
 *   tkrzw_is_open      -> false
 *   tkrzw_is_writable  -> false
 *   tkrzw_is_healthy   -> false
 *   tkrzw_should_rebuild -> false
 * =========================================================================== */

/** Number of records currently in the database. */
int64_t tkrzw_count(TkrzwDBM *db);

/** Total file size in bytes (0 for in-memory backends). */
int64_t tkrzw_file_size(TkrzwDBM *db);

/** Last modification timestamp (Unix epoch seconds, fractional). */
double tkrzw_timestamp(TkrzwDBM *db);

/** True iff the database is currently open. */
bool tkrzw_is_open(TkrzwDBM *db);

/** True iff the database was opened with writable=true. */
bool tkrzw_is_writable(TkrzwDBM *db);

/** True iff the backend reports itself healthy (no detected corruption). */
bool tkrzw_is_healthy(TkrzwDBM *db);

/** True iff the backend recommends a rebuild for efficiency. */
bool tkrzw_should_rebuild(TkrzwDBM *db);

/* ===========================================================================
 * Maintenance
 * =========================================================================== */

/** Remove all records. */
int32_t tkrzw_clear(TkrzwDBM *db);

/**
 * Synchronise the database to its backing storage.
 *   hard - if true, force a physical sync (fsync); otherwise a logical
 *          sync is sufficient.
 */
int32_t tkrzw_synchronize(TkrzwDBM *db, bool hard);

/** Rebuild the database (compaction / index reconstruction). */
int32_t tkrzw_rebuild(TkrzwDBM *db);

/**
 * Copy the underlying database file to dest_path (NUL-terminated).
 *   sync_hard - if true, fsync the destination after the copy completes.
 */
int32_t tkrzw_copy_file(TkrzwDBM *db, const char *dest_path, bool sync_hard);

/* ===========================================================================
 * Multi-key batch operations
 *
 * All array-shaped inputs are parallel C arrays of length `num`. The
 * caller owns and retains ownership of all input buffers.
 * =========================================================================== */

/**
 * Look up many keys in one call. For each i:
 *   - on a hit, *values_out[i] is a malloc'd buffer of length
 *     *values_len_out[i] (caller frees);
 *   - on a miss, *values_out[i] is NULL and *values_len_out[i] is 0.
 * Returns SUCCESS if all keys were found, NOT_FOUND_ERROR if at least one
 * key was missing (the non-missing slots are still populated), or another
 * error code on a structural failure (in which case no allocations are
 * left behind for the caller).
 *
 * PRECONDITION: keys[] must not contain duplicate entries. Duplicate keys
 * cause internal allocation leaks within the backend's getMulti implementation.
 */
int32_t tkrzw_get_multi(TkrzwDBM *db,
                        const char *const *keys,
                        const size_t *key_lens,
                        size_t num,
                        char **values_out,
                        size_t *values_len_out);

/**
 * Set many records atomically per backend semantics.
 *   overwrite - if false, DUPLICATION_ERROR is returned when any key
 *               already exists (partial-overwrite behaviour matches the
 *               underlying backend).
 */
int32_t tkrzw_set_multi(TkrzwDBM *db,
                        const char *const *keys, const size_t *key_lens,
                        const char *const *values, const size_t *value_lens,
                        size_t num,
                        bool overwrite);

/** Remove many records. NOT_FOUND_ERROR is returned if any key is absent. */
int32_t tkrzw_remove_multi(TkrzwDBM *db,
                           const char *const *keys, const size_t *key_lens,
                           size_t num);

/** Append to many records using a shared delimiter (may be NULL/0). */
int32_t tkrzw_append_multi(TkrzwDBM *db,
                           const char *const *keys, const size_t *key_lens,
                           const char *const *values, const size_t *value_lens,
                           size_t num,
                           const char *delim, size_t delim_len);

/* ===========================================================================
 * Atomic operations
 * =========================================================================== */

/**
 * Atomically add `delta` to a stored 64-bit integer value at `key`.
 * If the record does not exist it is initialised to `initial` and then
 * incremented (so the resulting value is initial+delta).
 *
 *   current_out - optional; if non-NULL, receives the post-increment value.
 */
int32_t tkrzw_increment(TkrzwDBM *db,
                        const char *key, size_t key_len,
                        int64_t delta,
                        int64_t *current_out,
                        int64_t initial);

/**
 * Rename a record.
 *   overwrite - if false and new_key already exists, DUPLICATION_ERROR.
 *   copying   - if true, the old record is preserved (copy instead of
 *               move).
 */
int32_t tkrzw_rekey(TkrzwDBM *db,
                    const char *old_key, size_t old_key_len,
                    const char *new_key, size_t new_key_len,
                    bool overwrite,
                    bool copying);

/**
 * Atomic compare-and-exchange on a single key.
 *
 *   expected            - TkrzwExpected selector
 *   expected_value,     - meaningful only when expected == EXACT; the bytes
 *   expected_value_len    the record must equal for the operation to apply
 *   desired             - TkrzwDesired selector
 *   desired_value,      - meaningful only when desired == SET; the bytes
 *   desired_value_len     to store
 *   actual_out,         - optional. On any return, when non-NULL receives a
 *   actual_len_out        malloc'd copy of the record's previous value
 *                         (caller frees) or (NULL, 0) if absent.
 *   found_out           - optional. Receives true iff the record existed
 *                         before the call.
 *
 * Returns SUCCESS if the desired action was applied, INFEASIBLE_ERROR if
 * the expected condition did not hold, or another error code on failure.
 */
int32_t tkrzw_compare_exchange(TkrzwDBM *db,
                               const char *key, size_t key_len,
                               TkrzwExpected expected,
                               const char *expected_value,
                               size_t expected_value_len,
                               TkrzwDesired desired,
                               const char *desired_value,
                               size_t desired_value_len,
                               char **actual_out,
                               size_t *actual_len_out,
                               bool *found_out);

/**
 * Atomic compare-and-exchange across multiple keys.
 *
 * All array inputs are parallel C arrays of length `num` (expected) and
 * `num_desired` (desired). The two arrays describe the precondition and
 * the action separately and may have different lengths.
 *
 *   expected_keys / expected_key_lens   - the keys whose state to inspect
 *   expected_modes                      - one TkrzwExpected per expected key
 *   expected_values / expected_value_lens - bytes for EXACT entries
 *                                           (ignored for ABSENT/ANY)
 *   desired_keys / desired_key_lens     - the keys to mutate
 *   desired_modes                       - one TkrzwDesired per desired key
 *   desired_values / desired_value_lens - bytes for SET entries
 *                                         (ignored for REMOVE/NOOP)
 *
 * Returns SUCCESS if all preconditions held and the actions were applied,
 * INFEASIBLE_ERROR otherwise.
 */
int32_t tkrzw_compare_exchange_multi(TkrzwDBM *db,
                                     const char *const *expected_keys,
                                     const size_t *expected_key_lens,
                                     const TkrzwExpected *expected_modes,
                                     const char *const *expected_values,
                                     const size_t *expected_value_lens,
                                     size_t num_expected,
                                     const char *const *desired_keys,
                                     const size_t *desired_key_lens,
                                     const TkrzwDesired *desired_modes,
                                     const char *const *desired_values,
                                     const size_t *desired_value_lens,
                                     size_t num_desired);

/**
 * Remove and return the lexicographically-first record.
 *   key_out / key_len_out     - optional; malloc'd buffer (caller frees)
 *   value_out / value_len_out - optional; malloc'd buffer (caller frees)
 * Returns NOT_FOUND_ERROR on an empty database.
 */
int32_t tkrzw_pop_first(TkrzwDBM *db,
                        char **key_out, size_t *key_len_out,
                        char **value_out, size_t *value_len_out);

/**
 * Append a record at the lexicographic end using a timestamp-derived key.
 *   wtime       - timestamp seed (Unix epoch seconds; pass a negative
 *                 value to use the current time).
 *   key_out / key_len_out - optional; if non-NULL, receives a malloc'd
 *                           copy of the generated key (caller frees).
 */
int32_t tkrzw_push_last(TkrzwDBM *db,
                        const char *value, size_t value_len,
                        double wtime,
                        char **key_out, size_t *key_len_out);

/* ===========================================================================
 * Cursor API
 *
 * A cursor is an opaque iterator bound to a single TkrzwDBM. The DBM must
 * remain open for the entire cursor lifetime. The caller must release
 * every cursor with tkrzw_cursor_free before closing the DBM.
 *
 * Only ordered backends (TreeDBM/.tkt, SkipDBM/.tks, BabyDBM/.tkmb)
 * support `last`, `previous`, `jump_lower`, `jump_upper` and inclusive
 * ordered semantics. Hash-based backends provide unordered iteration only.
 * =========================================================================== */

/**
 * Allocate a cursor bound to `db`. Returns NULL on failure (NULL db, OOM,
 * or backend refusal).
 */
TkrzwCursor *tkrzw_cursor_make(TkrzwDBM *db);

/**
 * Release a cursor. The cursor pointer is invalid after this call returns;
 * the caller should NULL its local pointer. Safe to call with NULL (no-op).
 * Calling this after tkrzw_deinit() will not crash: the cursor's own memory
 * is always reclaimed, and deregistration from the parent DBM's iterator
 * registry is skipped (the registry no longer exists once tkrzw_deinit
 * completes). The recommended order remains: free all cursors, then close
 * all DBMs, then call tkrzw_deinit.
 */
void tkrzw_cursor_free(TkrzwCursor *cur);

/** Position at the first record. */
int32_t tkrzw_cursor_first(TkrzwCursor *cur);

/** Position at the last record (ordered backends only). */
int32_t tkrzw_cursor_last(TkrzwCursor *cur);

/** Move forward. Returns NOT_FOUND_ERROR when past the last record. */
int32_t tkrzw_cursor_next(TkrzwCursor *cur);

/** Move backward (ordered backends only). */
int32_t tkrzw_cursor_previous(TkrzwCursor *cur);

/** Position at the first record whose key >= `key`. */
int32_t tkrzw_cursor_jump(TkrzwCursor *cur,
                          const char *key, size_t key_len);

/**
 * Position at the last record whose key <= `key`.
 *   inclusive - if false, requires strict < key.
 * Ordered backends only.
 */
int32_t tkrzw_cursor_jump_lower(TkrzwCursor *cur,
                                const char *key, size_t key_len,
                                bool inclusive);

/**
 * Position at the first record whose key >= `key`.
 *   inclusive - if false, requires strict > key.
 * Ordered backends only.
 */
int32_t tkrzw_cursor_jump_upper(TkrzwCursor *cur,
                                const char *key, size_t key_len,
                                bool inclusive);

/**
 * Read the current record without moving the cursor.
 *   key_out / key_len_out     - optional; malloc'd buffer (caller frees)
 *   value_out / value_len_out - optional; malloc'd buffer (caller frees)
 * Returns NOT_FOUND_ERROR if the cursor is not positioned on a record.
 */
int32_t tkrzw_cursor_get(TkrzwCursor *cur,
                         char **key_out, size_t *key_len_out,
                         char **value_out, size_t *value_len_out);

/**
 * Read the current record then advance to the next one.
 * Semantics for key_out / value_out match tkrzw_cursor_get.
 */
int32_t tkrzw_cursor_step(TkrzwCursor *cur,
                          char **key_out, size_t *key_len_out,
                          char **value_out, size_t *value_len_out);

/** Replace the current record's value. */
int32_t tkrzw_cursor_set(TkrzwCursor *cur,
                         const char *value, size_t value_len);

/** Remove the current record; the cursor advances to the next record. */
int32_t tkrzw_cursor_remove(TkrzwCursor *cur);

/* ===========================================================================
 * Callback-driven record processing
 *
 * The callback signature and lifetime rules are documented at
 * TkrzwRecordProcessor above.
 * =========================================================================== */

/**
 * Invoke `callback` for every record, exactly once per real record.
 * No empty-key boundary sentinels are delivered to the callback.
 *   writable - if true, return codes REMOVE/SET are honoured; if false,
 *              any non-NOOP return is treated as NOOP and an error may be
 *              raised by the backend.
 */
int32_t tkrzw_process_each(TkrzwDBM *db,
                           TkrzwRecordProcessor callback,
                           void *user_data,
                           bool writable);

/**
 * Invoke `callback` once on the record at `key`. If the record is absent
 * the callback is still invoked with (value=NULL, value_len=0); returning
 * SET in that case will create the record.
 * Note: if key is the empty string ("") and the record is absent, the
 * absent-key callback is suppressed (see TkrzwRecordProcessor for details).
 */
int32_t tkrzw_process(TkrzwDBM *db,
                      const char *key, size_t key_len,
                      TkrzwRecordProcessor callback,
                      void *user_data,
                      bool writable);

/** Invoke `callback` once on the first record (ordered or not). */
int32_t tkrzw_process_first(TkrzwDBM *db,
                            TkrzwRecordProcessor callback,
                            void *user_data,
                            bool writable);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* TKRZW_H */
