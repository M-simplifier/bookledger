{-# LANGUAGE OverloadedStrings #-}

module BookLedger.Backup
  ( BackupResult(..)
  , backupNow
  , listBackups
  ) where

import BookLedger.Config
import BookLedger.Domain
import BookLedger.Export
import qualified BookLedger.Store as Store
import Control.Exception (bracket)
import Control.Monad (forM_, when)
import qualified Data.ByteString as BS
import Data.List (sortOn)
import Data.Ord (Down(..))
import Data.Text (Text)
import qualified Data.Text.Encoding as TE
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
  , backupCsvPath :: FilePath
  , backupHtmlPath :: FilePath
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
      tempCsv = tempDir </> ("bookledger-" <> timestamp <> ".csv")
      tempHtml = tempDir </> ("bookledger-" <> timestamp <> ".html")
  removeIfExists tempSnapshot
  removeIfExists tempCsv
  removeIfExists tempHtml
  bracket (Store.openDb (cfgDbPath cfg)) close $ \conn -> do
    Store.initDb conn
    Store.integrityCheck conn
    Store.vacuumInto conn tempSnapshot
  bracket (Store.openDb tempSnapshot) close Store.integrityCheck
  books <- booksFromSnapshot tempSnapshot
  writeUtf8File tempCsv (renderCsv books)
  writeUtf8File tempHtml (renderHtml books)
  result <-
    if isWindowsDrivePath (cfgBackupDir cfg)
      then copySnapshotWindows cfg timestamp tempSnapshot tempCsv tempHtml
      else copySnapshotLocal cfg timestamp tempSnapshot tempCsv tempHtml
  removeIfExists tempSnapshot
  removeIfExists tempCsv
  removeIfExists tempHtml
  pure result

booksFromSnapshot :: FilePath -> IO [Book]
booksFromSnapshot path =
  bracket (Store.openDb path) close $ \conn ->
    Store.listBooks conn BookFilter
      { filterStatus = Nothing
      , filterCategory = Nothing
      , filterSeries = Nothing
      , filterSearch = Nothing
      , filterSort = SortCatalog
      }

listBackups :: Config -> IO [FilePath]
listBackups cfg
  | isWindowsDrivePath (cfgBackupDir cfg) = listBackupsWindows cfg
  | otherwise = listBackupsLocal cfg

copySnapshotLocal :: Config -> String -> FilePath -> FilePath -> FilePath -> IO BackupResult
copySnapshotLocal cfg timestamp source csvSource htmlSource = do
  let backupDir = cfgBackupDir cfg
      snapshotDir = backupDir </> "snapshots"
      latestPath = backupDir </> "latest.sqlite"
      csvPath = backupDir </> "latest.csv"
      htmlPath = backupDir </> "latest.html"
      snapshotPath = snapshotDir </> ("books-" <> timestamp <> ".sqlite")
  createDirectoryIfMissing True snapshotDir
  atomicCopy source latestPath
  atomicCopy csvSource csvPath
  atomicCopy htmlSource htmlPath
  atomicCopy source snapshotPath
  pruneLocal snapshotDir (cfgKeepSnapshots cfg)
  pure BackupResult
    { backupLatestPath = latestPath
    , backupSnapshotPath = snapshotPath
    , backupCsvPath = csvPath
    , backupHtmlPath = htmlPath
    }

copySnapshotWindows :: Config -> String -> FilePath -> FilePath -> FilePath -> IO BackupResult
copySnapshotWindows cfg timestamp source csvSource htmlSource = do
  winSource <- wslPathToWindows source
  winCsvSource <- wslPathToWindows csvSource
  winHtmlSource <- wslPathToWindows htmlSource
  let backupDir = cfgBackupDir cfg
      script = unlines
        [ "param([string]$src, [string]$csv, [string]$html, [string]$dir, [string]$ts, [int]$keep)"
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
        , "  $latestCsv = Join-Path $dir 'latest.csv'"
        , "  $latestCsvTmp = Join-Path $dir 'latest.csv.tmp'"
        , "  $latestHtml = Join-Path $dir 'latest.html'"
        , "  $latestHtmlTmp = Join-Path $dir 'latest.html.tmp'"
        , "  $snapshot = Join-Path $snapDir (\"books-$ts.sqlite\")"
        , "  $snapshotTmp = \"$snapshot.tmp\""
        , "  Copy-Item -LiteralPath $src -Destination $latestTmp -Force"
        , "  Move-Item -LiteralPath $latestTmp -Destination $latest -Force"
        , "  Copy-Item -LiteralPath $csv -Destination $latestCsvTmp -Force"
        , "  Move-Item -LiteralPath $latestCsvTmp -Destination $latestCsv -Force"
        , "  Copy-Item -LiteralPath $html -Destination $latestHtmlTmp -Force"
        , "  Move-Item -LiteralPath $latestHtmlTmp -Destination $latestHtml -Force"
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
      ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", winScript, winSource, winCsvSource, winHtmlSource, backupDir, timestamp, show (cfgKeepSnapshots cfg)]
      ""
  case code of
    ExitSuccess -> pure ()
    ExitFailure _ -> ioError (userError ("PowerShell backup failed: " <> trimNewline err))
  pure BackupResult
    { backupLatestPath = backupDir <> "\\latest.sqlite"
    , backupSnapshotPath = backupDir <> "\\snapshots\\books-" <> timestamp <> ".sqlite"
    , backupCsvPath = backupDir <> "\\latest.csv"
    , backupHtmlPath = backupDir <> "\\latest.html"
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

writeUtf8File :: FilePath -> Text -> IO ()
writeUtf8File path =
  BS.writeFile path . TE.encodeUtf8

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
