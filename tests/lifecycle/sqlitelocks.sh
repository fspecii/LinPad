#!/bin/sh
# Guest side of the lock tests: SQLite (what Firefox, VS Code and Zim keep their state
# in) relies on fcntl record locks. Four processes insert into one database at once in
# rollback-journal and in WAL mode; every row must arrive, the database must pass its
# integrity check, and a reader must see a writer's exclusive lock (SQLITE_BUSY).
# Prints "bad=N".
bad=0
for mode in delete wal; do
    db=/tmp/sqlitelocks-$mode.db
    rm -f "$db" "$db-wal" "$db-shm" "$db-journal"
    sqlite3 "$db" "pragma journal_mode=$mode; create table t(w int, i int);" >/dev/null
    for w in 1 2 3 4; do
        (i=0; while [ $i -lt 50 ]; do
            sqlite3 -cmd '.timeout 20000' "$db" "insert into t values($w, $i);" || echo "insert failed $w $i"
            i=$((i + 1))
        done) &
    done
    wait
    rows=$(sqlite3 "$db" "select count(*) from t")
    check=$(sqlite3 "$db" "pragma integrity_check")
    [ "$rows" = 200 ] && [ "$check" = ok ] && echo "ok   $mode: 4 writers, 200 rows, integrity ok" ||
        { echo "FAIL $mode: rows=$rows integrity=$check"; bad=$((bad + 1)); }
done
db=/tmp/sqlitelocks-delete.db
printf 'begin exclusive;\ninsert into t values(9, 9);\n.shell sleep 2\ncommit;\n' | sqlite3 "$db" >/dev/null &
sleep 1
if sqlite3 "$db" "select count(*) from t" 2>&1 | grep -q "locked"; then
    echo "ok   a reader sees a writer's exclusive lock (database is locked)"
else
    echo "FAIL a reader did not see the exclusive lock"; bad=$((bad + 1))
fi
wait
echo "bad=$bad"
