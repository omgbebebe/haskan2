import qualified Data.ByteString.Lazy as BSL
import System.Exit (exitFailure)
import System.IO (putStrLn)

import BindlessShader (program)
import FIR (compile, CompilerFlag(..), Version(..), moduleBinary)

main :: IO ()
main = do
  result <- compile [SPIRV (Version 1 0)] program
  case result of
    Left err -> do
      putStrLn $ "Compilation failed: " ++ show err
      exitFailure
    Right (mbSpirv, _reqs) -> do
      case mbSpirv of
        Nothing -> do
          putStrLn "Compilation produced no SPIR-V output"
          exitFailure
        Just spirvMod -> do
          let spirv = moduleBinary spirvMod
          BSL.writeFile "/tmp/bindless_test.spv" spirv
          putStrLn "SPIR-V written to /tmp/bindless_test.spv"

          -- Check for RuntimeDescriptorArray capability (33) in the binary
          -- SPIR-V is little-endian 32-bit words
          let ws = [ fromIntegral (BSL.index spirv i) + 256 * fromIntegral (BSL.index spirv (i+1)) + 65536 * fromIntegral (BSL.index spirv (i+2)) + 16777216 * fromIntegral (BSL.index spirv (i+3))
                   | i <- [0,4..fromIntegral (BSL.length spirv) - 1]
                   ]
              hasCap33 = any (== 33) ws
          if hasCap33
            then putStrLn "SUCCESS: RuntimeDescriptorArray capability (33) found"
            else do
              putStrLn "FAIL: RuntimeDescriptorArray capability not found"
              exitFailure
