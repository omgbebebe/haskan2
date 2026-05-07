{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

module Graphics.Haskan.Debug.Interface
  ( DebugMessage (..)
  , DebugCommand (..)
  , DebugEvent (..)
  , DebugResponse (..)
  , GameStateSnapshot (..)
  , DebugCameraSnapshot (..)
  , parseDebugMessage
  , debugMessageToActionEvent
  , encodeDebugResponse
  )
where

import Control.Monad (mzero)
import Data.Aeson
import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy qualified as LBS
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import GHC.Generics (Generic)
import Graphics.Haskan.Input (Action (..), ActionEvent)
import Linear (V2 (..), V3 (..))

instance ToJSON (V3 Float) where
  toJSON (V3 x y z) = toJSON [x, y, z]

instance FromJSON (V3 Float) where
  parseJSON v = do
    [x, y, z] <- parseJSON v
    pure (V3 x y z)

instance ToJSON (V2 Int) where
  toJSON (V2 x y) = toJSON [x, y]

instance FromJSON (V2 Int) where
  parseJSON v = do
    [x, y] <- parseJSON v
    pure (V2 x y)

-- | Commands that don't map to input events — direct state mutations.
data DebugCommand
  = SetCameraDistance Float
  | SetCameraTarget (V3 Float)
  | SetCameraAngles Float Float
  | TriggerFrameInspect
  | SetTimeScale Float
  | GetState
  | GetRenderState
  deriving (Eq, Show, Generic)

-- | Events that map to the existing ActionEvent system.
data DebugEvent
  = KeyPress Text Bool
  | MouseMoveEvent Int Int
  deriving (Eq, Show, Generic)

-- | Top-level message from debug client.
data DebugMessage
  = InjectEvent DebugEvent
  | Command DebugCommand
  deriving (Eq, Show, Generic)

instance ToJSON DebugCommand where
  toJSON = genericToJSON aesonOptions

instance FromJSON DebugCommand where
  parseJSON = genericParseJSON aesonOptions

instance ToJSON DebugEvent where
  toJSON = genericToJSON aesonOptions

instance FromJSON DebugEvent where
  parseJSON = genericParseJSON aesonOptions

instance ToJSON DebugMessage where
  toJSON = genericToJSON aesonOptions

instance FromJSON DebugMessage where
  parseJSON = genericParseJSON aesonOptions

aesonOptions :: Options
aesonOptions =
  defaultOptions
    { sumEncoding = ObjectWithSingleField
    , constructorTagModifier = camelTo2 '_'
    , fieldLabelModifier = camelTo2 '_'
    }

parseDebugMessage :: Text -> Either String DebugMessage
parseDebugMessage = Aeson.eitherDecodeStrict . Text.encodeUtf8

debugEventToAction :: DebugEvent -> Maybe ActionEvent
debugEventToAction (KeyPress keyName pressed) =
  case Text.toLower keyName of
    "w" -> Just (MoveForward, pressed)
    "s" -> Just (MoveBackward, pressed)
    "a" -> Just (StrafeLeft, pressed)
    "d" -> Just (StrafeRight, pressed)
    "f12" -> Just (FrameInspect, pressed)
    "escape" -> Just (Escape, pressed)
    _ -> Nothing
debugEventToAction (MouseMoveEvent x y) =
  Just (MouseMove (V2 x y), True)

debugMessageToActionEvent :: DebugMessage -> Either DebugCommand (Maybe ActionEvent)
debugMessageToActionEvent (InjectEvent ev) =
  Right (debugEventToAction ev)
debugMessageToActionEvent (Command cmd) =
  Left cmd

-- | Response sent back to debug clients.
data DebugResponse
  = StateResponse GameStateSnapshot
  | RenderStateResponse Value
  | AckResponse Text
  | ErrorResponse Text
  deriving (Eq, Show, Generic)

data GameStateSnapshot = GameStateSnapshot
  { gssCamera :: DebugCameraSnapshot
  , gssRunning :: Bool
  , gssFrameInspectorEnabled :: Bool
  }
  deriving (Eq, Show, Generic)

data DebugCameraSnapshot = DebugCameraSnapshot
  { csPosition :: V3 Float
  , csTarget :: V3 Float
  , csDistance :: Float
  , csAzimuth :: Float
  , csElevation :: Float
  }
  deriving (Eq, Show, Generic)

instance ToJSON DebugResponse where
  toJSON = genericToJSON aesonOptions

instance ToJSON GameStateSnapshot where
  toJSON = genericToJSON aesonOptions

instance ToJSON DebugCameraSnapshot where
  toJSON = genericToJSON aesonOptions

encodeDebugResponse :: DebugResponse -> Text
encodeDebugResponse = Text.decodeUtf8 . LBS.toStrict . encode