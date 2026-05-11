{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE RecordWildCards #-}

module Graphics.Haskan.Input
  ( Action (..)
  , ActionEvent
  , KeyModifier (..)
  , KeyBindings
  , defaultBindings
  , modifiersToList
  , payloadToActionEvent
  , mouseMotionToAction
  , keyToAction
  )
where

import Data.HashMap.Strict (HashMap)
import Data.HashMap.Strict qualified as HashMap
import Data.Hashable (Hashable (..))
import GHC.Generics (Generic)
import Linear (V2 (..))
import SDL qualified

data Action
  = MoveForward
  | MoveBackward
  | StrafeLeft
  | StrafeRight
  | MouseMove (V2 Int)
  | Zoom Float
  | Escape
  | FrameInspect
  | ToggleWireframe
  | ToggleAxisOverlay
  | ToggleGroundPlane
  | DebugMode Int
  | SaveScreenshot
  | SaveAllStages
  | SaveSwapchainScreenshot
  | ToggleMouseCapture
  deriving (Eq, Show, Generic)

type ActionEvent = (Action, Bool, Bool)  -- (action, pressed, isRepeated)

data KeyModifier
  = LShift
  | RShift
  | LCtrl
  | RCtrl
  | LAlt
  | RAlt
  | LGUI
  | RGUI
  | NumLock
  | CapsLock
  | AltGr
  deriving (Eq, Enum, Generic, Show)

type KeyBindings = HashMap ([KeyModifier], SDL.Keycode) Action

instance Hashable KeyModifier

instance Hashable SDL.Keycode

defaultBindings :: KeyBindings
defaultBindings =
  HashMap.fromList
    [ (([], SDL.KeycodeW), MoveForward),
      (([], SDL.KeycodeS), MoveBackward),
      (([], SDL.KeycodeA), StrafeLeft),
      (([], SDL.KeycodeD), StrafeRight),
      (([], SDL.KeycodeF12), FrameInspect),
      (([LShift], SDL.KeycodeQ), Escape),
      (([LShift], SDL.KeycodeF3), ToggleWireframe),
      (([], SDL.KeycodeG), ToggleAxisOverlay),
      (([LShift], SDL.KeycodeG), ToggleGroundPlane),
      -- Debug modes F1-F9 (modes 1-9)
      (([], SDL.KeycodeF1), DebugMode 1),   -- albedo
      (([], SDL.KeycodeF2), DebugMode 2),   -- normals
      (([], SDL.KeycodeF3), DebugMode 3),   -- roughness
      (([], SDL.KeycodeF4), DebugMode 4),   -- metallic
      (([], SDL.KeycodeF5), DebugMode 5),   -- position
      (([], SDL.KeycodeF6), DebugMode 6),   -- emissive
      (([], SDL.KeycodeF7), DebugMode 7),   -- AO
      (([], SDL.KeycodeF8), DebugMode 8),   -- NdotL
      (([], SDL.KeycodeF9), DebugMode 9),   -- irradiance
      -- Screenshots
      (([], SDL.KeycodeF10), SaveScreenshot),
      (([], SDL.KeycodeF11), SaveAllStages),
      (([LShift], SDL.KeycodeF11), SaveSwapchainScreenshot),
      -- Debug modes with modifiers
      (([LCtrl], SDL.KeycodeF12), DebugMode 10),  -- specular IBL
      (([LShift], SDL.KeycodeF12), DebugMode 11), -- Fresnel
      (([LShift, LCtrl], SDL.KeycodeF12), DebugMode 12), -- raw skybox
      (([], SDL.KeycodeM), ToggleMouseCapture)
    ]

modifiersToList :: SDL.KeyModifier -> [KeyModifier]
modifiersToList SDL.KeyModifier {..} = map fst . filter snd $
  [ (LShift,   keyModifierLeftShift)
  , (RShift,   keyModifierRightShift)
  , (LCtrl,    keyModifierLeftCtrl)
  , (RCtrl,    keyModifierRightCtrl)
  , (LAlt,     keyModifierLeftAlt)
  , (RAlt,     keyModifierRightAlt)
  ]

payloadToActionEvent :: SDL.EventPayload -> Maybe ActionEvent
payloadToActionEvent SDL.QuitEvent = Just (Escape, True, False)
payloadToActionEvent (SDL.KeyboardEvent keyboardEvent) = keyToAction keyboardEvent
payloadToActionEvent (SDL.MouseMotionEvent mouseMotionEvent) = mouseMotionToAction mouseMotionEvent
payloadToActionEvent (SDL.MouseWheelEvent mouseWheelEvent) = mouseWheelToAction mouseWheelEvent
payloadToActionEvent _ = Nothing

mouseWheelToAction :: SDL.MouseWheelEventData -> Maybe ActionEvent
mouseWheelToAction (SDL.MouseWheelEventData _window _mouseDevice scroll _direction) =
  let (SDL.V2 _scrollX scrollY) = scroll
      -- Negative scrollY means scroll down (zoom out), positive means scroll up (zoom in)
      zoomAmount = fromIntegral scrollY * (-0.01)  -- scale factor for zoom sensitivity
   in Just (Zoom zoomAmount, True, False)

mouseMotionToAction :: SDL.MouseMotionEventData -> Maybe ActionEvent
mouseMotionToAction (SDL.MouseMotionEventData _window _mouseDevice _mouseButtons _absolutePosition relativePosition) =
  let (SDL.V2 relX relY) = relativePosition
      x = fromIntegral relX
      y = fromIntegral relY
   in Just (MouseMove (V2 x y), True, False)

keyToAction :: SDL.KeyboardEventData -> Maybe ActionEvent
keyToAction (SDL.KeyboardEventData _window motion isRepeated keysym) =
  let modifiers = modifiersToList (SDL.keysymModifier keysym)
      key = SDL.keysymKeycode keysym
   in case HashMap.lookup (modifiers, key) defaultBindings of
        Just action -> Just (action, motion == SDL.Pressed, isRepeated)
        Nothing -> Nothing
