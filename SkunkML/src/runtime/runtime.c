/* The runtime the compiled code sits on.

   Everything the generated assembly does not want to do itself is here: the
   allocator, structural equality, printing, and the string and list work.  The
   division is deliberate -- the code generator only has to know how to move
   words, do tagged arithmetic and jump, and anything that needs a loop or a
   walk over the heap is a call.

   The value representation, which the compiler and this file have to agree on:

     an integer   2n + 1              tagged, so the low bit says "not a pointer"
     a block      a pointer, 8-aligned, whose word -1 is a descriptor pointer

   A descriptor is static, emitted by the compiler, and says what the block is:

     kind      0 record/tuple  1 constructor  2 string  3 closure  4 array  5 ref
     nfields   how many words follow (strings and arrays carry a length word)
     con       the constructor's name, for printing, or NULL
     labels    a NULL-terminated array of field labels, or NULL

   That is enough to compare two values structurally and to print one the way
   the interpreter prints it, which is what makes the differential test
   possible: a compiled program's output must match `skunk` byte for byte. */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

typedef intptr_t value;

#define IS_INT(v) (((v) & 1) != 0)
#define TO_INT(v) ((v) >> 1)
#define OF_INT(n) ((((value)(n)) << 1) | 1)
#define BLOCK(v) ((value *)(v))
#define DESC(v) ((struct desc *)(BLOCK(v)[-1]))

enum { K_RECORD = 0, K_CON = 1, K_STRING = 2, K_CLOSURE = 3, K_ARRAY = 4, K_REF = 5 };

struct desc {
  intptr_t kind;
  intptr_t nfields;
  const char *con;
  const char *const *labels;
};

/* A bump allocator that never gives anything back, which is what the
   interpreter's store does too.  Chapter 8 of the book says why: with no
   garbage collector the honest thing is to let it grow and say so. */
static char *heap_start, *heap_next, *heap_end;

static void grow(size_t need) {
  size_t size = 1 << 22;
  while (size < need + 64) size *= 2;
  heap_start = malloc(size);
  if (!heap_start) { fprintf(stderr, "skunk: out of memory\n"); exit(1); }
  heap_next = heap_start;
  heap_end = heap_start + size;
}

value skunk_alloc(struct desc *d, intptr_t nwords) {
  size_t bytes = (nwords + 1) * sizeof(value);
  if (heap_next + bytes > heap_end) grow(bytes);
  value *p = (value *)heap_next;
  heap_next += bytes;
  p[0] = (value)d;
  return (value)(p + 1);
}

void skunk_fail(const char *msg) {
  fflush(stdout);
  fprintf(stderr, "?: runtime error: %s\n", msg);
  exit(1);
}

void skunk_match_fail(const char *where) {
  fflush(stdout);
  fprintf(stderr, "%s: match failure: no pattern matched\n", where);
  exit(1);
}

/* ---- equality ------------------------------------------------------------ */

/* The same rules as the interpreter's `equal`: structural everywhere except
   that arrays and refs are compared by identity, and functions are an error
   the type checker should already have caught. */
static int equal(value a, value b) {
  if (a == b) return 1;
  if (IS_INT(a) || IS_INT(b)) return 0;
  struct desc *da = DESC(a), *db = DESC(b);
  if (da->kind != db->kind) return 0;
  switch (da->kind) {
    case K_ARRAY:
    case K_REF:
      return 0; /* identity, and a == b was already tried */
    case K_CLOSURE:
      skunk_fail("functions cannot be compared");
      return 0;
    case K_STRING: {
      intptr_t la = BLOCK(a)[0], lb = BLOCK(b)[0];
      if (la != lb) return 0;
      return memcmp((char *)&BLOCK(a)[1], (char *)&BLOCK(b)[1], la) == 0;
    }
    case K_CON:
      if (da != db) return 0;
      /* fall through */
    default: {
      if (da->nfields != db->nfields) return 0;
      for (intptr_t i = 0; i < da->nfields; i++)
        if (!equal(BLOCK(a)[i], BLOCK(b)[i])) return 0;
      return 1;
    }
  }
}

value skunk_equal(value a, value b) { return OF_INT(equal(a, b) ? 1 : 0); }
value skunk_noteq(value a, value b) { return OF_INT(equal(a, b) ? 0 : 1); }

/* ---- strings ------------------------------------------------------------- */

/* The descriptors the generated code has to be able to name.  A string
   literal is emitted as static data whose header points at this one. */
struct desc skunk_string_desc = { K_STRING, 0, NULL, NULL };
struct desc skunk_unit_desc = { K_RECORD, 0, NULL, NULL };
static value the_unit;
#define string_desc skunk_string_desc

static value make_string(const char *s, size_t n) {
  intptr_t words = 1 + (intptr_t)((n + sizeof(value)) / sizeof(value));
  value v = skunk_alloc(&string_desc, words);
  BLOCK(v)[0] = (value)n;
  char *p = (char *)&BLOCK(v)[1];
  memcpy(p, s, n);
  p[n] = 0;
  return v;
}

value skunk_string(const char *s, intptr_t n) { return make_string(s, (size_t)n); }
static const char *str_of(value v) { return (const char *)&BLOCK(v)[1]; }
static intptr_t str_len(value v) { return BLOCK(v)[0]; }

value skunk_concat(value a, value b) {
  intptr_t la = str_len(a), lb = str_len(b);
  char *tmp = malloc(la + lb + 1);
  memcpy(tmp, str_of(a), la);
  memcpy(tmp + la, str_of(b), lb);
  value r = make_string(tmp, la + lb);
  free(tmp);
  return r;
}

value skunk_size(value s) { return OF_INT(str_len(s)); }

value skunk_substring(value s, value i, value n) {
  intptr_t off = TO_INT(i), len = TO_INT(n);
  if (off < 0 || len < 0 || off + len > str_len(s))
    skunk_fail("String.substring: out of range");
  return make_string(str_of(s) + off, len);
}

value skunk_string_compare(value a, value b) {
  int c = strcmp(str_of(a), str_of(b));
  return OF_INT(c < 0 ? -1 : c > 0 ? 1 : 0);
}

value skunk_int_to_string(value n) {
  char buf[32];
  intptr_t v = TO_INT(n);
  if (v < 0) snprintf(buf, sizeof buf, "~%ld", -(long)v);
  else snprintf(buf, sizeof buf, "%ld", (long)v);
  return make_string(buf, strlen(buf));
}

value skunk_print(value s) {
  fwrite(str_of(s), 1, str_len(s), stdout);
  return the_unit;
}

/* ---- lists, arrays, refs ------------------------------------------------- */

/* `@` has to build a list, and building a list means knowing the descriptors
   the compiler emitted for nil and cons.  They are passed in rather than
   guessed. */
value skunk_append(struct desc *nil, struct desc *cons, value a, value b) {
  if (IS_INT(a) || DESC(a) == nil) return b;
  value pair = BLOCK(a)[0];
  value tail = skunk_append(nil, cons, BLOCK(pair)[1], b);
  value np = skunk_alloc(DESC(pair), 2);
  BLOCK(np)[0] = BLOCK(pair)[0];
  BLOCK(np)[1] = tail;
  value nc = skunk_alloc(cons, 1);
  BLOCK(nc)[0] = np;
  return nc;
}

struct desc skunk_array_desc = { K_ARRAY, 0, NULL, NULL };
struct desc skunk_ref_desc = { K_REF, 1, NULL, NULL };
#define array_desc skunk_array_desc
#define ref_desc skunk_ref_desc

value skunk_array(value n, value init) {
  intptr_t len = TO_INT(n);
  if (len < 0) skunk_fail("Array.array: negative size");
  value v = skunk_alloc(&array_desc, len + 1);
  BLOCK(v)[0] = (value)len;
  for (intptr_t i = 0; i < len; i++) BLOCK(v)[i + 1] = init;
  return v;
}

value skunk_array_length(value a) { return OF_INT(BLOCK(a)[0]); }

value skunk_array_sub(value a, value i) {
  intptr_t k = TO_INT(i), n = BLOCK(a)[0];
  if (k < 0 || k >= n) {
    char buf[80];
    snprintf(buf, sizeof buf, "Array.sub: index %ld out of 0..%ld", (long)k, (long)(n - 1));
    skunk_fail(buf);
  }
  return BLOCK(a)[k + 1];
}

value skunk_array_update(value a, value i, value x) {
  intptr_t k = TO_INT(i), n = BLOCK(a)[0];
  if (k < 0 || k >= n) {
    char buf[80];
    snprintf(buf, sizeof buf, "Array.update: index %ld out of 0..%ld", (long)k, (long)(n - 1));
    skunk_fail(buf);
  }
  BLOCK(a)[k + 1] = x;
  return the_unit;
}

value skunk_array_from_list(struct desc *nil, value l) {
  intptr_t n = 0;
  for (value p = l; !(IS_INT(p) || DESC(p) == nil); p = BLOCK(BLOCK(p)[0])[1]) n++;
  value v = skunk_alloc(&array_desc, n + 1);
  BLOCK(v)[0] = (value)n;
  intptr_t i = 0;
  for (value p = l; !(IS_INT(p) || DESC(p) == nil); p = BLOCK(BLOCK(p)[0])[1])
    BLOCK(v)[++i] = BLOCK(BLOCK(p)[0])[0];
  return v;
}

/* Built back to front.  A cons cell holds one field, a 2-tuple, so three
   descriptors are needed and all three come from the compiler. */
value skunk_array_to_list(struct desc *nil, struct desc *cons, struct desc *pair, value a) {
  intptr_t n = BLOCK(a)[0];
  value acc = skunk_alloc(nil, 0);
  for (intptr_t i = n - 1; i >= 0; i--) {
    value p = skunk_alloc(pair, 2);
    BLOCK(p)[0] = BLOCK(a)[i + 1];
    BLOCK(p)[1] = acc;
    value c = skunk_alloc(cons, 1);
    BLOCK(c)[0] = p;
    acc = c;
  }
  return acc;
}

value skunk_ref(value x) {
  value v = skunk_alloc(&ref_desc, 1);
  BLOCK(v)[0] = x;
  return v;
}

value skunk_deref(value r) { return BLOCK(r)[0]; }

value skunk_setref(value r, value x) {
  BLOCK(r)[0] = x;
  return the_unit;
}

/* ---- printing ------------------------------------------------------------ */

static void show(value v);

static int is_nil(value v) {
  return !IS_INT(v) && DESC(v)->kind == K_CON && DESC(v)->con &&
         strcmp(DESC(v)->con, "nil") == 0;
}

static int is_cons(value v) {
  return !IS_INT(v) && DESC(v)->kind == K_CON && DESC(v)->con &&
         strcmp(DESC(v)->con, "::") == 0;
}

static void show_list(value v) {
  putchar('[');
  int first = 1;
  while (is_cons(v)) {
    value pair = BLOCK(v)[0];
    if (!first) fputs(", ", stdout);
    first = 0;
    show(BLOCK(pair)[0]);
    v = BLOCK(pair)[1];
  }
  putchar(']');
}

static void show(value v) {
  if (IS_INT(v)) {
    intptr_t n = TO_INT(v);
    if (n < 0) printf("~%ld", -(long)n);
    else printf("%ld", (long)n);
    return;
  }
  struct desc *d = DESC(v);
  switch (d->kind) {
    case K_STRING: {
      putchar('"');
      const char *s = str_of(v);
      for (intptr_t i = 0; i < str_len(v); i++) {
        char c = s[i];
        if (c == '"' || c == '\\') { putchar('\\'); putchar(c); }
        else if (c == '\n') fputs("\\n", stdout);
        else if (c == '\t') fputs("\\t", stdout);
        else putchar(c);
      }
      putchar('"');
      return;
    }
    case K_CLOSURE: fputs("fn", stdout); return;
    case K_REF: fputs("ref ", stdout); show(BLOCK(v)[0]); return;
    case K_ARRAY: {
      fputs("[|", stdout);
      for (intptr_t i = 0; i < BLOCK(v)[0]; i++) {
        if (i) fputs(", ", stdout);
        show(BLOCK(v)[i + 1]);
      }
      fputs("|]", stdout);
      return;
    }
    case K_CON:
      if (is_nil(v) || is_cons(v)) { show_list(v); return; }
      fputs(d->con, stdout);
      if (d->nfields > 0) { putchar(' '); show(BLOCK(v)[0]); }
      return;
    default: {
      /* A record.  Labels 1, 2, ... n mean a tuple, and unit is the record
         with no fields -- the same rule the interpreter prints by. */
      if (d->nfields == 0) { fputs("()", stdout); return; }
      int tuple = d->labels == NULL;
      fputs(tuple ? "(" : "{ ", stdout);
      for (intptr_t i = 0; i < d->nfields; i++) {
        if (i) fputs(", ", stdout);
        if (!tuple) printf("%s = ", d->labels[i]);
        show(BLOCK(v)[i]);
      }
      fputs(tuple ? ")" : " }", stdout);
      return;
    }
  }
}

/* One reported binding, in the interpreter's format. */
void skunk_report(const char *label, value v) {
  fputs(label, stdout);
  fputs(" = ", stdout);
  show(v);
  putchar('\n');
}

void skunk_report_label(const char *label) {
  fputs(label, stdout);
  putchar('\n');
}

extern void skunk_program(void);

value skunk_div(value a, value b) {
  intptr_t y = TO_INT(b);
  if (y == 0) skunk_fail("division by zero");
  return OF_INT(TO_INT(a) / y);
}

value skunk_mod(value a, value b) {
  intptr_t y = TO_INT(b);
  if (y == 0) skunk_fail("division by zero");
  return OF_INT(TO_INT(a) % y);
}

/* `<` and friends are overloaded over int and string, and which one it is was
   decided by the type checker and then erased.  So the value decides, exactly
   as the interpreter's `order` does. */
static intptr_t order(value a, value b) {
  if (IS_INT(a)) return TO_INT(a) < TO_INT(b) ? -1 : TO_INT(a) > TO_INT(b) ? 1 : 0;
  return (intptr_t)strcmp(str_of(a), str_of(b));
}

value skunk_lt(value a, value b) { return OF_INT(order(a, b) < 0); }
value skunk_le(value a, value b) { return OF_INT(order(a, b) <= 0); }
value skunk_gt(value a, value b) { return OF_INT(order(a, b) > 0); }
value skunk_ge(value a, value b) { return OF_INT(order(a, b) >= 0); }

int main(void) {
  grow(0);
  the_unit = skunk_alloc(&skunk_unit_desc, 0);
  skunk_program();
  fflush(stdout);
  return 0;
}
