{- Adapted from the awesome work on the json-to-dhall branch from
 - https://github.com/antislava/dhall-haskell.
 -
 - Vendored ghere until it is merged into Dhall and the functionality exposed as a library
 -}
{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE FlexibleInstances   #-}
{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE PatternGuards       #-}
{-# LANGUAGE RecordWildCards     #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications    #-}

{-| The tool for converting JSON data to Dhall given a Dhall /type/ expression necessary to make the translation unambiguous.

    Reasonable requirements to the conversion tool are:

    1. The Dhall type expression @/t/@ passed as an argument to @json-to-dhall@ should be a valid type of the resulting Dhall expression
    2. A JSON data produced by the corresponding @dhall-to-json@ from the Dhall expression of type @/t/@ should (under reasonable assumptions) reproduce the original Dhall expression using @json-to-dhall@ with type argument @/t/@

    Only a subset of Dhall types consisting of all the primitive types as well as @Optional@, @Union@ and @Record@ constructs, is used for reading JSON data:

    * @Bool@s
    * @Natural@s
    * @Integer@s
    * @Double@s
    * @Text@s
    * @List@s
    * @Optional@ values
    * unions
    * records

== Primitive types

    JSON @Bool@s translate to Dhall bools:

> $ json-to-dhall Bool <<< 'true'
> True
> $ json-to-dhall Bool <<< 'false'
> False

    JSON numbers translate to Dhall numbers:

> $ json-to-dhall Integer <<< 2
> +2
> $ json-to-dhall Natural <<< 2
> 2
> $ json-to-dhall Double <<< -2.345
> -2.345

    Dhall @Text@ corresponds to JSON text:

> $ json-to-dhall Text <<< '"foo bar"'
> "foo bar"


== Lists and records

    Dhall @List@s correspond to JSON lists:

> $ json-to-dhall 'List Integer' <<< '[1, 2, 3]'
> [ +1, +2, +3 ]


    Dhall __records__ correspond to JSON records:

> $ json-to-dhall '{foo : List Integer}' <<< '{"foo": [1, 2, 3]}'
> { foo = [ +1, +2, +3 ] }


    Note, that by default, only the fields required by the Dhall type argument are parsed (as you commonly will not need all the data), the remaining ones being ignored:

> $ json-to-dhall '{foo : List Integer}' <<< '{"foo": [1, 2, 3], "bar" : "asdf"}'
> { foo = [ +1, +2, +3 ] }


    If you do need to make sure that Dhall fully reflects JSON record data comprehensively, @--records-strict@ flag should be used:

> $ json-to-dhall --records-strict '{foo : List Integer}' <<< '{"foo": [1, 2, 3], "bar" : "asdf"}'
> Error: Key(s) @bar@ present in the JSON object but not in the corresponding Dhall record. This is not allowed in presence of --records-strict:


    By default, JSON key-value arrays will be converted to Dhall records:

> $ json-to-dhall '{ a : Integer, b : Text }' <<< '[{"key":"a", "value":1}, {"key":"b", "value":"asdf"}]'
> { a = +1, b = "asdf" }


    Attempting to do the same with @--no-keyval-arrays@ on will result in error:

> $ json-to-dhall --no-keyval-arrays '{ a : Integer, b : Text }' <<< '[{"key":"a", "value":1}, {"key":"b", "value":"asdf"}]'
> Error: JSON (key-value) arrays cannot be converted to Dhall records under --no-keyval-arrays flag:

    Conversion of the homogeneous JSON maps to the corresponding Dhall association lists by default:

> $ json-to-dhall 'List { mapKey : Text, mapValue : Text }' <<< '{"foo": "bar"}'
> [ { mapKey = "foo", mapValue = "bar" } ]

    Flag @--no-keyval-maps@ switches off this mechanism (if one would ever need it):

> $ json-to-dhall --no-keyval-maps 'List { mapKey : Text, mapValue : Text }' <<< '{"foo": "bar"}'
> Error: Homogeneous JSON map objects cannot be converted to Dhall association lists under --no-keyval-arrays flag


== Optional values and unions

    Dhall @Optional@ Dhall type allows null or missing JSON values:

> $ json-to-dhall "Optional Integer" <<< '1'
> Some +1

> $ json-to-dhall "Optional Integer" <<< null
> None

> $ json-to-dhall '{ a : Integer, b : Optional Text }' <<< '{ "a": 1 }'
{ a = +1, b = None Text }



    For Dhall __union types__ the correct value will be based on matching the type of JSON expression:

> $ json-to-dhall 'List < Left : Text | Right : Integer >' <<< '[1, "bar"]'
> [ < Right = +1 | Left : Text >, < Left = "bar" | Right : Integer > ]

> $ json-to-dhall '{foo : < Left : Text | Right : Integer >}' <<< '{ "foo": "bar" }'
> { foo = < Left = "bar" | Right : Integer > }

    In presence of multiple potential matches, the first will be selected by default:

> $ json-to-dhall '{foo : < Left : Text | Middle : Text | Right : Integer >}' <<< '{ "foo": "bar"}'
> { foo = < Left = "bar" | Middle : Text | Right : Integer > }

    This will result in error if @--unions-strict@ flag is used, with the list of alternative matches being reported (as a Dhall list)

> $ json-to-dhall --unions-strict '{foo : < Left : Text | Middle : Text | Right : Integer >}' <<< '{ "foo": "bar"}'
> Error: More than one union component type matches JSON value
> ...
> Possible matches:
> < Left = "bar" | Middle : Text | Right : Integer >
> --------
> < Middle = "bar" | Left : Text | Right : Integer >

-}

module JsonToDhall (
  CompileError(..)
, Conversion(..)
, UnionConv(..)
, defaultConversion
, dhallFromJSON
) where

import           Control.Exception          (Exception)
import qualified Data.Aeson                 as A
import           Data.Aeson.Encode.Pretty   (encodePretty)
import qualified Data.ByteString.Lazy.Char8 as BSL8
import           Data.Either                (rights)
import           Data.Foldable              (toList)
import qualified Data.HashMap.Strict        as HM
import           Data.List                  ((\\))
import           Data.Monoid                ((<>))
import           Data.Scientific            (floatingOrInteger, toRealFloat)
import qualified Data.Sequence              as Seq
import           Data.String                (IsString)
import           Data.Text                  (Text)
import qualified Data.Text                  as Text

import qualified Dhall
import           Dhall.Core                 (Chunks (..), Expr (App))
import qualified Dhall.Core                 as D
import qualified Dhall.Map                  as Map
import           Dhall.Parser               (Src)
import           Dhall.TypeCheck            (X)
import qualified Dhall.TypeCheck            as D



-- | JSON-to-dhall translation options
data Conversion = Conversion
    { strictRecs  :: Bool
    , noKeyValArr :: Bool
    , noKeyValMap :: Bool
    , unions      :: UnionConv
    } deriving Show

data UnionConv = UFirst | UNone | UStrict deriving (Show, Read, Eq)

defaultConversion :: Conversion
defaultConversion =  Conversion
    { strictRecs  = False
    , noKeyValArr = False
    , noKeyValMap = False
    , unions      = UFirst
    }

-- ----------
-- Conversion
-- ----------

-- The 'Expr' type concretization used throughout this module
type ExprX = Expr Src X


keyValMay :: A.Value -> Maybe (Text, A.Value)
keyValMay (A.Object o) = do
     A.String k <- HM.lookup "key" o
     v <- HM.lookup "value" o
     return (k, v)
keyValMay _ = Nothing


-- | The main conversion function. Traversing/zipping Dhall /type/ and Aeson value trees together to produce a Dhall /term/ tree, given 'Conversion' options
dhallFromJSON
  :: Conversion -> ExprX -> A.Value -> Either CompileError ExprX
dhallFromJSON (Conversion {..}) = loop
  where
    -- Union
    loop t@(D.Union tmMay) v = case unions of
      UNone -> Left $ ContainsUnion t
      _     -> case Map.traverseWithKey (const id) tmMay of
          Nothing -> undefined
          Just tm ->
            let f k a = D.UnionLit k <$> loop a v
                                     <*> pure (Map.delete k tmMay)
             in case rights . toList $ Map.mapWithKey f tm of
                  [ ]   -> Left $ Mismatch t v
                  [x]   -> Right x
                  xs@(x:_:_) -> case unions of
                      UStrict -> Left $ UndecidableUnion t v xs
                      UFirst  -> Right x
                      UNone   -> undefined -- can't happen

    -- object ~> Record
    loop (D.Record r) v@(A.Object o)
        | extraKeys <- HM.keys o \\ Map.keys r
        , strictRecs && not (null extraKeys)
        = Left (UnhandledKeys extraKeys (D.Record r) v)
        | otherwise
        = let f :: Text -> ExprX -> Either CompileError ExprX
              f k t | Just value <- HM.lookup k o
                    = loop t value
                    | App D.Optional t' <- t
                    = Right (App D.None t')
                    | otherwise
                    = Left (MissingKey k t v)
           in D.RecordLit <$> Map.traverseWithKey f r

    -- key-value list ~> Record
    loop t@(D.Record _) v@(A.Array a)
        | not noKeyValArr
        , os :: [A.Value] <- toList a
        , Just kvs <- traverse keyValMay os
        = loop t (A.Object $ HM.fromList kvs)
        | noKeyValArr
        = Left (NoKeyValArray t v)
        | otherwise
        = Left (Mismatch t v)

    -- object ~> List (key, value)
    loop t@(App D.List (D.Record r)) v@(A.Object o)
        | not noKeyValMap
        , ["mapKey", "mapValue"] == Map.keys r
        , Just D.Text == Map.lookup "mapKey" r
        , Just mapValue <- Map.lookup "mapValue" r
        , keyExprMap    :: Either CompileError (HM.HashMap Text ExprX)
                        <- traverse (loop mapValue) o
        = let f :: (Text, ExprX) -> ExprX
              f (key, val) = D.RecordLit ( Map.fromList
                  [ ("mapKey"  , D.TextLit (Chunks [] key))
                  , ("mapValue", val)
                  ] )
              recs :: Either CompileError (Dhall.Seq ExprX)
              recs = fmap f . Seq.fromList . HM.toList <$> keyExprMap
              typeAnn = if HM.null o then Just mapValue else Nothing
           in D.ListLit typeAnn <$> recs
        | noKeyValMap
        = Left (NoKeyValMap t v)
        | otherwise
        = Left (Mismatch t v)

    -- array ~> List
    loop (App D.List t) (A.Array a)
        = let f :: [ExprX] -> ExprX
              f es = D.ListLit
                       (if null es then Just t else Nothing)
                       (Seq.fromList es)
           in f <$> traverse (loop t) (toList a)

    -- number -> Integer
    loop D.Integer (A.Number x)
        | Right n <- floatingOrInteger @Double @Integer x
        = Right (D.IntegerLit n)
        | otherwise
        = Left (Mismatch D.Integer (A.Number x))

    -- number -> Natural
    loop D.Natural (A.Number x)
        | Right n <- floatingOrInteger @Double @Dhall.Natural x
        , n >= 0
        = Right (D.NaturalLit n)
        | otherwise
        = Left (Mismatch D.Natural (A.Number x))

    -- number ~> Double
    loop D.Double (A.Number x)
        = Right (D.DoubleLit $ toRealFloat x)

    -- string ~> Text
    loop D.Text (A.String t)
        = Right (D.TextLit (Chunks [] t))

    -- bool ~> Bool
    loop D.Bool (A.Bool t)
        = Right (D.BoolLit t)

    -- null ~> Optional
    loop (App D.Optional _xpr) A.Null
        = Right D.None

    -- value ~> Optional
    loop (App D.Optional expr) value
        = D.Some <$> loop expr value

    -- fail
    loop expr value
        = Left (Mismatch expr value)


-- ----------
-- EXCEPTIONS
-- ----------

red, purple, green :: (Semigroup a, IsString a) => a -> a
red    s = "\ESC[1;31m" <> s <> "\ESC[0m" -- bold
purple s = "\ESC[1;35m" <> s <> "\ESC[0m" -- bold
green  s = "\ESC[0;32m" <> s <> "\ESC[0m" -- plain

showExpr :: ExprX   -> String
showExpr dhall = Text.unpack (D.pretty dhall)

showJSON :: A.Value -> String
showJSON value = BSL8.unpack (encodePretty value)

data CompileError
  -- Dhall shema
  = TypeError (D.TypeError Src X)
  | WrongType
      ExprX -- Expression type
      ExprX -- Whole expression
  -- generic mismatch (fallback)
  | Mismatch
      ExprX   -- Dhall expression
      A.Value -- Aeson value
  -- record specific
  | MissingKey     Text  ExprX A.Value
  | UnhandledKeys [Text] ExprX A.Value
  | NoKeyValArray        ExprX A.Value
  | NoKeyValMap          ExprX A.Value
  -- union specific
  | ContainsUnion        ExprX
  | UndecidableUnion     ExprX A.Value [ExprX]

instance Show CompileError where
  show = let prefix = red "\nError: "
          in \case
    TypeError e -> show e

    WrongType t e   -> prefix
      <> "Schema expression is succesfully parsed but has Dhall type:\n"
      <> showExpr t <> "\nExpected Dhall type: Type"
      <> "\nParsed expression: "
      <> showExpr e <> "\n"

    ContainsUnion e -> prefix
      <> "Dhall type expression contains union type:\n"
      <> showExpr e <> "\nwhile it is forbidden by option "
      <> green "--unions-none\n"

    UndecidableUnion e v xs -> prefix
      <> "More than one union component type matches JSON value"
      <> "\n\nDhall:\n" <> showExpr e
      <> "\n\nJSON:\n"  <> showJSON v
      <> "\n\nPossible matches:\n" -- Showing all the allowed matches
      <> showExpr (D.ListLit Nothing (Seq.fromList xs))
      <> "\n"
      <> "\n\nPossible matches:\n\n" -- Showing all the allowed matches
      <> Text.unpack (Text.intercalate sep $ D.pretty <$> xs)
        where sep = red "\n--------\n" :: Text

    Mismatch e v -> prefix
      <> "Dhall type expression and json value do not match:"
      <> "\n\nDhall:\n" <> showExpr e
      <> "\n\nJSON:\n"  <> showJSON v
      <> "\n"

    MissingKey k e v -> prefix
      <> "Key " <> purple (Text.unpack k) <> ", expected by Dhall type:\n"
      <> showExpr e
      <> "\nis not present in JSON object:\n"
      <> showJSON v <> "\n"

    UnhandledKeys ks e v -> prefix
      <> "Key(s) " <> purple (Text.unpack (Text.intercalate ", " ks))
      <> " present in the JSON object but not in the corresponding Dhall record. This is not allowed in presence of "
      <> green "--records-strict" <> " flag:"
      <> "\n\nDhall:\n" <> showExpr e
      <> "\n\nJSON:\n"  <> showJSON v
      <> "\n"

    NoKeyValArray e v -> prefix
      <> "JSON (key-value) arrays cannot be converted to Dhall records under "
      <> green "--no-keyval-arrays" <> " flag"
      <> "\n\nDhall:\n" <> showExpr e
      <> "\n\nJSON:\n"  <> showJSON v
      <> "\n"

    NoKeyValMap e v -> prefix
      <> "Homogeneous JSON map objects cannot be converted to Dhall association lists under "
      <> green "--no-keyval-arrays" <> " flag"
      <> "\n\nDhall:\n" <> showExpr e
      <> "\n\nJSON:\n"  <> showJSON v
      <> "\n"

instance Exception CompileError
