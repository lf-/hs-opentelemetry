{-# LANGUAGE CPP #-}
{-# LANGUAGE DeriveLift #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TemplateHaskell #-}
module OpenTelemetry.Baggage 
  (
  -- * Constructing 'Baggage' structures
    Baggage
  , fromHashMap
  , values
  , Token
  , token
  , mkToken
  , Element
  , element
  , properties
  , InvalidBaggage(..)
  -- * Modifying 'Baggage'
  -- * Encoding and decoding 'Baggage'
  , encodeBaggageHeader
  , encodeBaggageHeaderB
  , decodeBaggageHeader 
  , decodeBaggageHeaderP
  ) where
import Control.Applicative
import qualified Data.Attoparsec.ByteString.Char8 as P
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Internal as BS
import Data.ByteString.Internal (ByteString(..) )
import qualified Data.ByteString.Lazy as L
import qualified Data.ByteString.Builder.Extra as BS
import Data.ByteString.Unsafe (unsafePackAddressLen)
import Data.CharSet (CharSet)
import qualified Data.CharSet as C
import Data.Hashable
import qualified Data.HashMap.Strict as H
import Data.List (intersperse)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Text.Encoding (encodeUtf8, decodeUtf8)
import qualified Data.ByteString.Builder as B
import Language.Haskell.TH.Lib
import Language.Haskell.TH.Quote
import Language.Haskell.TH.Syntax
import Network.HTTP.Types.URI
import System.IO.Unsafe

newtype Token = Token ByteString
  deriving stock (Show, Eq, Ord)
  deriving newtype (Hashable)

instance Lift Token where
  liftTyped (Token tok) = unsafeTExpCoerce $ bsToExp tok

data Element = Element
  { value :: Text
  , properties :: [Property]
  }
  deriving stock (Show, Eq)

element :: Text -> Element
element t = Element t []

data Property = Property
  { propertyKey :: Token
  , propertyValue :: Maybe Text
  }
  deriving stock (Show, Eq)

property :: Token -> Maybe Text -> Property
property = Property

newtype Baggage = Baggage (H.HashMap Token Element)
  deriving stock (Show, Eq)
  deriving newtype (Semigroup)

tokenCharacters :: CharSet
tokenCharacters = C.fromList "!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"

-- Ripped from file-embed-0.0.13
bsToExp :: ByteString -> Q Exp
#if MIN_VERSION_template_haskell(2, 5, 0)
bsToExp bs =
    return $ ConE 'Token
      `AppE` (VarE 'unsafePerformIO
      `AppE` (VarE 'unsafePackAddressLen
      `AppE` LitE (IntegerL $ fromIntegral $ BS.length bs)
#if MIN_VERSION_template_haskell(2, 16, 0)
      `AppE` LitE (bytesPrimL (
                let BS.PS ptr off sz = bs
                in  mkBytes ptr (fromIntegral off) (fromIntegral sz)))))
#elif MIN_VERSION_template_haskell(2, 8, 0)
      `AppE` LitE (StringPrimL $ B.unpack bs)))
#else
      `AppE` LitE (StringPrimL $ B8.unpack bs)))
#endif
#else
bsToExp bs = do
    helper <- [| stringToBs |]
    let chars = B8.unpack bs
    return $! AppE helper $! LitE $! StringL chars
#endif

mkToken :: Text -> Maybe Token
mkToken txt
  | txt `T.compareLength` 4096 == GT = Nothing
  | T.all (`C.member` tokenCharacters) txt = Just $ Token $ encodeUtf8 txt
  | otherwise = Nothing

token :: QuasiQuoter
token = QuasiQuoter
  { quoteExp = parseExp
  , quotePat = \_ -> fail "Token as pattern not implemented"
  , quoteType = \_ -> fail "Can't use a Baggage Token as a type"
  , quoteDec = \_ -> fail "Can't use a Baggage Token as a declaration"
  }
  where
    parseExp = \str -> case mkToken $ T.pack str of
      Nothing -> fail (show str ++ " is not a valid Token.")
      Just tok -> lift tok


data InvalidBaggage
  = BaggageTooLong
  | MemberTooLong
  | TooManyListMembers
  | Empty

-- TODO: The fact that this can be a max of 8192 bytes 
-- should allow this to optimized pretty heavily
encodeBaggageHeader :: Baggage -> ByteString
encodeBaggageHeader = 
  L.toStrict . 
  BS.toLazyByteStringWith (BS.untrimmedStrategy (8192 + 16) BS.smallChunkSize) L.empty .
  encodeBaggageHeaderB

encodeBaggageHeaderB :: Baggage -> B.Builder
encodeBaggageHeaderB (Baggage bmap) =
  mconcat $ 
  intersperse (B.char7 ',') $ 
  map go $
  H.toList bmap
  where
    go (Token k, Element v props) = 
      B.byteString k <>
      B.char7 '=' <>
      urlEncodeBuilder False (encodeUtf8 v) <>
      (mconcat $ intersperse (B.char7 ';') $ map propEncoder props)
    propEncoder (Property (Token k) mv) = 
      B.byteString k <>
      maybe 
        mempty 
        (\v -> B.char7 '=' <> urlEncodeBuilder False (encodeUtf8 v))
        mv

decodeBaggageHeader :: ByteString -> Either String Baggage
decodeBaggageHeader = P.parseOnly decodeBaggageHeaderP

decodeBaggageHeaderP :: P.Parser Baggage
decodeBaggageHeaderP = do
  owsP
  firstMember <- memberP
  otherMembers <- many (owsP >> P.char8 ',' >> owsP >> memberP)
  owsP
  pure $ Baggage $ H.fromList (firstMember : otherMembers)
  where
    owsSet = C.fromList " \t"
    owsP = P.skipWhile (`C.member` owsSet)
    memberP :: P.Parser (Token, Element)
    memberP = do
      tok <- tokenP 
      owsP
      P.char8 '='
      owsP
      val <- valP
      props <- many (owsP >> P.char8 ';' >> owsP >> propertyP)
      pure (tok, Element val props)
    valueSet = C.fromList $
      concat 
        [ ['\x21']
        , ['\x23'..'\x2B']
        , ['\x2D'..'\x3A']
        , ['\x3C'..'\x5B']
        , ['\x5D'..'\x7E']
        ]
    tokenP :: P.Parser Token
    tokenP = Token <$> P.takeWhile1 (`C.member` tokenCharacters)
    valP = decodeUtf8 <$> P.takeWhile (`C.member` valueSet)
    propertyP :: P.Parser Property
    propertyP = do
      key <- tokenP
      owsP
      val <- P.option Nothing $ do
        P.char8 '='
        owsP
        Just <$> valP
      pure $ Property key val

empty :: Baggage
empty = Baggage H.empty

insert :: Token -> Element -> Baggage -> Baggage
insert k v (Baggage c) = Baggage (H.insert k v c)

delete :: Token -> Baggage -> Baggage 
delete k (Baggage c) = Baggage (H.delete k c)

values :: Baggage -> H.HashMap Token Element
values (Baggage m) = m

fromHashMap :: H.HashMap Token Element -> Baggage
fromHashMap = Baggage

-- TODO Must implement
-- * A `TextMapPropagator` implementing the [W3C Baggage Specification](https://w3c.github.io/baggage).