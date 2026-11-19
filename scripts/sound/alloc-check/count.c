// Interposes the allocation entry points and counts calls while counting is on (test only).
#include <stdlib.h>
#include <malloc/malloc.h>
#include <stdint.h>
typedef unsigned long long malloc_type_id_t_;
extern void *malloc_type_malloc(size_t, malloc_type_id_t_);
extern void *malloc_type_calloc(size_t, size_t, malloc_type_id_t_);
extern void *malloc_type_realloc(void *, size_t, malloc_type_id_t_);
extern void *malloc_type_zone_malloc(malloc_zone_t *, size_t, malloc_type_id_t_);
volatile int fringe_count_on = 0;
volatile long fringe_count = 0;
#define C if (fringe_count_on) __atomic_add_fetch(&fringe_count, 1, __ATOMIC_RELAXED)
static void *m(size_t s) { C; return malloc(s); }
static void *c(size_t n, size_t s) { C; return calloc(n, s); }
static void *r(void *p, size_t s) { C; return realloc(p, s); }
static void *tm(size_t s, malloc_type_id_t_ t) { C; return malloc_type_malloc(s, t); }
static void *tc(size_t n, size_t s, malloc_type_id_t_ t) { C; return malloc_type_calloc(n, s, t); }
static void *tr(void *p, size_t s, malloc_type_id_t_ t) { C; return malloc_type_realloc(p, s, t); }
static void *zm(malloc_zone_t *z, size_t s) { C; return malloc_zone_malloc(z, s); }
static void *tzm(malloc_zone_t *z, size_t s, malloc_type_id_t_ t) { C; return malloc_type_zone_malloc(z, s, t); }
__attribute__((used)) static struct { const void *n; const void *o; } interposers[] __attribute__((section("__DATA,__interpose"))) = {
  {(const void *)m, (const void *)malloc}, {(const void *)c, (const void *)calloc}, {(const void *)r, (const void *)realloc},
  {(const void *)tm, (const void *)malloc_type_malloc}, {(const void *)tc, (const void *)malloc_type_calloc},
  {(const void *)tr, (const void *)malloc_type_realloc}, {(const void *)zm, (const void *)malloc_zone_malloc},
  {(const void *)tzm, (const void *)malloc_type_zone_malloc},
};
