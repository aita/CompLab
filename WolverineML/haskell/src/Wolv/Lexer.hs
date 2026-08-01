-- | Tokens, and the hand-written scanner that produces them.
module Wolv.Lexer
  ( Tok (..),
    Token (..),
    kindText,
    showToken,
    keywords,
    punctuation,
    lexAll,
    dump,
  )
where

import Data.Char (chr, isAlpha, isAlphaNum, isDigit, ord)
import Data.List (isPrefixOf, sortOn)
import Wolv.Diag

-- | A token kind.  The name a dump prints is the constructor written down, and
-- 'kindText' is the other direction — what an error message calls a kind.
data Tok
  = INT | STRING | IDENT | EOF
  | AND | ANDALSO | BREAK | DO | ELSE | END | FALSE | FOR | FUN | IF | IN
  | LET | MOD | NIL | ORELSE | THEN | TO | TRUE | TYPE | VAL | VAR | WHILE
  | LPAREN | RPAREN | LBRACK | RBRACK | LBRACE | RBRACE | COMMA | COLON
  | SEMI | DOT | ASSIGN | EQ_ | NE | LE | LT_ | GE | GT_ | PLUS | MINUS
  | STAR | SLASH | CARET | TILDE
  deriving (Eq, Show, Enum, Bounded)

kindText :: Tok -> String
kindText t = case t of
  INT -> "an integer"; STRING -> "a string"; IDENT -> "an identifier"
  EOF -> "end of input"
  AND -> "and"; ANDALSO -> "andalso"; BREAK -> "break"; DO -> "do"
  ELSE -> "else"; END -> "end"; FALSE -> "false"; FOR -> "for"; FUN -> "fun"
  IF -> "if"; IN -> "in"; LET -> "let"; MOD -> "mod"; NIL -> "nil"
  ORELSE -> "orelse"; THEN -> "then"; TO -> "to"; TRUE -> "true"
  TYPE -> "type"; VAL -> "val"; VAR -> "var"; WHILE -> "while"
  LPAREN -> "("; RPAREN -> ")"; LBRACK -> "["; RBRACK -> "]"
  LBRACE -> "{"; RBRACE -> "}"; COMMA -> ","; COLON -> ":"; SEMI -> ";"
  DOT -> "."; ASSIGN -> ":="; EQ_ -> "="; NE -> "<>"; LE -> "<="; LT_ -> "<"
  GE -> ">="; GT_ -> ">"; PLUS -> "+"; MINUS -> "-"; STAR -> "*"
  SLASH -> "/"; CARET -> "^"; TILDE -> "~"

-- | The name a dump prints, which is the constructor without its tie-breaker.
showKind :: Tok -> String
showKind EQ_ = "EQ"
showKind LT_ = "LT"
showKind GT_ = "GT"
showKind t = show t

named :: [Tok]
named = [INT, STRING, IDENT, EOF]

keywords :: [(String, Tok)]
keywords =
  [(kindText t, t) | t <- [minBound ..], t `notElem` named, all isAlpha (kindText t)]

-- | Longest first, so that @:=@ beats @:@ and @<=@ beats @<@.
punctuation :: [(String, Tok)]
punctuation =
  sortOn (negate . length . fst)
    [(kindText t, t) | t <- [minBound ..], t `notElem` named, not (isAlpha (head (kindText t)))]

escapes :: [(Char, Char)]
escapes = [('n', '\n'), ('t', '\t'), ('r', '\r'), ('"', '"'), ('\\', '\\')]

data Token = Token {tokKind :: Tok, tokText :: String, tokAt :: Span}
  deriving (Eq, Show)

-- | What an error message calls a token it found.
showToken :: Token -> String
showToken (Token EOF _ _) = "end of input"
showToken (Token STRING text _) = "\"" ++ text ++ "\""
showToken (Token _ text _) = "`" ++ text ++ "`"

-- | The scanner's whole state: what is left, and where that is.
data Scanner = Scanner {scSrc :: String, scAt :: Span}

-- | Source text into tokens, in one pass, no regexes.
lexAll :: String -> Either WolvError [Token]
lexAll source = go (Scanner source (Span 1 1))
  where
    go s = do
      (tok, s') <- next s
      if tokKind tok == EOF then Right [tok] else (tok :) <$> go s'

-- | Every character the scanner consumes goes through this, which is what keeps
-- the line and column right without a second pass over the text.
advance :: Int -> Scanner -> Scanner
advance 0 s = s
advance n (Scanner (c : rest) (Span line col))
  | c == '\n' = advance (n - 1) (Scanner rest (Span (line + 1) 1))
  | otherwise = advance (n - 1) (Scanner rest (Span line (col + 1)))
advance _ s = s

next :: Scanner -> Either WolvError (Token, Scanner)
next s0 = do
  s <- skipTrivia s0
  let at = scAt s
  case scSrc s of
    [] -> Right (Token EOF "" at, s)
    (c : _)
      | isDigit c -> number at s
      | isAlpha c || c == '_' -> Right (word at s)
      | c == '"' -> string at (advance 1 s)
      | otherwise -> case [(text, kind) | (text, kind) <- punctuation, text `isPrefixOf` scSrc s] of
          ((text, kind) : _) -> Right (Token kind text at, advance (length text) s)
          [] -> lexError at ("stray character `" ++ [c] ++ "`")

number :: Span -> Scanner -> Either WolvError (Token, Scanner)
number at s =
  let digits = takeWhile isDigit (scSrc s)
      s' = advance (length digits) s
   in case scSrc s' of
        (c : _)
          | isAlphaNum c || c == '_' ->
              lexError at ("`" ++ digits ++ [c] ++ "` is not a number")
        _ -> Right (Token INT digits at, s')

word :: Span -> Scanner -> (Token, Scanner)
word at s =
  let text = takeWhile (\c -> isAlphaNum c || c `elem` "_'") (scSrc s)
   in (Token (maybe IDENT id (lookup text keywords)) text at, advance (length text) s)

-- | A string literal is a sequence of bytes.  @size@, @ord@ and @substring@
-- count bytes at run time, so a literal is read as bytes here too: source text
-- contributes its UTF-8 encoding, and @\\ddd@ names one byte.  Each byte is kept
-- as one 'Char' below 256, which is what 'Wolv.Emit.escape' writes back out.
string :: Span -> Scanner -> Either WolvError (Token, Scanner)
string at = go ""
  where
    go acc s = case scSrc s of
      [] -> lexError at "unterminated string"
      ('"' : _) -> Right (Token STRING (reverse acc) at, advance 1 s)
      ('\n' : _) -> lexError (scAt s) "a string may not span lines"
      ('\\' : _) -> do
        (text, s') <- escape (advance 1 s)
        go (reverse text ++ acc) s'
      (c : _) -> go (reverse (utf8 c) ++ acc) (advance 1 s)

escape :: Scanner -> Either WolvError (String, Scanner)
escape s = case scSrc s of
  [] -> lexError (scAt s) "unterminated escape"
  (c : _)
    | isDigit c ->
        let digits = take 3 (scSrc s)
         in if length digits == 3 && all isDigit digits && read digits < (256 :: Int)
              then Right ([chr (read digits)], advance 3 s)
              else lexError (scAt s) "a numeric escape is three digits, `\\065`"
    | otherwise -> case lookup c escapes of
        Just replacement -> Right ([replacement], advance 1 s)
        Nothing -> lexError (scAt s) ("unknown escape `\\" ++ [c] ++ "`")

-- | One source character as the bytes it is written in, each kept as a 'Char'.
utf8 :: Char -> String
utf8 c
  | n < 0x80 = [c]
  | n < 0x800 = map chr [0xC0 + n `div` 64, 0x80 + n `mod` 64]
  | n < 0x10000 =
      map chr [0xE0 + n `div` 4096, 0x80 + (n `div` 64) `mod` 64, 0x80 + n `mod` 64]
  | otherwise =
      map
        chr
        [ 0xF0 + n `div` 262144,
          0x80 + (n `div` 4096) `mod` 64,
          0x80 + (n `div` 64) `mod` 64,
          0x80 + n `mod` 64
        ]
  where
    n = ord c

skipTrivia :: Scanner -> Either WolvError Scanner
skipTrivia s = case scSrc s of
  (c : _) | c `elem` " \t\r\n" -> skipTrivia (advance 1 s)
  src | "(*" `isPrefixOf` src -> comment (scAt s) 0 s >>= skipTrivia
  _ -> Right s

-- | Comments nest, which is why this counts rather than looks for the end.
comment :: Span -> Int -> Scanner -> Either WolvError Scanner
comment at depth s = case scSrc s of
  [] -> lexError at "unterminated comment"
  src
    | "(*" `isPrefixOf` src -> comment at (depth + 1) (advance 2 s)
    | "*)" `isPrefixOf` src ->
        if depth - 1 == 0 then Right (advance 2 s) else comment at (depth - 1) (advance 2 s)
    | otherwise -> comment at depth (advance 1 s)

dump :: [Token] -> String
dump toks =
  unlines' [showSpan (tokAt t) ++ "\t" ++ showKind (tokKind t) ++ "\t" ++ tokText t | t <- toks]
  where
    unlines' = foldr1 (\a b -> a ++ "\n" ++ b)
