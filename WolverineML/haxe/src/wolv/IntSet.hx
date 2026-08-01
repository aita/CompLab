package wolv;

/**
 * A set of registers that can be walked in order.
 *
 * The other ports get this for nothing: OCaml's `Set.Make(Int)` and Kotlin's
 * sorted sets already iterate in order, and Python only has to say `sorted` at
 * the few places that need it.  Haxe's `Map` has no order at all, so the
 * allocator would otherwise pick a different node to simplify on every run.
 *
 * Only four places actually depend on the order — `least`, the spill choice, the
 * saved-register list and the order victims are rewritten in — but ordering every
 * walk costs little here and means the dependence never has to be rediscovered.
 */
class IntSet {
  final members = new Map<Int, Bool>();

  public function new() {}

  public static function of(values:Array<Int>):IntSet {
    final s = new IntSet();
    for (v in values) s.add(v);
    return s;
  }

  public function add(r:Int):IntSet {
    members.set(r, true);
    return this;
  }

  public function remove(r:Int):Void members.remove(r);

  public function has(r:Int):Bool return members.exists(r);

  public function isEmpty():Bool return !members.keys().hasNext();

  public function size():Int {
    var n = 0;
    for (_ in members.keys()) n += 1;
    return n;
  }

  /** Ascending, which is what every walk of a set in this compiler means. */
  public function ordered():Array<Int> {
    final out = [for (r in members.keys()) r];
    out.sort((a, b) -> a - b);
    return out;
  }

  public function least():Int {
    var best:Null<Int> = null;
    for (r in members.keys()) if (best == null || r < best) best = r;
    if (best == null) throw "the set is empty";
    return best;
  }

  public function copy():IntSet {
    final s = new IntSet();
    for (r in members.keys()) s.add(r);
    return s;
  }

  public function union(other:IntSet):IntSet {
    final s = copy();
    for (r in other.members.keys()) s.add(r);
    return s;
  }

  public function inter(other:IntSet):IntSet {
    final s = new IntSet();
    for (r in members.keys()) if (other.has(r)) s.add(r);
    return s;
  }

  public function diff(other:IntSet):IntSet {
    final s = new IntSet();
    for (r in members.keys()) if (!other.has(r)) s.add(r);
    return s;
  }

  public function addAll(values:Array<Int>):Void {
    for (v in values) add(v);
  }
}
