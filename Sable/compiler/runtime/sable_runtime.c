/* The Sable runtime.
 *
 * Compiled programs are ordinary RISC-V objects; this file gives them an entry
 * point, a heap and the handful of primitives the language exposes.  Every
 * Sable value is one 64-bit word: an integer, or the address of a block.
 *
 * The heap is a bump allocator and nothing is ever freed.  A collector would
 * need the compiler to describe where the pointers are, which is a different
 * project from the one this compiler is about. */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef long word;

extern word sable_main(void);

static char *heap_next;
static char *heap_end;

static void fatal(const char *message) {
  fflush(stdout);
  fprintf(stderr, "sable: %s\n", message);
  exit(2);
}

word sable_alloc(word bytes) {
  bytes = (bytes + 7) & ~(word)7;
  if (bytes < 0 || bytes > heap_end - heap_next) fatal("out of memory");
  char *block = heap_next;
  heap_next += bytes;
  return (word)block;
}

word sable_make_array(word length, word init) {
  if (length < 0) fatal("Array.make with a negative length");
  word *array = (word *)sable_alloc(length * (word)sizeof(word));
  for (word i = 0; i < length; i++) array[i] = init;
  return (word)array;
}

/* A string is a block: one word of length, then that many bytes. */
static long string_length(word s) { return *(const long *)s; }
static const char *string_bytes(word s) { return (const char *)(s + (word)sizeof(word)); }

void sable_print_string(word s) {
  fwrite(string_bytes(s), 1, (size_t)string_length(s), stdout);
}

word sable_string_concat(word a, word b) {
  long na = string_length(a);
  long nb = string_length(b);
  word block = sable_alloc((word)sizeof(word) + na + nb);
  *(long *)block = na + nb;
  char *bytes = (char *)(block + (word)sizeof(word));
  memcpy(bytes, string_bytes(a), (size_t)na);
  memcpy(bytes + na, string_bytes(b), (size_t)nb);
  return block;
}

word sable_string_equal(word a, word b) {
  long n = string_length(a);
  if (n != string_length(b)) return 0;
  return memcmp(string_bytes(a), string_bytes(b), (size_t)n) == 0;
}

void sable_print_int(word n) { printf("%ld", n); }
void sable_print_char(word c) { putchar((int)c); }
void sable_print_newline(word unit) { (void)unit; putchar('\n'); }

word sable_read_int(word unit) {
  (void)unit;
  long n;
  if (scanf("%ld", &n) != 1) fatal("read_int: no integer on standard input");
  return n;
}

void sable_match_failure(void) { fatal("match failure"); }

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
  sable_main();
  fflush(stdout);
  return 0;
}
