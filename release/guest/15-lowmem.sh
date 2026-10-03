# shellcheck shell=sh
# Sourced by ishwl-session (/etc/ishwl/session.d). Low-memory defaults for every app the
# desktop starts (ipad-jit/lowmem-report.md). The whole system shares the few GB iPadOS
# gives the app, so allocators keep less in reserve, as on low-RAM distributions.
# glibc programs (VS Code, Wine and the other apps in the glibc island) keep up to eight
# malloc arenas per core; two hold far less unused memory with many threads. musl's
# allocator has no arenas and ignores it.
export MALLOC_ARENA_MAX="${MALLOC_ARENA_MAX:-2}"
