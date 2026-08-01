package main

import (
	"strings"
	"testing"
	"unicode/utf8"
)

func mustLex(t *testing.T, source string) []token {
	t.Helper()
	toks, err := lex(source)
	if err != nil {
		t.Fatalf("lex(%q): %v", source, err)
	}
	return toks
}

func kinds(t *testing.T, source string) []tok {
	t.Helper()
	var out []tok
	for _, tk := range mustLex(t, source) {
		out = append(out, tk.kind)
	}
	return out
}

func sameKinds(a, b []tok) bool {
	if len(a) != len(b) {
		return false
	}
	for at := range a {
		if a[at] != b[at] {
			return false
		}
	}
	return true
}

// refusesLex insists that the source is rejected, with `want` in the message.
func refusesLex(t *testing.T, source, want string) {
	t.Helper()
	_, err := lex(source)
	if err == nil {
		t.Fatalf("lex(%q) was accepted", source)
	}
	if !strings.Contains(err.Error(), want) {
		t.Fatalf("lex(%q): %v, want %q in it", source, err, want)
	}
}

func TestKeywordsAreNotIdentifiers(t *testing.T) {
	if got := kinds(t, "let val"); !sameKinds(got, []tok{tLET, tVAL, tEOF}) {
		t.Errorf("got %v", got)
	}
	if got := kinds(t, "letter"); !sameKinds(got, []tok{tIDENT, tEOF}) {
		t.Errorf("got %v", got)
	}
}

func TestLongestPunctuationWins(t *testing.T) {
	want := []tok{tASSIGN, tCOLON, tLE, tLT, tNE, tGE, tEOF}
	if got := kinds(t, ":= : <= < <> >="); !sameKinds(got, want) {
		t.Errorf("got %v, want %v", got, want)
	}
}

func TestCommentsNest(t *testing.T) {
	if got := kinds(t, "(* a (* b *) c *) 1"); !sameKinds(got, []tok{tINT, tEOF}) {
		t.Errorf("got %v", got)
	}
}

func TestUnterminatedComment(t *testing.T) { refusesLex(t, "(* forever", "unterminated comment") }

func TestStringEscapes(t *testing.T) {
	got := mustLex(t, `"a\nb\t\"\\\065"`)[0].text
	if want := "a\nb\t\"\\A"; got != want {
		t.Errorf("got %q, want %q", got, want)
	}
}

func TestAStringIsBytes(t *testing.T) {
	// Source text contributes its UTF-8; `\ddd` names one byte of it.
	if got, want := mustLex(t, `"日"`)[0].text, "日"; got != want {
		t.Errorf("got %q, want %q", got, want)
	}
	if got, want := mustLex(t, `"\230\151\165"`)[0].text, "日"; got != want {
		t.Errorf("got %q, want %q", got, want)
	}
	if got := len(mustLex(t, `"日本語"`)[0].text); got != 9 {
		t.Errorf("size is %d bytes, want 9", got)
	}
}

func TestOutsideTheBasicPlane(t *testing.T) {
	const emoji = "\U0001F600"
	if got := len(mustLex(t, `"`+emoji+`"`)[0].text); got != 4 {
		t.Errorf("size is %d bytes, want 4", got)
	}
	if got := mustLex(t, `"`+emoji+`"`)[0].text; got != emoji {
		t.Errorf("got %q, want %q", got, emoji)
	}
	if utf8.RuneCountInString(emoji) != 1 {
		t.Fatal("the test needs a single rune")
	}
	// The rune is one character, so a column counts it once: `(*x*) x` would put
	// the name in the same place.
	if got, want := mustLex(t, "(*"+emoji+"*) x")[0].at, (span{1, 7}); got != want {
		t.Errorf("got %v, want %v", got, want)
	}
}

func TestANameMayBeWrittenInAnyScript(t *testing.T) {
	if got := kinds(t, "名前"); !sameKinds(got, []tok{tIDENT, tEOF}) {
		t.Errorf("got %v", got)
	}
}

func TestANumericEscapeIsThreeDigits(t *testing.T) { refusesLex(t, `"\65"`, "three digits") }

func TestAStringMayNotSpanLines(t *testing.T) {
	refusesLex(t, "\"one\ntwo\"", "may not span lines")
}

func TestSpansCountFromOne(t *testing.T) {
	toks := mustLex(t, "val\n  x")
	if toks[0].at != (span{1, 1}) {
		t.Errorf("got %v", toks[0].at)
	}
	if toks[1].at != (span{2, 3}) {
		t.Errorf("got %v", toks[1].at)
	}
}

func TestANumberMayNotRunIntoAName(t *testing.T) { refusesLex(t, "12ab", "is not a number") }

func TestStrayCharacter(t *testing.T) { refusesLex(t, "a ? b", "stray character") }
