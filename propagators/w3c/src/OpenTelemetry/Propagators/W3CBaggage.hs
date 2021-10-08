{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
module OpenTelemetry.Propagators.W3CBaggage where

import Data.ByteString
import Data.Maybe
import Data.Semigroup
import Network.HTTP.Types
import qualified OpenTelemetry.Baggage as Baggage
import OpenTelemetry.Context (Context, insertBaggage, lookupBaggage)
import OpenTelemetry.Context.Propagators

decodeBaggage :: ByteString -> Maybe Baggage.Baggage
decodeBaggage bs = case Baggage.decodeBaggageHeader bs of
  Left _ -> Nothing
  Right b -> Just b

encodeBaggage :: Baggage.Baggage -> ByteString
encodeBaggage = Baggage.encodeBaggageHeader

w3cBaggagePropagator :: Propagator Context RequestHeaders ResponseHeaders
w3cBaggagePropagator = Propagator{..}
  where
    propagatorNames = [ "w3cBaggage" ]

    extractor hs c = case Prelude.lookup "baggage" hs of
      Nothing -> pure c
      Just baggageHeader -> case decodeBaggage baggageHeader of
        Nothing -> pure c
        Just baggage -> pure $! insertBaggage baggage c

    injector c hs = do
      case lookupBaggage c of
        Nothing -> pure hs
        Just baggage -> pure $! (("baggage", encodeBaggage baggage) : hs)