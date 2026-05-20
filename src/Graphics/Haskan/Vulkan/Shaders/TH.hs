{-# LANGUAGE TemplateHaskell #-}

module Graphics.Haskan.Vulkan.Shaders.TH
  ( compileShader,
  )
where

import FIR (CompilableProgram)
import FIR qualified
import Data.Text.Short (ShortText)
import Data.Text.Short qualified as ShortText
import Language.Haskell.TH
import System.IO (hPutStrLn, stderr)

-- | Compile a FIR shader module to SPIR-V at compile time.
--
-- Usage:
--   $(compileShader "data/shaders/fir/myshader.spv" [FIR.SPIRV (FIR.Version 1 5), FIR.Optimize] MyShaderModule.program)
--
-- This runs FIR compilation during cabal build, failing the build immediately
-- if the shader has errors, rather than deferring failure to runtime.
compileShader :: CompilableProgram prog => String -> [FIR.CompilerFlag] -> prog -> Q [Dec]
compileShader path targets shader = do
  result <- runIO $ FIR.compileTo path targets shader
  case result of
    Left err -> do
      let errStr = ShortText.unpack err
      runIO $ hPutStrLn stderr $ "[Shader Compile Error] " ++ path ++ ": " ++ errStr
      fail $ "Shader compilation failed: " ++ path ++ "\n" ++ errStr
    Right _ -> do
      runIO $ putStrLn $ "[Shader Compile OK] " ++ path
      pure []