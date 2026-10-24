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
import Control.Monad (filterM, forM_, unless, when)
import qualified Data.ByteString as BS
import Data.List (sortOn)
import Data.Maybe (isJust)
import Data.Ord (Down(..))
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Time (UTCTime, defaultTimeLocale, formatTime, getCurrentTime, parseTimeM)
import Database.SQLite.Simple (close)
import System.Directory
  ( copyFile
  , createDirectoryIfMissing
  , doesDirectoryExist
  , doesFileExist
  , doesPathExist
  , listDirectory
  , pathIsSymbolicLink
  , removeFile
  , renameFile
  )
import System.FilePath ((</>))
import System.Exit (ExitCode(..))
import System.IO.Temp (withSystemTempDirectory, withTempDirectory)
import System.Process (readProcess, readProcessWithExitCode)

data BackupResult = BackupResult
  { backupLatestPath :: FilePath
  , backupSnapshotPath :: FilePath
  , backupCsvPath :: FilePath
  , backupHtmlPath :: FilePath
  } deriving (Eq, Show)

backupNow :: Config -> IO BackupResult
backupNow cfg = do
  sourceExists <- doesFileExist (cfgDbPath cfg)
  unless sourceExists $
    ioError (userError ("book ledger does not exist: " <> cfgDbPath cfg))
  now <- getCurrentTime
  let timestamp =
        formatTime defaultTimeLocale "%Y%m%d-%H%M%S" now
          <> "-"
          <> take 6 (formatTime defaultTimeLocale "%q" now)
  withSystemTempDirectory "bookledger-backup-" $ \workDir -> do
    let tempSnapshot = workDir </> "books.sqlite"
        tempCsv = workDir </> "books.csv"
        tempHtml = workDir </> "books.html"
    bracket (Store.openDb (cfgDbPath cfg)) close $ \conn -> do
      Store.initDb conn
      Store.integrityCheck conn
      Store.vacuumInto conn tempSnapshot
    bracket (Store.openDb tempSnapshot) close Store.integrityCheck
    books <- booksFromSnapshot tempSnapshot
    writeUtf8File tempCsv (renderCsv books)
    writeUtf8File tempHtml (renderHtmlAt now books)
    if isWindowsDrivePath (cfgBackupDir cfg)
      then copySnapshotWindows cfg timestamp tempSnapshot tempCsv tempHtml
      else copySnapshotLocal cfg timestamp tempSnapshot tempCsv tempHtml

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
      publications =
        [ (source, "snapshot.sqlite", snapshotPath)
        , (csvSource, "latest.csv", csvPath)
        , (htmlSource, "latest.html", htmlPath)
        , (source, "latest.sqlite", latestPath)
        ]
  createDirectoryIfMissing True snapshotDir
  snapshotExists <- doesPathExist snapshotPath
  when snapshotExists (ioError (userError ("backup snapshot already exists: " <> snapshotPath)))
  forM_ publications $ \(_, _, target) -> do
    isDirectory <- doesDirectoryExist target
    when isDirectory (ioError (userError ("backup destination is a directory: " <> target)))
  withTempDirectory backupDir ".bookledger-publish-" $ \stagingDir -> do
    forM_ publications $ \(input, stagedName, _) -> copyFile input (stagingDir </> stagedName)
    -- Keep a restore point before replacing the individually atomic latest files.
    forM_ publications $ \(_, stagedName, target) -> renameFile (stagingDir </> stagedName) target
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
        , managedSnapshotPowerShell
        , "function Publish-File([string]$source, [string]$target) {"
        , "  if ([System.IO.File]::Exists($target)) {"
        , "    $previous = Join-Path $stageDir ('previous-' + [System.IO.Path]::GetFileName($target))"
        , "    [System.IO.File]::Replace($source, $target, $previous)"
        , "  }"
        , "  else { [System.IO.File]::Move($source, $target) }"
        , "}"
        , "$stageDir = $null"
        , "$staged = @()"
        , "try {"
        , "  $drive = Split-Path -Qualifier $dir"
        , "  if ($drive -and -not (Test-Path -LiteralPath $drive)) {"
        , "    throw \"BookLedger backup drive is not available: $drive. Start the drive provider or update backup_dir in ~/.config/bookledger/config.toml.\""
        , "  }"
        , "  $snapDir = Join-Path $dir 'snapshots'"
        , "  New-Item -ItemType Directory -Force -Path $snapDir | Out-Null"
        , "  $latest = Join-Path $dir 'latest.sqlite'"
        , "  $latestCsv = Join-Path $dir 'latest.csv'"
        , "  $latestHtml = Join-Path $dir 'latest.html'"
        , "  $snapshot = Join-Path $snapDir (\"books-$ts.sqlite\")"
        , "  if (Test-Path -LiteralPath $snapshot) { throw \"Backup snapshot already exists: $snapshot\" }"
        , "  foreach ($target in @($latest, $latestCsv, $latestHtml)) {"
        , "    if (Test-Path -LiteralPath $target -PathType Container) { throw \"Backup destination is a directory: $target\" }"
        , "  }"
        , "  $stageDir = Join-Path $dir ('.bookledger-publish-' + [Guid]::NewGuid().ToString('N'))"
        , "  [System.IO.Directory]::CreateDirectory($stageDir) | Out-Null"
        , "  $staged = @('snapshot.sqlite', 'latest.csv', 'latest.html', 'latest.sqlite', 'previous-latest.csv', 'previous-latest.html', 'previous-latest.sqlite') | ForEach-Object { Join-Path $stageDir $_ }"
        , "  Copy-Item -LiteralPath $src -Destination $staged[0]"
        , "  Copy-Item -LiteralPath $csv -Destination $staged[1]"
        , "  Copy-Item -LiteralPath $html -Destination $staged[2]"
        , "  Copy-Item -LiteralPath $src -Destination $staged[3]"
        , "  [System.IO.File]::Move($staged[0], $snapshot)"
        , "  Publish-File $staged[1] $latestCsv"
        , "  Publish-File $staged[2] $latestHtml"
        , "  Publish-File $staged[3] $latest"
        , "  Get-ChildItem -LiteralPath $snapDir -File | Where-Object { Test-ManagedSnapshot $_ } | Sort-Object Name -Descending | Select-Object -Skip ([Math]::Max(1, $keep)) | ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force }"
        , "} catch {"
        , "  [Console]::Error.WriteLine($_.Exception.Message)"
        , "  exit 1"
        , "} finally {"
        , "  foreach ($path in $staged) { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force } }"
        , "  if ($stageDir -and (Test-Path -LiteralPath $stageDir)) { Remove-Item -LiteralPath $stageDir -Force }"
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
      map (snapshotDir </>) <$> managedSnapshotsLocal snapshotDir

listBackupsWindows :: Config -> IO [FilePath]
listBackupsWindows cfg = do
  let script = unlines
        [ "param([string]$backupDir)"
        , "$ErrorActionPreference = 'Stop'"
        , "[Console]::OutputEncoding = [System.Text.Encoding]::UTF8"
        , managedSnapshotPowerShell
        , "try {"
        , "  $drive = Split-Path -Qualifier $backupDir"
        , "  if ($drive -and -not (Test-Path -LiteralPath $drive)) {"
        , "    throw \"BookLedger backup drive is not available: $drive. Start the drive provider or update backup_dir in ~/.config/bookledger/config.toml.\""
        , "  }"
        , "  $dir = Join-Path $backupDir 'snapshots'"
        , "  if (Test-Path -LiteralPath $dir) {"
        , "    Get-ChildItem -LiteralPath $dir -File | Where-Object { Test-ManagedSnapshot $_ } | Sort-Object Name -Descending | ForEach-Object { $_.FullName }"
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
    ExitSuccess -> pure (map trimNewline (lines out))
    ExitFailure _ -> ioError (userError ("PowerShell backup listing failed: " <> trimNewline err))

writeUtf8File :: FilePath -> Text -> IO ()
writeUtf8File path =
  BS.writeFile path . TE.encodeUtf8

pruneLocal :: FilePath -> Int -> IO ()
pruneLocal snapshotDir keep = do
  snapshots <- managedSnapshotsLocal snapshotDir
  forM_ (drop (max 1 keep) snapshots) (removeFile . (snapshotDir </>))

managedSnapshotsLocal :: FilePath -> IO [FilePath]
managedSnapshotsLocal snapshotDir = do
  names <- listDirectory snapshotDir
  snapshots <- filterM isSnapshot names
  pure (sortOn Down snapshots)
 where
  isSnapshot name
    | not (isManagedSnapshot name) = pure False
    | otherwise = do
        let path = snapshotDir </> name
        isFile <- doesFileExist path
        isLink <- pathIsSymbolicLink path
        pure (isFile && not isLink)

isManagedSnapshot :: FilePath -> Bool
isManagedSnapshot name =
  case T.stripPrefix "books-" (T.pack name) >>= T.stripSuffix ".sqlite" of
    Just timestamp -> case T.splitOn "-" timestamp of
      [date, clock, fraction] ->
        map T.length [date, clock, fraction] == [8, 6, 6]
          && all (T.all (\digit -> digit >= '0' && digit <= '9')) [date, clock, fraction]
          && isJust (parseTimeM True defaultTimeLocale "%Y%m%d-%H%M%S" (T.unpack (date <> "-" <> clock)) :: Maybe UTCTime)
      _ -> False
    Nothing -> False

managedSnapshotPowerShell :: String
managedSnapshotPowerShell = unlines
  [ "function Test-ManagedSnapshot($item) {"
  , "  if ($item.Name -notmatch '^books-[0-9]{8}-[0-9]{6}-[0-9]{6}\\.sqlite$') { return $false }"
  , "  if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { return $false }"
  , "  $parsed = [DateTime]::MinValue"
  , "  return [DateTime]::TryParseExact($item.Name.Substring(6, 15), 'yyyyMMdd-HHmmss', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$parsed)"
  , "}"
  ]

isWindowsDrivePath :: FilePath -> Bool
isWindowsDrivePath (drive : ':' : '\\' : _) = drive `elem` ['A' .. 'Z'] || drive `elem` ['a' .. 'z']
isWindowsDrivePath (drive : ':' : '/' : _) = drive `elem` ['A' .. 'Z'] || drive `elem` ['a' .. 'z']
isWindowsDrivePath _ = False

wslPathToWindows :: FilePath -> IO FilePath
wslPathToWindows path = trimNewline <$> readProcess "wslpath" ["-w", path] ""

withPowerShellScript :: String -> String -> (FilePath -> IO a) -> IO a
withPowerShellScript stem script action =
  withSystemTempDirectory stem $ \workDir -> do
    let scriptPath = workDir </> "backup.ps1"
    writeFile scriptPath script
    winScript <- wslPathToWindows scriptPath
    action winScript

trimNewline :: String -> String
trimNewline = reverse . dropWhile (`elem` ['\n', '\r']) . reverse
