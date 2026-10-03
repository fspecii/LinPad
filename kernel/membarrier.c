// membarrier(2). Guest threads are host threads, so a guest barrier on every
// running thread of the process is a host barrier on every thread of ish.
// Without the syscall musl falls back to signalling every thread and waiting
// for all of them (dlopen of a library with TLS does this), which is slow and
// deadlocked Audacity's start-up.
#include <stdatomic.h>
#if __APPLE__
#include <mach/mach.h>
#include <mach/thread_state.h>
#endif
#include "kernel/calls.h"
#include "kernel/errno.h"
#include "kernel/mm.h"
#include "kernel/task.h"

#define MEMBARRIER_CMD_QUERY_ 0
#define MEMBARRIER_CMD_GLOBAL_ (1 << 0)
#define MEMBARRIER_CMD_GLOBAL_EXPEDITED_ (1 << 1)
#define MEMBARRIER_CMD_REGISTER_GLOBAL_EXPEDITED_ (1 << 2)
#define MEMBARRIER_CMD_PRIVATE_EXPEDITED_ (1 << 3)
#define MEMBARRIER_CMD_REGISTER_PRIVATE_EXPEDITED_ (1 << 4)
#define MEMBARRIER_CMD_PRIVATE_EXPEDITED_SYNC_CORE_ (1 << 5)
#define MEMBARRIER_CMD_REGISTER_PRIVATE_EXPEDITED_SYNC_CORE_ (1 << 6)
#define MEMBARRIER_CMD_GET_REGISTRATIONS_ (1 << 9)

#define MEMBARRIER_SUPPORTED (MEMBARRIER_CMD_GLOBAL_ | MEMBARRIER_CMD_GLOBAL_EXPEDITED_ | \
        MEMBARRIER_CMD_REGISTER_GLOBAL_EXPEDITED_ | MEMBARRIER_CMD_PRIVATE_EXPEDITED_ | \
        MEMBARRIER_CMD_REGISTER_PRIVATE_EXPEDITED_ | MEMBARRIER_CMD_PRIVATE_EXPEDITED_SYNC_CORE_ | \
        MEMBARRIER_CMD_REGISTER_PRIVATE_EXPEDITED_SYNC_CORE_ | MEMBARRIER_CMD_GET_REGISTRATIONS_)

// A full memory barrier on every thread of the host process. On Darwin, as
// .NET's FlushProcessWriteBuffers does: reading another thread's registers
// makes the kernel stop it, which orders its memory accesses.
static void host_membarrier(void) {
    atomic_thread_fence(memory_order_seq_cst);
#if __APPLE__
    thread_act_array_t threads;
    mach_msg_type_number_t count;
    if (task_threads(mach_task_self(), &threads, &count) != KERN_SUCCESS)
        return;
    thread_act_t self = mach_thread_self();
    for (mach_msg_type_number_t i = 0; i < count; i++) {
        if (threads[i] != self) {
            uintptr_t sp;
            uintptr_t regs[128];
            size_t nregs = sizeof(regs) / sizeof(regs[0]);
            thread_get_register_pointer_values(threads[i], &sp, &nregs, regs);
        }
        mach_port_deallocate(mach_task_self(), threads[i]);
    }
    mach_port_deallocate(mach_task_self(), self);
    vm_deallocate(mach_task_self(), (vm_address_t) threads, count * sizeof(threads[0]));
    atomic_thread_fence(memory_order_seq_cst);
#endif
}

int_t sys_membarrier(int_t cmd, uint_t flags, int_t UNUSED(cpu_id)) {
    STRACE("membarrier(%#x, %#x)", cmd, flags);
    if (flags != 0)
        return _EINVAL;
    struct mm *mm = current->mm;
    switch (cmd) {
        case MEMBARRIER_CMD_QUERY_:
            return MEMBARRIER_SUPPORTED;
        case MEMBARRIER_CMD_GET_REGISTRATIONS_:
            return atomic_load(&mm->membarrier_registered);
        case MEMBARRIER_CMD_REGISTER_GLOBAL_EXPEDITED_:
        case MEMBARRIER_CMD_REGISTER_PRIVATE_EXPEDITED_:
        case MEMBARRIER_CMD_REGISTER_PRIVATE_EXPEDITED_SYNC_CORE_:
            atomic_fetch_or(&mm->membarrier_registered, cmd);
            return 0;
        case MEMBARRIER_CMD_PRIVATE_EXPEDITED_:
        case MEMBARRIER_CMD_PRIVATE_EXPEDITED_SYNC_CORE_:
            if (!(atomic_load(&mm->membarrier_registered) & (cmd << 1)))
                return _EPERM;
            host_membarrier();
            return 0;
        case MEMBARRIER_CMD_GLOBAL_:
        case MEMBARRIER_CMD_GLOBAL_EXPEDITED_:
            host_membarrier();
            return 0;
        default:
            return _EINVAL;
    }
}
