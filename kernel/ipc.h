#ifndef KERNEL_IPC_H
#define KERNEL_IPC_H
#include "misc.h"

struct proc_entry;
struct proc_data;

// The thread group tgid is gone: undo its SEM_UNDO semaphore operations.
void sysv_ipc_exit(pid_t_ tgid);

int proc_sysvipc_shm(struct proc_entry *entry, struct proc_data *buf);
int proc_sysvipc_sem(struct proc_entry *entry, struct proc_data *buf);
int proc_sysvipc_msg(struct proc_entry *entry, struct proc_data *buf);
int proc_sys_kernel_shmmax(struct proc_entry *entry, struct proc_data *buf);
int proc_sys_kernel_shmall(struct proc_entry *entry, struct proc_data *buf);
int proc_sys_kernel_shmmni(struct proc_entry *entry, struct proc_data *buf);
int proc_sys_kernel_sem(struct proc_entry *entry, struct proc_data *buf);
int proc_sys_kernel_msgmax(struct proc_entry *entry, struct proc_data *buf);
int proc_sys_kernel_msgmnb(struct proc_entry *entry, struct proc_data *buf);
int proc_sys_kernel_msgmni(struct proc_entry *entry, struct proc_data *buf);

#endif
