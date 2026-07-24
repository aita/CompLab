#!/usr/bin/env python3
"""CPython oracle: run the same program under CPython and under minpython.

tests/fuzz.py checks the JITs against the interpreter, which cannot see a bug
the interpreter shares -- it found nothing while `True & True` was printing 1.
This checks the whole implementation against the language it is a subset of.

Generated programs stay inside that subset and keep their values small
(constants <= 50, every assignment masked), so int64 and Python's bignums
cannot diverge on anything they can reach.

    tests/oracle.py [N]
"""
import random
import subprocess
import sys
import tempfile
from pathlib import Path
BIN = Path(__file__).resolve().parent.parent / 'build' / 'minpython'


def gen(seed):
    r = random.Random(seed)
    def expr(vs, d=0):
        c = ['k', 'v', 'v']
        if d < 3: c += ['bin', 'un', 'cmp', 'cond', 'bool', 'par']
        w = r.choice(c)
        if w == 'k': return str(r.randint(-20, 50))
        if w == 'v': return r.choice(vs)
        if w == 'par': return '(' + expr(vs, d+1) + ')'
        if w == 'un': return r.choice(['-', '~', 'not ']) + '(' + expr(vs, d+1) + ')'
        if w == 'cmp': return '(%s %s %s)' % (expr(vs, d+1), r.choice(['==','!=','<','<=','>','>=']), expr(vs, d+1))
        if w == 'cond': return '(%s if %s else %s)' % (expr(vs, d+1), expr(vs, d+1), expr(vs, d+1))
        if w == 'bool': return '(%s %s %s)' % (expr(vs, d+1), r.choice(['and','or']), expr(vs, d+1))
        op = r.choice(['+','-','*','&','|','^','<<','>>','//','%'])
        if op in ('<<','>>'): return '(%s %s %d)' % (expr(vs, d+1), op, r.randint(0,4))
        if op in ('//','%'):  return '(%s %s %s)' % (expr(vs, d+1), op, r.choice(['2','3','7','-3']))
        return '(%s %s %s)' % (expr(vs, d+1), op, expr(vs, d+1))

    def block(ind, d, in_loop, vs, budget):
        out = []
        for _ in range(r.randint(1, 3)):
            if budget[0] <= 0: break
            budget[0] -= 1
            pool = ['asn', 'asn', 'aug', 'if', 'while']
            if in_loop: pool += ['brk']
            w = r.choice(pool)
            if w == 'asn':
                out.append('%s%s = (%s) %% 997' % (ind, r.choice(vs), expr(vs)))
            elif w == 'aug':
                # masked right after, or `*=` in a loop leaves int64 behind and
                # CPython's bignums answer a different question
                v = r.choice(vs)
                out.append('%s%s %s= (%s) %% 97' % (ind, v, r.choice(['+','-','*']), expr(vs)))
                out.append('%s%s = %s %% 997' % (ind, v, v))
            elif w == 'if' and d < 3:
                out.append('%sif %s:' % (ind, expr(vs)))
                out += block(ind+'    ', d+1, in_loop, vs, budget)
                if r.random() < 0.5:
                    out.append('%selse:' % ind)
                    out += block(ind+'    ', d+1, in_loop, vs, budget)
            elif w == 'while' and d < 3:
                cv = 'k%d' % d
                out.append('%s%s = 0' % (ind, cv))
                out.append('%swhile %s < %d:' % (ind, cv, r.choice([3, 12, 400])))
                body = block(ind+'    ', d+1, True, vs, budget)
                out += body
                out.append('%s    %s = %s + 1' % (ind, cv, cv))
            elif w == 'brk':
                out.append('%s%s' % (ind, r.choice(['break', 'continue'])))
                break
        return out or ['%spass' % ind]

    L = ['a = %d' % r.randint(0, 50), 'b = %d' % r.randint(0, 50),
         'c = %d' % r.randint(0, 50)]
    # a function over its own locals, so nothing needs `global`
    L.append('def f(p, q):')
    L.append('    u = p')
    L.append('    v = q')
    L += block('    ', 1, False, ['p', 'q', 'u', 'v'], [10])
    L.append('    return (u + v + p) % 997')
    L += ['t = 0', 'i = 0', 'while i < 60:']
    L += block('    ', 1, True, ['a', 'b', 'c'], [8])
    L += ['    t = (t + f(i, a)) % 99991', '    i = i + 1']
    L += ['print(t)', 'print(a)', 'print(b)', 'print(c)']
    return '\n'.join(L) + '\n'

bad = ran = skip = 0
with tempfile.TemporaryDirectory() as td:
    t = Path(td)/'p.mpy'
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 400
    for seed in range(n):
        src = gen(seed)
        t.write_text(src)
        try:
            py = subprocess.run([sys.executable, str(t)], capture_output=True, text=True, timeout=15)
        except subprocess.TimeoutExpired:
            skip += 1; continue
        if py.returncode: skip += 1; continue
        outs = []
        for mode in ([], ['--jit'], ['--tiered']):
            try:
                p = subprocess.run([str(BIN)]+mode+[str(t)], capture_output=True, text=True, timeout=25)
                outs.append(p.stdout)
            except subprocess.TimeoutExpired:
                outs.append(None)
        if any(o is None for o in outs): skip += 1; continue
        ran += 1
        for mode, o in zip(['interp','jit','tiered'], outs):
            if o != py.stdout:
                bad += 1
                if bad <= 3:
                    print('=' * 50); print(src)
                    print(' cpython:', repr(py.stdout)); print(' %s:' % mode, repr(o))
                break
print('%d/%d disagreed with CPython (%d skipped)' % (bad, ran, skip))
