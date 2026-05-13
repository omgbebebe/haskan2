{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}


module Graphics.Haskan.Debug.Interface
  ( DebugMessage (..),
    DebugCommand (..),
    DebugEvent (..),
    DebugResponse (..),
    GameStateSnapshot (..),
    DebugCameraSnapshot (..),
    parseDebugMessage,
    debugMessageToActionEvent,
    encodeDebugResponse,
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
    { sumEncoding = ObjectWithSingleField,
      constructorTagModifier = camelTo2 '_',
      fieldLabelModifier = camelTo2 '_'
    }

parseDebugMessage :: Text -> Either String DebugMessage
parseDebugMessage = Aeson.eitherDecodeStrict . Text.encodeUtf8

debugEventToAction :: DebugEvent -> Maybe ActionEvent
debugEventToAction (KeyPress keyName pressed) =
  case Text.toLower keyName of
    "w" -> Just (MoveForward, pressed, False)
    "s" -> Just (MoveBackward, pressed, False)
    "a" -> Just (StrafeLeft, pressed, False)
    "d" -> Just (StrafeRight, pressed, False)
    "f1" -> Just (DebugMode 1, pressed, False)
    "f2" -> Just (DebugMode 2, pressed, False)
    "f3" -> Just (DebugMode 3, pressed, False)
    "shift+f3" -> Just (ToggleWireframe, pressed, False)
    "g" -> Just (ToggleAxisOverlay, pressed, False)
    "shift+g" -> Just (ToggleGroundPlane, pressed, False)
    "f4" -> Just (DebugMode 4, pressed, False)
    "f5" -> Just (DebugMode 5, pressed, False)
    "f6" -> Just (DebugMode 6, pressed, False)
    "f7" -> Just (DebugMode 7, pressed, False)
    "f8" -> Just (DebugMode 8, pressed, False)
    "f9" -> Just (DebugMode 9, pressed, False)
    "f10" -> Just (SaveScreenshot, pressed, False)
    "f11" -> Just (SaveAllStages, pressed, False)
    "shift+f11" -> Just (SaveSwapchainScreenshot, pressed, False)
    "ctrl+f12" -> Just (DebugMode 10, pressed, False)
    "shift+f12" -> Just (DebugMode 11, pressed, False)
    "shift+ctrl+f12" -> Just (DebugMode 12, pressed, False)
    "f12" -> Just (FrameInspect, pressed, False)
    "m" -> Just (ToggleMouseCapture, pressed, False)
    "escape" -> Just (Escape, pressed, False)
    _ -> Nothing
debugEventToAction (MouseMoveEvent x y) =
  Just (MouseMove (V2 x y), True, False)

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
  { gssCamera :: DebugCameraSnapshot,
    gssRunning :: Bool,
    gssFrameInspectorEnabled :: Bool
  }
  deriving (Eq, Show, Generic)

data DebugCameraSnapshot = DebugCameraSnapshot
  { csPosition :: V3 Float,
    csTarget :: V3 Float,
    csDistance :: Float,
    csAzimuth :: Float,
    csElevation :: Float
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
