{-# LANGUAGE ForeignFunctionInterface #-}

module Graphics.Haskan.Physics.Jolt.FFI where

import Foreign
import Foreign.C

foreign import ccall unsafe "jolt_wrapper.h joltCreateWorld"
  c_joltCreateWorld :: CInt -> CInt -> CInt -> IO (Ptr ())

foreign import ccall unsafe "jolt_wrapper.h joltDestroyWorld"
  c_joltDestroyWorld :: Ptr () -> IO ()

foreign import ccall unsafe "jolt_wrapper.h joltUpdate"
  c_joltUpdate :: Ptr () -> CFloat -> CInt -> IO ()

foreign import ccall unsafe "jolt_wrapper.h joltCreateBoxBody"
  c_joltCreateBoxBody :: Ptr () -> CFloat -> CFloat -> CFloat -> CFloat -> CFloat -> CFloat -> CFloat -> IO CInt

foreign import ccall unsafe "jolt_wrapper.h joltCreateSphereBody"
  c_joltCreateSphereBody :: Ptr () -> CFloat -> CFloat -> CFloat -> CFloat -> CFloat -> IO CInt

foreign import ccall unsafe "jolt_wrapper.h joltCreateStaticPlane"
  c_joltCreateStaticPlane :: Ptr () -> CFloat -> CFloat -> CFloat -> CFloat -> IO CInt

foreign import ccall unsafe "jolt_wrapper.h joltRemoveBody"
  c_joltRemoveBody :: Ptr () -> CInt -> IO ()

foreign import ccall unsafe "jolt_wrapper.h joltGetPosition"
  c_joltGetPosition :: Ptr () -> CInt -> Ptr CFloat -> Ptr CFloat -> Ptr CFloat -> IO ()

foreign import ccall unsafe "jolt_wrapper.h joltGetRotation"
  c_joltGetRotation :: Ptr () -> CInt -> Ptr CFloat -> Ptr CFloat -> Ptr CFloat -> Ptr CFloat -> IO ()

foreign import ccall unsafe "jolt_wrapper.h joltGetLinearVelocity"
  c_joltGetLinearVelocity :: Ptr () -> CInt -> Ptr CFloat -> Ptr CFloat -> Ptr CFloat -> IO ()

foreign import ccall unsafe "jolt_wrapper.h joltIsActive"
  c_joltIsActive :: Ptr () -> CInt -> IO CInt

foreign import ccall unsafe "jolt_wrapper.h joltSetPosition"
  c_joltSetPosition :: Ptr () -> CInt -> CFloat -> CFloat -> CFloat -> IO ()

foreign import ccall unsafe "jolt_wrapper.h joltSetLinearVelocity"
  c_joltSetLinearVelocity :: Ptr () -> CInt -> CFloat -> CFloat -> CFloat -> IO ()

foreign import ccall unsafe "jolt_wrapper.h joltAddForce"
  c_joltAddForce :: Ptr () -> CInt -> CFloat -> CFloat -> CFloat -> IO ()

foreign import ccall unsafe "jolt_wrapper.h joltAddImpulse"
  c_joltAddImpulse :: Ptr () -> CInt -> CFloat -> CFloat -> CFloat -> IO ()
