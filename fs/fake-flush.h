#ifndef FS_FAKE_FLUSH_H
#define FS_FAKE_FLUSH_H

// Makes everything the guest wrote so far durable, for the app's move to the
// background: host file data, then every fakefs meta.db (a WAL checkpoint and a full
// fsync of the database file). Returns the number of databases flushed. Safe to call
// from any thread while guest programs run; it blocks for as long as the checkpoint
// takes.
int ish_fakefs_flush(void);

#endif
