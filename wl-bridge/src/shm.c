/* wl_shm without libwayland's built-in implementation: that one grows pools with
 * mremap(), which iSH does not support for file mappings. */
#include <stdlib.h>
#include <sys/mman.h>
#include <unistd.h>
#include "ishwl.h"

static void pool_unref(struct shm_pool *pool) {
    if (--pool->refcount > 0)
        return;
    if (pool->data != MAP_FAILED)
        munmap(pool->data, pool->size);
    close(pool->fd);
    free(pool);
}

static void buffer_handle_destroy(struct wl_client *client, struct wl_resource *resource) {
    wl_resource_destroy(resource);
}

static const struct wl_buffer_interface buffer_impl = {
    .destroy = buffer_handle_destroy,
};

struct shm_buffer *shm_buffer_from_resource(struct wl_resource *resource) {
    if (!wl_resource_instance_of(resource, &wl_buffer_interface, &buffer_impl))
        return NULL;
    return wl_resource_get_user_data(resource);
}

static void buffer_resource_destroy(struct wl_resource *resource) {
    struct shm_buffer *buffer = wl_resource_get_user_data(resource);
    pool_unref(buffer->pool);
    free(buffer);
}

static void pool_create_buffer(struct wl_client *client, struct wl_resource *resource, uint32_t id,
                               int32_t offset, int32_t width, int32_t height, int32_t stride, uint32_t format) {
    struct shm_pool *pool = wl_resource_get_user_data(resource);
    if (format != WL_SHM_FORMAT_ARGB8888 && format != WL_SHM_FORMAT_XRGB8888) {
        wl_resource_post_error(resource, WL_SHM_ERROR_INVALID_FORMAT, "unsupported format 0x%x", format);
        return;
    }
    if (offset < 0 || width <= 0 || height <= 0 || stride < width * 4 ||
        (size_t) offset + (size_t) stride * (size_t) height > pool->size) {
        wl_resource_post_error(resource, WL_SHM_ERROR_INVALID_STRIDE, "invalid buffer geometry");
        return;
    }
    struct shm_buffer *buffer = calloc(1, sizeof(*buffer));
    if (!buffer) {
        wl_client_post_no_memory(client);
        return;
    }
    buffer->resource = wl_resource_create(client, &wl_buffer_interface, 1, id);
    if (!buffer->resource) {
        free(buffer);
        wl_client_post_no_memory(client);
        return;
    }
    buffer->pool = pool;
    pool->refcount++;
    buffer->offset = offset;
    buffer->width = width;
    buffer->height = height;
    buffer->stride = stride;
    buffer->format = format;
    wl_resource_set_implementation(buffer->resource, &buffer_impl, buffer, buffer_resource_destroy);
}

static void pool_handle_destroy(struct wl_client *client, struct wl_resource *resource) {
    wl_resource_destroy(resource);
}

/* Buffers already created keep pointing into the pool, so the new mapping must
 * replace the old one in place of a fresh pool object. */
static void pool_resize(struct wl_client *client, struct wl_resource *resource, int32_t size) {
    struct shm_pool *pool = wl_resource_get_user_data(resource);
    if (size <= 0 || (size_t) size < pool->size) {
        wl_resource_post_error(resource, WL_SHM_ERROR_INVALID_FD, "shrinking pool invalid");
        return;
    }
    void *data = mmap(NULL, size, PROT_READ, MAP_SHARED, pool->fd, 0);
    if (data == MAP_FAILED) {
        wl_resource_post_error(resource, WL_SHM_ERROR_INVALID_FD, "failed to remap pool");
        return;
    }
    munmap(pool->data, pool->size);
    pool->data = data;
    pool->size = size;
}

static const struct wl_shm_pool_interface pool_impl = {
    .create_buffer = pool_create_buffer,
    .destroy = pool_handle_destroy,
    .resize = pool_resize,
};

static void pool_resource_destroy(struct wl_resource *resource) {
    pool_unref(wl_resource_get_user_data(resource));
}

static void shm_create_pool(struct wl_client *client, struct wl_resource *resource, uint32_t id,
                            int32_t fd, int32_t size) {
    struct shm_pool *pool = calloc(1, sizeof(*pool));
    if (!pool) {
        close(fd);
        wl_client_post_no_memory(client);
        return;
    }
    pool->refcount = 1;
    pool->fd = fd;
    pool->size = size;
    pool->data = size > 0 ? mmap(NULL, size, PROT_READ, MAP_SHARED, fd, 0) : MAP_FAILED;
    if (pool->data == MAP_FAILED) {
        close(fd);
        free(pool);
        wl_resource_post_error(resource, WL_SHM_ERROR_INVALID_FD, "failed to map pool");
        return;
    }
    struct wl_resource *pool_resource = wl_resource_create(client, &wl_shm_pool_interface, 1, id);
    if (!pool_resource) {
        pool_unref(pool);
        wl_client_post_no_memory(client);
        return;
    }
    wl_resource_set_implementation(pool_resource, &pool_impl, pool, pool_resource_destroy);
}

static void shm_release(struct wl_client *client, struct wl_resource *resource) {
    wl_resource_destroy(resource);
}

static const struct wl_shm_interface shm_impl = {
    .create_pool = shm_create_pool,
    .release = shm_release,
};

static void shm_bind(struct wl_client *client, void *data, uint32_t version, uint32_t id) {
    struct wl_resource *resource = wl_resource_create(client, &wl_shm_interface, version, id);
    if (!resource) {
        wl_client_post_no_memory(client);
        return;
    }
    wl_resource_set_implementation(resource, &shm_impl, data, NULL);
    wl_shm_send_format(resource, WL_SHM_FORMAT_ARGB8888);
    wl_shm_send_format(resource, WL_SHM_FORMAT_XRGB8888);
}

void shm_init(struct server *s) {
    wl_global_create(s->display, &wl_shm_interface, 1, s, shm_bind);
}
