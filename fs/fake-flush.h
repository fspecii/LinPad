#ifndef FS_FAKE_FLUSH_H
#define FS_FAKE_FLUSH_H

// Makes everything the guest wrote so far durable, for the app's move to the
// background: host file data, then every fakefs meta.db (a WAL checkpoint and a full
// fsync of the database file). Returns the number of databases flushed. Safe to call
// from any thread while guest programs run; it blocks for as long as the checkpoint
// takes.
int ish_fakefs_flush(void);

// Closes every fakefs meta.db connection so LinPad holds no lock on a file in its shared
// container while iPadOS suspends it (a suspended app holding one is killed,
// 0xDEAD10CC). Until ish_fakefs_unpark, guest tasks wait at their next system call
// (fakefs_park_gate); anything else that needs the database reopens a connection for
// one transaction. Call after ish_fakefs_flush, as the last thing before the app may be
// suspended.
int ish_fakefs_park(void);
void ish_fakefs_unpark(void);
// Called by the system call dispatcher, where a guest task holds no kernel lock: waits
// while the file system is parked. One atomic load when it is not.
void fakefs_park_gate(void);
// How many meta.db connections are open now (0 while parked and idle), for tests.
int ish_fakefs_open_connections(void);

#endif
