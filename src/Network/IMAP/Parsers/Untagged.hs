module Network.IMAP.Parsers.Untagged where

import Network.IMAP.Types
import Network.IMAP.Parsers.Utils

import Data.Attoparsec.ByteString
import qualified Data.Attoparsec.ByteString as AP
import Data.Word8
import qualified Data.Text as T
import qualified Data.Text.Read as TR
import Data.Text.Encoding (decodeUtf8)
import Data.Either.Combinators (mapBoth, mapRight)
import qualified Debug.Trace as DT

import Control.Applicative
import Control.Monad (mzero)

parseOk :: Parser UntaggedResult
parseOk = do
  string "OK "
  contents <- AP.takeWhile (/= _cr)
  return . OKResult . decodeUtf8 $ contents

parseFlag :: Parser Flag
parseFlag = do
  word8 _backslash
  flagName <- takeWhile1 (\c -> isLetter c || c == _asterisk)
  case flagName of
            "Seen" -> return FSeen
            "Answered" -> return FAnswered
            "Flagged" -> return FFlagged
            "Deleted" -> return FDeleted
            "Draft" -> return FDraft
            "Recent" -> return FRecent
            "*" -> return FAny
            _ -> mzero

parseWeirdFlag :: Parser Flag
parseWeirdFlag = do
  flagText <- AP.takeWhile1 (\c -> isLetter c || c == _dollar)
  return . FOther . decodeUtf8 $ flagText

parseFlagList :: Parser [Flag]
parseFlagList = word8 _parenleft *>
                (parseFlag <|> parseWeirdFlag) `sepBy` word8 _space
                <* word8 _parenright

parseFlags :: Parser (Either ErrorMessage UntaggedResult)
parseFlags = Right . Flags <$> (string "FLAGS " *> parseFlagList)

parseExists :: Parser (Either ErrorMessage UntaggedResult)
parseExists = parseNumber Exists "" "EXISTS"

parseBye :: Parser UntaggedResult
parseBye = string "BYE" *> AP.takeWhile (/= _cr) *> return Bye

parseRecent :: Parser (Either ErrorMessage UntaggedResult)
parseRecent = parseNumber Recent "" "RECENT"

parseOkResp :: Parser a -> Parser a
parseOkResp innerParser = string "OK [" *> innerParser <* string "]"

parseUnseen :: Parser (Either ErrorMessage UntaggedResult)
parseUnseen = parseOkResp $
  (\x -> toInt x >>= Right . Unseen) <$>
  (string "UNSEEN " *> takeWhile1 isDigit)

parsePermanentFlags :: Parser UntaggedResult
parsePermanentFlags = parseOkResp $
  PermanentFlags <$> (string "PERMANENTFLAGS " *> parseFlagList)

parseUidNext :: Parser (Either ErrorMessage UntaggedResult)
parseUidNext = parseOkResp $ parseNumber UIDNext "UIDNEXT" ""

parseUidValidity :: Parser (Either ErrorMessage UntaggedResult)
parseUidValidity = parseOkResp $ parseNumber UIDValidity "UIDVALIDITY" ""

parseHighestModSeq :: Parser (Either ErrorMessage UntaggedResult)
parseHighestModSeq = parseOkResp $ parseNumber HighestModSeq "HIGHESTMODSEQ" ""

parseStatusItem :: Parser (Either ErrorMessage UntaggedResult)
parseStatusItem = do
  anyWord8
  itemName <- (AP.takeWhile1 isAtomChar >>= return . decodeUtf8)
  string " "
  value <- (AP.takeWhile1 isDigit >>= return . decodeUtf8)

  let decodingError = T.concat ["Error decoding '", value, "' as integer"]
  let valAsNumber = mapBoth (const decodingError) fst $ TR.decimal value

  return $ valAsNumber >>= \n -> case itemName of
    "MESSAGES" -> Right $ Messages n
    "RECENT" -> Right $ Recent n
    "UIDNEXT" -> Right $ UIDNext n
    "UIDVALIDITY" -> Right $ UIDValidity n
    "UNSEEN" -> Right $ Unseen n
    _ -> Left $ T.concat ["Unknown status item '", itemName, "'"]

parseStatus :: Parser (Either ErrorMessage UntaggedResult)
parseStatus = do
  string "STATUS "
  mailboxName <- (AP.takeWhile1 isAtomChar >>= return . decodeUtf8)

  string " "
  statuses <- parseStatusItem `manyTill` string ")"
  let formattedStatuses = mapM id statuses

  return $ formattedStatuses >>= return . StatusR mailboxName

parseCapabilityList :: Parser (Either ErrorMessage UntaggedResult)
parseCapabilityList = do
  string "CAPABILITY "
  caps <- (parseCapabilityWithValue <|> parseNamedCapability) `sepBy` word8 _space
  return . (mapRight Capabilities) $ (mapM id) caps

parseCapabilityWithValue :: Parser (Either ErrorMessage Capability)
parseCapabilityWithValue = do
  name <- (AP.takeWhile1 isAtomChar >>= return . decodeUtf8)
  word8 _equal
  value <- AP.takeWhile1 isAtomChar

  let decodedValue = decodeUtf8 value
  let decodingError = T.concat ["Error decoding '", decodedValue, "' as integer"]
  let valAsNumber = mapBoth (const decodingError) fst $ TR.decimal decodedValue
  case T.toLower name of
    "compress" -> return . Right . CCompress $ decodedValue
    "utf8" -> return . Right . CUtf8 $ decodedValue
    "auth" -> return . Right . CAuth $ decodedValue
    "appendlimit" -> return (valAsNumber >>= return . CAppendLimit)
    _ -> return . Right $ COther name (Just decodedValue)

parseNamedCapability :: Parser (Either ErrorMessage Capability)
parseNamedCapability = do
  name <- AP.takeWhile isAtomChar
  let decodedName = decodeUtf8 name

  return . Right $ case T.toLower decodedName of
    "imap4" -> CIMAP4
    "imap4rev1" -> CIMAP4
    "unselect" -> CUnselect
    "idle" -> CIdle
    "namespace" -> CNamespace
    "quota" -> CQuota
    "id" -> CId
    "children" -> CChildren
    "uidplus" -> CUIDPlus
    "enable" -> CEnable
    "move" -> CMove
    "condstore" -> CCondstore
    "esearch" -> CEsearch
    "list-extended" -> CListExtended
    "list-status" -> CListStatus
    _ -> if T.head decodedName == 'X'
          then CExperimental decodedName
          else COther decodedName Nothing

parseExpunge :: Parser (Either ErrorMessage UntaggedResult)
parseExpunge = do
  msgId <- AP.takeWhile1 isDigit
  string " EXPUNGE"

  return $ toInt msgId >>= return . Expunge

parseSearchResult :: Parser (Either ErrorMessage UntaggedResult)
parseSearchResult = do
  string "SEARCH "
  msgIds <- (AP.takeWhile1 isDigit) `sepBy` word8 _space
  let parsedIds = mapM id $ map toInt msgIds
  return $ parsedIds >>= return . Search