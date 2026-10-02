#include <string.h>
#include "kernel/calls.h"

static int __user_read_mem(struct mem *mem, addr_t addr, void *buf, size_t count) {
    char *cbuf = (char *) buf;
    addr_t p = addr;
    while (p < addr + count) {
        addr_t chunk_end = (PAGE(p) + 1) << PAGE_BITS;
        if (chunk_end > addr + count)
            chunk_end = addr + count;
        const char *ptr = mem_ptr(mem, p, MEM_READ);
        if (ptr == NULL)
            return 1;
        memcpy(&cbuf[p - addr], ptr, chunk_end - p);
        p = chunk_end;
    }
    return 0;
}

static int __user_write_mem(struct mem *mem, addr_t addr, const void *buf, size_t count, bool ptrace) {
    const char *cbuf = (const char *) buf;
    addr_t p = addr;
    while (p < addr + count) {
        addr_t chunk_end = (PAGE(p) + 1) << PAGE_BITS;
        if (chunk_end > addr + count)
            chunk_end = addr + count;
        char *ptr = mem_ptr(mem, p, ptrace ? MEM_WRITE_PTRACE : MEM_WRITE);
        if (ptr == NULL)
            return 1;
        memcpy(ptr, &cbuf[p - addr], chunk_end - p);
        p = chunk_end;
    }
    return 0;
}

int user_read_task(struct task *task, addr_t addr, void *buf, size_t count) {
    read_wrlock(&task->mem->lock);
    int res = __user_read_mem(task->mem, addr, buf, count);
    read_wrunlock(&task->mem->lock);
    return res;
}

int user_read(addr_t addr, void *buf, size_t count) {
    return user_read_task(current, addr, buf, count);
}

int user_write_task(struct task *task, addr_t addr, const void *buf, size_t count) {
    read_wrlock(&task->mem->lock);
    int res = __user_write_mem(task->mem, addr, buf, count, false);
    read_wrunlock(&task->mem->lock);
    return res;
}

int user_write_task_ptrace(struct task *task, addr_t addr, const void *buf, size_t count) {
    read_wrlock(&task->mem->lock);
    int res = __user_write_mem(task->mem, addr, buf, count, true);
    read_wrunlock(&task->mem->lock);
    return res;
}

int user_read_mem(struct mem *mem, addr_t addr, void *buf, size_t count) {
    read_wrlock(&mem->lock);
    int res = __user_read_mem(mem, addr, buf, count);
    read_wrunlock(&mem->lock);
    return res;
}

int user_write_mem_ptrace(struct mem *mem, addr_t addr, const void *buf, size_t count) {
    read_wrlock(&mem->lock);
    int res = __user_write_mem(mem, addr, buf, count, true);
    read_wrunlock(&mem->lock);
    return res;
}

int user_write(addr_t addr, const void *buf, size_t count) {
    return user_write_task(current, addr, buf, count);
}

int user_read_string(addr_t addr, char *buf, size_t max) {
    if (addr == 0)
        return 1;
    read_wrlock(&current->mem->lock);
    size_t i = 0;
    while (i < max) {
        if (__user_read_mem(current->mem, addr + i, &buf[i], sizeof(buf[i]))) {
            read_wrunlock(&current->mem->lock);
            return 1;
        }
        if (buf[i] == '\0')
            break;
        i++;
    }
    read_wrunlock(&current->mem->lock);
    if (i == max && max > 0)
        buf[max - 1] = '\0';
    return 0;
}

int user_write_string(addr_t addr, const char *buf) {
    if (addr == 0)
        return 1;
    read_wrlock(&current->mem->lock);
    size_t i = 0;
    do {
        if (__user_write_mem(current->mem, addr + i, &buf[i], sizeof(buf[i]), false)) {
            read_wrunlock(&current->mem->lock);
            return 1;
        }
        i++;
    } while (buf[i - 1] != '\0');
    read_wrunlock(&current->mem->lock);
    return 0;
}
