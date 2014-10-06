{-# LANGUAGE ExistentialQuantification, RecordWildCards,
             ScopedTypeVariables, FlexibleInstances,
             OverloadedStrings, PatternGuards, GADTs, 
             EmptyDataDecls, DefaultSignatures #-}

-- | Building RQL queries in Haskell
module Database.RethinkDB.ReQL (
  ReQL(..),
  op, op',
  Term(..),
  TermAttribute(..),
  buildQuery,
  Backtrace, convertBacktrace, Frame(..),
  Expr(..),
  QuerySettings(..),
  newVarId,
  str,
  num,
  Attribute(..),
  Static, Dynamic, OptArg,
  OptArgs(..),
  cons,
  arr,
  baseArray,
  withQuerySettings,
  reqlToDatum,
  Bound(..),
  closedOrOpen,
  datumTerm,
  boolToTerm,
  nil, empty,
  WireQuery(..),
  WireBacktrace(..),
  note,
  (?:=)
  ) where

import Data.Aeson (Value)
import qualified Data.Vector as V
import qualified Data.HashMap.Lazy as M
import Data.Maybe (fromMaybe, catMaybes)
import Data.String (IsString(..))
import Data.List (intercalate)
import Control.Monad.State (State, get, put, runState)
import Control.Applicative ((<$>))
import Data.Default (Default, def)
import qualified Data.Text as T
import Data.Foldable (toList)
import Data.Time
import Data.Time.Clock.POSIX
import Control.Monad.Fix
import Data.Int
import Data.Monoid
import Data.Char
import Data.Ratio

import {-# SOURCE #-} Database.RethinkDB.Functions as R
import Database.RethinkDB.Wire
import Database.RethinkDB.Wire.Query
import qualified Database.RethinkDB.Wire.Term as Term
import Database.RethinkDB.Wire.Term hiding (JSON)
import Database.RethinkDB.Types
import Database.RethinkDB.Datum

-- $setup
--
-- Get the doctests ready
--
-- >>> import qualified Database.RethinkDB as R
-- >>> import Database.RethinkDB.NoClash
-- >>> h' <- connect "localhost" 28015 def
-- >>> let h = use "doctests" h'

-- | A ReQL Term
data ReQL = ReQL { runReQL :: State QuerySettings Term }

data Term = Term {
  termType :: TermType,
  termArgs :: [Term],
  termOptArgs :: [TermAttribute]
  } | Datum {
  termDatum :: Datum
  } | Note {
  termNote :: String,
  termTerm :: Term
  } deriving Eq

newtype WireTerm = WireTerm { termJSON :: Datum }

data QuerySettings = QuerySettings {
  queryToken :: Int64,
  queryDefaultDatabase :: Database,
  queryVarIndex :: Int,
  queryUseOutdated :: Maybe Bool
  }

instance Default QuerySettings where
  def = QuerySettings 0 (Database "") 0 Nothing

withQuerySettings :: (QuerySettings -> ReQL) -> ReQL
withQuerySettings f = ReQL $ (runReQL . f) =<< get

class OptArgs a where
  ex :: a -> [Attribute Static] -> a

instance OptArgs ReQL where
  ex (ReQL m) attrs = ReQL $ do
    e <- m
    case e of
      Datum _ -> return e
      Term t a oa -> Term t a . (oa ++) <$> baseAttributes attrs
      Note n t -> Note n <$> runReQL (ex (ReQL $ return t) attrs)
      
instance OptArgs b => OptArgs (a -> b) where
  ex f a = flip ex a . f

boolToTerm :: Bool -> Term
boolToTerm b = Datum $ toDatum b

newVarId :: State QuerySettings Int
newVarId = do
  QuerySettings {..} <- get
  let n = queryVarIndex + 1
  put QuerySettings {queryVarIndex = n, ..}
  return $ n

instance Show Term where
  show (Datum dat) = show dat
  show (Note n term) = shortLines "" ["{- " ++ n ++ " -}", show term]
  show (Term MAKE_ARRAY x []) = "[" ++ (shortLines "," $ map show x) ++ "]"
  show (Term MAKE_OBJ [] x) = "{" ++ (shortLines "," $ map show x) ++ "}"
  show (Term MAKE_OBJ args []) = "{" ++ (shortLines "," $ map (\(a,b) -> show a ++ ":" ++ show b) $ pairs args) ++ "}"
     where pairs (a:b:xs) = (a,b) : pairs xs
           pairs _ = []
  show (Term VAR [Datum d] []) | Just x <- toInt d = varName x
  show (Term FUNC [args, body] []) | Just vars <- argList args =
    "(\\" ++ (shortLines " " $ map varName vars)
    ++ " -> " ++ show body ++ ")"
  show (Term BRACKET [o, k] []) = show o ++ "[" ++ show k ++ "]"
  show (Term FUNCALL (f : as) []) = "(" ++ show f ++ ")(" ++ shortLines "," (map show as) ++ ")"
  show (Term fun args oargs) =
    map toLower (show fun) ++ "(" ++
    shortLines "," (map show args ++ map show oargs) ++ ")"

shortLines :: String -> [String] -> String
shortLines sep args =
  if tooLong
  then "\n" ++ intercalate (sep ++ "\n") (map indent args)
  else intercalate (sep ++ " ") args
  where
    tooLong = any ('\n' `elem`) args || 80 < (length $ concat args)
    indent = (\x -> case x of [] -> []; _ -> init x) . unlines . map ("  "++) . lines 

varName :: Int -> String
varName n = replicate (q+1) (chr $ ord 'a' + r)
  where (q, r) = quotRem n 26

-- | Convert other types into ReQL expressions
class Expr e where
  expr :: e -> ReQL
  default expr :: ToDatum e => e -> ReQL
  expr = datumTerm
  exprList :: [e] -> ReQL
  exprList = expr . arr

instance Expr ReQL where
  expr t = t

instance Expr Char where
  exprList = datumTerm

-- | A list of terms
data ArgList = ArgList { baseArray :: State QuerySettings [Term] }

-- | Build arrays of exprs
class Arr a where
  arr :: a -> ArgList

cons :: Expr e => e -> ArgList -> ArgList
cons x xs = ArgList $ do
  bt <- runReQL (expr x)
  xs' <- baseArray xs
  return $ bt : xs'

instance Arr () where
  arr () = ArgList $ return []

instance Expr a => Arr [a] where
  arr [] = ArgList $ return []
  arr (x:xs) = cons x (arr xs)

instance (Expr a, Expr b) => Arr (a, b) where
  arr (a,b) = cons a $ cons b $ arr ()

instance (Expr a, Expr b, Expr c) => Arr (a, b, c) where
  arr (a,b,c) = cons a $ cons b $ cons c $ arr ()

instance (Expr a, Expr b, Expr c, Expr d) => Arr (a, b, c, d) where
  arr (a,b,c,d) = cons a $ cons b $ cons c $ cons d $ arr ()

instance Arr ArgList where
  arr = id

infix 0 :=

-- | A key/value pair used for building objects
data Attribute a where 
  (:=) :: Expr e => T.Text -> e -> Attribute a
  (::=) :: (Expr k, Expr v) => k -> v -> Attribute Dynamic
  NoAttribute :: Attribute a

(?:=) :: Expr e => T.Text -> Maybe e -> Attribute a
_ ?:= Nothing = NoAttribute
k ?:= (Just v) = k := v

type OptArg = Attribute Static

data Static
data Dynamic

instance Expr (Attribute a) where
  expr (k := v) = expr (k, v)
  expr (k ::= v) = expr (k, v)
  expr NoAttribute = expr Null
  exprList kvs = maybe (obj kvs) (op' MAKE_OBJ () . concat) $ mapM staticPair kvs
    where staticPair :: Attribute a -> Maybe [Attribute Static]
          staticPair (k := v) = Just [k := v]
          staticPair NoAttribute = Just []
          staticPair _ = Nothing
          obj :: [Attribute a] -> ReQL
          obj = op OBJECT . concatMap unpair
          unpair :: Attribute a -> [ReQL]
          unpair (k := v) = [expr k, expr v]
          unpair (k ::= v) = [expr k, expr v]
          unpair NoAttribute = []

data TermAttribute = TermAttribute T.Text Term deriving Eq

mapTermAttribute :: (Term -> Term) -> TermAttribute -> TermAttribute
mapTermAttribute f (TermAttribute k v) = TermAttribute k (f v)

instance Show TermAttribute where
  show (TermAttribute a b) = T.unpack a ++ ": " ++ show b

baseAttributes :: [Attribute Static] -> State QuerySettings [TermAttribute]
baseAttributes = sequence . concat . map toBase
  where
    toBase :: Attribute Static -> [State QuerySettings TermAttribute]
    toBase (k := v) = [TermAttribute k <$> runReQL (expr v)]
    toBase NoAttribute = []

-- | Build a term
op' :: Arr a => TermType -> a -> [Attribute Static] -> ReQL
op' t a b = ReQL $ do
  a' <- baseArray (arr a)
  b' <- baseAttributes b
  case (t, a', b') of
    -- Inline function calls if all arguments are variables
    (FUNCALL, (Term FUNC [argsFunTerm, fun] [] : argsCall), []) |
      Just varsFun <- argList argsFunTerm,
      length varsFun == length argsCall,
      Just varsCall <- varsOf argsCall ->
        return $ alphaRename (zip varsFun varsCall) fun
    _ -> return $ Term t a' b'

-- | Build a term with no optargs
op :: Arr a => TermType -> a -> ReQL
op t a = op' t a []

argList :: Term -> Maybe [Int]
argList (Datum d) | Just a <- toInts d = Just a
argList (Term MAKE_ARRAY a []) = mapM toInt =<< datums a
  where datums (Datum d:xs) = fmap (d:) $ datums xs; datums [] = Just []; datums _ = Nothing
argList _ = Nothing

toInts :: Datum -> Maybe [Int]
toInts (Array xs) = mapM toInt $ toList xs
toInts _ = Nothing

toInt :: Datum -> Maybe Int
toInt (Number n) = if denominator (toRational n) == 1 then Just (truncate n) else Nothing
toInt _ = Nothing

varsOf :: [Term] -> Maybe [Int]
varsOf = sequence . map varOf
    
varOf :: Term -> Maybe Int
varOf (Term VAR [Datum d] []) = toInt d
varOf _ = Nothing

alphaRename :: [(Int, Int)] -> Term -> Term
alphaRename assoc = fix $ \f x ->
  case varOf x of
    Just n
      | Just n' <- lookup n assoc ->
      Term VAR [Datum $ toDatum n'] []
      | otherwise -> x
    _ -> updateChildren x f

updateChildren :: Term -> (Term -> Term) -> Term
updateChildren (Note _ t) f = updateChildren t f
updateChildren d@Datum{} _ = d
updateChildren (Term t a o) f = Term t (map f a) (map (mapTermAttribute f) o)

datumTerm :: ToDatum a => a -> ReQL
datumTerm = ReQL . return . Datum . toDatum

-- | A shortcut for inserting strings into ReQL expressions
-- Useful when OverloadedStrings makes the type ambiguous
str :: String -> ReQL
str = datumTerm

-- | A shortcut for inserting numbers into ReQL expressions
num :: Double -> ReQL
num = expr

instance Expr Int64
instance Expr Int
instance Expr Integer

instance Num ReQL where
  fromInteger = datumTerm
  a + b = op ADD (a, b)
  a * b = op MUL (a, b)
  a - b = op SUB (a, b)
  negate a = op SUB (0 :: Double, a)
  abs n = op BRANCH (op Term.LT (n, 0 :: Double), negate n, n)
  signum n = op BRANCH (op Term.LT (n, 0 :: Double),
                        -1 :: Double,
                        op BRANCH (op Term.EQ (n, 0 :: Double), 0 :: Double, 1 :: Double))

instance Expr T.Text
instance Expr Bool

instance Expr () where
  expr _ = ReQL $ return $ Datum $ Null

instance IsString ReQL where
  fromString = datumTerm

instance (a ~ ReQL) => Expr (a -> ReQL) where
  expr f = ReQL $ do
    v <- newVarId
    runReQL $ op FUNC (toDatum [v], expr $ f (op VAR [v]))

instance (a ~ ReQL, b ~ ReQL) => Expr (a -> b -> ReQL) where
  expr f = ReQL $ do
    a <- newVarId
    b <- newVarId
    runReQL $ op FUNC (toDatum [a, b], expr $ f (op VAR [a]) (op VAR [b]))

instance Expr Table where
  expr (Table mdb name _) = withQuerySettings $ \QuerySettings {..} ->
    op' TABLE (fromMaybe queryDefaultDatabase mdb, name) $ catMaybes [
      fmap ("use_outdated" :=) queryUseOutdated ]

instance Expr Database where
  expr (Database name) = op DB [name]

instance Expr Value
instance Expr Datum
instance Expr Double

instance Expr Rational where
  expr x = expr (fromRational x :: Double)

instance Expr x => Expr (V.Vector x) where
  expr v = expr (V.toList v)

instance Expr a => Expr [a] where
  expr = exprList

instance Expr ArgList where
  expr a = op MAKE_ARRAY a

instance Expr e => Expr (M.HashMap T.Text e) where
  expr m = expr $ map (uncurry (:=)) $ M.toList m

buildTerm :: Term -> WireTerm
buildTerm (Note _ t) = buildTerm t
buildTerm (Datum d) = WireTerm (toDatum d)
buildTerm (Term type_ args oargs) =
  WireTerm $ toDatum (
    toWire type_,
    map (termJSON . buildTerm) args,
    buildAttributes oargs)

buildAttributes :: [TermAttribute] -> Datum
buildAttributes ts = toDatum $ M.fromList $ map toPair ts
 where toPair (TermAttribute a b) = (a, termJSON $ buildTerm b)

newtype WireQuery = WireQuery { queryJSON :: Datum }

buildQuery :: ReQL -> Int64 -> Database -> [(T.Text, Datum)] -> (WireQuery, Term)
buildQuery reql token db opts =
  (WireQuery $ toDatum (toWire START, termJSON pterm, object opts), bterm)
  where
    bterm = fst $ runState (runReQL reql) (def {queryToken = token,
                                                queryDefaultDatabase = db })
    pterm = buildTerm bterm

instance Show ReQL where
  show t = show . snd $ buildQuery t 0 (Database "") []

reqlToDatum :: ReQL -> Datum
reqlToDatum t = queryJSON $ fst $ buildQuery t 0 (Database "") []

type Backtrace = [Frame]

data Frame = FramePos Int | FrameOpt T.Text

instance Show Frame where
    show (FramePos n) = show n
    show (FrameOpt k) = show k

instance FromDatum Frame where
  parseDatum d@Number{} | Success i <- fromDatum d = return $ FramePos i
  parseDatum (String s) = return $ FrameOpt s
  parseDatum _ = mempty

newtype WireBacktrace = WireBacktrace { backtraceJSON :: Datum }

convertBacktrace :: WireBacktrace -> Backtrace
convertBacktrace (WireBacktrace b) =
  case fromDatum b of
    Success a -> a
    Error _ -> []

instance Expr UTCTime where
  expr t = op EPOCH_TIME [expr . toRational $ utcTimeToPOSIXSeconds t]

instance Expr ZonedTime where
  expr (ZonedTime
        (LocalTime
         date
         (TimeOfDay hour minute seconds))
        timezone) = let
    (year, month, day) = toGregorian date
    in  op TIME [
      expr year, expr month, expr day, expr hour, expr minute, expr (toRational seconds),
      str $ timeZoneOffsetString timezone]

instance Expr Term where
  expr = ReQL . return

-- | An upper or lower bound for between and during
data Bound a =
  Open { getBound :: a } -- ^ An inclusive bound
  | Closed { getBound :: a } -- ^ An exclusive bound
  | DefaultBound { getBound :: a }

instance Functor Bound where
  fmap f (Open a) = Open (f a)
  fmap f (Closed a) = Closed (f a)
  fmap f (DefaultBound a) = DefaultBound (f a)

closedOrOpen :: Bound a -> Maybe T.Text
closedOrOpen Open{} = Just "open"
closedOrOpen Closed{} = Just "closed"
closedOrOpen DefaultBound{} = Nothing

boundOp :: (a -> a -> a) -> Bound a -> Bound a -> Bound a
boundOp f (Closed a) (Closed b) = Closed $ f a b
boundOp f (Closed a) (Open b) = Open $ f a b
boundOp f (Open a) (Closed b) = Open $ f a b
boundOp f (Open a) (Open b) = Open $ f a b
boundOp f (DefaultBound a) b = fmap (f a) b
boundOp f a (DefaultBound b) = fmap (flip f b) a

instance Num a => Num (Bound a) where
  (+) = boundOp (+)
  (-) = boundOp (-)
  (*) = boundOp (*)
  negate = fmap negate
  abs = fmap abs
  signum = fmap signum
  fromInteger = DefaultBound . fromInteger

-- | An empty list
nil :: ReQL
nil = expr ([] :: [()])

-- | An empty object
empty :: ReQL
empty = expr ([] :: [Attribute Static])

instance (Expr a, Expr b) => Expr (a, b) where
  expr (a, b) = expr [expr a, expr b]

instance (Expr a, Expr b, Expr c) => Expr (a, b, c) where
  expr (a, b, c) = expr [expr a, expr b, expr c]

instance (Expr a, Expr b, Expr c, Expr d) => Expr (a, b, c, d) where
  expr (a, b, c, d) = expr [expr a, expr b, expr c, expr d]

instance (Expr a, Expr b, Expr c, Expr d, Expr e) => Expr (a, b, c, d, e) where
  expr (a, b, c, d, e) = expr [expr a, expr b, expr c, expr d, expr e]

-- | Add a note a a ReQL Term
--
-- This note does not get sent to the server. It is used to annotate
-- backtraces and help debugging.
note :: String -> ReQL -> ReQL
note n (ReQL t) = ReQL $ return . Note n =<< t

instance Fractional ReQL where
  a / b = op DIV [a, b]
  recip a = op DIV [num 1, a]
  fromRational = expr

instance Floating ReQL where
  pi = js "Math.PI"
  exp x = js "(function(x){return Math.pow(Math.E,x)})" `apply` [x]
  sqrt x = js "Math.sqrt" `apply` [x]
  log x = js "Math.log" `apply` [x]
  (**) x y = js "Math.pow" `apply` [x, y]
  logBase x y = js "(function(x, y){return Math.log(x)/Math.log(y)})" `apply` [x, y]
  sin x = js "Math.sin" `apply` [x]
  tan x = js "Math.tan" `apply` [x]
  cos x = js "Math.cos" `apply` [x]
  asin x = js "Math.asin" `apply` [x]
  atan x = js "Math.atan" `apply` [x]
  acos x = js "Math.acos" `apply` [x]
  sinh = error "hyberbolic math is not supported"
  tanh = error "hyberbolic math is not supported"
  cosh = error "hyberbolic math is not supported"
  asinh = error "hyberbolic math is not supported"
  atanh = error "hyberbolic math is not supported"
  acosh = error "hyberbolic math is not supported"
