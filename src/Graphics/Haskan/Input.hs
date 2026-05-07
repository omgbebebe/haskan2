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
  | Escape
  | FrameInspect
  deriving (Eq, Show, Generic)

type ActionEvent = (Action, Bool)

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
      (([LShift], SDL.KeycodeQ), Escape)
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
payloadToActionEvent SDL.QuitEvent = Just (Escape, True)
payloadToActionEvent (SDL.KeyboardEvent keyboardEvent) = keyToAction keyboardEvent
payloadToActionEvent (SDL.MouseMotionEvent mouseMotionEvent) = mouseMotionToAction mouseMotionEvent
payloadToActionEvent _ = Nothing

mouseMotionToAction :: SDL.MouseMotionEventData -> Maybe ActionEvent
mouseMotionToAction (SDL.MouseMotionEventData _window _mouseDevice _mouseButtons _absolutePosition relativePosition) =
  let (SDL.V2 relX relY) = relativePosition
   in Just ((MouseMove (V2 (fromIntegral (relX * 10)) (fromIntegral (relY * 10)))), True)

keyToAction :: SDL.KeyboardEventData -> Maybe ActionEvent
keyToAction (SDL.KeyboardEventData _window motion isRepeated keysym)
  | isRepeated = Nothing
  | otherwise =
      let modifiers = modifiersToList (SDL.keysymModifier keysym)
          key = SDL.keysymKeycode keysym
       in case HashMap.lookup (modifiers, key) defaultBindings of
            Just action -> Just (action, motion == SDL.Pressed)
            Nothing -> Nothing