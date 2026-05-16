module Graphics.Haskan.Physics.Jolt.World
  ( createWorld
  , destroyWorld
  , stepWorld
  , createBody
  , removeBody
  , getBodyState
  , setBodyPosition
  , setBodyVelocity
  , addBodyForce
  , addBodyImpulse
  ) where

import Control.Exception (bracket)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Foreign
import Foreign.C
import Linear (V3 (..), Quaternion (..))

import Graphics.Haskan.Physics.Jolt.FFI
import Graphics.Haskan.Physics.Jolt.Types

createWorld :: MonadIO m => Int -> Int -> Int -> m JoltWorld
createWorld maxBodies maxPairs maxContacts = liftIO $
  JoltWorld <$> c_joltCreateWorld (fromIntegral maxBodies) (fromIntegral maxPairs) (fromIntegral maxContacts)

destroyWorld :: MonadIO m => JoltWorld -> m ()
destroyWorld (JoltWorld ptr) = liftIO $ c_joltDestroyWorld ptr

withWorld :: Int -> Int -> Int -> (JoltWorld -> IO a) -> IO a
withWorld maxBodies maxPairs maxContacts =
  bracket (createWorld maxBodies maxPairs maxContacts) destroyWorld

stepWorld :: MonadIO m => JoltWorld -> Float -> Int -> m ()
stepWorld (JoltWorld ptr) dt steps = liftIO $
  c_joltUpdate ptr (realToFrac dt) (fromIntegral steps)

createBody :: MonadIO m => JoltWorld -> BodyType -> V3 Float -> m BodyId
createBody (JoltWorld ptr) bodyType (V3 px py pz) = liftIO $ do
  bid <- case bodyType of
    BoxBody (V3 hx hy hz) mass ->
      c_joltCreateBoxBody ptr (realToFrac hx) (realToFrac hy) (realToFrac hz) (realToFrac mass) (realToFrac px) (realToFrac py) (realToFrac pz)
    SphereBody radius mass ->
      c_joltCreateSphereBody ptr (realToFrac radius) (realToFrac mass) (realToFrac px) (realToFrac py) (realToFrac pz)
    StaticPlane (V3 nx ny nz) dist ->
      c_joltCreateStaticPlane ptr (realToFrac nx) (realToFrac ny) (realToFrac nz) (realToFrac dist)
  return $ BodyId (fromIntegral bid)

removeBody :: MonadIO m => JoltWorld -> BodyId -> m ()
removeBody (JoltWorld ptr) (BodyId bid) = liftIO $
  c_joltRemoveBody ptr (fromIntegral bid)

getBodyState :: MonadIO m => JoltWorld -> BodyId -> m BodyState
getBodyState (JoltWorld ptr) (BodyId bid) = liftIO $ do
  alloca $ \pxPtr ->
    alloca $ \pyPtr ->
      alloca $ \pzPtr ->
        alloca $ \qxPtr ->
          alloca $ \qyPtr ->
            alloca $ \qzPtr ->
              alloca $ \qwPtr ->
                alloca $ \vxPtr ->
                  alloca $ \vyPtr ->
                    alloca $ \vzPtr -> do
                      c_joltGetPosition ptr (fromIntegral bid) pxPtr pyPtr pzPtr
                      c_joltGetRotation ptr (fromIntegral bid) qxPtr qyPtr qzPtr qwPtr
                      c_joltGetLinearVelocity ptr (fromIntegral bid) vxPtr vyPtr vzPtr
                      active <- c_joltIsActive ptr (fromIntegral bid)
                      px <- peek pxPtr
                      py <- peek pyPtr
                      pz <- peek pzPtr
                      qx <- peek qxPtr
                      qy <- peek qyPtr
                      qz <- peek qzPtr
                      qw <- peek qwPtr
                      vx <- peek vxPtr
                      vy <- peek vyPtr
                      vz <- peek vzPtr
                      return BodyState
                        { bsPosition = V3 (realToFrac px) (realToFrac py) (realToFrac pz)
                        , bsRotation = Quaternion (realToFrac qw) (V3 (realToFrac qx) (realToFrac qy) (realToFrac qz))
                        , bsVelocity = V3 (realToFrac vx) (realToFrac vy) (realToFrac vz)
                        , bsActive   = active /= 0
                        }

setBodyPosition :: MonadIO m => JoltWorld -> BodyId -> V3 Float -> m ()
setBodyPosition (JoltWorld ptr) (BodyId bid) (V3 x y z) = liftIO $
  c_joltSetPosition ptr (fromIntegral bid) (realToFrac x) (realToFrac y) (realToFrac z)

setBodyVelocity :: MonadIO m => JoltWorld -> BodyId -> V3 Float -> m ()
setBodyVelocity (JoltWorld ptr) (BodyId bid) (V3 x y z) = liftIO $
  c_joltSetLinearVelocity ptr (fromIntegral bid) (realToFrac x) (realToFrac y) (realToFrac z)

addBodyForce :: MonadIO m => JoltWorld -> BodyId -> V3 Float -> m ()
addBodyForce (JoltWorld ptr) (BodyId bid) (V3 x y z) = liftIO $
  c_joltAddForce ptr (fromIntegral bid) (realToFrac x) (realToFrac y) (realToFrac z)

addBodyImpulse :: MonadIO m => JoltWorld -> BodyId -> V3 Float -> m ()
addBodyImpulse (JoltWorld ptr) (BodyId bid) (V3 x y z) = liftIO $
  c_joltAddImpulse ptr (fromIntegral bid) (realToFrac x) (realToFrac y) (realToFrac z)
