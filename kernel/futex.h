#ifndef KERNEL_FUTEX_H
#define KERNEL_FUTEX_H

int futex_wake(addr_t uaddr, dword_t val);
void futex_exit_robust_list(void);

#endif
