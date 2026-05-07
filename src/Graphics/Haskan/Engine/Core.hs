{-# LANGUAGE DeriveGeneric #-}

module Graphics.Haskan.Engine.Core where

import Control.Concurrent.STM.TVar (TVar)
import Data.HashMap.Strict (HashMap)
import Data.Hashable (Hashable(..))  
import GHC.Generics (Generic)
import Linear.V2 (V2)
import Linear.V3 (V3)
import SDL qualified

data Action = MoveForward | MoveBackward | StrafeLeft | StrafeRight  
            | MouseMove (V2 Int) | Escape
  deriving (Eq, Show)

type ActionEvent = (Action, Bool)

data EngineConfig = EngineConfig
  { targetRenderFPS :: !Integer,
    targetPhysicsFPS :: !Integer, 
    targetNetworkFPS :: !Integer,
    targetInputFPS   :: !Integer }
  deriving (Show)

type Position = V3 Float  
type Distance = Float

data WorldState cam = WorldState { activeCamera :: TVar cam }

data GameState cam = GameState
  { world       :: TVar (WorldState cam),
    isRunning   :: TVar Bool,
    moveForward :: TVar Bool, 
    moveBackward:: TVar Bool,
    strafeLeft  :: TVar Bool,
    strafeRight :: TVar Bool }

data ControlMessage = Terminate  

data KeyModifier  
  = LShift | RShift | LCtrl | RCtrl | LAlt | RAlt  
  | LGUI | RGUI | NumLock | CapsLock | AltGr
  deriving (Eq, Enum, Generic, Show)

instance Hashable KeyModifier
instance Hashable SDL.Keycode  

type KeyBindings = HashMap ([KeyModifier], SDL.Keycode) Action  

defaultBindings :: KeyBindings
defaultBindings = HashMap.fromList
    [ (([], SDL.KeycodeW), MoveForward)
    , (([], SDL.KeycodeS), MoveBackward)  
    , (([], SDL.KeycodeA), StrafeLeft)
    , (([], SDL.KeycodeD), StrafeRight)
    , (([LShift], SDL.KeycodeQ), Escape) ]
