/* libish-sysvipc.so: process-local System V shared memory and semaphores for apps
 * that need them only to find another running copy of themselves.
 *
 * iSH implements no System V IPC (shmget, semget, ... return ENOSYS). Audacity uses
 * them for its single-instance check and quits with "Unable to create shared memory
 * segment" when they fail. Preloaded into such apps (LinPad Store fixups), these calls
 * first try the kernel; on ENOSYS they fall back to an in-process table, so every
 * launch behaves like the first copy of the app: it starts, and a second launch opens
 * a second window instead of handing its files to the first.
 *
 * Build (in the guest, with build-base): see build-fixups.sh next to this file. */
#define _GNU_SOURCE
#include <errno.h>
#include <stdarg.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ipc.h>
#include <sys/sem.h>
#include <sys/shm.h>
#include <sys/syscall.h>
#include <unistd.h>

#define MAX_OBJECTS 64
#define FAKE_ID_BASE 0x15500000
#define MAX_SEMS 16

struct shm_object {
    key_t key;
    size_t size;
    void *memory;
    int used;
};

struct sem_object {
    key_t key;
    int count;
    int values[MAX_SEMS];
    int used;
};

static struct shm_object shms[MAX_OBJECTS];
static struct sem_object sems[MAX_OBJECTS];

static int enosys(long result) {
    return result == -1 && errno == ENOSYS;
}

int shmget(key_t key, size_t size, int flags) {
    long r = syscall(SYS_shmget, key, size, flags);
    if (!enosys(r)) return (int) r;
    for (int i = 0; i < MAX_OBJECTS; i++) {
        if (shms[i].used && key != IPC_PRIVATE && shms[i].key == key) {
            if ((flags & IPC_CREAT) && (flags & IPC_EXCL)) { errno = EEXIST; return -1; }
            return FAKE_ID_BASE + i;
        }
    }
    if (!(flags & IPC_CREAT) && key != IPC_PRIVATE) { errno = ENOENT; return -1; }
    for (int i = 0; i < MAX_OBJECTS; i++) {
        if (shms[i].used) continue;
        void *memory = calloc(1, size ? size : 1);
        if (!memory) { errno = ENOMEM; return -1; }
        shms[i] = (struct shm_object) { .key = key, .size = size, .memory = memory, .used = 1 };
        return FAKE_ID_BASE + i;
    }
    errno = ENOSPC;
    return -1;
}

static struct shm_object *shm_lookup(int id) {
    int i = id - FAKE_ID_BASE;
    return i >= 0 && i < MAX_OBJECTS && shms[i].used ? &shms[i] : NULL;
}

void *shmat(int id, const void *address, int flags) {
    struct shm_object *object = shm_lookup(id);
    if (!object) return (void *) syscall(SYS_shmat, id, address, flags);
    return object->memory;
}

int shmdt(const void *address) {
    for (int i = 0; i < MAX_OBJECTS; i++)
        if (shms[i].used && shms[i].memory == address) return 0;
    return (int) syscall(SYS_shmdt, address);
}

int shmctl(int id, int command, struct shmid_ds *buffer) {
    struct shm_object *object = shm_lookup(id);
    if (!object) return (int) syscall(SYS_shmctl, id, command, buffer);
    switch (command) {
    case IPC_RMID:
        return 0;
    case IPC_STAT:
        if (buffer) {
            memset(buffer, 0, sizeof *buffer);
            buffer->shm_segsz = object->size;
            buffer->shm_nattch = 1;
            buffer->shm_perm.__key = object->key;
            buffer->shm_perm.mode = 0600;
        }
        return 0;
    default:
        return 0;
    }
}

int semget(key_t key, int count, int flags) {
    long r = syscall(SYS_semget, key, count, flags);
    if (!enosys(r)) return (int) r;
    if (count < 0 || count > MAX_SEMS) { errno = EINVAL; return -1; }
    for (int i = 0; i < MAX_OBJECTS; i++) {
        if (sems[i].used && key != IPC_PRIVATE && sems[i].key == key) {
            if ((flags & IPC_CREAT) && (flags & IPC_EXCL)) { errno = EEXIST; return -1; }
            return FAKE_ID_BASE + i;
        }
    }
    if (!(flags & IPC_CREAT) && key != IPC_PRIVATE) { errno = ENOENT; return -1; }
    for (int i = 0; i < MAX_OBJECTS; i++) {
        if (sems[i].used) continue;
        sems[i] = (struct sem_object) { .key = key, .count = count, .used = 1 };
        return FAKE_ID_BASE + i;
    }
    errno = ENOSPC;
    return -1;
}

static struct sem_object *sem_lookup(int id) {
    int i = id - FAKE_ID_BASE;
    return i >= 0 && i < MAX_OBJECTS && sems[i].used ? &sems[i] : NULL;
}

/* One process: an operation that would block can never be woken, so it fails with
 * EAGAIN, as IPC_NOWAIT asks, instead of hanging. */
int semtimedop(int id, struct sembuf *ops, size_t count, const struct timespec *timeout) {
    struct sem_object *object = sem_lookup(id);
    if (!object) return (int) syscall(SYS_semtimedop, id, ops, count, timeout);
    for (size_t i = 0; i < count; i++) {
        if (ops[i].sem_num >= object->count) { errno = EFBIG; return -1; }
        int value = object->values[ops[i].sem_num] + ops[i].sem_op;
        if (value < 0 || (ops[i].sem_op == 0 && object->values[ops[i].sem_num] != 0)) { errno = EAGAIN; return -1; }
    }
    for (size_t i = 0; i < count; i++) object->values[ops[i].sem_num] += ops[i].sem_op;
    return 0;
}

int semop(int id, struct sembuf *ops, size_t count) {
    return semtimedop(id, ops, count, NULL);
}

int semctl(int id, int number, int command, ...) {
    va_list args;
    va_start(args, command);
    unsigned long argument = va_arg(args, unsigned long);
    va_end(args);
    struct sem_object *object = sem_lookup(id);
    if (!object) return (int) syscall(SYS_semctl, id, number, command, argument);
    if (command == IPC_RMID) return 0;
    if (number < 0 || number >= object->count) { errno = EINVAL; return -1; }
    switch (command) {
    case SETVAL: object->values[number] = (int) argument; return 0;
    case GETVAL: return object->values[number];
    default: return 0;
    }
}
