-- | Source positions, and the one error every pass raises.
--
-- Nothing here throws.  A pass that can fail answers @Either WolvError a@, and
-- the driver is the only place that turns one into a message on standard error.
module Wolv.Diag
  ( Span (..),
    showSpan,
    WolvError (..),
    Kind (..),
    lexError,
    parseError,
    typeError,
  )
where

-- | A position in the source, counted from one.
data Span = Span {spanLine :: !Int, spanCol :: !Int}
  deriving (Eq, Show)

showSpan :: Span -> String
showSpan (Span line col) = show line ++ ":" ++ show col

-- | Which pass raised it, so that a test can ask for the one it means.
data Kind = LexKind | ParseKind | TypeKind
  deriving (Eq, Show)

data WolvError = WolvError {errKind :: Kind, errAt :: Span, errMessage :: String}
  deriving (Eq, Show)

-- | The message a user sees is where, then what.
lexError, parseError, typeError :: Span -> String -> Either WolvError a
lexError at message = Left (WolvError LexKind at message)
parseError at message = Left (WolvError ParseKind at message)
typeError at message = Left (WolvError TypeKind at message)
