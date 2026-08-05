/* The runtime, in C -- and freestanding.

   The allocator, structural equality, `show` and the garbage collector live
   here, because they are loops and walks over the heap and the code generator
   should only have to know how to move words, do tagged arithmetic and jump.

   *Freestanding* is the constraint.  Using libc would mean every compiled
   program needs libc; there are no headers here, no `memcpy` from anywhere
   else, and exactly three ways out to the world, each one line of inline
   assembly: `mmap` for the heap, `write` for output, `exit` at the end.
   Compiled with `-nostdlib -ffreestanding -fno-pic`, the result is an object
   file whose only undefined symbols are the ones the compiler emits, and
   `clang -nostdlib -static` links it without pulling anything else in.

   Everything this file and the generated code have to agree on is written down
   in one place, [12章](../../doc/12-abi.md).  The two facts you cannot read this
   file without:

     an integer   2n + 1              tagged, so the low bit says "not a pointer"
     a block      a pointer, 8-aligned, whose word -1 is a descriptor pointer

   The descriptors, the name strings and the blocks for the built-in
   constructors are all here, because two constructors are equal only when their
   descriptors are the same pointer and there has to be one owner.  A block's
   value is the address *after* its descriptor word, which C can say --
   `&blk + 1` is an address constant -- so the compiler names the block and adds
   the eight itself. */

typedef long value;
typedef unsigned long uword;

#define IS_INT(v) (((v) & 1) != 0)
#define TO_INT(v) ((v) >> 1)
#define OF_INT(n) ((((value)(n)) << 1) | 1)
#define BLOCK(v) ((value *)(v))
#define DESC(v) ((struct desc *)(BLOCK(v)[-1]))

enum { K_RECORD = 0, K_CON = 1, K_STRING = 2, K_CLOSURE = 3, K_ARRAY = 4, K_REF = 5, K_FREE = 6 };

struct desc {
  value kind;
  value nfields;
  const value *con;     /* a string block, or 0 */
  const value **labels; /* one string block per field, or 0 for a tuple */
  value list;           /* 0 ordinary, 1 nil, 2 cons */
  value tag;            /* which constructor of its datatype */
};

/* ---- the three syscalls -------------------------------------------------- */

static long sys3(long n, long a, long b, long c) {
  long r;
  __asm__ volatile("syscall" : "=a"(r) : "a"(n), "D"(a), "S"(b), "d"(c) : "rcx", "r11", "memory");
  return r;
}

static long sys6(long n, long a, long b, long c, long d, long e, long f) {
  long r;
  register long r10 __asm__("r10") = d;
  register long r8 __asm__("r8") = e;
  register long r9 __asm__("r9") = f;
  __asm__ volatile("syscall"
                   : "=a"(r)
                   : "a"(n), "D"(a), "S"(b), "d"(c), "r"(r10), "r"(r8), "r"(r9)
                   : "rcx", "r11", "memory");
  return r;
}

static void write_fd(int fd, const char *p, long n) {
  while (n > 0) {
    long w = sys3(1, fd, (long)p, n);
    if (w <= 0) break;
    p += w;
    n -= w;
  }
}

__attribute__((noreturn)) static void leave(int code) {
  sys3(60, code, 0, 0);
  __builtin_unreachable();
}

/* Freestanding means these are ours.  The three with reserved names are here
   because LLVM is allowed to turn a copy or a fill into a call to one of them
   whatever the source said, and with `-nostdlib` there is nobody else to
   answer it. */
void *memcpy(void *d, const void *s, unsigned long n) {
  char *dp = d;
  const char *sp = s;
  for (unsigned long i = 0; i < n; i++) dp[i] = sp[i];
  return d;
}

void *memmove(void *d, const void *s, unsigned long n) {
  char *dp = d;
  const char *sp = s;
  if (dp < sp)
    for (unsigned long i = 0; i < n; i++) dp[i] = sp[i];
  else
    for (unsigned long i = n; i > 0; i--) dp[i - 1] = sp[i - 1];
  return d;
}

void *memset(void *d, int c, unsigned long n) {
  char *dp = d;
  for (unsigned long i = 0; i < n; i++) dp[i] = (char)c;
  return d;
}

static void copy(char *d, const char *s, long n) {
  for (long i = 0; i < n; i++) d[i] = s[i];
}

static int same_bytes(const char *a, const char *b, long n) {
  for (long i = 0; i < n; i++)
    if (a[i] != b[i]) return 0;
  return 1;
}

static long c_len(const char *s) {
  long n = 0;
  while (s[n]) n++;
  return n;
}

/* ---- output -------------------------------------------------------------- */

/* stdout is buffered here rather than in the kernel, because `show` writes a
   byte at a time.  Anything about to write to stderr flushes first, so the two
   streams stay in the order they were produced. */
#define OUTBUF 4096
static char outbuf[OUTBUF];
static long outlen;

void skunk_flush(void) {
  if (outlen) {
    write_fd(1, outbuf, outlen);
    outlen = 0;
  }
}

static void out(const char *p, long n) {
  while (n > 0) {
    long room = OUTBUF - outlen;
    long k = n < room ? n : room;
    copy(outbuf + outlen, p, k);
    outlen += k;
    p += k;
    n -= k;
    if (outlen == OUTBUF) skunk_flush();
  }
}

static void outc(char c) { out(&c, 1); }
static void outz(const char *s) { out(s, c_len(s)); }

static void errz(const char *s) {
  skunk_flush();
  write_fd(2, s, c_len(s));
}

/* Digits, backwards into a buffer.  Returns a pointer into `buf`. */
static char *digits(long n, char *buf, long size, long *len) {
  char *p = buf + size;
  do {
    *--p = (char)('0' + (n % 10));
    n /= 10;
  } while (n);
  *len = buf + size - p;
  return p;
}

static void out_int(long n) {
  char buf[24];
  long len;
  if (n < 0) {
    outc('~');
    n = -n;
  }
  char *p = digits(n, buf, sizeof buf, &len);
  out(p, len);
}

static void err_int(long n) {
  char buf[24];
  long len;
  if (n < 0) {
    errz("~");
    n = -n;
  }
  char *p = digits(n, buf, sizeof buf, &len);
  skunk_flush();
  write_fd(2, p, len);
}

__attribute__((noreturn)) static void fail(const char *what) {
  errz("?: runtime error: ");
  errz(what);
  errz("\n");
  leave(1);
}

/* An out-of-range index, with the numbers in it, because "index 5 out of 0..1"
   is the difference between a message and a shrug. */
__attribute__((noreturn)) static void fail_index(const char *what, long k, long n) {
  errz("?: runtime error: ");
  errz(what);
  errz(": index ");
  err_int(k);
  errz(" out of 0..");
  err_int(n - 1);
  errz("\n");
  leave(1);
}

__attribute__((noreturn)) void skunk_match_fail(const value *where) {
  skunk_flush();
  write_fd(2, (const char *)&where[1], where[0]);
  errz(": match failure: no pattern matched\n");
  leave(1);
}

/* ---- the heap ------------------------------------------------------------ */

/* One mapping holds the heap and everything the collector needs beside it: a
   byte per heap word saying where blocks start, another for the marks, and a
   mark stack big enough that it cannot overflow ([13章](../../doc/13-gc.md)).
   Sizes are fixed at start-up; only the pages touched become resident. */
#define HEAP_BYTES (1L << 26)
#define HEAP_WORDS (HEAP_BYTES / 8)
#define MAP_BYTES HEAP_WORDS
#define MSTACK_ENTRIES (HEAP_WORDS / 2)

static char *heap_start, *heap_end, *cursor;
static unsigned char *starts, *marks;
static value **mstack;
static long mtop;
/* The largest block ever allocated, in words.  It bounds the walk back from an
   interior pointer to the block that contains it. */
static long widest;

/* Set once, in `_start`: the top of the stack, so that the collector knows
   where the roots end. */
static void *stack_top;

/* A free block is a header word holding this, and then its size in words.  It is
   a descriptor so that one linear walk can tell free from live without a second
   table. */
static struct desc free_desc = { K_FREE, 0, 0, 0, 0, 0 };

static void heap_init(void) {
  long total = HEAP_BYTES + 2 * MAP_BYTES + MSTACK_ENTRIES * 8;
  long p = sys6(9 /* mmap */, 0, total, 3 /* rw */, 0x22 /* private|anon */, -1, 0);
  if (p <= 0) fail("cannot map the heap");
  heap_start = (char *)p;
  heap_end = heap_start + HEAP_BYTES;
  cursor = heap_start;
  starts = (unsigned char *)heap_end;
  marks = starts + MAP_BYTES;
  mstack = (value **)(marks + MAP_BYTES);
  /* One free block covering the whole heap. */
  ((value *)heap_start)[0] = (value)&free_desc;
  ((value *)heap_start)[1] = HEAP_WORDS;
}

/* Every block is an even number of words, so a gap is never one word long -- a
   free block needs two, for its marker and its size. */
static long round_even(long w) { return (w + 1) & ~1L; }

/* The size of the block whose header is at `h`.  The descriptor is not quite
   enough on its own: a string and an array carry their own length. */
static long block_words(value *h) {
  struct desc *d = (struct desc *)h[0];
  if (d == &free_desc) return h[1];
  switch (d->kind) {
    case K_STRING: return round_even(2 + (h[1] + 8) / 8);
    case K_ARRAY: return round_even(h[1] + 2);
    default: return round_even(1 + d->nfields);
  }
}

static long map_index(void *v) { return ((char *)v - heap_start) / 8; }

static void collect(void);

/* Next-fit: walk on from where the last allocation stopped, merging adjacent
   free blocks on the way.  Sweeping builds no free list and coalesces nothing;
   both happen here, only where allocation actually looks. */
static value *find(long need) {
  char *p = cursor;
  while (p < heap_end) {
    value *h = (value *)p;
    if ((struct desc *)h[0] != &free_desc) {
      p += 8 * block_words(h);
      continue;
    }
    long size = h[1];
    for (;;) {
      value *next = (value *)(p + 8 * size);
      if ((char *)next >= heap_end || (struct desc *)next[0] != &free_desc) break;
      size += next[1];
      h[1] = size;
    }
    if (size >= need) {
      long rest = size - need;
      if (rest) {
        value *r = (value *)(p + 8 * need);
        r[0] = (value)&free_desc;
        r[1] = rest;
      }
      cursor = p + 8 * need;
      return h;
    }
    p += 8 * size;
  }
  return 0;
}

value skunk_alloc(struct desc *d, long nwords) {
  long need = round_even(nwords + 1);
  value *h = find(need);
  if (!h) {
    collect();
    h = find(need);
  }
  if (!h) fail("out of memory");
  h[0] = (value)d;
  value v = (value)(h + 1);
  /* One byte per allocation, and it is what makes the conservative scan safe:
     an address that is not inside a block is not a pointer, whatever it looks
     like. */
  starts[map_index((void *)v)] = 1;
  if (need > widest) widest = need;
  return v;
}

/* ---- the collector ------------------------------------------------------- */

/* Mark and sweep, with conservative roots.  Nothing moves, which is what makes
   guessing safe: a word that looks like a pointer but is not one keeps an object
   alive and never breaks anything ([13章](../../doc/13-gc.md)). */

/* Which block an address falls in, or 0.

   A conservative collector sitting behind a code generator of its own could ask
   only about block *starts*, because that generator kept the start of a block in
   a register for as long as it wanted any of its fields.  LLVM will not promise
   that: it is free to compute `v + 24` once and let `v` die, so the only
   surviving reference to a live cell can be a pointer into the middle of it.
   So the question has to be answered for any address -- walk back to the nearest
   start byte and check that the block starting there reaches this far.  `widest`
   is what bounds the walk. */
static value *containing(char *p) {
  long i = map_index(p);
  if (i < 1) return 0;
  if (starts[i]) return (value *)p;
  /* The descriptor is at word -1, so a pointer to the header is a pointer to
     the block too -- and it is the one address that is *below* its start byte
     rather than above it. */
  if (i + 1 < HEAP_WORDS && starts[i + 1]) return (value *)(p + 8);
  long lo = i - widest;
  if (lo < 1) lo = 1;
  for (long k = i - 1; k >= lo; k--)
    if (starts[k]) {
      value *b = (value *)(heap_start + 8 * k);
      long w = block_words(b - 1);
      return p < (char *)(b - 1) + 8 * w ? b : 0;
    }
  return 0;
}

static void mark(value v) {
  if (v & 7) return; /* an integer is 2n+1, so this is where they leave */
  char *p = (char *)v;
  if (p <= heap_start || p >= heap_end) return;
  value *b = containing(p);
  if (!b) return;
  long i = map_index(b);
  if (marks[i]) return;
  marks[i] = 1;
  mstack[mtop++] = b;
}

static void scan(value *from, value *to) {
  for (value *p = from; p < to; p++) mark(*p);
}

/* Which words are values is exactly what the descriptor says.  Three kinds have
   a word that is not one: a string's length, an array's length, and a closure's
   code address -- and that last matters, because a code address is 8-aligned and
   would otherwise be followed. */
static void trace(value *v) {
  struct desc *d = (struct desc *)v[-1];
  switch (d->kind) {
    case K_STRING: return;
    case K_ARRAY:
      for (long i = 0; i < v[0]; i++) mark(v[i + 1]);
      return;
    case K_CLOSURE:
      for (long i = 1; i < d->nfields; i++) mark(v[i]);
      return;
    default:
      for (long i = 0; i < d->nfields; i++) mark(v[i]);
      return;
  }
}

/* The compiler puts everything it emits into one section, and the linker names
   its two ends.  That is the whole of the root set outside the stack: a global's
   word really does point into the heap, and the descriptors and static blocks
   beside it are checked and rejected. */
extern char __start_skunk_data[];
extern char __stop_skunk_data[];

value skunk_the_unit;

static void sweep(void) {
  char *p = heap_start;
  while (p < heap_end) {
    value *h = (value *)p;
    if ((struct desc *)h[0] == &free_desc) {
      p += 8 * h[1];
      continue;
    }
    long w = block_words(h);
    long i = map_index(h + 1);
    if (marks[i]) marks[i] = 0;
    else {
      starts[i] = 0;
      h[0] = (value)&free_desc;
      h[1] = w;
    }
    p += 8 * w;
  }
  cursor = heap_start;
}

static void collect(void) {
  /* The registers are roots too: the caller may be holding a pointer in a
     callee-saved register, because anything live across a call goes there or
     into a frame slot.  Spilling them onto our own frame is enough, since the
     stack is what gets scanned. */
  value regs[6];
  __asm__ volatile("mov %%rbx, %0\n\tmov %%rbp, %1\n\tmov %%r12, %2\n\t"
                   "mov %%r13, %3\n\tmov %%r14, %4\n\tmov %%r15, %5"
                   : "=m"(regs[0]), "=m"(regs[1]), "=m"(regs[2]), "=m"(regs[3]), "=m"(regs[4]),
                     "=m"(regs[5]));
  mtop = 0;
  mark(skunk_the_unit);
  scan((value *)__start_skunk_data, (value *)__stop_skunk_data);
  scan(regs, regs + 6);
  scan((value *)&regs, (value *)stack_top);
  while (mtop) trace(mstack[--mtop]);
  sweep();
}

/* ---- the built-in constructors ------------------------------------------- */

struct desc skunk_string_desc = { K_STRING, 0, 0, 0, 0, 0 };
struct desc skunk_unit_desc = { K_RECORD, 0, 0, 0, 0, 0 };
struct desc skunk_array_desc = { K_ARRAY, 0, 0, 0, 0, 0 };
struct desc skunk_ref_desc = { K_REF, 1, 0, 0, 0, 0 };
struct desc skunk_pair_desc = { K_RECORD, 2, 0, 0, 0, 0 };

/* A string block is [descriptor][length][bytes][NUL], and its value is the
   address of the length word.  The NUL is not counted; it is there so that a
   string can be handed to a syscall without copying. */
#define STRING_BLOCK(name, text, n)                                                                \
  static const struct {                                                                            \
    const struct desc *d;                                                                          \
    value len;                                                                                     \
    char s[n + 1];                                                                                 \
  } name = { &skunk_string_desc, n, text }

STRING_BLOCK(true_name, "true", 4);
STRING_BLOCK(false_name, "false", 5);
STRING_BLOCK(nil_name, "nil", 3);
STRING_BLOCK(cons_name, "::", 2);

struct desc skunk_true_desc = { K_CON, 0, &true_name.len, 0, 0, 1 };
struct desc skunk_false_desc = { K_CON, 0, &false_name.len, 0, 0, 0 };
struct desc skunk_nil_desc = { K_CON, 0, &nil_name.len, 0, 1, 0 };
struct desc skunk_cons_desc = { K_CON, 1, &cons_name.len, 0, 2, 1 };

/* The blocks for the three constructors that carry nothing.  Each is the same
   value every time, so it is static rather than allocated: a descriptor word,
   and no fields at all after it.  The word that is there instead is what makes
   the value an address inside an object rather than one past the end of one --
   the compiler names the block and adds the eight. */
struct nullary {
  const struct desc *d;
  value none;
};

const struct nullary skunk_true_blk = { &skunk_true_desc, 0 };
const struct nullary skunk_false_blk = { &skunk_false_desc, 0 };
const struct nullary skunk_nil_blk = { &skunk_nil_desc, 0 };

#define TRUE_VAL ((value)&skunk_true_blk.none)
#define FALSE_VAL ((value)&skunk_false_blk.none)
#define NIL_VAL ((value)&skunk_nil_blk.none)

static value bool_of(int b) { return b ? TRUE_VAL : FALSE_VAL; }

/* ---- strings ------------------------------------------------------------- */

static long str_len(value v) { return BLOCK(v)[0]; }
static const char *str_of(value v) { return (const char *)&BLOCK(v)[1]; }

static value make_string(const char *s, long n) {
  value v = skunk_alloc(&skunk_string_desc, 1 + (n + 8) / 8);
  BLOCK(v)[0] = n;
  char *p = (char *)&BLOCK(v)[1];
  copy(p, s, n);
  p[n] = 0;
  return v;
}

value skunk_size(value s) { return OF_INT(str_len(s)); }

value skunk_concat(value a, value b) {
  long la = str_len(a), lb = str_len(b);
  value v = skunk_alloc(&skunk_string_desc, 1 + (la + lb + 8) / 8);
  BLOCK(v)[0] = la + lb;
  char *p = (char *)&BLOCK(v)[1];
  copy(p, str_of(a), la);
  copy(p + la, str_of(b), lb);
  p[la + lb] = 0;
  return v;
}

value skunk_substring(value s, value i, value n) {
  long off = TO_INT(i), len = TO_INT(n);
  if (off < 0 || len < 0 || off + len > str_len(s)) fail("String.substring: out of range");
  return make_string(str_of(s) + off, len);
}

value skunk_int_to_string(value n) {
  char buf[24];
  long len, v = TO_INT(n);
  int neg = v < 0;
  if (neg) v = -v;
  char *p = digits(v, buf, sizeof buf, &len);
  if (neg) {
    *--p = '~';
    len++;
  }
  return make_string(p, len);
}

value skunk_print(value s) {
  out(str_of(s), str_len(s));
  return skunk_the_unit;
}

/* ---- equality and order -------------------------------------------------- */

/* Structural everywhere except that arrays and refs are compared by identity,
   and functions are an error the type checker should already have caught. */
static int equal(value a, value b) {
  if (a == b) return 1;
  if (IS_INT(a) || IS_INT(b)) return 0;
  struct desc *da = DESC(a), *db = DESC(b);
  if (da->kind != db->kind) return 0;
  switch (da->kind) {
    case K_ARRAY:
    case K_REF: return 0; /* identity, and a == b was already tried */
    case K_CLOSURE: fail("functions cannot be compared");
    case K_STRING:
      if (str_len(a) != str_len(b)) return 0;
      return same_bytes(str_of(a), str_of(b), str_len(a));
    case K_CON:
      /* Two constructors of a datatype are equal only if they are the same
         constructor, and the descriptor is what says which. */
      if (da != db) return 0;
      /* fall through */
    default:
      if (da->nfields != db->nfields) return 0;
      for (long i = 0; i < da->nfields; i++)
        if (!equal(BLOCK(a)[i], BLOCK(b)[i])) return 0;
      return 1;
  }
}

value skunk_equal(value a, value b) { return bool_of(equal(a, b)); }
value skunk_noteq(value a, value b) { return bool_of(!equal(a, b)); }
value skunk_not(value b) { return bool_of(b == FALSE_VAL); }

/* `<` and friends are overloaded over int and string, and which one it is was
   decided by the type checker and then erased.  So the value decides.  For
   integers the tagged representation is monotone, so no untagging is needed. */
static long order(value a, value b) {
  if (IS_INT(a)) return a < b ? -1 : a > b ? 1 : 0;
  long la = str_len(a), lb = str_len(b);
  const char *pa = str_of(a), *pb = str_of(b);
  for (long i = 0; i < la; i++) {
    if (i >= lb) return 1;
    unsigned char x = pa[i], y = pb[i];
    if (x != y) return x < y ? -1 : 1;
  }
  return la < lb ? -1 : 0;
}

value skunk_lt(value a, value b) { return bool_of(order(a, b) < 0); }
value skunk_le(value a, value b) { return bool_of(order(a, b) <= 0); }
value skunk_gt(value a, value b) { return bool_of(order(a, b) > 0); }
value skunk_ge(value a, value b) { return bool_of(order(a, b) >= 0); }
value skunk_compare(value a, value b) { return OF_INT(order(a, b)); }

/* ---- arithmetic, arrays, refs, lists ------------------------------------- */

value skunk_div(value a, value b) {
  long y = TO_INT(b);
  if (!y) fail("division by zero");
  return OF_INT(TO_INT(a) / y);
}

value skunk_mod(value a, value b) {
  long y = TO_INT(b);
  if (!y) fail("division by zero");
  return OF_INT(TO_INT(a) % y);
}

value skunk_abs(value n) {
  long v = TO_INT(n);
  return OF_INT(v < 0 ? -v : v);
}

value skunk_min(value a, value b) { return a <= b ? a : b; }
value skunk_max(value a, value b) { return a >= b ? a : b; }

value skunk_array(value n, value init) {
  long len = TO_INT(n);
  if (len < 0) fail("Array.array: negative size");
  /* `init` has to survive the allocation, and it does: the collector sees this
     frame. */
  value v = skunk_alloc(&skunk_array_desc, len + 1);
  BLOCK(v)[0] = len;
  for (long i = 0; i < len; i++) BLOCK(v)[i + 1] = init;
  return v;
}

value skunk_array_length(value a) { return OF_INT(BLOCK(a)[0]); }

value skunk_array_sub(value a, value i) {
  long k = TO_INT(i), n = BLOCK(a)[0];
  if (k < 0 || k >= n) fail_index("Array.sub", k, n);
  return BLOCK(a)[k + 1];
}

value skunk_array_update(value a, value i, value x) {
  long k = TO_INT(i), n = BLOCK(a)[0];
  if (k < 0 || k >= n) fail_index("Array.update", k, n);
  BLOCK(a)[k + 1] = x;
  return skunk_the_unit;
}

value skunk_ref(value x) {
  value v = skunk_alloc(&skunk_ref_desc, 1);
  BLOCK(v)[0] = x;
  return v;
}

value skunk_deref(value r) { return BLOCK(r)[0]; }

value skunk_setref(value r, value x) {
  BLOCK(r)[0] = x;
  return skunk_the_unit;
}

/* A cons cell carries one field, a pair, so building a list needs three
   descriptors -- which is why `@` and the array/list conversions are here and
   not in the basis written in SkunkML. */
static int is_cons(value v) { return !IS_INT(v) && DESC(v)->list == 2; }

value skunk_append(value a, value b) {
  if (!is_cons(a)) return b;
  value pair = BLOCK(a)[0];
  value head = BLOCK(pair)[0];
  value tail = skunk_append(BLOCK(pair)[1], b);
  value p = skunk_alloc(&skunk_pair_desc, 2);
  BLOCK(p)[0] = head;
  BLOCK(p)[1] = tail;
  value c = skunk_alloc(&skunk_cons_desc, 1);
  BLOCK(c)[0] = p;
  return c;
}

value skunk_array_from_list(value l) {
  long n = 0;
  for (value p = l; is_cons(p); p = BLOCK(BLOCK(p)[0])[1]) n++;
  value v = skunk_alloc(&skunk_array_desc, n + 1);
  BLOCK(v)[0] = n;
  long i = 0;
  for (value p = l; is_cons(p); p = BLOCK(BLOCK(p)[0])[1]) BLOCK(v)[++i] = BLOCK(BLOCK(p)[0])[0];
  return v;
}

value skunk_array_to_list(value a) {
  value acc = NIL_VAL;
  for (long i = BLOCK(a)[0] - 1; i >= 0; i--) {
    value p = skunk_alloc(&skunk_pair_desc, 2);
    BLOCK(p)[0] = BLOCK(a)[i + 1];
    BLOCK(p)[1] = acc;
    value c = skunk_alloc(&skunk_cons_desc, 1);
    BLOCK(c)[0] = p;
    acc = c;
  }
  return acc;
}

/* ---- printing ------------------------------------------------------------ */

/* Prints a value the way the interpreter prints it, which is what makes the
   differential test possible: a compiled program's output has to match `skunk`
   byte for byte. */
static void show(value v) {
  if (IS_INT(v)) {
    out_int(TO_INT(v));
    return;
  }
  struct desc *d = DESC(v);
  switch (d->kind) {
    case K_STRING: {
      outc('"');
      const char *s = str_of(v);
      for (long i = 0; i < str_len(v); i++) {
        char c = s[i];
        if (c == '"' || c == '\\') {
          outc('\\');
          outc(c);
        } else if (c == '\n') outz("\\n");
        else if (c == '\t') outz("\\t");
        else outc(c);
      }
      outc('"');
      return;
    }
    case K_CLOSURE: outz("fn"); return;
    case K_REF:
      outz("ref ");
      show(BLOCK(v)[0]);
      return;
    case K_ARRAY:
      outz("[|");
      for (long i = 0; i < BLOCK(v)[0]; i++) {
        if (i) outz(", ");
        show(BLOCK(v)[i + 1]);
      }
      outz("|]");
      return;
    case K_CON:
      if (d->list) {
        /* The datatype prints as a list, which is a fact about the datatype and
           so something the descriptor says outright. */
        outc('[');
        int first = 1;
        while (is_cons(v)) {
          value pair = BLOCK(v)[0];
          if (!first) outz(", ");
          first = 0;
          show(BLOCK(pair)[0]);
          v = BLOCK(pair)[1];
        }
        outc(']');
        return;
      }
      out((const char *)&d->con[1], d->con[0]);
      if (d->nfields) {
        outc(' ');
        show(BLOCK(v)[0]);
      }
      return;
    default: {
      /* A record.  No fields is unit, and no labels is a tuple. */
      if (!d->nfields) {
        outz("()");
        return;
      }
      int tuple = d->labels == 0;
      outz(tuple ? "(" : "{ ");
      for (long i = 0; i < d->nfields; i++) {
        if (i) outz(", ");
        if (!tuple) {
          const value *l = d->labels[i];
          out((const char *)&l[1], l[0]);
          outz(" = ");
        }
        show(BLOCK(v)[i]);
      }
      outz(tuple ? ")" : " }");
      return;
    }
  }
}

void skunk_report(const value *label, value v) {
  out((const char *)&label[1], label[0]);
  outz(" = ");
  show(v);
  outc('\n');
}

void skunk_report_label(const value *label) {
  out((const char *)&label[1], label[0]);
  outc('\n');
}

/* ---- entry --------------------------------------------------------------- */

extern void skunk_program(void);

/* There is no libc, so nothing has run before this: no constructors, no argv.
   The stack pointer is the argument, because it is where the collector's root
   scan stops; after that there is the heap, the one unit value everything
   shares, and the program. */
__attribute__((noreturn)) void skunk_boot(void *sp) {
  stack_top = sp;
  heap_init();
  skunk_the_unit = skunk_alloc(&skunk_unit_desc, 0);
  skunk_program();
  skunk_flush();
  leave(0);
}

/* The kernel jumps straight here, with the stack pointer at the top of the stack
   and no return address under it -- so this is not a C frame, and the one thing
   that has to happen before C can run is the sixteen-byte alignment that a call
   would otherwise have arranged. */
__attribute__((naked, noreturn)) void _start(void) {
  __asm__ volatile("movq %rsp, %rdi\n\tandq $-16, %rsp\n\tcallq skunk_boot");
}
