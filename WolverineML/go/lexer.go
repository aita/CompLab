// Tokens, and the hand-written scanner that produces them.

package main

import (
	"sort"
	"strings"
	"unicode"
	"unicode/utf8"
)

// tok is a token kind.  Its text is what an error message calls it.
type tok int

const (
	tINT tok = iota
	tSTRING
	tIDENT
	tEOF

	tAND
	tANDALSO
	tBREAK
	tDO
	tELSE
	tEND
	tFALSE
	tFOR
	tFUN
	tIF
	tIN
	tLET
	tMOD
	tNIL
	tORELSE
	tTHEN
	tTO
	tTRUE
	tTYPE
	tVAL
	tVAR
	tWHILE

	tLPAREN
	tRPAREN
	tLBRACK
	tRBRACK
	tLBRACE
	tRBRACE
	tCOMMA
	tCOLON
	tSEMI
	tDOT
	tASSIGN
	tEQ
	tNE
	tLE
	tLT
	tGE
	tGT
	tPLUS
	tMINUS
	tSTAR
	tSLASH
	tCARET
	tTILDE
)

var tokText = [...]string{
	tINT: "an integer", tSTRING: "a string", tIDENT: "an identifier", tEOF: "end of input",

	tAND: "and", tANDALSO: "andalso", tBREAK: "break", tDO: "do", tELSE: "else",
	tEND: "end", tFALSE: "false", tFOR: "for", tFUN: "fun", tIF: "if", tIN: "in",
	tLET: "let", tMOD: "mod", tNIL: "nil", tORELSE: "orelse", tTHEN: "then",
	tTO: "to", tTRUE: "true", tTYPE: "type", tVAL: "val", tVAR: "var", tWHILE: "while",

	tLPAREN: "(", tRPAREN: ")", tLBRACK: "[", tRBRACK: "]", tLBRACE: "{", tRBRACE: "}",
	tCOMMA: ",", tCOLON: ":", tSEMI: ";", tDOT: ".", tASSIGN: ":=", tEQ: "=", tNE: "<>",
	tLE: "<=", tLT: "<", tGE: ">=", tGT: ">", tPLUS: "+", tMINUS: "-", tSTAR: "*",
	tSLASH: "/", tCARET: "^", tTILDE: "~",
}

// tokName is what a token dump calls it, which is the constant's own name.
var tokName = [...]string{
	tINT: "INT", tSTRING: "STRING", tIDENT: "IDENT", tEOF: "EOF",
	tAND: "AND", tANDALSO: "ANDALSO", tBREAK: "BREAK", tDO: "DO", tELSE: "ELSE",
	tEND: "END", tFALSE: "FALSE", tFOR: "FOR", tFUN: "FUN", tIF: "IF", tIN: "IN",
	tLET: "LET", tMOD: "MOD", tNIL: "NIL", tORELSE: "ORELSE", tTHEN: "THEN",
	tTO: "TO", tTRUE: "TRUE", tTYPE: "TYPE", tVAL: "VAL", tVAR: "VAR", tWHILE: "WHILE",
	tLPAREN: "LPAREN", tRPAREN: "RPAREN", tLBRACK: "LBRACK", tRBRACK: "RBRACK",
	tLBRACE: "LBRACE", tRBRACE: "RBRACE", tCOMMA: "COMMA", tCOLON: "COLON",
	tSEMI: "SEMI", tDOT: "DOT", tASSIGN: "ASSIGN", tEQ: "EQ", tNE: "NE", tLE: "LE",
	tLT: "LT", tGE: "GE", tGT: "GT", tPLUS: "PLUS", tMINUS: "MINUS", tSTAR: "STAR",
	tSLASH: "SLASH", tCARET: "CARET", tTILDE: "TILDE",
}

func (t tok) text() string { return tokText[t] }
func (t tok) name() string { return tokName[t] }

var (
	keywords    = map[string]tok{}
	punctuation []tok // longest first, so that `:=` beats `:` and `<=` beats `<`
	escapes     = map[rune]byte{'n': '\n', 't': '\t', 'r': '\r', '"': '"', '\\': '\\'}
)

func init() {
	for kind, word := range tokText {
		switch {
		case word == "":
		case allLetters(word):
			keywords[word] = tok(kind)
		case !unicode.IsLetter(rune(word[0])):
			punctuation = append(punctuation, tok(kind))
		}
	}
	sort.SliceStable(punctuation, func(i, j int) bool {
		return len(punctuation[i].text()) > len(punctuation[j].text())
	})
}

func allLetters(s string) bool {
	for _, r := range s {
		if !unicode.IsLetter(r) {
			return false
		}
	}
	return true
}

// token is one token, and where it started.
type token struct {
	kind tok
	text string
	at   span
}

func (t token) String() string {
	switch t.kind {
	case tEOF:
		return "end of input"
	case tSTRING:
		return "\"" + t.text + "\""
	default:
		return "`" + t.text + "`"
	}
}

// lex turns source text into tokens, in one pass, no regexes.
func lex(source string) (toks []token, err error) {
	defer catch(&err)
	return newScanner(source).tokens(), nil
}

// The scanner reads runes and not bytes, so a character outside the basic plane
// is one character everywhere it matters: it is one column, it is a letter if
// Unicode says it is, and inside a string literal it contributes the UTF-8 bytes
// of the whole of itself.
type scanner struct {
	src  string
	pos  int
	line int
	col  int
}

func newScanner(src string) *scanner { return &scanner{src: src, line: 1, col: 1} }

func (s *scanner) tokens() []token {
	var out []token
	for {
		t := s.next()
		out = append(out, t)
		if t.kind == tEOF {
			return out
		}
	}
}

// -- reading runes -----------------------------------------------------------

func (s *scanner) done() bool { return s.pos >= len(s.src) }

// here is the rune under the cursor, and how many bytes it took.
func (s *scanner) here() (rune, int) { return utf8.DecodeRuneInString(s.src[s.pos:]) }

// advance moves on by n bytes, counting columns in runes.
func (s *scanner) advance(n int) {
	for end := s.pos + n; s.pos < end; {
		if s.src[s.pos] == '\n' {
			s.line++
			s.col = 1
			s.pos++
			continue
		}
		_, width := s.here()
		s.col++
		s.pos += width
	}
}

// step moves on by one rune.
func (s *scanner) step() {
	_, width := s.here()
	s.advance(width)
}

func (s *scanner) at() span { return span{line: s.line, col: s.col} }

// -- the scanner -------------------------------------------------------------

func (s *scanner) next() token {
	s.skipTrivia()
	start := s.at()
	if s.done() {
		return token{kind: tEOF, at: start}
	}

	ch, _ := s.here()
	switch {
	case unicode.IsDigit(ch):
		return s.number(start)
	case unicode.IsLetter(ch) || ch == '_':
		return s.word(start)
	case ch == '"':
		return s.text(start)
	}
	for _, kind := range punctuation {
		if strings.HasPrefix(s.src[s.pos:], kind.text()) {
			s.advance(len(kind.text()))
			return token{kind: kind, text: kind.text(), at: start}
		}
	}
	panic(lexErrorf(start, "stray character `%c`", ch))
}

func (s *scanner) number(start span) token {
	from := s.pos
	for !s.done() {
		if ch, _ := s.here(); !unicode.IsDigit(ch) {
			break
		}
		s.step()
	}
	body := s.src[from:s.pos]
	if !s.done() {
		if ch, _ := s.here(); unicode.IsLetter(ch) || ch == '_' {
			panic(lexErrorf(start, "`%s%c` is not a number", body, ch))
		}
	}
	return token{kind: tINT, text: body, at: start}
}

func (s *scanner) word(start span) token {
	from := s.pos
	for !s.done() {
		ch, _ := s.here()
		if !unicode.IsLetter(ch) && !unicode.IsDigit(ch) && ch != '_' && ch != '\'' {
			break
		}
		s.step()
	}
	body := s.src[from:s.pos]
	if kind, ok := keywords[body]; ok {
		return token{kind: kind, text: body, at: start}
	}
	return token{kind: tIDENT, text: body, at: start}
}

// text scans a string literal, which is a sequence of bytes.
//
// `size`, `ord` and `substring` count bytes at run time, so a literal is read as
// bytes here too: source text contributes its UTF-8 encoding, and `\ddd` names
// one byte.  A Go string is already bytes, which is what escapeString writes
// back out.
func (s *scanner) text(start span) token {
	s.step()
	var out strings.Builder
	for {
		if s.done() {
			panic(lexErrorf(start, "unterminated string"))
		}
		ch, width := s.here()
		switch {
		case ch == '"':
			s.step()
			return token{kind: tSTRING, text: out.String(), at: start}
		case ch == '\n':
			panic(lexErrorf(s.at(), "a string may not span lines"))
		case ch == '\\':
			s.step()
			out.WriteByte(s.escape())
		default:
			// One rune, surrogate pair and all, as the UTF-8 bytes it already is.
			out.WriteString(s.src[s.pos : s.pos+width])
			s.step()
		}
	}
}

func (s *scanner) escape() byte {
	if s.done() {
		panic(lexErrorf(s.at(), "unterminated escape"))
	}
	ch, _ := s.here()
	if unicode.IsDigit(ch) {
		value := 0
		for i := 0; i < 3 && value >= 0; i++ {
			digit := -1
			if s.pos+i < len(s.src) {
				digit = int(s.src[s.pos+i] - '0')
			}
			if digit < 0 || digit > 9 {
				value = -1
				break
			}
			value = value*10 + digit
		}
		if value >= 0 && value < 256 {
			s.advance(3)
			return byte(value)
		}
		panic(lexErrorf(s.at(), "a numeric escape is three digits, `\\065`"))
	}
	if got, ok := escapes[ch]; ok {
		s.step()
		return got
	}
	panic(lexErrorf(s.at(), "unknown escape `\\%c`", ch))
}

func (s *scanner) skipTrivia() {
	for !s.done() {
		switch {
		case strings.IndexByte(" \t\r\n", s.src[s.pos]) >= 0:
			s.advance(1)
		case strings.HasPrefix(s.src[s.pos:], "(*"):
			s.comment()
		default:
			return
		}
	}
}

func (s *scanner) comment() {
	start := s.at()
	depth := 0
	for !s.done() {
		switch {
		case strings.HasPrefix(s.src[s.pos:], "(*"):
			depth++
			s.advance(2)
		case strings.HasPrefix(s.src[s.pos:], "*)"):
			depth--
			s.advance(2)
			if depth == 0 {
				return
			}
		default:
			s.step()
		}
	}
	panic(lexErrorf(start, "unterminated comment"))
}
