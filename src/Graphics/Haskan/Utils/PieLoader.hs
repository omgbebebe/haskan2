module Graphics.Haskan.Utils.PieLoader where

-- base
import Control.Monad.IO.Class (MonadIO, liftIO)
import Data.Functor (void)
import Data.Maybe (fromMaybe)
import Data.Void

-- linear
import Linear (V2(..), V3(..))

-- megaparsec
import Text.Megaparsec
import Text.Megaparsec.Char
import Text.Megaparsec.Char.Lexer hiding (space)

-- scientific
import Data.Scientific (toRealFloat)

-- text
import Data.Text (Text)
import qualified Data.Text.IO as T

type Vertex = V3 Float
data Triangle =
  Triangle { indices :: V3 Int
           , uvs :: V3 (V2 Float)
           } deriving (Eq, Show)

data Animation =
  Animation { animTime :: Int
            , cycleCount :: Int
            , frameCount :: Int
            , frames :: [AnimationFrame]
            } deriving (Eq, Show)

data AnimationFrame =
  AnimationFrame { animPos :: V3 Int
                 , animRot :: V3 Int
                 , animScale :: V3 Int
                 } deriving (Eq, Show)

type Connector = V3 Float

data PieLevel =
  PieLevel { vertices :: [Vertex]
           , triangles :: [Triangle]
           , animation :: Maybe Animation
           , connectors :: [Connector]
           } deriving (Eq, Show)

data Pie =
  Pie { pieVersion :: Int
      , textureName :: Text
      , levels :: [PieLevel]
      } deriving (Eq, Show)

type Parser = Parsec Void Text

parsePie :: (MonadFail m, MonadIO m) => FilePath -> m Pie
parsePie path = do
  fileData <- liftIO (T.readFile path)
  case runParser pieP path fileData of
    Left e -> fail ("failed to parse '" <> show e <> "'")
    Right p -> pure p

pieP :: Parser Pie
pieP = do
  _ <- string "PIE" <* skipSpaces
  pieVersion <- intP <* newline
  _ <- string "TYPE" <* skipSpaces
  _type <- intP <* newline
  _ <- string "TEXTURE" <* skipSpaces
  _tn <- intP
  textureName <- takeWhile1P (Just "Texture name") (\x -> x /= ' ') <* skipSpaces
  _ <- intP
  _ <- intP <* newline
  _ <- string "LEVELS" <* skipSpaces
  _levelCount <- intP <* newline
  pieLevels <- some (levelP pieVersion)
  pure $ Pie pieVersion textureName pieLevels

levelP :: Int -> Parser PieLevel
levelP pieVersion = do
  _ <- string "LEVEL" <* skipSpaces
  _n <- intP <* newline
  points <- label "points" $ takeMany "POINTS" pointP
  polygons <- label "polygons" $ takeMany "POLYGONS" (polygonP pieVersion)
  connectors <- optional $ label "connectors" $ takeMany "CONNECTORS" connectorP
  animation <- optional (label "animation" animationP)
  pure (PieLevel points polygons animation (fromMaybe [] connectors))

takeMany :: Text -> Parser a -> Parser [a]
takeMany s p = do
  _ <- string s <* skipSpaces
  _n <- intP <* newline
  some p

connectorP :: Parser Connector
connectorP = tab *> v3FloatP <* newline

pointP :: Parser Vertex
pointP = tab *> fmap (*0.1) v3FloatP <* newline

polygonP :: Int -> Parser Triangle
polygonP pieVersion = do
  void tab
  _flags <- intP
  _vertexCount <- intP
  indices <- v3IntP
  uv1 <- v2FloatP
  uv2 <- v2FloatP
  uv3 <- v2FloatP
  (void newline <|> eof)
  case pieVersion of
    3 -> pure $ Triangle indices (V3 uv1 uv2 uv3)
    2 -> pure $ Triangle indices (V3 (uv1/256.0) (uv2/256.0) (uv3/256.0))

animationP :: Parser Animation
animationP = do
  void (string "ANIMOBJECT") <* skipSpaces
  time <- intP <* skipSpaces
  cycles <- intP <* skipSpaces
  frames <- intP <* newline
  animFrames <- many animationFrameP
  pure $ Animation time cycles frames animFrames

animationFrameP :: Parser AnimationFrame
animationFrameP = do
  void tab
  _frameIndex <- uintP
  AnimationFrame
    <$> v3IntP
    <*> v3IntP
    <*> v3IntP
  <* (void newline <|> eof)

skipSpaces :: Parser ()
skipSpaces = skipMany separatorChar

floatP :: Parser Float
floatP = toRealFloat <$> signed skipSpaces (lexeme skipSpaces scientific)

intP :: Parser Int
intP = signed skipSpaces uintP

uintP :: Parser Int
uintP = lexeme skipSpaces decimal

v3IntP :: Parser (V3 Int)
v3IntP =
  V3 <$> intP <*> intP <*> intP

v3FloatP :: Parser (V3 Float)
v3FloatP =
  V3 <$> floatP <*> floatP <*> floatP

v2FloatP :: Parser (V2 Float)
v2FloatP =
  V2 <$> floatP <*> floatP
