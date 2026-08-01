/* A test harness small enough to read.
 *
 * Haxe's standard library has no test runner, and the only thing this suite needs
 * of one is a name, a count and a non-zero exit status, so a haxelib dependency
 * would cost more than it saves. */

class Check {
  static var passed = 0;
  static var failed = 0;
  static var skipped = 0;
  static var group = "";

  public static function about(name:String):Void {
    group = name;
  }

  public static function skip(why:String):Void {
    skipped += 1;
    Sys.println('  ~ skipped: $why');
  }

  public static function that(name:String, ok:Bool, ?detail:String):Void {
    if (ok) {
      passed += 1;
    } else {
      failed += 1;
      Sys.println('  FAIL $group: $name' + (detail == null ? "" : '\n        $detail'));
    }
  }

  public static function equals<T>(name:String, want:T, got:T):Void {
    that(name, want == got, 'want ${Std.string(want)}\n        got  ${Std.string(got)}');
  }

  /** The error a pass is expected to raise, by kind. */
  public static function raises(name:String, kind:wolv.Diag.Kind, body:Void->Void):Void {
    try {
      body();
      that(name, false, "nothing was raised");
    } catch (e:wolv.Diag.WolvError) {
      that(name, Type.enumEq(e.kind, kind), 'raised ${e.kind}: ${e.detail}');
    }
  }

  public static function report():Int {
    Sys.println('$passed passed, $failed failed'
      + (skipped > 0 ? ', $skipped skipped' : ''));
    return failed == 0 ? 0 : 1;
  }
}
