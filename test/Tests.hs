module Main where

import Test.Tasty
import Test.Tasty.HUnit

main :: IO ()
main = defaultTests

defaultTests :: IO ()
defaultTests = defaultMain tests

tests :: TestTree
tests = testGroup "haskan2 tests"
  [ testCase "placeholder" $ 1 @=? 1
  ]
