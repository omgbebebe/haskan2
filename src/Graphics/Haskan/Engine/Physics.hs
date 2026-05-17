module Graphics.Haskan.Engine.Physics
  ( physicsLoop
  ) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.MVar (MVar, putMVar)
import Control.Concurrent.STM (STM)
import Control.Concurrent.STM qualified as STM
import Control.Concurrent.STM.TVar (TVar)
import Control.Monad (unless, when)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Data.IntMap.Strict (IntMap)
import Data.IntMap.Strict qualified as IntMap
import Linear (V3 (..))

import Graphics.Haskan.Engine.Types (GameState (..), PhysicsBodySpec (..))
import Graphics.Haskan.Logger (LogCategory (..), logInfoIO, showT)
import Graphics.Haskan.Physics.Jolt.Types (BodyId (..), BodyState (..), BodyType (..))
import Graphics.Haskan.Physics.Jolt.World qualified as Physics
import Graphics.Haskan.Scene.ECS (EntityId (..))
import System.Clock (Clock (..), getTime, toNanoSecs)

physicsLoop :: MonadIO m => Integer -> GameState cam -> MVar () -> m ()
physicsLoop targetFPS gameState finishedSemaphore = liftIO $ do
  logInfoIO LogGeneral "physicsLoop starting"

  world <- Physics.createWorld 1024 1024 1024

  -- Ground plane
  _ground <- Physics.createBody world (StaticPlane (V3 0 1 0) 0) (V3 0 0 0)

  -- Read pending body specs from scene loader
  specs <- STM.atomically $ do
    s <- STM.readTVar (physicsPendingSpecs gameState)
    STM.writeTVar (physicsPendingSpecs gameState) []
    pure s

  bodies <- mapM (\spec -> do
    bid <- Physics.createBody world (pbsBodyType spec) (pbsPosition spec)
    pure (unBodyId bid, pbsEntityId spec)
    ) specs

  let bodyIds = map (BodyId . fst) bodies
  STM.atomically $ STM.writeTVar (physicsBodyToEntity gameState) (IntMap.fromList bodies)

  when (null specs) $ do
    -- Fallback test box if no scene specs provided
    boxId <- Physics.createBody world (BoxBody (V3 0.5 0.5 0.5) 10) (V3 0 5 0)
    STM.atomically $ STM.writeTVar (physicsBodyToEntity gameState) (IntMap.singleton (unBodyId boxId) (EntityId 0))
    let _ = bodyIds ++ [boxId]
    pure ()

  let allBodyIds = if null specs then [BodyId 0] else bodyIds

  let loop :: [BodyId] -> Integer -> Integer -> IO ()
      loop bids tFPS prevTime = do
        running <- STM.readTVarIO (isRunning gameState)
        when running $ do
          autoStep <- STM.readTVarIO (physicsAutoStep gameState)
          timeScale <- STM.readTVarIO (physicsTimeScale gameState)

          newTime <- toNanoSecs <$> getTime Monotonic
          let dtSeconds = min 0.1 (realToFrac (newTime - prevTime) / 1e9) :: Float

          when autoStep $ do
            let stepDt = dtSeconds * timeScale
            Physics.stepWorld world stepDt 1

            states <- mapM (\bid -> do
              st <- Physics.getBodyState world bid
              pure (unBodyId bid, st)
              ) bids
            STM.atomically $ STM.writeTVar (physicsBodies gameState) (IntMap.fromList states)

          let targetDelayMicros = 1000000 `div` fromIntegral tFPS
          threadDelay (fromIntegral targetDelayMicros)
          loop bids tFPS newTime

  currentTime <- toNanoSecs <$> getTime Monotonic
  loop allBodyIds targetFPS currentTime

  Physics.destroyWorld world
  logInfoIO LogGeneral "physicsLoop finished"
  putMVar finishedSemaphore ()
