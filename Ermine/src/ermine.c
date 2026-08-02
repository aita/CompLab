/* Ermine -- a Forth.
 *
 * The whole system is one flat array of bytes: the dictionary, the data space,
 * the two stacks and the input buffers all live in it, and every address a
 * Forth program handles is an offset into it.  That is what makes SAVE-IMAGE a
 * single fwrite, and what makes `@` and `!` total -- there is nothing outside
 * the image for them to reach.
 *
 * This file holds the inner interpreter, the primitives, and just enough of an
 * outer interpreter to read lib/core.erm.  Everything else -- the compiler, the
 * control structures, the defining words, CATCH, the number formatter, the
 * decompiler, and the outer interpreter you actually type at -- is Forth, and
 * lives in lib/core.erm.
 */

#include <setjmp.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

typedef int64_t cell;
typedef uint64_t ucell;
typedef unsigned char byte;

#define CELL ((cell)sizeof(cell))
#define MAGIC "ERMINE01"
#define VERSION 1

/* ------------------------------------------------------------------ image */

/* The bottom of the image is a boot record at fixed offsets, which a saved
 * image and this file both agree on.  Everything the kernel needs to find
 * again after a restart is named here, because after a restart there is no C
 * code left that remembers where anything went. */
#define BOOT_MAGIC 0 /* 8 bytes, not a cell */
#define BOOT_VERSION 8
#define BOOT_MEMSIZE 16
#define BOOT_USED 24     /* the dictionary pointer at the moment of the save */
#define BOOT_XT 32       /* what to run when the image is started */
#define BOOT_PRIMSIG 40  /* hash of the primitive table that built the image */
#define BOOT_DISPATCH 48 /* which inner interpreter saved it, informational */
#define BOOT_DP 56       /* the five kernel variables, by address, so that a */
#define BOOT_LATEST 64   /* restored image needs no rebuilding */
#define BOOT_STATE 72
#define BOOT_BASE 80
#define BOOT_TOIN 88
#define BOOT_STOPXT 96  /* the one-cell word that stops the inner interpreter */
#define THROW_TRAMP 112 /* [ xt of THROW ][ stop ] */
#define RUN_TRAMP 128   /* RUN_SLOTS pairs of [ xt ][ stop ], for run_xt */
#define RUN_SLOTS 16
#define VAR_DP 384 /* the bodies of the five variables */
#define VAR_LATEST 392
#define VAR_STATE 400
#define VAR_BASE 408
#define VAR_TOIN 416
#define SCRATCH 512 /* where SOURCE-NAME and ARG hand a string to Forth */
#define SCRATCH_SIZE 512
#define SRCBUF 1024 /* one line buffer per nested input source */
#define SRCBUF_SIZE 1024
#define MAX_SOURCES 16
#define DICT_START (SRCBUF + MAX_SOURCES * SRCBUF_SIZE)

/* Both stacks grow downwards, and each has a guard band above and below it.
 * The bands are why the inner interpreter can check the stacks once per
 * instruction rather than once per primitive: one instruction moves a pointer
 * by at most a few cells, so it cannot get past a band unnoticed. */
#define DSTACK_CELLS 1024
#define RSTACK_CELLS 1024
#define GUARD_CELLS 64
#define DEFAULT_IMAGE (16 * 1024 * 1024)

#define F_IMMEDIATE 0x80
#define F_HIDDEN 0x40
#define F_COMPILE 0x20 /* an error to execute while interpreting */
#define F_LENMASK 0x1f

static byte *mem;
static cell memsize;
static cell sp0, dstack_base, rp0, rstack_base, dict_limit;
static cell ip, sp, rp;

static cell v_dp, v_latest, v_state, v_base, v_toin; /* variable bodies */
static cell xt_exit, xt_lit;      /* what the kernel's `:` and `;` compile */
static int run_depth;             /* nesting of run_xt */
static int booting = 1;           /* an error while loading core.erm is fatal */
static jmp_buf top_jmp;
static int fargc;                 /* the arguments handed on to Forth */
static char **fargv;
static struct timespec t_start;

static inline cell fetch(cell a) {
  cell v;
  memcpy(&v, mem + a, sizeof v);
  return v;
}
static inline void store(cell a, cell v) { memcpy(mem + a, &v, sizeof v); }
static inline int in_image(cell a, cell n) {
  return a >= 0 && n >= 0 && a <= memsize - n;
}
static inline void push(cell v) {
  sp -= CELL;
  store(sp, v);
}
static inline cell pop(void) {
  cell v = fetch(sp);
  sp += CELL;
  return v;
}
static inline void rpush(cell v) {
  rp -= CELL;
  store(rp, v);
}
static inline cell rpop(void) {
  cell v = fetch(rp);
  rp += CELL;
  return v;
}

static void fatal(const char *fmt, ...) {
  va_list ap;
  fflush(stdout);
  fputs("ermine: ", stderr);
  va_start(ap, fmt);
  vfprintf(stderr, fmt, ap);
  va_end(ap);
  fputc('\n', stderr);
  exit(1);
}

/* -------------------------------------------------------------- primitives */

/* The first six have no name.  They are the code fields of the word *classes*
 * -- what a colon definition, a CREATEd word, a constant or a DOES> word does
 * when it is executed -- and Forth reaches them through the constants DOCOL,
 * DOVAR, DOCON, DOVAL and DODOES rather than by executing them. */
#define PRIMS(X)                                                               \
  X(DOCOL, "")                                                                 \
  X(DOVAR, "")                                                                 \
  X(DOCON, "")                                                                 \
  X(DOVAL, "")                                                                 \
  X(DODOES, "")                                                                \
  X(STOP, "")                                                                  \
  X(EXIT, "exit")                                                              \
  X(LIT, "(lit)")                                                              \
  X(BRANCH, "(branch)")                                                        \
  X(ZBRANCH, "(0branch)")                                                      \
  X(EXECUTE, "execute")                                                        \
  X(DUP, "dup")                                                                \
  X(DROP, "drop")                                                              \
  X(SWAP, "swap")                                                              \
  X(OVER, "over")                                                              \
  X(ROT, "rot")                                                                \
  X(TOR, ">r")                                                                 \
  X(RFROM, "r>")                                                               \
  X(RFETCH, "r@")                                                              \
  X(SPFETCH, "sp@")                                                            \
  X(SPSTORE, "sp!")                                                            \
  X(RPFETCH, "rp@")                                                            \
  X(RPSTORE, "rp!")                                                            \
  X(FETCH, "@")                                                                \
  X(STORE, "!")                                                                \
  X(CFETCH, "c@")                                                              \
  X(CSTORE, "c!")                                                              \
  X(MOVE, "move")                                                              \
  X(FILL, "fill")                                                              \
  X(PLUS, "+")                                                                 \
  X(MINUS, "-")                                                                \
  X(TIMES, "*")                                                                \
  X(UMTIMES, "um*")                                                            \
  X(UMDIVMOD, "um/mod")                                                        \
  X(SREM, "s/rem")                                                             \
  X(AND, "and")                                                                \
  X(OR, "or")                                                                  \
  X(XOR, "xor")                                                                \
  X(INVERT, "invert")                                                          \
  X(LSHIFT, "lshift")                                                          \
  X(RSHIFT, "rshift")                                                          \
  X(EQUAL, "=")                                                                \
  X(LESS, "<")                                                                 \
  X(ULESS, "u<")                                                               \
  X(ZEQUAL, "0=")                                                              \
  X(KEY, "key")                                                                \
  X(EMIT, "emit")                                                              \
  X(TYPE, "type")                                                              \
  X(SOURCE, "source")                                                          \
  X(REFILL, "refill")                                                          \
  X(PUSHFILE, "(push-file)")                                                   \
  X(PUSHSTR, "(push-string)")                                                  \
  X(POPSRC, "(pop-source)")                                                    \
  X(SRCLINE, "source-line")                                                    \
  X(SRCNAME, "source-name")                                                    \
  X(COLON, ":")                                                                \
  X(SEMI, ";")                                                                 \
  X(BYE, "bye")                                                                \
  X(DIE, "(die)")                                                              \
  X(UNCAUGHT, "(uncaught)")                                                    \
  X(SAVEIMG, "(save-image)")                                                   \
  X(ARGC, "argc")                                                              \
  X(ARG, "arg")                                                                \
  X(TICKS, "ticks")                                                            \
  X(TTY, "tty?")                                                               \
  X(DISPATCH, "(dispatch)")

enum {
#define X(id, name) OP_##id,
  PRIMS(X)
#undef X
      OP_COUNT
};

static const char *const prim_names[] = {
#define X(id, name) name,
    PRIMS(X)
#undef X
};

/* ------------------------------------------------------------- input stack */

typedef struct {
  FILE *f;
  int is_file;
  int close_it;
  cell buf; /* where this level's text sits in the image */
  cell len;
  cell saved_toin;
  int line;
  char name[256];
} Source;

static Source srcs[MAX_SOURCES];
static int nsrc;

/* ------------------------------------------------------------- dictionary */

static cell here(void) { return fetch(v_dp); }
static void set_here(cell a) { store(v_dp, a); }
static cell aligned_addr(cell a) { return (a + CELL - 1) & ~(CELL - 1); }

static void comma(cell v) {
  cell h = here();
  if (h + CELL > dict_limit)
    fatal("dictionary full");
  store(h, v);
  set_here(h + CELL);
}

/* A header is [ link ][ flags+length ][ name ][ padding ], and the execution
 * token is the aligned address just past it.  lib/core.erm builds headers of
 * exactly this shape in HEADER, -- the format is the one thing the kernel and
 * the Forth source both have to know. */
static cell nt_to_xt(cell nt) {
  cell b = nt + CELL;
  return aligned_addr(b + 1 + (mem[b] & F_LENMASK));
}

static cell create_header(const char *name, size_t len, int flags) {
  cell nt, h;
  if (len == 0 || len > F_LENMASK)
    fatal("bad definition name");
  set_here(aligned_addr(here()));
  nt = here();
  comma(fetch(v_latest));
  h = here();
  mem[h] = (byte)(flags | (int)len);
  memcpy(mem + h + 1, name, len);
  set_here(aligned_addr(h + 1 + (cell)len));
  store(v_latest, nt);
  return here();
}

static cell find_word(const char *name, size_t len) {
  cell nt = fetch(v_latest);
  while (nt) {
    byte f = mem[nt + CELL];
    if (!(f & F_HIDDEN) && (size_t)(f & F_LENMASK) == len &&
        memcmp(mem + nt + CELL + 1, name, len) == 0)
      return nt;
    nt = fetch(nt);
  }
  return 0;
}

static cell xt_of(const char *name) {
  cell nt = find_word(name, strlen(name));
  if (!nt)
    fatal("the kernel expected `%s` to be defined", name);
  return nt_to_xt(nt);
}

static void def_prim(const char *name, int op, int flags) {
  create_header(name, strlen(name), flags);
  comma(op);
}

/* Constants and variables share the layout of every created word:
 * [ code ][ DOES> slot ][ body ].  A variable is a constant holding an
 * address, which is all a variable ever is. */
static void def_const(const char *name, cell v) {
  create_header(name, strlen(name), 0);
  comma(OP_DOCON);
  comma(0);
  comma(v);
}

/* ------------------------------------------------------------------ errors */

/* A primitive reports an error by arranging for THROW to run next: it pushes
 * the code and points IP at a two-cell thread whose first cell is THROW's
 * token.  The error then travels the same way a Forth THROW does, through
 * whatever CATCH is closest. */
static void do_throw(cell code) {
  if (!fetch(THROW_TRAMP)) {
    cell nt = find_word("throw", 5);
    if (!nt) {
      fflush(stdout);
      fprintf(stderr, "ermine: throw %lld before THROW is defined\n",
              (long long)code);
      longjmp(top_jmp, 1);
    }
    store(THROW_TRAMP, nt_to_xt(nt));
    store(THROW_TRAMP + CELL, fetch(BOOT_STOPXT));
  }
  push(code);
  ip = THROW_TRAMP;
}

/* --------------------------------------------------------------- the loop */

#if defined(__GNUC__) && !defined(ERMINE_SWITCH)
#define COMPUTED_GOTO 1
#else
#define COMPUTED_GOTO 0
#endif

/* The check the inner interpreter runs before every instruction has to be
 * small enough to be inlined at all sixty-odd dispatch sites; what to do when
 * it fails does not, and is out of line. */
static inline int stacks_ok(void) {
  return (ucell)(sp0 - sp) <= (ucell)(DSTACK_CELLS * CELL) &&
         (ucell)(rp0 - rp) <= (ucell)(RSTACK_CELLS * CELL);
}

static void stack_fault(void) {
  if ((ucell)(sp0 - sp) > (ucell)(DSTACK_CELLS * CELL)) {
    cell code = sp > sp0 ? -4 : -3;
    sp = sp0;
    do_throw(code);
    return;
  }
  {
    cell code = rp > rp0 ? -6 : -5;
    rp = rp0;
    do_throw(code);
  }
}

static cell refill_source(void);
static cell push_file(const char *path);
static void pop_source(void);
static cell save_image(const char *path);
static int parse_name(cell *addr, cell *len);

static void inner(void) {
  cell w = 0, op;
#if COMPUTED_GOTO
  static void *labels[] = {
#define X(id, name) &&L_##id,
      PRIMS(X)
#undef X
  };
/* The point of a computed goto is not the indirect jump -- a switch compiles
 * to one of those too -- but that there is a separate one at the end of every
 * handler, so that the processor can predict the next word from the current
 * one.  Sharing a single dispatch site would throw that away, so DISPATCH is
 * pasted in whole at each ENDCASE. */
#define DISPATCH                                                               \
  do {                                                                         \
    if (!stacks_ok()) {                                                        \
      stack_fault();                                                           \
      goto next;                                                               \
    }                                                                          \
    w = fetch(ip);                                                             \
    ip += CELL;                                                                \
    if (!in_image(w, CELL)) {                                                  \
      do_throw(-9);                                                            \
      goto next;                                                               \
    }                                                                          \
    op = fetch(w);                                                             \
    if ((ucell)op >= (ucell)OP_COUNT) {                                        \
      do_throw(-13);                                                           \
      goto next;                                                               \
    }                                                                          \
    goto *labels[op];                                                          \
  } while (0)

#define CASE(id) L_##id:
#define ENDCASE DISPATCH;
#define AGAIN goto next;

next:
  DISPATCH;
run:
  if (!in_image(w, CELL)) {
    do_throw(-9);
    goto next;
  }
  op = fetch(w);
  if ((ucell)op >= (ucell)OP_COUNT) {
    do_throw(-13);
    goto next;
  }
  goto *labels[op];
#else
#define CASE(id) case OP_##id:
#define ENDCASE break;
#define AGAIN continue;

  for (;;) {
    if (!stacks_ok()) {
      stack_fault();
      continue;
    }
    w = fetch(ip);
    ip += CELL;
  run:
    if (!in_image(w, CELL)) {
      do_throw(-9);
      continue;
    }
    op = fetch(w);
    switch (op) {
#endif

      CASE(DOCOL) {
        rpush(ip);
        ip = w + CELL;
      }
      ENDCASE

      CASE(DOVAR) { push(w + 2 * CELL); }
      ENDCASE

      CASE(DOCON) { push(fetch(w + 2 * CELL)); }
      ENDCASE

      CASE(DOVAL) { push(fetch(w + 2 * CELL)); }
      ENDCASE

      /* The body address first, then a call into the code DOES> left behind. */
      CASE(DODOES) {
        push(w + 2 * CELL);
        rpush(ip);
        ip = fetch(w + CELL);
      }
      ENDCASE

      CASE(STOP) { return; }

      CASE(EXIT) { ip = rpop(); }
      ENDCASE

      CASE(LIT) {
        push(fetch(ip));
        ip += CELL;
      }
      ENDCASE

      CASE(BRANCH) { ip = fetch(ip); }
      ENDCASE

      CASE(ZBRANCH) {
        if (pop() == 0)
          ip = fetch(ip);
        else
          ip += CELL;
      }
      ENDCASE

      CASE(EXECUTE) {
        w = pop();
        goto run;
      }

      CASE(DUP) { push(fetch(sp)); }
      ENDCASE
      CASE(DROP) { sp += CELL; }
      ENDCASE
      CASE(SWAP) {
        cell a = fetch(sp), b = fetch(sp + CELL);
        store(sp, b);
        store(sp + CELL, a);
      }
      ENDCASE
      CASE(OVER) { push(fetch(sp + CELL)); }
      ENDCASE
      CASE(ROT) {
        cell a = fetch(sp), b = fetch(sp + CELL), c = fetch(sp + 2 * CELL);
        store(sp, c);
        store(sp + CELL, a);
        store(sp + 2 * CELL, b);
      }
      ENDCASE

      CASE(TOR) { rpush(pop()); }
      ENDCASE
      CASE(RFROM) { push(rpop()); }
      ENDCASE
      CASE(RFETCH) { push(fetch(rp)); }
      ENDCASE
      CASE(SPFETCH) {
        cell t = sp;
        push(t);
      }
      ENDCASE
      CASE(SPSTORE) { sp = fetch(sp); }
      ENDCASE
      CASE(RPFETCH) { push(rp); }
      ENDCASE
      CASE(RPSTORE) { rp = pop(); }
      ENDCASE

      CASE(FETCH) {
        cell a = fetch(sp);
        if (!in_image(a, CELL)) {
          do_throw(-9);
          AGAIN
        }
        store(sp, fetch(a));
      }
      ENDCASE
      CASE(STORE) {
        cell a = pop(), v = pop();
        if (!in_image(a, CELL)) {
          do_throw(-9);
          AGAIN
        }
        store(a, v);
      }
      ENDCASE
      CASE(CFETCH) {
        cell a = fetch(sp);
        if (!in_image(a, 1)) {
          do_throw(-9);
          AGAIN
        }
        store(sp, mem[a]);
      }
      ENDCASE
      CASE(CSTORE) {
        cell a = pop(), v = pop();
        if (!in_image(a, 1)) {
          do_throw(-9);
          AGAIN
        }
        mem[a] = (byte)v;
      }
      ENDCASE
      CASE(MOVE) {
        cell n = pop(), d = pop(), s = pop();
        if (n < 0 || !in_image(s, n) || !in_image(d, n)) {
          do_throw(-9);
          AGAIN
        }
        if (n)
          memmove(mem + d, mem + s, (size_t)n);
      }
      ENDCASE
      CASE(FILL) {
        cell c = pop(), n = pop(), a = pop();
        if (n < 0 || !in_image(a, n)) {
          do_throw(-9);
          AGAIN
        }
        if (n)
          memset(mem + a, (int)(byte)c, (size_t)n);
      }
      ENDCASE

      CASE(PLUS) {
        cell b = pop();
        store(sp, (cell)((ucell)fetch(sp) + (ucell)b));
      }
      ENDCASE
      CASE(MINUS) {
        cell b = pop();
        store(sp, (cell)((ucell)fetch(sp) - (ucell)b));
      }
      ENDCASE
      CASE(TIMES) {
        cell b = pop();
        store(sp, (cell)((ucell)fetch(sp) * (ucell)b));
      }
      ENDCASE
      CASE(UMTIMES) { /* u1 u2 -- lo hi */
        ucell b = (ucell)pop(), a = (ucell)fetch(sp);
        unsigned __int128 p = (unsigned __int128)a * b;
        store(sp, (cell)(ucell)p);
        push((cell)(ucell)(p >> 64));
      }
      ENDCASE
      CASE(UMDIVMOD) { /* ud-lo ud-hi u -- rem quot */
        ucell d = (ucell)pop(), hi = (ucell)pop(), lo = (ucell)fetch(sp);
        unsigned __int128 n;
        if (d == 0) {
          sp += CELL;
          do_throw(-10);
          AGAIN
        }
        n = ((unsigned __int128)hi << 64) | lo;
        if ((n / d) >> 64) {
          sp += CELL;
          do_throw(-11);
          AGAIN
        }
        store(sp, (cell)(ucell)(n % d));
        push((cell)(ucell)(n / d));
      }
      ENDCASE
      CASE(SREM) { /* n1 n2 -- rem quot, truncated towards zero */
        cell b = pop(), a = fetch(sp);
        if (b == 0) {
          sp += CELL;
          do_throw(-10);
          AGAIN
        }
        if (a == INT64_MIN && b == -1) {
          sp += CELL;
          do_throw(-11);
          AGAIN
        }
        store(sp, a % b);
        push(a / b);
      }
      ENDCASE

      CASE(AND) {
        cell b = pop();
        store(sp, fetch(sp) & b);
      }
      ENDCASE
      CASE(OR) {
        cell b = pop();
        store(sp, fetch(sp) | b);
      }
      ENDCASE
      CASE(XOR) {
        cell b = pop();
        store(sp, fetch(sp) ^ b);
      }
      ENDCASE
      CASE(INVERT) { store(sp, ~fetch(sp)); }
      ENDCASE
      CASE(LSHIFT) {
        cell n = pop();
        ucell v = (ucell)fetch(sp);
        store(sp, (cell)(n >= 64 || n < 0 ? 0 : v << n));
      }
      ENDCASE
      CASE(RSHIFT) {
        cell n = pop();
        ucell v = (ucell)fetch(sp);
        store(sp, (cell)(n >= 64 || n < 0 ? 0 : v >> n));
      }
      ENDCASE

      CASE(EQUAL) {
        cell b = pop();
        store(sp, fetch(sp) == b ? -1 : 0);
      }
      ENDCASE
      CASE(LESS) {
        cell b = pop();
        store(sp, fetch(sp) < b ? -1 : 0);
      }
      ENDCASE
      CASE(ULESS) {
        ucell b = (ucell)pop();
        store(sp, (ucell)fetch(sp) < b ? -1 : 0);
      }
      ENDCASE
      CASE(ZEQUAL) { store(sp, fetch(sp) == 0 ? -1 : 0); }
      ENDCASE

      CASE(KEY) {
        int c;
        fflush(stdout);
        c = getchar();
        push(c == EOF ? -1 : c);
      }
      ENDCASE
      CASE(EMIT) { putchar((int)(byte)pop()); }
      ENDCASE
      CASE(TYPE) {
        cell n = pop(), a = pop();
        if (n < 0 || !in_image(a, n)) {
          do_throw(-9);
          AGAIN
        }
        if (n)
          fwrite(mem + a, 1, (size_t)n, stdout);
      }
      ENDCASE

      CASE(SOURCE) {
        push(srcs[nsrc - 1].buf);
        push(srcs[nsrc - 1].len);
      }
      ENDCASE
      CASE(REFILL) { push(refill_source()); }
      ENDCASE
      CASE(PUSHFILE) {
        cell n = pop(), a = pop();
        char path[512];
        if (n < 0 || n >= (cell)sizeof path || !in_image(a, n)) {
          do_throw(-9);
          AGAIN
        }
        memcpy(path, mem + a, (size_t)n);
        path[n] = 0;
        push(push_file(path));
      }
      ENDCASE
      CASE(PUSHSTR) {
        cell n = pop(), a = pop();
        if (n < 0 || !in_image(a, n)) {
          do_throw(-9);
          AGAIN
        }
        if (nsrc >= MAX_SOURCES) {
          do_throw(-38);
          AGAIN
        }
        srcs[nsrc - 1].saved_toin = fetch(v_toin);
        srcs[nsrc].f = NULL;
        srcs[nsrc].is_file = 0;
        srcs[nsrc].close_it = 0;
        srcs[nsrc].buf = a;
        srcs[nsrc].len = n;
        srcs[nsrc].line = srcs[nsrc - 1].line;
        memcpy(srcs[nsrc].name, srcs[nsrc - 1].name, sizeof srcs[nsrc].name);
        nsrc++;
        store(v_toin, 0);
      }
      ENDCASE
      CASE(POPSRC) { pop_source(); }
      ENDCASE
      CASE(SRCLINE) { push(srcs[nsrc - 1].line); }
      ENDCASE
      CASE(SRCNAME) {
        size_t n = strlen(srcs[nsrc - 1].name);
        if (n > SCRATCH_SIZE)
          n = SCRATCH_SIZE;
        memcpy(mem + SCRATCH, srcs[nsrc - 1].name, n);
        push(SCRATCH);
        push((cell)n);
      }
      ENDCASE

      /* The kernel's `:` and `;`.  lib/core.erm defines both again, in Forth;
       * these two exist only so that it can. */
      CASE(COLON) {
        cell a, n;
        if (!parse_name(&a, &n))
          fatal("%s:%d: `:` with no name", srcs[nsrc - 1].name,
                srcs[nsrc - 1].line);
        create_header((const char *)(mem + a), (size_t)n, F_HIDDEN);
        comma(OP_DOCOL);
        store(v_state, 1);
      }
      ENDCASE
      CASE(SEMI) {
        cell nt = fetch(v_latest);
        comma(xt_exit);
        mem[nt + CELL] &= (byte)~F_HIDDEN;
        store(v_state, 0);
      }
      ENDCASE

      CASE(BYE) {
        fflush(stdout);
        exit(0);
      }
      ENDCASE
      CASE(DIE) {
        cell n = pop();
        fflush(stdout);
        exit((int)n);
      }
      ENDCASE
      CASE(UNCAUGHT) {
        cell code = pop();
        fflush(stdout);
        fprintf(stderr, "%s:%d: uncaught throw %lld\n", srcs[nsrc - 1].name,
                srcs[nsrc - 1].line, (long long)code);
        longjmp(top_jmp, 1);
      }
      ENDCASE

      CASE(SAVEIMG) {
        cell n = pop(), a = pop();
        char path[512];
        if (n < 0 || n >= (cell)sizeof path || !in_image(a, n)) {
          do_throw(-9);
          AGAIN
        }
        memcpy(path, mem + a, (size_t)n);
        path[n] = 0;
        push(save_image(path));
      }
      ENDCASE

      CASE(ARGC) { push(fargc); }
      ENDCASE
      CASE(ARG) {
        cell i = pop();
        if (i < 0 || i >= fargc) {
          push(SCRATCH);
          push(0);
        } else {
          size_t n = strlen(fargv[i]);
          if (n > SCRATCH_SIZE)
            n = SCRATCH_SIZE;
          memcpy(mem + SCRATCH, fargv[i], n);
          push(SCRATCH);
          push((cell)n);
        }
      }
      ENDCASE

      CASE(TICKS) {
        struct timespec t;
        clock_gettime(CLOCK_MONOTONIC, &t);
        push((cell)(t.tv_sec - t_start.tv_sec) * 1000000 +
             (t.tv_nsec - t_start.tv_nsec) / 1000);
      }
      ENDCASE
      CASE(TTY) { push(isatty(0) ? -1 : 0); }
      ENDCASE
      CASE(DISPATCH) { push(COMPUTED_GOTO); }
      ENDCASE

#if !COMPUTED_GOTO
    default:
      do_throw(-13);
      continue;
    }
  }
#endif
}

#undef CASE
#undef ENDCASE
#undef AGAIN

/* Run one execution token from C.  The trampoline is a two-cell thread whose
 * second cell stops the inner interpreter, so `inner` returns exactly when the
 * word is finished. */
static void run_xt(cell xt) {
  cell slot, saved_ip = ip;
  if (run_depth >= RUN_SLOTS)
    fatal("run trampoline overflow");
  slot = RUN_TRAMP + run_depth * 2 * CELL;
  run_depth++;
  store(slot, xt);
  store(slot + CELL, fetch(BOOT_STOPXT));
  ip = slot;
  inner();
  run_depth--;
  ip = saved_ip;
}

/* ------------------------------------------------------------ input stack */

static void init_stdin_source(void) {
  srcs[0].f = stdin;
  srcs[0].is_file = 1;
  srcs[0].close_it = 0;
  srcs[0].buf = SRCBUF;
  srcs[0].len = 0;
  srcs[0].line = 0;
  snprintf(srcs[0].name, sizeof srcs[0].name, "<stdin>");
  nsrc = 1;
  store(v_toin, 0);
}

static cell push_file(const char *path) {
  FILE *f;
  if (nsrc >= MAX_SOURCES)
    return -38;
  f = fopen(path, "r");
  if (!f)
    return -38;
  srcs[nsrc - 1].saved_toin = fetch(v_toin);
  srcs[nsrc].f = f;
  srcs[nsrc].is_file = 1;
  srcs[nsrc].close_it = 1;
  srcs[nsrc].buf = SRCBUF + (cell)nsrc * SRCBUF_SIZE;
  srcs[nsrc].len = 0;
  srcs[nsrc].line = 0;
  snprintf(srcs[nsrc].name, sizeof srcs[nsrc].name, "%s", path);
  nsrc++;
  store(v_toin, 0);
  return 0;
}

static void pop_source(void) {
  if (nsrc <= 1)
    return;
  nsrc--;
  if (srcs[nsrc].close_it && srcs[nsrc].f)
    fclose(srcs[nsrc].f);
  store(v_toin, srcs[nsrc - 1].saved_toin);
}

static cell refill_source(void) {
  Source *s = &srcs[nsrc - 1];
  char line[SRCBUF_SIZE];
  size_t n;
  if (!s->is_file)
    return 0;
  if (s->f == stdin)
    fflush(stdout);
  if (!fgets(line, sizeof line, s->f))
    return 0;
  n = strlen(line);
  while (n && (line[n - 1] == '\n' || line[n - 1] == '\r'))
    n--;
  memcpy(mem + s->buf, line, n);
  s->len = (cell)n;
  s->line++;
  store(v_toin, 0);
  return -1;
}

/* --------------------------------------------------- the boot interpreter */

/* Enough of an outer interpreter to read lib/core.erm, and no more: it parses
 * a name, finds it, executes or compiles it, and otherwise reads a number in
 * the current BASE.  Once core.erm has defined INTERPRET and QUIT in Forth
 * this is never used again -- the prompt you type at is the Forth one. */

/* The blank that ends the name is consumed with it, exactly as PARSE-NAME in
 * core.erm does -- otherwise a `."` compiled by this interpreter would see the
 * space in front of its text and one compiled by the Forth one would not. */
static int parse_name(cell *addr, cell *len) {
  cell buf = srcs[nsrc - 1].buf, l = srcs[nsrc - 1].len;
  cell i = fetch(v_toin), s;
  while (i < l && mem[buf + i] <= ' ')
    i++;
  s = i;
  while (i < l && mem[buf + i] > ' ')
    i++;
  *addr = buf + s;
  *len = i - s;
  store(v_toin, i < l ? i + 1 : i);
  return i > s;
}

static int to_number(const char *s, cell n, cell *out) {
  cell base = fetch(v_base), v = 0, i = 0;
  int neg = 0, any = 0;
  if (n == 3 && s[0] == '\'' && s[2] == '\'') {
    *out = (byte)s[1];
    return 1;
  }
  if (n > 1 && (s[0] == '-' || s[0] == '+')) {
    neg = s[0] == '-';
    i = 1;
  }
  if (n - i > 1 && s[i] == '$') {
    base = 16;
    i++;
  } else if (n - i > 1 && s[i] == '#') {
    base = 10;
    i++;
  } else if (n - i > 1 && s[i] == '%') {
    base = 2;
    i++;
  }
  for (; i < n; i++) {
    int c = (byte)s[i], d;
    if (c >= '0' && c <= '9')
      d = c - '0';
    else if (c >= 'a' && c <= 'z')
      d = c - 'a' + 10;
    else if (c >= 'A' && c <= 'Z')
      d = c - 'A' + 10;
    else
      return 0;
    if (d >= base)
      return 0;
    v = v * base + d;
    any = 1;
  }
  if (!any)
    return 0;
  *out = neg ? -v : v;
  return 1;
}

static void boot_interpret(void) {
  cell a, n;
  while (parse_name(&a, &n)) {
    cell nt = find_word((const char *)(mem + a), (size_t)n);
    if (nt) {
      if (fetch(v_state) && !(mem[nt + CELL] & F_IMMEDIATE))
        comma(nt_to_xt(nt));
      else
        run_xt(nt_to_xt(nt));
    } else {
      cell v;
      if (!to_number((const char *)(mem + a), n, &v))
        fatal("%s:%d: %.*s?", srcs[nsrc - 1].name, srcs[nsrc - 1].line, (int)n,
              (const char *)(mem + a));
      if (fetch(v_state)) {
        comma(xt_lit);
        comma(v);
      } else
        push(v);
    }
  }
}

static void boot_load(const char *path) {
  if (push_file(path) != 0)
    fatal("cannot open %s", path);
  for (;;) {
    boot_interpret();
    if (!refill_source())
      break;
  }
  pop_source();
}

/* ------------------------------------------------------------------ image */

static cell prim_signature(void) {
  ucell h = 1469598103934665603ULL;
  int i;
  for (i = 0; i < OP_COUNT; i++) {
    const char *p = prim_names[i];
    for (; *p; p++) {
      h ^= (byte)*p;
      h *= 1099511628211ULL;
    }
    h ^= (byte)i;
    h *= 1099511628211ULL;
  }
  return (cell)(h & 0x7fffffffffffffffULL);
}

static cell save_image(const char *path) {
  FILE *f;
  cell used = here();
  memcpy(mem + BOOT_MAGIC, MAGIC, 8);
  store(BOOT_VERSION, VERSION);
  store(BOOT_MEMSIZE, memsize);
  store(BOOT_USED, used);
  store(BOOT_PRIMSIG, prim_signature());
  store(BOOT_DISPATCH, COMPUTED_GOTO);
  store(BOOT_DP, v_dp);
  store(BOOT_LATEST, v_latest);
  store(BOOT_STATE, v_state);
  store(BOOT_BASE, v_base);
  store(BOOT_TOIN, v_toin);
  f = fopen(path, "wb");
  if (!f)
    return -38;
  if (fwrite(mem, 1, (size_t)used, f) != (size_t)used) {
    fclose(f);
    return -38;
  }
  fclose(f);
  return 0;
}

static void set_limits(void) {
  sp0 = memsize - GUARD_CELLS * CELL;
  dstack_base = sp0 - DSTACK_CELLS * CELL;
  rp0 = dstack_base - GUARD_CELLS * CELL;
  rstack_base = rp0 - RSTACK_CELLS * CELL;
  dict_limit = rstack_base - GUARD_CELLS * CELL;
  sp = sp0;
  rp = rp0;
}

static void load_image(const char *path) {
  FILE *f = fopen(path, "rb");
  byte head[512];
  cell used, sig;
  if (!f)
    fatal("cannot open image %s", path);
  if (fread(head, 1, sizeof head, f) != sizeof head)
    fatal("%s: truncated image", path);
  if (memcmp(head, MAGIC, 8) != 0)
    fatal("%s: not an ermine image", path);
  memcpy(&memsize, head + BOOT_MEMSIZE, sizeof memsize);
  memcpy(&used, head + BOOT_USED, sizeof used);
  memcpy(&sig, head + BOOT_PRIMSIG, sizeof sig);
  if (sig != prim_signature())
    fatal("%s: saved by a kernel with a different primitive table", path);
  if (memsize < DICT_START || used > memsize)
    fatal("%s: corrupt image", path);
  mem = calloc(1, (size_t)memsize);
  if (!mem)
    fatal("out of memory");
  memcpy(mem, head, sizeof head);
  if (used > (cell)sizeof head) {
    size_t rest = (size_t)(used - (cell)sizeof head);
    if (fread(mem + sizeof head, 1, rest, f) != rest)
      fatal("%s: truncated image", path);
  }
  fclose(f);
  v_dp = fetch(BOOT_DP);
  v_latest = fetch(BOOT_LATEST);
  v_state = fetch(BOOT_STATE);
  v_base = fetch(BOOT_BASE);
  v_toin = fetch(BOOT_TOIN);
  set_limits();
}

/* ------------------------------------------------------------------- boot */

static void build_dictionary(void) {
  int i;
  cell stop;

  /* The five kernel variables live at fixed addresses in the boot record, so
   * that the dictionary can be built with them rather than around them. */
  v_dp = VAR_DP;
  v_latest = VAR_LATEST;
  v_state = VAR_STATE;
  v_base = VAR_BASE;
  v_toin = VAR_TOIN;
  store(v_dp, DICT_START);
  store(v_latest, 0);
  store(v_state, 0);
  store(v_base, 10);
  store(v_toin, 0);

  /* One nameless cell holding OP_STOP: the only word that can make the inner
   * interpreter return to C. */
  stop = here();
  comma(OP_STOP);
  store(BOOT_STOPXT, stop);

  for (i = 0; i < OP_COUNT; i++)
    if (prim_names[i][0])
      def_prim(prim_names[i], i, strcmp(prim_names[i], ";") == 0 ? F_IMMEDIATE : 0);

  xt_exit = xt_of("exit");
  xt_lit = xt_of("(lit)");

  def_const("dp", VAR_DP);
  def_const("latest", VAR_LATEST);
  def_const("state", VAR_STATE);
  def_const("base", VAR_BASE);
  def_const(">in", VAR_TOIN);

  /* The three tokens the Forth source cannot look up before it can look
   * anything up: they are what IF, LITERAL and friends compile. */
  def_const("'lit", xt_lit);
  def_const("'branch", xt_of("(branch)"));
  def_const("'0branch", xt_of("(0branch)"));

  def_const("docol", OP_DOCOL);
  def_const("dovar", OP_DOVAR);
  def_const("docon", OP_DOCON);
  def_const("doval", OP_DOVAL);
  def_const("dodoes", OP_DODOES);

  def_const("cell", CELL);
  def_const("s0", sp0);
  def_const("r0", rp0);
  def_const("limit", dict_limit);
  def_const("boot-vector", BOOT_XT);
  def_const("image-size", memsize);
  def_const("f_immediate", F_IMMEDIATE);
  def_const("f_hidden", F_HIDDEN);
  def_const("f_compile", F_COMPILE);
  def_const("f_lenmask", F_LENMASK);
}

static const char *find_core(const char *given) {
  static char buf[1024];
  const char *env;
  char exe[512];
  ssize_t n;
  char *slash;
  FILE *f;
  if (given)
    return given;
  env = getenv("ERMINE_CORE");
  if (env)
    return env;
  n = readlink("/proc/self/exe", exe, sizeof exe - 1);
  if (n > 0) {
    exe[n] = 0;
    slash = strrchr(exe, '/');
    if (slash) {
      *slash = 0;
      snprintf(buf, sizeof buf, "%s/../lib/core.erm", exe);
      f = fopen(buf, "r");
      if (f) {
        fclose(f);
        return buf;
      }
      snprintf(buf, sizeof buf, "%s/lib/core.erm", exe);
      f = fopen(buf, "r");
      if (f) {
        fclose(f);
        return buf;
      }
    }
  }
  return "lib/core.erm";
}

static void usage(void) {
  fputs("usage: ermine [--image FILE] [--core FILE] [--memory MB] [args...]\n",
        stderr);
  exit(2);
}

int main(int argc, char **argv) {
  const char *image = NULL, *core = NULL;
  cell want = DEFAULT_IMAGE;
  int i = 1;

  clock_gettime(CLOCK_MONOTONIC, &t_start);
  for (; i < argc; i++) {
    if (strcmp(argv[i], "--image") == 0 && i + 1 < argc)
      image = argv[++i];
    else if (strcmp(argv[i], "--core") == 0 && i + 1 < argc)
      core = argv[++i];
    else if (strcmp(argv[i], "--memory") == 0 && i + 1 < argc)
      want = (cell)atoi(argv[++i]) * 1024 * 1024;
    else if (strcmp(argv[i], "--help") == 0)
      usage();
    else
      break;
  }
  fargc = argc - i;
  fargv = argv + i;

  if (image) {
    load_image(image);
  } else {
    memsize = want < DICT_START + 1024 * 1024 ? DICT_START + 1024 * 1024 : want;
    mem = calloc(1, (size_t)memsize);
    if (!mem)
      fatal("out of memory");
    set_limits();
    build_dictionary();
  }
  init_stdin_source();

  if (setjmp(top_jmp) != 0) {
    if (booting)
      return 1;
    /* An error escaped every CATCH.  Throw the world away down to the
     * outermost input source and start the outer interpreter again. */
    while (nsrc > 1)
      pop_source();
    sp = sp0;
    rp = rp0;
    run_depth = 0;
    store(v_state, 0);
    run_xt(xt_of("quit"));
    return 0;
  }

  if (!image)
    boot_load(find_core(core));
  booting = 0;

  {
    cell boot = fetch(BOOT_XT);
    if (!boot)
      fatal("no boot word: lib/core.erm must set BOOT-VECTOR");
    run_xt(boot);
  }
  fflush(stdout);
  return 0;
}
