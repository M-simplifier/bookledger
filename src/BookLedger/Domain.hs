{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}

module BookLedger.Domain
  ( Status(..)
  , allStatuses
  , parseStatus
  , statusText
  , statusLabel
  , BookSort(..)
  , parseBookSort
  , Book(..)
  , NewBook(..)
  , BookUpdate(..)
  , BookUpdateBatch(..)
  , BookFilter(..)
  ) where

import Data.Aeson (FromJSON(..), ToJSON(..), Value(String), object, withObject, withText, (.=), (.:), (.:?))
import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as NE
import Data.Text (Text)
import qualified Data.Text as T
import GHC.Generics (Generic)

data Status
  = Planned
  | Unread
  | Reading
  | Finished
  | Disposed
  deriving (Eq, Ord, Show, Read, Enum, Bounded, Generic)

allStatuses :: [Status]
allStatuses = [Planned, Unread, Reading, Finished, Disposed]

statusText :: Status -> Text
statusText status =
  case status of
    Planned -> "planned"
    Unread -> "unread"
    Reading -> "reading"
    Finished -> "finished"
    Disposed -> "disposed"

statusLabel :: Status -> Text
statusLabel status =
  case status of
    Planned -> "購入予定"
    Unread -> "未読"
    Reading -> "読書中"
    Finished -> "読了"
    Disposed -> "処分"

parseStatus :: Text -> Maybe Status
parseStatus value =
  case T.toLower (T.strip value) of
    "planned" -> Just Planned
    "unread" -> Just Unread
    "reading" -> Just Reading
    "finished" -> Just Finished
    "disposed" -> Just Disposed
    "購入予定" -> Just Planned
    "未読" -> Just Unread
    "読書中" -> Just Reading
    "読了" -> Just Finished
    "処分" -> Just Disposed
    _ -> Nothing

instance ToJSON Status where
  toJSON = String . statusText

instance FromJSON Status where
  parseJSON = withText "Status" $ \value ->
    maybe (fail ("unknown status: " <> T.unpack value)) pure (parseStatus value)

data BookSort
  = SortActive
  | SortUpdated
  | SortCatalog
  deriving (Eq, Show, Read, Generic)

parseBookSort :: Text -> Maybe BookSort
parseBookSort value =
  case T.toLower (T.strip value) of
    "active" -> Just SortActive
    "updated" -> Just SortUpdated
    "catalog" -> Just SortCatalog
    _ -> Nothing

data Book = Book
  { bookId :: Int
  , bookTitle :: Text
  , bookAuthor :: Text
  , bookStatus :: Status
  , bookCategory :: Text
  , bookSeries :: Maybe Text
  , bookVolumeNo :: Maybe Double
  , bookMemo :: Text
  , bookUrl :: Maybe Text
  , bookCreatedAt :: Text
  , bookUpdatedAt :: Text
  } deriving (Eq, Show, Generic)

instance ToJSON Book where
  toJSON book = object
    [ "id" .= bookId book
    , "title" .= bookTitle book
    , "author" .= bookAuthor book
    , "status" .= bookStatus book
    , "statusLabel" .= statusLabel (bookStatus book)
    , "category" .= bookCategory book
    , "series" .= bookSeries book
    , "volumeNo" .= bookVolumeNo book
    , "memo" .= bookMemo book
    , "url" .= bookUrl book
    , "createdAt" .= bookCreatedAt book
    , "updatedAt" .= bookUpdatedAt book
    ]

data NewBook = NewBook
  { newTitle :: Text
  , newAuthor :: Text
  , newStatus :: Status
  , newCategory :: Text
  , newSeries :: Maybe Text
  , newVolumeNo :: Maybe Double
  , newMemo :: Text
  , newUrl :: Maybe Text
  } deriving (Eq, Show, Generic)

instance FromJSON NewBook where
  parseJSON = withObject "NewBook" $ \obj -> do
    title <- obj .: "title"
    author <- obj .: "author"
    status <- obj .:? "status" >>= pure . maybe Unread id
    category <- obj .: "category"
    series <- obj .:? "series"
    volumeNo <- obj .:? "volumeNo"
    memo <- obj .:? "memo" >>= pure . maybe "" id
    url <- obj .:? "url"
    pure NewBook
      { newTitle = title
      , newAuthor = author
      , newStatus = status
      , newCategory = category
      , newSeries = normalizeMaybe series
      , newVolumeNo = volumeNo
      , newMemo = memo
      , newUrl = normalizeMaybe url
      }

data BookUpdate = BookUpdate
  { bookUpdateId :: Int
  , bookUpdateTitle :: Text
  , bookUpdateAuthor :: Text
  , bookUpdateStatus :: Status
  , bookUpdateCategory :: Text
  , bookUpdateSeries :: Maybe Text
  , bookUpdateVolumeNo :: Maybe Double
  , bookUpdateMemo :: Text
  , bookUpdateUrl :: Maybe Text
  } deriving (Eq, Show, Generic)

instance FromJSON BookUpdate where
  parseJSON = withObject "BookUpdate" $ \obj -> do
    bookId <- obj .: "id"
    title <- obj .: "title"
    author <- obj .: "author"
    status <- obj .: "status"
    category <- obj .: "category"
    series <- obj .:? "series"
    volumeNo <- obj .:? "volumeNo"
    memo <- obj .:? "memo" >>= pure . maybe "" id
    url <- obj .:? "url"
    pure BookUpdate
      { bookUpdateId = bookId
      , bookUpdateTitle = T.strip title
      , bookUpdateAuthor = T.strip author
      , bookUpdateStatus = status
      , bookUpdateCategory = T.strip category
      , bookUpdateSeries = normalizeMaybe series
      , bookUpdateVolumeNo = volumeNo
      , bookUpdateMemo = memo
      , bookUpdateUrl = normalizeMaybe url
      }

newtype BookUpdateBatch = BookUpdateBatch
  { batchBookUpdates :: NonEmpty BookUpdate
  } deriving (Eq, Show, Generic)

instance FromJSON BookUpdateBatch where
  parseJSON = withObject "BookUpdateBatch" $ \obj -> do
    updates <- obj .: "books"
    case NE.nonEmpty updates of
      Nothing -> fail "books must contain at least one update"
      Just nonEmptyUpdates -> pure (BookUpdateBatch nonEmptyUpdates)

data BookFilter = BookFilter
  { filterStatus :: Maybe Status
  , filterCategory :: Maybe Text
  , filterSeries :: Maybe Text
  , filterSearch :: Maybe Text
  , filterSort :: BookSort
  } deriving (Eq, Show)

normalizeMaybe :: Maybe Text -> Maybe Text
normalizeMaybe Nothing = Nothing
normalizeMaybe (Just value)
  | T.null (T.strip value) = Nothing
  | otherwise = Just (T.strip value)
