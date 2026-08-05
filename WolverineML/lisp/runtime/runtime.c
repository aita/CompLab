/* The run-time system.
 *
 * Everything the compiler cannot express in one instruction lives here:
 * allocation, strings, and the three errors a check can raise.  A string is a
 * length and its bytes, with a NUL after them so that C can read one without
 * copying; the compiler emits literals in exactly this shape.  An array is a
 * length followed by its elements, and every element is one word.
 *
 * There is no garbage collector.  Memory comes from a bump allocator and is
 * never given back.
 */

#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    int64_t len;
    char data[];
} wol_string;

extern void wol_main(void);

/* -- allocation ---------------------------------------------------------- */

#define CHUNK (1 << 20)

static char *bump = NULL;
static size_t left = 0;

void *wol_alloc(int64_t bytes)
{
    size_t want = (size_t)((bytes + 15) & ~(int64_t)15);
    if (want > left) {
        size_t size = want > CHUNK ? want : CHUNK;
        bump = calloc(1, size);
        if (bump == NULL) {
            fputs("wolverine: out of memory\n", stderr);
            exit(1);
        }
        left = size;
    }
    void *p = bump;
    bump += want;
    left -= want;
    return p;
}

static wol_string *string_of(int64_t len)
{
    wol_string *s = wol_alloc((int64_t)sizeof(wol_string) + len + 1);
    s->len = len;
    return s;
}

int64_t *wol_array(int64_t n, int64_t init)
{
    if (n < 0) {
        fprintf(stderr, "wolverine: array length %" PRId64 " is negative\n", n);
        exit(1);
    }
    int64_t *a = wol_alloc((n + 1) * 8);
    a[0] = n;
    for (int64_t i = 0; i < n; i++)
        a[i + 1] = init;
    return a;
}

/* -- output and input ---------------------------------------------------- */

void wol_print(const wol_string *s)
{
    fwrite(s->data, 1, (size_t)s->len, stdout);
}

void wol_println(const wol_string *s)
{
    fwrite(s->data, 1, (size_t)s->len, stdout);
    putchar('\n');
}

void wol_print_int(int64_t n)
{
    printf("%" PRId64, n);
}

void wol_flush(void)
{
    fflush(stdout);
}

wol_string *wol_getchar(void)
{
    int c = getchar();
    if (c == EOF)
        return string_of(0);
    wol_string *s = string_of(1);
    s->data[0] = (char)c;
    return s;
}

/* -- strings ------------------------------------------------------------- */

int64_t wol_size(const wol_string *s)
{
    return s->len;
}

int64_t wol_ord(const wol_string *s)
{
    return s->len == 0 ? -1 : (unsigned char)s->data[0];
}

wol_string *wol_chr(int64_t code)
{
    if (code < 0 || code > 255) {
        fprintf(stderr, "wolverine: chr(%" PRId64 ") is out of range\n", code);
        exit(1);
    }
    wol_string *s = string_of(1);
    s->data[0] = (char)code;
    return s;
}

wol_string *wol_concat(const wol_string *a, const wol_string *b)
{
    wol_string *s = string_of(a->len + b->len);
    memcpy(s->data, a->data, (size_t)a->len);
    memcpy(s->data + a->len, b->data, (size_t)b->len);
    return s;
}

wol_string *wol_substring(const wol_string *s, int64_t first, int64_t n)
{
    if (first < 0 || n < 0 || first + n > s->len) {
        fprintf(stderr,
                "wolverine: substring(_, %" PRId64 ", %" PRId64
                ") is outside a string of %" PRId64 "\n",
                first, n, s->len);
        exit(1);
    }
    wol_string *out = string_of(n);
    memcpy(out->data, s->data + first, (size_t)n);
    return out;
}

int64_t wol_string_cmp(const wol_string *a, const wol_string *b)
{
    int64_t shorter = a->len < b->len ? a->len : b->len;
    int order = memcmp(a->data, b->data, (size_t)shorter);
    if (order != 0)
        return order < 0 ? -1 : 1;
    if (a->len == b->len)
        return 0;
    return a->len < b->len ? -1 : 1;
}

wol_string *wol_int_to_string(int64_t n)
{
    char buffer[32];
    int len = snprintf(buffer, sizeof buffer, "%" PRId64, n);
    wol_string *s = string_of(len);
    memcpy(s->data, buffer, (size_t)len);
    return s;
}

int64_t wol_string_to_int(const wol_string *s)
{
    return strtoll(s->data, NULL, 10);
}

/* -- leaving, and failing ------------------------------------------------ */

void wol_exit(int64_t code)
{
    fflush(stdout);
    exit((int)code);
}

void wol_nil_error(void)
{
    fflush(stdout);
    fputs("wolverine: a field of nil was used\n", stderr);
    exit(1);
}

void wol_bounds_error(int64_t index, int64_t len)
{
    fflush(stdout);
    fprintf(stderr,
            "wolverine: index %" PRId64 " is outside an array of %" PRId64 "\n",
            index, len);
    exit(1);
}

void wol_div_error(void)
{
    fflush(stdout);
    fputs("wolverine: division by zero\n", stderr);
    exit(1);
}

int main(void)
{
    wol_main();
    fflush(stdout);
    return 0;
}
