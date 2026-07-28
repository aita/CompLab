/* The MartenML runtime.
 *
 * Compiled programs are ordinary RISC-V objects; this file gives them an entry
 * point, a heap and the handful of primitives the language exposes.  Every
 * MartenML value is one 64-bit word: an integer, or the address of a block.
 *
 * The heap is a bump allocator and nothing is ever freed.  A collector would
 * need the compiler to describe where the pointers are, which is a different
 * project from the one this compiler is about. */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef long word;

extern word martenml_main(void);

static char *heap_next;
static char *heap_end;

static void fatal(const char *message) {
  fflush(stdout);
  fprintf(stderr, "martenml: %s\n", message);
  exit(2);
}

word martenml_alloc(word bytes) {
  bytes = (bytes + 7) & ~(word)7;
  if (bytes < 0 || bytes > heap_end - heap_next) fatal("out of memory");
  char *block = heap_next;
  heap_next += bytes;
  return (word)block;
}

word martenml_make_array(word length, word init) {
  if (length < 0) fatal("Array.make with a negative length");
  word *array = (word *)martenml_alloc(length * (word)sizeof(word));
  for (word i = 0; i < length; i++) array[i] = init;
  return (word)array;
}

/* A string is a block: one word of length, then that many bytes. */
static long string_length(word s) { return *(const long *)s; }
static const char *string_bytes(word s) { return (const char *)(s + (word)sizeof(word)); }

void martenml_print_string(word s) {
  fwrite(string_bytes(s), 1, (size_t)string_length(s), stdout);
}

word martenml_string_concat(word a, word b) {
  long na = string_length(a);
  long nb = string_length(b);
  word block = martenml_alloc((word)sizeof(word) + na + nb);
  *(long *)block = na + nb;
  char *bytes = (char *)(block + (word)sizeof(word));
  memcpy(bytes, string_bytes(a), (size_t)na);
  memcpy(bytes + na, string_bytes(b), (size_t)nb);
  return block;
}

word martenml_string_equal(word a, word b) {
  long n = string_length(a);
  if (n != string_length(b)) return 0;
  return memcmp(string_bytes(a), string_bytes(b), (size_t)n) == 0;
}

void martenml_print_int(word n) { printf("%ld", n); }
void martenml_print_char(word c) { putchar((int)c); }
void martenml_print_newline(word unit) { (void)unit; putchar('\n'); }

word martenml_read_int(word unit) {
  (void)unit;
  long n;
  if (scanf("%ld", &n) != 1) fatal("read_int: no integer on standard input");
  return n;
}

void martenml_match_failure(void) { fatal("match failure"); }
void martenml_division_by_zero(void) { fatal("division by zero"); }

int main(void) {
  size_t heap_size = 256u << 20;
  const char *requested = getenv("SABLE_HEAP_MB");
  if (requested) {
    long mb = strtol(requested, NULL, 10);
    if (mb > 0) heap_size = (size_t)mb << 20;
  }
  heap_next = malloc(heap_size);
  if (!heap_next) fatal("cannot reserve the heap");
  heap_end = heap_next + heap_size;
  martenml_main();
  fflush(stdout);
  return 0;
}
