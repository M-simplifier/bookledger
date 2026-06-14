{-# LANGUAGE OverloadedStrings #-}

module BookLedger.Backup
  ( BackupResult(..)
  , backupNow
  , listBackups
  ) where

import BookLedger.Config
import qualified BookLedger.Store as Store
import Control.Exception (bracket)
import Control.Monad (forM_, when)
import qualified Data.ByteString as BS
import Data.List (sortOn)
import Data.Ord (Down(..))
import Data.Time (defaultTimeLocale, formatTime, getCurrentTime)
import Database.SQLite.Simple (close)
import System.Directory
  ( createDirectoryIfMissing
  , doesDirectoryExist
  , doesFileExist
  , getTemporaryDirectory
  , listDirectory
  , removeFile
  , renameFile
  )
import System.FilePath ((</>), takeExtension)
import System.Exit (ExitCode(..))
import System.Process (readProcess, readProcessWithExitCode)

data BackupResult = BackupResult
  { backupLatestPath :: FilePath
  , backupSnapshotPath :: FilePath
  } deriving (Eq, Show)

backupNow :: Config -> IO BackupResult
backupNow cfg = do
  now <- getCurrentTime
  let timestamp =
        formatTime defaultTimeLocale "%Y%m%d-%H%M%S" now
          <> "-"
          <> take 6 (formatTime defaultTimeLocale "%q" now)
  tempDir <- getTemporaryDirectory
  let tempSnapshot = tempDir </> ("bookledger-" <> timestamp <> ".sqlite")
  removeIfExists tempSnapshot
  bracket (Store.openDb (cfgDbPath cfg)) close $ \conn -> do
    Store.integrityCheck conn
    Store.vacuumInto conn tempSnapshot
  bracket (Store.openDb tempSnapshot) close Store.integrityCheck
  result <-
    if isWindowsDrivePath (cfgBackupDir cfg)
      then copySnapshotWindows cfg timestamp tempSnapshot
      else copySnapshotLocal cfg timestamp tempSnapshot
  removeIfExists tempSnapshot
  pure result

listBackups :: Config -> IO [FilePath]
listBackups cfg
  | isWindowsDrivePath (cfgBackupDir cfg) = listBackupsWindows cfg
  | otherwise = listBackupsLocal cfg

copySnapshotLocal :: Config -> String -> FilePath -> IO BackupResult
copySnapshotLocal cfg timestamp source = do
  let backupDir = cfgBackupDir cfg
      snapshotDir = backupDir </> "snapshots"
      latestPath = backupDir </> "latest.sqlite"
      snapshotPath = snapshotDir </> ("books-" <> timestamp <> ".sqlite")
  createDirectoryIfMissing True snapshotDir
  atomicCopy source latestPath
  atomicCopy source snapshotPath
  pruneLocal snapshotDir (cfgKeepSnapshots cfg)
  pure BackupResult
    { backupLatestPath = latestPath
    , backupSnapshotPath = snapshotPath
    }

copySnapshotWindows :: Config -> String -> FilePath -> IO BackupResult
copySnapshotWindows cfg timestamp source = do
  winSource <- wslPathToWindows source
  let backupDir = cfgBackupDir cfg
      script = unlines
        [ "param([string]$src, [string]$dir, [string]$ts, [int]$keep)"
        , "$ErrorActionPreference = 'Stop'"
        , "[Console]::OutputEncoding = [System.Text.Encoding]::UTF8"
        , "try {"
        , "  $drive = Split-Path -Qualifier $dir"
        , "  if ($drive -and -not (Test-Path -LiteralPath $drive)) {"
        , "    throw \"BookLedger backup drive is not available: $drive. Start the drive provider or update backup_dir in ~/.config/bookledger/config.toml.\""
        , "  }"
        , "  $snapDir = Join-Path $dir 'snapshots'"
        , "  New-Item -ItemType Directory -Force -Path $snapDir | Out-Null"
        , "  $latest = Join-Path $dir 'latest.sqlite'"
        , "  $latestTmp = Join-Path $dir 'latest.sqlite.tmp'"
        , "  $snapshot = Join-Path $snapDir (\"books-$ts.sqlite\")"
        , "  $snapshotTmp = \"$snapshot.tmp\""
        , "  Copy-Item -LiteralPath $src -Destination $latestTmp -Force"
        , "  Move-Item -LiteralPath $latestTmp -Destination $latest -Force"
        , "  Copy-Item -LiteralPath $src -Destination $snapshotTmp -Force"
        , "  Move-Item -LiteralPath $snapshotTmp -Destination $snapshot -Force"
        , "  Get-ChildItem -LiteralPath $snapDir -Filter 'books-*.sqlite' | Sort-Object Name -Descending | Select-Object -Skip $keep | Remove-Item -Force"
        , "} catch {"
        , "  [Console]::Error.WriteLine($_.Exception.Message)"
        , "  exit 1"
        , "}"
        ]
  (code, _out, err) <- withPowerShellScript "bookledger-backup" script $ \winScript ->
    readProcessWithExitCode
      "powershell.exe"
      ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", winScript, winSource, backupDir, timestamp, show (cfgKeepSnapshots cfg)]
      ""
  case code of
    ExitSuccess -> pure ()
    ExitFailure _ -> ioError (userError ("PowerShell backup failed: " <> trimNewline err))
  pure BackupResult
    { backupLatestPath = backupDir <> "\\latest.sqlite"
    , backupSnapshotPath = backupDir <> "\\snapshots\\books-" <> timestamp <> ".sqlite"
    }

listBackupsLocal :: Config -> IO [FilePath]
listBackupsLocal cfg = do
  let snapshotDir = cfgBackupDir cfg </> "snapshots"
  exists <- doesDirectoryExist snapshotDir
  if not exists
    then pure []
    else do
      names <- listDirectory snapshotDir
      pure
        [ snapshotDir </> name
        | name <- sortOn Down names
        , takeExtension name == ".sqlite"
        ]

listBackupsWindows :: Config -> IO [FilePath]
listBackupsWindows cfg = do
  let script = unlines
        [ "param([string]$backupDir)"
        , "$ErrorActionPreference = 'Stop'"
        , "[Console]::OutputEncoding = [System.Text.Encoding]::UTF8"
        , "try {"
        , "  $drive = Split-Path -Qualifier $backupDir"
        , "  if ($drive -and -not (Test-Path -LiteralPath $drive)) {"
        , "    throw \"BookLedger backup drive is not available: $drive. Start the drive provider or update backup_dir in ~/.config/bookledger/config.toml.\""
        , "  }"
        , "  $dir = Join-Path $backupDir 'snapshots'"
        , "  if (Test-Path -LiteralPath $dir) {"
        , "    Get-ChildItem -LiteralPath $dir -Filter 'books-*.sqlite' | Sort-Object Name -Descending | ForEach-Object { $_.FullName }"
        , "  }"
        , "} catch {"
        , "  [Console]::Error.WriteLine($_.Exception.Message)"
        , "  exit 1"
        , "}"
        ]
  (code, out, err) <- withPowerShellScript "bookledger-list-backups" script $ \winScript ->
    readProcessWithExitCode
      "powershell.exe"
      ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", winScript, cfgBackupDir cfg]
      ""
  case code of
    ExitSuccess -> pure (lines out)
    ExitFailure _ -> ioError (userError ("PowerShell backup listing failed: " <> trimNewline err))

atomicCopy :: FilePath -> FilePath -> IO ()
atomicCopy source target = do
  let tempTarget = target <> ".tmp"
  removeIfExists tempTarget
  writeCopy source tempTarget
  removeIfExists target
  renameFile tempTarget target

writeCopy :: FilePath -> FilePath -> IO ()
writeCopy source target = do
  bytes <- BS.readFile source
  BS.writeFile target bytes

pruneLocal :: FilePath -> Int -> IO ()
pruneLocal snapshotDir keep = do
  names <- listDirectory snapshotDir
  let snapshots =
        [ name
        | name <- sortOn Down names
        , takeExtension name == ".sqlite"
        ]
      stale = drop keep snapshots
  forM_ stale (removeFile . (snapshotDir </>))

removeIfExists :: FilePath -> IO ()
removeIfExists path = do
  exists <- doesFileExist path
  when exists (removeFile path)

isWindowsDrivePath :: FilePath -> Bool
isWindowsDrivePath (drive : ':' : '\\' : _) = drive `elem` ['A' .. 'Z'] || drive `elem` ['a' .. 'z']
isWindowsDrivePath (drive : ':' : '/' : _) = drive `elem` ['A' .. 'Z'] || drive `elem` ['a' .. 'z']
isWindowsDrivePath _ = False

wslPathToWindows :: FilePath -> IO FilePath
wslPathToWindows path = trimNewline <$> readProcess "wslpath" ["-w", path] ""

withPowerShellScript :: String -> String -> (FilePath -> IO a) -> IO a
withPowerShellScript stem script action =
  bracket create removeIfExists $ \scriptPath -> do
    winScript <- wslPathToWindows scriptPath
    action winScript
  where
    create = do
      tempDir <- getTemporaryDirectory
      let scriptPath = tempDir </> stem <> ".ps1"
      writeFile scriptPath script
      pure scriptPath

trimNewline :: String -> String
trimNewline = reverse . dropWhile (`elem` ['\n', '\r']) . reverse
