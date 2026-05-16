{-# LANGUAGE TemplateHaskell #-}

module Graphics.Haskan.Vulkan.DescriptorSetLayout.TH
  ( descriptorSetLayoutBindings,
  )
where

import Control.Monad (when)
import Language.Haskell.TH

-- | Generate a list of `layoutBinding` calls from a FIR shader definitions type.
--
-- Usage:
--   $(descriptorSetLayoutBindings (\b -> [e| if b == 4 then vkVertexFragmentBits else vkFragmentBit |]) Nothing ''CloudFragmentDefs)
--
-- The first argument is a function from binding number (as a TH expression) to
-- stage flags (as a TH expression). This allows per-binding stage flags.
--
-- Only processes Global-like entries (Texture*, Image*, Uniform, StorageBuffer).
-- Skips Input, Output, EntryPoint, PushConstant.
descriptorSetLayoutBindings :: (Integer -> Q Exp) -> Maybe Integer -> Name -> Q Exp
descriptorSetLayoutBindings stageFlagsFn mBindlessCount defsName = do
  info <- reify defsName
  defsType <- case info of
    TyConI (TySynD _ _ t) -> pure t
    _ -> fail $ show defsName ++ " is not a type synonym"
  entries <- extractList defsType
  bindings <- concat <$> mapM (processEntry stageFlagsFn mBindlessCount) entries
  listE (map pure bindings)

-- Extract elements from a promoted type-level list
extractList :: Type -> Q [Type]
extractList ty = go ty
  where
    go (AppT (AppT PromotedConsT hd) tl) = (hd :) <$> go tl
    go (SigT PromotedNilT _) = pure []
    go (SigT t _) = go t
    go PromotedNilT = pure []
    go t = fail $ "Expected a promoted list, got: " ++ pprint t

-- Each entry is: name ':-> defType
processEntry :: (Integer -> Q Exp) -> Maybe Integer -> Type -> Q [Exp]
processEntry stageFlagsFn mBindlessCount entry =
  case entry of
    AppT (AppT (PromotedT mapArrow) _nameLit) defType
      | nameBase mapArrow == ":->" -> processDefType stageFlagsFn mBindlessCount defType
    AppT (AppT (ConT mapArrow) _nameLit) defType
      | nameBase mapArrow == ":->" -> processDefType stageFlagsFn mBindlessCount defType
    _ -> fail $ "Expected (name ':-> def), got: " ++ pprint entry

processDefType :: (Integer -> Q Exp) -> Maybe Integer -> Type -> Q [Exp]
processDefType stageFlagsFn mBindlessCount ty =
  case ty of
    -- Synonyms with two arguments: decorations + value type
    AppT (AppT (ConT conName) decs) _valType
      | isTextureSyn conName -> do
          (binding, _ds) <- extractDecorations decs
          stageFlags <- stageFlagsFn binding
          let count =
                if isBindlessSyn conName
                  then maybe 1 id mBindlessCount
                  else 1
              descType = if nameBase conName == "StorageImage" then storageImage else combinedImageSampler
          pure [mkLayoutBindingExp binding count descType stageFlags]
      | nameBase conName == "Uniform" -> do
          (binding, _ds) <- extractDecorations decs
          stageFlags <- stageFlagsFn binding
          pure [mkLayoutBindingExp binding count uniformBuffer stageFlags]
      | nameBase conName == "StorageBuffer" -> do
          (binding, _ds) <- extractDecorations decs
          stageFlags <- stageFlagsFn binding
          pure [mkLayoutBindingExp binding count storageBuffer stageFlags]
      | nameBase conName == "Input" || nameBase conName == "Output" || nameBase conName == "PushConstant" ->
          pure [] -- not descriptor bindings
      | otherwise -> fail $ "Unknown definition type: " ++ show conName
    -- Three-argument texture synonyms (Texture2D')
    AppT (AppT (AppT (ConT conName) decs) _sampledFmt) _imageFmt
      | isTextureSyn conName -> do
          (binding, _ds) <- extractDecorations decs
          stageFlags <- stageFlagsFn binding
          let count =
                if isBindlessSyn conName
                  then maybe 1 id mBindlessCount
                  else 1
          pure [mkLayoutBindingExp binding count combinedImageSampler stageFlags]

    -- EntryPoint has a different shape
    AppT (AppT (PromotedT entryPoint) _) _
      | nameBase entryPoint == "EntryPoint" -> pure []
    _ ->
      fail $ "Unexpected definition type: " ++ show ty ++ " (pprint: " ++ pprint ty ++ ")"
  where
    count = 1

isTextureSyn :: Name -> Bool
isTextureSyn n =
  nameBase n
    `elem` [ "Texture1D",
             "Texture2D",
             "Texture2D'",
             "Texture3D",
             "TextureCube",
             "Texture1DArray",
             "Texture2DArray",
             "Texture3DArray",
             "Texture",
             "StorageImage"
           ]

isBindlessSyn :: Name -> Bool
isBindlessSyn n = nameBase n == "BindlessTexture2D"

extractDecorations :: Type -> Q (Integer, Integer)
extractDecorations decs = do
  let go (AppT (AppT PromotedConsT (AppT (PromotedT dec) (LitT (NumTyLit n)))) tl)
        | nameBase dec == "Binding" = first (const n) <$> go tl
        | nameBase dec == "DescriptorSet" = second (const n) <$> go tl
        | otherwise = go tl
      go (SigT PromotedNilT _) = pure (-1, -1)
      go PromotedNilT = pure (-1, -1)
      go (SigT t _) = go t
      go t = fail $ "Expected decoration list, got: " ++ pprint t
      first f (a, b) = (f a, b)
      second f (a, b) = (a, f b)
  (b, ds) <- go decs
  when (b < 0) $ fail "Missing Binding decoration"
  when (ds < 0) $ fail "Missing DescriptorSet decoration"
  pure (b, ds)

-- Emit: layoutBinding binding count descriptorType stageFlags
mkLayoutBindingExp :: Integer -> Integer -> Exp -> Exp -> Exp
mkLayoutBindingExp binding count descriptorType stageFlags =
  AppE
    ( AppE
        ( AppE
            ( AppE
                (VarE (mkName "layoutBinding"))
                (LitE (IntegerL binding))
            )
            (LitE (IntegerL count))
        )
        descriptorType
    )
    stageFlags

combinedImageSampler :: Exp
combinedImageSampler = VarE (mkName "vkCombinedImageSampler")

uniformBuffer :: Exp
uniformBuffer = VarE (mkName "vkUniformBuffer")

storageBuffer :: Exp
storageBuffer = VarE (mkName "vkStorageBuffer")

storageImage :: Exp
storageImage = VarE (mkName "vkStorageImage")
