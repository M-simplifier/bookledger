{-# LANGUAGE OverloadedStrings #-}

module BookLedger.Config
  ( Config(..)
  , loadConfig
  , defaultConfigPath
  ) where

import Data.Char (isSpace, toLower)
import Data.Maybe (fromMaybe)
import System.Directory (getHomeDirectory)
import qualified System.Directory
import System.Environment (lookupEnv)
import System.FilePath ((</>))

data Config = Config
  { cfgDbPath :: FilePath
  , cfgBackupDir :: FilePath
  , cfgKeepSnapshots :: Int
  , cfgBackupAfterWrite :: Bool
  } deriving (Eq, Show)

defaultConfigPath :: IO FilePath
defaultConfigPath = do
  home <- getHomeDirectory
  pure (home </> ".config" </> "bookledger" </> "config.toml")

loadConfig :: IO Config
loadConfig = do
  home <- getHomeDirectory
  envPath <- lookupEnv "BOOKLEDGER_CONFIG"
  path <- maybe defaultConfigPath pure envPath
  raw <- readFileIfExists path
  let pairs = parsePairs raw
      pick key = lookup key pairs
  dbPath <- expandHome home (fromMaybe "~/.local/share/bookledger/books.sqlite" (pick "db_path"))
  backupDir <- expandHome home (fromMaybe "~/BookLedgerBackups" (pick "backup_dir"))
  let keepSnapshots = maybe 30 readInt (pick "keep_snapshots")
      backupAfterWrite = maybe True readBool (pick "backup_after_write")
  pure Config
    { cfgDbPath = dbPath
    , cfgBackupDir = backupDir
    , cfgKeepSnapshots = max 1 keepSnapshots
    , cfgBackupAfterWrite = backupAfterWrite
    }

readFileIfExists :: FilePath -> IO String
readFileIfExists path = do
  exists <- System.Directory.doesFileExist path
  if exists then readFile path else pure ""

parsePairs :: String -> [(String, String)]
parsePairs =
  mapMaybeLine parseLine . lines
 where
  mapMaybeLine f = foldr (\x acc -> maybe acc (: acc) (f x)) []

parseLine :: String -> Maybe (String, String)
parseLine line =
  case break (== '=') (takeWhile (/= '#') line) of
    (key, '=' : value) ->
      let k = trim key
          v = stripQuotes (trim value)
      in if null k then Nothing else Just (k, v)
    _ -> Nothing

stripQuotes :: String -> String
stripQuotes value =
  case value of
    '\'' : rest | lastMay rest == Just '\'' -> init rest
    '"' : rest | lastMay rest == Just '"' -> init rest
    _ -> value

lastMay :: [a] -> Maybe a
lastMay [] = Nothing
lastMay xs = Just (last xs)

trim :: String -> String
trim = dropWhileEnd isSpace . dropWhile isSpace

dropWhileEnd :: (a -> Bool) -> [a] -> [a]
dropWhileEnd p = reverse . dropWhile p . reverse

readInt :: String -> Int
readInt value =
  case reads value of
    [(n, "")] -> n
    _ -> 30

readBool :: String -> Bool
readBool value =
  case map toLower value of
    "true" -> True
    "false" -> False
    "yes" -> True
    "no" -> False
    "1" -> True
    "0" -> False
    _ -> True

expandHome :: FilePath -> FilePath -> IO FilePath
expandHome home path =
  case path of
    '~' : '/' : rest -> pure (home </> rest)
    "~" -> pure home
    _ -> pure path
