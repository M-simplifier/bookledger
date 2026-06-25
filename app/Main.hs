{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import BookLedger.Actions
import BookLedger.Backup (BackupResult(..), listBackups)
import BookLedger.Config
import BookLedger.Domain
import BookLedger.Web (runWeb)
import Data.Foldable (for_)
import qualified Data.Text as T
import Options.Applicative

data Command
  = Init
  | Add AddOptions
  | List ListOptions
  | SetStatus Int Status
  | CategoryAdd String
  | CategoryRename String String
  | CategoryList
  | SeriesAdd String
  | SeriesRename String String
  | SeriesList
  | Backup
  | Backups
  | Web Int

data AddOptions = AddOptions
  { addTitle :: String
  , addAuthor :: String
  , addStatus :: Status
  , addCategory :: String
  , addSeries :: Maybe String
  , addVolume :: Maybe Double
  , addMemo :: String
  , addUrl :: Maybe String
  }

data ListOptions = ListOptions
  { listStatus :: Maybe Status
  , listCategory :: Maybe String
  , listSeries :: Maybe String
  , listSearch :: Maybe String
  }

main :: IO ()
main = do
  selectedCommand <- execParser parserInfo
  cfg <- loadConfig
  runCommand cfg selectedCommand

runCommand :: Config -> Command -> IO ()
runCommand cfg selectedCommand =
  case selectedCommand of
    Init -> do
      initialize cfg
      putStrLn ("initialized: " <> cfgDbPath cfg)
    Add opts -> do
      (bookId, warning) <- addBookAction cfg (newBookFromOptions opts)
      putStrLn ("added book #" <> show bookId)
      printWarning warning
    List opts -> do
      books <- listBooksAction cfg (filterFromOptions opts)
      mapM_ printBook books
    SetStatus bookId status -> do
      warning <- setStatusAction cfg bookId status
      putStrLn ("updated book #" <> show bookId <> " -> " <> T.unpack (statusText status))
      printWarning warning
    CategoryAdd name -> do
      warning <- addCategoryAction cfg name
      putStrLn ("added category: " <> name)
      printWarning warning
    CategoryRename old new -> do
      warning <- renameCategoryAction cfg old new
      putStrLn ("renamed category: " <> old <> " -> " <> new)
      printWarning warning
    CategoryList ->
      listCategoriesAction cfg >>= mapM_ putStrLn
    SeriesAdd title -> do
      warning <- addSeriesAction cfg title
      putStrLn ("added series: " <> title)
      printWarning warning
    SeriesRename old new -> do
      warning <- renameSeriesAction cfg old new
      putStrLn ("renamed series: " <> old <> " -> " <> new)
      printWarning warning
    SeriesList ->
      listSeriesAction cfg >>= mapM_ putStrLn
    Backup -> do
      result <- backupAction cfg
      putStrLn ("latest: " <> backupLatestPath result)
      putStrLn ("snapshot: " <> backupSnapshotPath result)
      putStrLn ("csv: " <> backupCsvPath result)
      putStrLn ("html: " <> backupHtmlPath result)
    Backups ->
      listBackups cfg >>= mapM_ putStrLn
    Web port ->
      runWeb cfg port

parserInfo :: ParserInfo Command
parserInfo =
  info (helper <*> commandParser)
    ( fullDesc
    <> progDesc "Small local-first book ledger"
    )

commandParser :: Parser Command
commandParser =
  hsubparser
    ( command "init" (info (pure Init) (progDesc "Initialize the SQLite database"))
    <> command "add" (info (Add <$> addOptions) (progDesc "Add a book"))
    <> command "list" (info (List <$> listOptions) (progDesc "List books"))
    <> command "set-status" (info setStatusParser (progDesc "Set a book status"))
    <> command "category" (info categoryParser (progDesc "Manage categories"))
    <> command "series" (info seriesParser (progDesc "Manage series"))
    <> command "backup" (info (pure Backup) (progDesc "Create a SQLite snapshot backup"))
    <> command "backups" (info (pure Backups) (progDesc "List snapshot backups"))
    <> command "web" (info (Web <$> portOption) (progDesc "Run the local web UI"))
    )

addOptions :: Parser AddOptions
addOptions =
  AddOptions
    <$> strArgument (metavar "TITLE")
    <*> strOption (long "author" <> metavar "AUTHOR")
    <*> option statusReader (long "status" <> value Unread <> showDefaultWith (T.unpack . statusText) <> metavar "STATUS")
    <*> strOption (long "category" <> metavar "CATEGORY")
    <*> optional (strOption (long "series" <> metavar "SERIES"))
    <*> optional (option auto (long "volume" <> metavar "NUMBER"))
    <*> strOption (long "memo" <> value "" <> metavar "TEXT")
    <*> optional (strOption (long "url" <> metavar "URL"))

listOptions :: Parser ListOptions
listOptions =
  ListOptions
    <$> optional (option statusReader (long "status" <> metavar "STATUS"))
    <*> optional (strOption (long "category" <> metavar "CATEGORY"))
    <*> optional (strOption (long "series" <> metavar "SERIES"))
    <*> optional (strOption (long "search" <> short 's' <> metavar "TEXT"))

setStatusParser :: Parser Command
setStatusParser =
  SetStatus
    <$> argument auto (metavar "ID")
    <*> argument statusReader (metavar "STATUS")

categoryParser :: Parser Command
categoryParser =
  hsubparser
    ( command "add" (info (CategoryAdd <$> strArgument (metavar "NAME")) (progDesc "Add a category"))
    <> command "rename" (info (CategoryRename <$> strArgument (metavar "OLD") <*> strArgument (metavar "NEW")) (progDesc "Rename a category"))
    <> command "list" (info (pure CategoryList) (progDesc "List categories"))
    )

seriesParser :: Parser Command
seriesParser =
  hsubparser
    ( command "add" (info (SeriesAdd <$> strArgument (metavar "TITLE")) (progDesc "Add a series"))
    <> command "rename" (info (SeriesRename <$> strArgument (metavar "OLD") <*> strArgument (metavar "NEW")) (progDesc "Rename a series"))
    <> command "list" (info (pure SeriesList) (progDesc "List series"))
    )

portOption :: Parser Int
portOption =
  option auto (long "port" <> value 8765 <> showDefault <> metavar "PORT")

statusReader :: ReadM Status
statusReader =
  eitherReader $ \rawValue ->
    maybe (Left ("unknown status: " <> rawValue)) Right (parseStatus (T.pack rawValue))

newBookFromOptions :: AddOptions -> NewBook
newBookFromOptions opts =
  NewBook
    { newTitle = T.pack (addTitle opts)
    , newAuthor = T.pack (addAuthor opts)
    , newStatus = addStatus opts
    , newCategory = T.pack (addCategory opts)
    , newSeries = T.pack <$> addSeries opts
    , newVolumeNo = addVolume opts
    , newMemo = T.pack (addMemo opts)
    , newUrl = T.pack <$> addUrl opts
    }

filterFromOptions :: ListOptions -> BookFilter
filterFromOptions opts =
  BookFilter
    { filterStatus = listStatus opts
    , filterCategory = T.pack <$> listCategory opts
    , filterSeries = T.pack <$> listSeries opts
    , filterSearch = T.pack <$> listSearch opts
    , filterSort = SortCatalog
    }

printBook :: Book -> IO ()
printBook book =
  putStrLn (unwords
    [ "#" <> show (bookId book)
    , T.unpack (bookTitle book)
    , "[" <> T.unpack (statusLabel (bookStatus book)) <> "]"
    , T.unpack (bookAuthor book)
    , T.unpack (bookCategory book)
    , maybe "" T.unpack (bookSeries book)
    , maybe "" show (bookVolumeNo book)
    ])

printWarning :: Maybe String -> IO ()
printWarning warning =
  for_ warning $ \message -> putStrLn ("warning: " <> message)
