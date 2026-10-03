#include <fcntl.h>
#include <limits.h>
#include <stdio.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <sys/stat.h>
#include <unistd.h>
#include "kernel/errno.h"
#include "debug.h"
#include "misc.h"
#include "fs/fake-db.h"
#include "util/signpost.h"

static void db_check_error(struct fakefs_db *fs) {
    int errcode = sqlite3_errcode(fs->db);
    switch (errcode) {
        case SQLITE_OK:
        case SQLITE_ROW:
        case SQLITE_DONE:
            break;

        default:
            die("sqlite error: %d %#x %s", errcode, sqlite3_extended_errcode(fs->db), sqlite3_errmsg(fs->db));
    }
}

// Retry-aware variants that handle SQLITE_BUSY/SQLITE_LOCKED instead of aborting.
#define DB_RETRY_MAX 50
#define DB_RETRY_DELAY_US 20000  /* 20ms between retries = up to 1s total */

static bool db_exec_retry(struct fakefs_db *fs, sqlite3_stmt *stmt) {
    for (int attempt = 0; attempt < DB_RETRY_MAX; attempt++) {
        int err = sqlite3_step(stmt);
        if (err == SQLITE_ROW || err == SQLITE_DONE || err == SQLITE_OK)
            return err == SQLITE_ROW;
        int errcode = sqlite3_errcode(fs->db);
        if (errcode == SQLITE_BUSY || errcode == SQLITE_LOCKED) {
            sqlite3_reset(stmt);
            usleep(DB_RETRY_DELAY_US);
            continue;
        }
        db_check_error(fs);
        return false;
    }
    printk("WARNING: db_exec_retry exhausted %d attempts, proceeding\n", DB_RETRY_MAX);
    return false;
}

static void db_reset_retry(struct fakefs_db *fs, sqlite3_stmt *stmt) {
    for (int attempt = 0; attempt < DB_RETRY_MAX; attempt++) {
        sqlite3_reset(stmt);
        int errcode = sqlite3_errcode(fs->db);
        if (errcode == SQLITE_OK || errcode == SQLITE_ROW || errcode == SQLITE_DONE)
            return;
        if (errcode == SQLITE_BUSY || errcode == SQLITE_LOCKED) {
            usleep(DB_RETRY_DELAY_US);
            continue;
        }
        db_check_error(fs);
        return;
    }
    printk("WARNING: db_reset_retry exhausted %d attempts\n", DB_RETRY_MAX);
}

static sqlite3_stmt *db_prepare(struct fakefs_db *fs, const char *stmt) {
    sqlite3_stmt *statement;
    sqlite3_prepare_v2(fs->db, stmt, strlen(stmt) + 1, &statement, NULL);
    db_check_error(fs);
    return statement;
}

bool db_exec(struct fakefs_db *fs, sqlite3_stmt *stmt) {
    ISH_SIGNPOST_SCOPE_BEGIN(fs, "db_exec", _dbe_spid);
    bool r = db_exec_retry(fs, stmt);
    ISH_SIGNPOST_SCOPE_END(fs, "db_exec", _dbe_spid);
    return r;
}
void db_reset(struct fakefs_db *fs, sqlite3_stmt *stmt) {
    db_reset_retry(fs, stmt);
}
void db_exec_reset(struct fakefs_db *fs, sqlite3_stmt *stmt) {
    db_exec(fs, stmt);
    db_reset(fs, stmt);
}

// A transaction that changed anything invalidates the stat cache. Statements
// can write inside a "read" transaction too, so compare the change counter.
static void db_note_changes(struct fakefs_db *fs) {
    if (sqlite3_total_changes64(fs->db) != fs->txn_changes)
        fs->write_gen++;
}

static void db_ensure_open(struct fakefs_db *fs);
static int db_close_connection(struct fakefs_db *fs);
bool fake_db_is_parked(void);

void db_begin_read(struct fakefs_db *fs) {
    sqlite3_mutex_enter(fs->lock);
    db_ensure_open(fs);
    fs->txn_changes = sqlite3_total_changes64(fs->db);
    db_exec_reset(fs, fs->stmt.begin_deferred);
}
void db_begin_write(struct fakefs_db *fs) {
    sqlite3_mutex_enter(fs->lock);
    db_ensure_open(fs);
    fs->txn_changes = sqlite3_total_changes64(fs->db);
    fs->write_gen++;
    db_exec_reset(fs, fs->stmt.begin_immediate);
}
void db_commit(struct fakefs_db *fs) {
    db_exec_reset(fs, fs->stmt.commit);
    db_note_changes(fs);
    // Parked: a host thread reopened the connection for this transaction; close it again.
    if (fake_db_is_parked())
        db_close_connection(fs);
    sqlite3_mutex_leave(fs->lock);
}
void db_rollback(struct fakefs_db *fs) {
    db_exec_reset(fs, fs->stmt.rollback);
    db_note_changes(fs);
    if (fake_db_is_parked())
        db_close_connection(fs);
    sqlite3_mutex_leave(fs->lock);
}

// === stat cache ===
// path -> (inode, ish_stat) or "doesn't exist", direct-mapped by path hash.
// An entry is valid while the db is unchanged: this process's own changes
// bump write_gen, and a commit by another process (the iOS File Provider
// opens the same meta.db) rewrites meta.db-wal, changing its mtime or size.
// The token is taken before the SELECT, so a commit racing the fill leaves
// an entry that is already stale by token, never a stale one that looks
// valid.

#define STAT_CACHE_SIZE 8192

struct stat_cache_token {
    uint64_t write_gen;
    int64_t wal_mtime_ns;
    int64_t wal_size;
};

struct stat_cache_entry {
    char *path;
    uint32_t hash;
    bool exists;
    inode_t inode;
    struct ish_stat stat;
    struct stat_cache_token token;
};

struct stat_cache {
    pthread_mutex_t lock;
    // last look at meta.db-wal
    bool wal_valid;
    int64_t wal_checked_ns;
    int64_t wal_mtime_ns;
    int64_t wal_size;
    struct stat_cache_entry entries[STAT_CACHE_SIZE];
};

static uint32_t stat_cache_hash(const char *path) {
    uint32_t hash = 2166136261u;
    for (const char *c = path; *c != '\0'; c++)
        hash = (hash ^ (uint8_t) *c) * 16777619u;
    return hash;
}

// Another process's commit is noticed within this long; checking the wal on
// every lookup would cost about as much as the lookup saves.
#define WAL_CHECK_INTERVAL_NS 1000000

static int64_t monotonic_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t) ts.tv_sec * 1000000000 + ts.tv_nsec;
}

static bool stat_cache_token(struct fakefs_db *fs, struct stat_cache_token *token) {
    struct stat_cache *cache = fs->stat_cache;
    if (cache == NULL || fs->wal_fd < 0)
        return false;
    int64_t now = monotonic_ns();
    pthread_mutex_lock(&cache->lock);
    bool fresh = cache->wal_valid && now - cache->wal_checked_ns < WAL_CHECK_INTERVAL_NS;
    int64_t mtime = cache->wal_mtime_ns, size = cache->wal_size;
    pthread_mutex_unlock(&cache->lock);
    if (!fresh) {
        struct stat wal;
        if (fstat(fs->wal_fd, &wal) < 0 || wal.st_nlink == 0)
            return false;
#if __APPLE__
        mtime = (int64_t) wal.st_mtimespec.tv_sec * 1000000000 + wal.st_mtimespec.tv_nsec;
#else
        mtime = (int64_t) wal.st_mtim.tv_sec * 1000000000 + wal.st_mtim.tv_nsec;
#endif
        size = wal.st_size;
        pthread_mutex_lock(&cache->lock);
        cache->wal_mtime_ns = mtime;
        cache->wal_size = size;
        cache->wal_checked_ns = now;
        cache->wal_valid = true;
        pthread_mutex_unlock(&cache->lock);
    }
    token->write_gen = fs->write_gen;
    token->wal_mtime_ns = mtime;
    token->wal_size = size;
    return true;
}

static bool stat_cache_token_eq(const struct stat_cache_token *a, const struct stat_cache_token *b) {
    return a->write_gen == b->write_gen && a->wal_mtime_ns == b->wal_mtime_ns && a->wal_size == b->wal_size;
}

int path_read_stat_cached(struct fakefs_db *fs, const char *path, struct ish_stat *stat, inode_t *inode) {
    struct stat_cache_token now;
    if (!stat_cache_token(fs, &now))
        return -1;
    uint32_t hash = stat_cache_hash(path);
    struct stat_cache_entry *e = &fs->stat_cache->entries[hash % STAT_CACHE_SIZE];
    int res = -1;
    pthread_mutex_lock(&fs->stat_cache->lock);
    if (e->path != NULL && e->hash == hash && stat_cache_token_eq(&e->token, &now) &&
            strcmp(e->path, path) == 0) {
        res = e->exists;
        if (e->exists) {
            if (stat)
                *stat = e->stat;
            if (inode)
                *inode = e->inode;
        }
    }
    pthread_mutex_unlock(&fs->stat_cache->lock);
    return res;
}

static void stat_cache_fill(struct fakefs_db *fs, const char *path, const struct stat_cache_token *token,
        bool exists, inode_t inode, const struct ish_stat *stat) {
    uint32_t hash = stat_cache_hash(path);
    struct stat_cache_entry *e = &fs->stat_cache->entries[hash % STAT_CACHE_SIZE];
    char *copy = strdup(path);
    if (copy == NULL)
        return;
    pthread_mutex_lock(&fs->stat_cache->lock);
    char *old = e->path;
    e->path = copy;
    e->hash = hash;
    e->exists = exists;
    e->inode = inode;
    if (exists)
        e->stat = *stat;
    e->token = *token;
    pthread_mutex_unlock(&fs->stat_cache->lock);
    free(old);
}

static void bind_path(sqlite3_stmt *stmt, int i, const char *path) {
    sqlite3_bind_blob(stmt, i, path, strlen(path), SQLITE_TRANSIENT);
}

inode_t path_get_inode(struct fakefs_db *fs, const char *path) {
    // select inode from paths where path = ?
    bind_path(fs->stmt.path_get_inode, 1, path);
    inode_t inode = 0;
    if (db_exec(fs, fs->stmt.path_get_inode))
        inode = sqlite3_column_int64(fs->stmt.path_get_inode, 0);
    db_reset(fs, fs->stmt.path_get_inode);
    return inode;
}
bool path_read_stat(struct fakefs_db *fs, const char *path, struct ish_stat *stat, inode_t *inode) {
    // Inside a write transaction the db may already differ from what any
    // cached entry says, so skip the cache there.
    bool cacheable = sqlite3_total_changes64(fs->db) == fs->txn_changes;
    struct stat_cache_token token;
    if (cacheable && !stat_cache_token(fs, &token))
        cacheable = false;
    if (cacheable) {
        int cached = path_read_stat_cached(fs, path, stat, inode);
        if (cached >= 0)
            return cached;
    }
    // select inode, stat from stats natural join paths where path = ?
    bind_path(fs->stmt.path_read_stat, 1, path);
    bool exists = db_exec(fs, fs->stmt.path_read_stat);
    inode_t found_inode = 0;
    struct ish_stat found_stat = {0};
    if (exists) {
        found_inode = sqlite3_column_int64(fs->stmt.path_read_stat, 0);
        found_stat = *(struct ish_stat *) sqlite3_column_blob(fs->stmt.path_read_stat, 1);
        if (inode)
            *inode = found_inode;
        if (stat)
            *stat = found_stat;
    }
    db_reset(fs, fs->stmt.path_read_stat);
    if (cacheable)
        stat_cache_fill(fs, path, &token, exists, found_inode, &found_stat);
    return exists;
}
inode_t path_create(struct fakefs_db *fs, const char *path, struct ish_stat *stat) {
    // insert into stats (stat) values (?)
    sqlite3_bind_blob(fs->stmt.path_create_stat, 1, stat, sizeof(*stat), SQLITE_TRANSIENT);
    db_exec_reset(fs, fs->stmt.path_create_stat);
    inode_t inode = sqlite3_last_insert_rowid(fs->db);
    // insert or replace into paths values (?, last_insert_rowid())
    bind_path(fs->stmt.path_create_path, 1, path);
    db_exec_reset(fs, fs->stmt.path_create_path);
    return inode;
}

void inode_read_stat_or_die(struct fakefs_db *fs, inode_t inode, struct ish_stat *stat) {
    if (!inode_read_stat_if_exist(fs, inode, stat))
        die("inode_read_stat(%llu): missing inode", (unsigned long long) inode);
}
bool inode_read_stat_if_exist(struct fakefs_db *fs, inode_t inode, struct ish_stat *stat) {
    // select stat from stats where inode = ?
    sqlite3_bind_int64(fs->stmt.inode_read_stat, 1, inode);
    bool exist = db_exec(fs, fs->stmt.inode_read_stat);
    if (exist)
        *stat = *(struct ish_stat *) sqlite3_column_blob(fs->stmt.inode_read_stat, 0);
    db_reset(fs, fs->stmt.inode_read_stat);
    return exist;
}
void inode_write_stat(struct fakefs_db *fs, inode_t inode, struct ish_stat *stat) {
    // update stats set stat = ? where inode = ?
    sqlite3_bind_blob(fs->stmt.inode_write_stat, 1, stat, sizeof(*stat), SQLITE_TRANSIENT);
    sqlite3_bind_int64(fs->stmt.inode_write_stat, 2, inode);
    db_exec_reset(fs, fs->stmt.inode_write_stat);
}

void path_link(struct fakefs_db *fs, const char *src, const char *dst) {
    inode_t inode = path_get_inode(fs, src);
    if (inode == 0)
        die("fakefs link(%s, %s): nonexistent src path", src, dst);
    // insert or replace into paths (path, inode) values (?, ?)
    bind_path(fs->stmt.path_link, 1, dst);
    sqlite3_bind_int64(fs->stmt.path_link, 2, inode);
    db_exec_reset(fs, fs->stmt.path_link);
}
inode_t path_unlink(struct fakefs_db *fs, const char *path) {
    inode_t inode = path_get_inode(fs, path);
    if (inode == 0)
        return 0;  // Path not in meta.db — already gone or never tracked
    // delete from paths where path = ?
    bind_path(fs->stmt.path_unlink, 1, path);
    db_exec_reset(fs, fs->stmt.path_unlink);
    return inode;
}
void path_rename(struct fakefs_db *fs, const char *src, const char *dst) {
    // update or replace paths set path = change_prefix(path, ? [len(src)], ? [dst])
    //  where (path >= ? [src plus /] and path < [src plus 0]) or path = ? [src]
    // arguments:
    // 1. length of src
    // 2. dst
    // 3. src plus /
    // 4. src plus 0
    // 5. src
    size_t src_len = strlen(src);
    sqlite3_bind_int64(fs->stmt.path_rename, 1, src_len);
    bind_path(fs->stmt.path_rename, 2, dst);
    char src_extra[src_len + 1];
    memcpy(src_extra, src, src_len);
    src_extra[src_len] = '/';
    sqlite3_bind_blob(fs->stmt.path_rename, 3, src_extra, src_len + 1, SQLITE_TRANSIENT);
    src_extra[src_len] = '0';
    sqlite3_bind_blob(fs->stmt.path_rename, 4, src_extra, src_len + 1, SQLITE_TRANSIENT);
    sqlite3_bind_blob(fs->stmt.path_rename, 5, src_extra, src_len, SQLITE_TRANSIENT);
    db_exec_reset(fs, fs->stmt.path_rename);
}

#if DEBUG_sql
static int trace_callback(unsigned UNUSED(why), void *UNUSED(fuck), void *stmt, void *_sql) {
    char *sql = _sql;
    printk("%d sql trace: %s %s\n", current ? current->pid : -1, sqlite3_expanded_sql(stmt), sql[0] == '-' ? sql : "");
    return 0;
}
#endif

static void sqlite_func_change_prefix(sqlite3_context *context, int argc, sqlite3_value **args) {
    assert(argc == 3);
    const void *in_blob = sqlite3_value_blob(args[0]);
    size_t in_size = sqlite3_value_bytes(args[0]);
    size_t start = sqlite3_value_int64(args[1]);
    const void *replacement = sqlite3_value_blob(args[2]);
    size_t replacement_size = sqlite3_value_bytes(args[2]);
    size_t out_size = in_size - start + replacement_size;
    char *out_blob = sqlite3_malloc(out_size);
    memcpy(out_blob, replacement, replacement_size);
    memcpy(out_blob + replacement_size, in_blob + start, in_size - start);
    sqlite3_result_blob(context, out_blob, out_size, sqlite3_free);
}

extern int fakefs_rebuild(struct fakefs_db *fs, int root_fd);
extern int fakefs_migrate(struct fakefs_db *fs, int root_fd);

// Opens the connection with the settings every connection needs. The maintenance that
// only the first open does (migration, rebuild, orphan cleanup) is in fake_db_init.
static int db_open_connection(struct fakefs_db *fs, const char *db_path) {
    int err = sqlite3_open_v2(db_path, &fs->db, SQLITE_OPEN_READWRITE, NULL);
    if (err != SQLITE_OK) {
        printk("error opening database: %s\n", sqlite3_errmsg(fs->db));
        sqlite3_close(fs->db);
        fs->db = NULL;
        return _EINVAL;
    }
    sqlite3_busy_timeout(fs->db, 5000);
    sqlite3_create_function(fs->db, "change_prefix", 3, SQLITE_UTF8 | SQLITE_DETERMINISTIC, NULL, sqlite_func_change_prefix, NULL, NULL);
    db_check_error(fs);

    // let's do WAL mode
    sqlite3_stmt *statement = db_prepare(fs, "pragma journal_mode=wal");
    db_check_error(fs);
    sqlite3_step(statement);
    db_check_error(fs);
    sqlite3_finalize(statement);

    statement = db_prepare(fs, "pragma foreign_keys=true");
    db_check_error(fs);
    sqlite3_step(statement);
    db_check_error(fs);
    sqlite3_finalize(statement);

    // N18: Apple-friendly sqlite tuning. The fakefs db is read-mostly
    // during normal use (writes happen for chmod / chown / mknod / new
    // files). N17 signpost data showed 78K db_exec calls totaling
    // 122ms = 8% of npm --version user CPU. Three knobs help on macOS:
    //
    //  - PRAGMA mmap_size: lets sqlite read pages directly through
    //    mmap instead of read() syscalls. The OS's unified buffer
    //    cache then serves repeated reads at memcpy speed.
    //  - PRAGMA cache_size (negative => KB of in-process page cache):
    //    sqlite default is 2 MB; bump to 64 MB so the working set fits.
    //  - PRAGMA synchronous=NORMAL: WAL with NORMAL is durable across
    //    process crashes (like FULL) but skips an fsync per commit,
    //    cheap when fakefs writes are infrequent.
    //  - PRAGMA temp_store=MEMORY: keeps sort/temp tables off disk.
    static const char *tuning[] = {
        "pragma mmap_size=268435456",   // 256 MB
        "pragma cache_size=-65536",     // 64 MB in-process page cache
        "pragma synchronous=NORMAL",
        "pragma temp_store=MEMORY",
    };
    for (size_t ti = 0; ti < sizeof(tuning)/sizeof(tuning[0]); ti++) {
        statement = db_prepare(fs, tuning[ti]);
        db_check_error(fs);
        sqlite3_step(statement);
        db_check_error(fs);
        sqlite3_finalize(statement);
    }

#if DEBUG_sql
    sqlite3_trace_v2(mount->db, SQLITE_TRACE_STMT, trace_callback, NULL);
#endif
    return 0;
}

static void db_prepare_statements(struct fakefs_db *fs) {
    char wal_path[PATH_MAX];
    snprintf(wal_path, sizeof(wal_path), "%s-wal", fs->db_path);
    fs->wal_fd = open(wal_path, O_RDONLY | O_CLOEXEC);
    fs->stmt.begin_deferred = db_prepare(fs, "begin deferred");
    fs->stmt.begin_immediate = db_prepare(fs, "begin immediate");
    fs->stmt.commit = db_prepare(fs, "commit");
    fs->stmt.rollback = db_prepare(fs, "rollback");
    fs->stmt.path_get_inode = db_prepare(fs, "select inode from paths where path = ?");
    fs->stmt.path_read_stat = db_prepare(fs, "select inode, stat from stats natural join paths where path = ?");
    fs->stmt.path_create_stat = db_prepare(fs, "insert into stats (stat) values (?)");
    fs->stmt.path_create_path = db_prepare(fs, "insert or replace into paths values (?, last_insert_rowid())");
    fs->stmt.inode_read_stat = db_prepare(fs, "select stat from stats where inode = ?");
    fs->stmt.inode_write_stat = db_prepare(fs, "update stats set stat = ? where inode = ?");
    fs->stmt.path_link = db_prepare(fs, "insert or replace into paths (path, inode) values (?, ?)");
    fs->stmt.path_unlink = db_prepare(fs, "delete from paths where path = ?");
    fs->stmt.path_rename = db_prepare(fs, "update or replace paths set path = change_prefix(path, ?, ?) "
            "where (path >= ? and path < ?) or path = ?");
    fs->stmt.path_from_inode = db_prepare(fs, "select path from paths where inode = ?");
    fs->stmt.try_cleanup_inode = db_prepare(fs, "delete from stats where inode = ? and not exists (select 1 from paths where inode = stats.inode)");
}

// Finalizes the statements and closes the connection, which releases every lock SQLite
// holds on meta.db and meta.db-shm. Called with fs->lock held (or before it exists).
static int db_close_connection(struct fakefs_db *fs) {
    if (fs->db == NULL)
        return SQLITE_OK;
    sqlite3_stmt **statements = (sqlite3_stmt **) &fs->stmt;
    for (size_t i = 0; i < sizeof(fs->stmt) / sizeof(sqlite3_stmt *); i++) {
        sqlite3_finalize(statements[i]);
        statements[i] = NULL;
    }
    if (fs->wal_fd >= 0)
        close(fs->wal_fd);
    fs->wal_fd = -1;
    int err = sqlite3_close(fs->db);
    if (err != SQLITE_OK)
        printk("WARNING: closing meta.db: %d\n", err);
    fs->db = NULL;
    return err;
}

int fake_db_init(struct fakefs_db *fs, const char *db_path, int root_fd) {
    fs->stat_cache = NULL;
    fs->wal_fd = -1;
    fs->db = NULL;
    fs->db_path = strdup(db_path);
    int err = db_open_connection(fs, db_path);
    if (err < 0)
        return err;
    sqlite3_stmt *statement;

    err = fakefs_migrate(fs, root_fd);
    if (err < 0)
        return err;

    // after the filesystem is compressed, transmitted, and uncompressed, the
    // inode numbers will be different. to detect this, the inode of the
    // database file is stored inside the database and compared with the actual
    // database file inode, and if they're different we rebuild the database.
    struct stat statbuf;
    if (stat(db_path, &statbuf) < 0) ERRNO_DIE("stat database");
    ino_t db_inode = statbuf.st_ino;
    statement = db_prepare(fs, "select db_inode from meta");
    if (sqlite3_step(statement) == SQLITE_ROW) {
        if ((uint64_t) sqlite3_column_int64(statement, 0) != db_inode) {
            sqlite3_finalize(statement);
            statement = NULL;
            int err = fakefs_rebuild(fs, root_fd);
            if (err < 0) {
                return err;
            }
        }
    }
    if (statement != NULL)
        sqlite3_finalize(statement);

    // save current inode
    statement = db_prepare(fs, "update meta set db_inode = ?");
    sqlite3_bind_int64(statement, 1, (int64_t) db_inode);
    db_check_error(fs);
    sqlite3_step(statement);
    db_check_error(fs);
    sqlite3_finalize(statement);

    // delete orphaned stats
    statement = db_prepare(fs, "delete from stats where not exists (select 1 from paths where inode = stats.inode)");
    db_check_error(fs);
    sqlite3_step(statement);
    db_check_error(fs);
    sqlite3_finalize(statement);

    fs->lock = sqlite3_mutex_alloc(SQLITE_MUTEX_FAST);
    fs->write_gen = 0;
    fs->txn_changes = 0;
    fs->stat_cache = calloc(1, sizeof(struct stat_cache));
    if (fs->stat_cache != NULL)
        pthread_mutex_init(&fs->stat_cache->lock, NULL);
    db_prepare_statements(fs);
    return 0;
}

int fake_db_deinit(struct fakefs_db *fs) {
    if (fs->stat_cache != NULL) {
        for (int i = 0; i < STAT_CACHE_SIZE; i++)
            free(fs->stat_cache->entries[i].path);
        pthread_mutex_destroy(&fs->stat_cache->lock);
        free(fs->stat_cache);
        fs->stat_cache = NULL;
    }
    int err = db_close_connection(fs);
    free(fs->db_path);
    fs->db_path = NULL;
    return err;
}

// === parking (fs/fake-flush.h) ===
// iPadOS ends a suspended app that holds a lock on a file in its shared container
// (0xDEAD10CC), and an open WAL connection always holds one on meta.db-shm. Before
// LinPad is suspended the connections are closed ("parked"). While parked, guest tasks
// wait at their next system call entry (fake_db_wait_while_parked, called from the
// syscall dispatcher, where they hold no kernel lock) until LinPad is in front again;
// they would be frozen by the suspension anyway. Anything already inside a system call,
// and the app's own threads, reopen the connection for one transaction and it is closed
// again at its end, so no lock outlives a transaction.

static pthread_mutex_t park_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t park_cond = PTHREAD_COND_INITIALIZER;
static _Atomic bool parked;

void fake_db_set_parked(bool park) {
    pthread_mutex_lock(&park_lock);
    parked = park;
    if (!park)
        pthread_cond_broadcast(&park_cond);
    pthread_mutex_unlock(&park_lock);
}

bool fake_db_is_parked(void) {
    return parked;
}

void fake_db_wait_while_parked(void) {
    if (!parked)
        return;
    pthread_mutex_lock(&park_lock);
    while (parked)
        pthread_cond_wait(&park_cond, &park_lock);
    pthread_mutex_unlock(&park_lock);
}

// With fs->lock held: the connection is open when this returns.
static void db_ensure_open(struct fakefs_db *fs) {
    if (fs->db != NULL)
        return;
    if (db_open_connection(fs, fs->db_path) < 0)
        die("could not reopen %s", fs->db_path);
    db_prepare_statements(fs);
    // Another process (the File Provider) may have changed the db meanwhile.
    fs->write_gen++;
}

void fake_db_park(struct fakefs_db *fs) {
    sqlite3_mutex_enter(fs->lock);
    if (fs->db != NULL) {
        int log_frames = 0, checkpointed = 0;
        sqlite3_wal_checkpoint_v2(fs->db, NULL, SQLITE_CHECKPOINT_PASSIVE, &log_frames, &checkpointed);
        db_close_connection(fs);
    }
    fs->write_gen++;
    sqlite3_mutex_leave(fs->lock);
}

bool fake_db_is_open(struct fakefs_db *fs) {
    sqlite3_mutex_enter(fs->lock);
    bool open = fs->db != NULL;
    sqlite3_mutex_leave(fs->lock);
    return open;
}
