// Semantic types, and the symbols that carry them.
//
// Types are monomorphic.  Records are nominal — two record types with the same
// fields are different types — and everything else is structural, which for this
// language means arrays compare by their element type.

export class IntT {
  readonly tag = "int" as const;
  toString(): string { return "int"; }
}

export class StringT {
  readonly tag = "string" as const;
  toString(): string { return "string"; }
}

export class BoolT {
  readonly tag = "bool" as const;
  toString(): string { return "bool"; }
}

export class UnitT {
  readonly tag = "unit" as const;
  toString(): string { return "unit"; }
}

/** The type of `nil` before it is known which record it stands for. */
export class NilT {
  readonly tag = "nil" as const;
  toString(): string { return "nil"; }
}

export class RecordT {
  readonly tag = "record" as const;
  readonly name: string;
  fields: [string, Type][] = [];

  constructor(name: string) {
    this.name = name;
  }

  index(name: string): number {
    return this.fields.findIndex(([field]) => field === name);
  }

  fieldType(name: string): Type | null {
    const at = this.index(name);
    return at < 0 ? null : this.fields[at]![1];
  }

  toString(): string { return this.name; }
}

export class ArrayT {
  readonly tag = "array" as const;
  readonly elem: Type;

  constructor(elem: Type) {
    this.elem = elem;
  }

  toString(): string { return `${this.elem} array`; }
}

export type Type = IntT | StringT | BoolT | UnitT | NilT | RecordT | ArrayT;

// The atoms carry nothing, so one of each is all there is.
export const INT = new IntT();
export const STRING = new StringT();
export const BOOL = new BoolT();
export const UNIT = new UnitT();
export const NIL = new NilT();

/** Type equality: nominal for records, structural for arrays. */
export function same(a: Type, b: Type): boolean {
  if (a instanceof RecordT || b instanceof RecordT) return a === b;
  if (a instanceof ArrayT && b instanceof ArrayT) return same(a.elem, b.elem);
  return a.tag === b.tag;
}

/** Equality, but `nil` stands in for any record. */
export function compatible(a: Type, b: Type): boolean {
  if (a instanceof NilT && (b instanceof RecordT || b instanceof NilT)) return true;
  if ((a instanceof RecordT || a instanceof NilT) && b instanceof NilT) return true;
  return same(a, b);
}

// -- symbols ------------------------------------------------------------------

/**
 * One binding occurrence of a variable.
 *
 * `depth` is the static nesting depth of the function that binds it.  A variable
 * read from a deeper function escapes, and then it lives in a frame slot instead
 * of a register.
 */
export class VarSym {
  readonly name: string;
  readonly ty: Type;
  readonly mutable: boolean;
  readonly depth: number;
  escapes = false;
  slot = -1;
  reg = -1;

  constructor(name: string, ty: Type, mutable: boolean, depth: number) {
    this.name = name;
    this.ty = ty;
    this.mutable = mutable;
    this.depth = depth;
  }

  toString(): string { return this.name; }
}

/** A function.  Functions are not values, so there is no function type. */
export class FunSym {
  readonly name: string;
  readonly label: string;
  readonly params: VarSym[];
  readonly result: Type;
  readonly depth: number;
  readonly builtin: string | null;

  constructor(
    name: string, label: string, params: VarSym[], result: Type,
    depth: number, builtin: string | null = null,
  ) {
    this.name = name;
    this.label = label;
    this.params = params;
    this.result = result;
    this.depth = depth;
    this.builtin = builtin;
  }

  toString(): string { return this.name; }
}

/** What a name can be bound to. */
export type Sym = VarSym | FunSym;
