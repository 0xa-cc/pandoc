{-# LANGUAGE RelaxedPolyRec #-} -- needed for inlinesBetween on GHC < 7
{-
Copyright (C) 2006-2010 John MacFarlane <jgm@berkeley.edu>

This program is free software; you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation; either version 2 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program; if not, write to the Free Software
Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
-}

{- |
   Module      : Text.Pandoc.Readers.Markdown
   Copyright   : Copyright (C) 2006-2010 John MacFarlane
   License     : GNU GPL, version 2 or above

   Maintainer  : John MacFarlane <jgm@berkeley.edu>
   Stability   : alpha
   Portability : portable

Conversion of markdown-formatted plain text to 'Pandoc' document.
-}
module Text.Pandoc.Readers.Markdown ( readMarkdown ) where

import Data.List ( transpose, sortBy, findIndex, intercalate )
import qualified Data.Map as M
import Data.Ord ( comparing )
import Data.Char ( isAlphaNum, toLower )
import Data.Maybe
import Text.Pandoc.Definition
import qualified Text.Pandoc.Builder as B
import Text.Pandoc.Builder (Inlines, Blocks, trimInlines, (<>))
import Text.Pandoc.Options
import Text.Pandoc.Shared
import Text.Pandoc.Parsing hiding (tableWith)
import Text.Pandoc.Readers.LaTeX ( rawLaTeXInline, rawLaTeXBlock )
import Text.Pandoc.Readers.HTML ( htmlTag, htmlInBalanced, isInlineTag, isBlockTag,
                                  isTextTag, isCommentTag )
import Text.Pandoc.XML ( fromEntities )
import Data.Monoid (mconcat, mempty)
import Control.Applicative ((<$>), (<*), (*>), (<$))
import Control.Monad
import Text.HTML.TagSoup
import Text.HTML.TagSoup.Match (tagOpen)
import qualified Data.Set as Set

type MarkdownParser m = Parser [Char] ParserState m

-- | Read markdown from an input string and return a Pandoc document.
readMarkdown :: PMonad m
             => ReaderOptions -- ^ Reader options
             -> String        -- ^ String to parse (assuming @'\n'@ line endings)
             -> m Pandoc
readMarkdown opts s =
  (readWith parseMarkdown) def{ stateOptions = opts } (s ++ "\n\n")

trimInlinesF :: F Inlines -> F Inlines
trimInlinesF = liftM trimInlines

--
-- Constants and data structure definitions
--

isBulletListMarker :: Char -> Bool
isBulletListMarker '*' = True
isBulletListMarker '+' = True
isBulletListMarker '-' = True
isBulletListMarker _   = False

isHruleChar :: Char -> Bool
isHruleChar '*' = True
isHruleChar '-' = True
isHruleChar '_' = True
isHruleChar _   = False

setextHChars :: String
setextHChars = "=-"

isBlank :: Char -> Bool
isBlank ' '  = True
isBlank '\t' = True
isBlank '\n' = True
isBlank _    = False

--
-- auxiliary functions
--

isNull :: F Inlines -> Bool
isNull ils = B.isNull $ runF ils def

spnl :: Monad m => Parser [Char] st m ()
spnl = try $ do
  skipSpaces
  optional newline
  skipSpaces
  notFollowedBy (char '\n')

indentSpaces :: Monad m => MarkdownParser m String
indentSpaces = try $ do
  tabStop <- getOption readerTabStop
  count tabStop (char ' ') <|>
    string "\t" <?> "indentation"

nonindentSpaces :: Monad m => MarkdownParser m String
nonindentSpaces = do
  tabStop <- getOption readerTabStop
  sps <- many (char ' ')
  if length sps < tabStop
     then return sps
     else unexpected "indented line"

skipNonindentSpaces :: Monad m => MarkdownParser m ()
skipNonindentSpaces = do
  tabStop <- getOption readerTabStop
  atMostSpaces (tabStop - 1)

atMostSpaces :: Monad m => Int -> MarkdownParser m ()
atMostSpaces 0 = notFollowedBy (char ' ')
atMostSpaces n = (char ' ' >> atMostSpaces (n-1)) <|> return ()

litChar :: Monad m => MarkdownParser m Char
litChar = escapedChar'
       <|> noneOf "\n"
       <|> (newline >> notFollowedBy blankline >> return ' ')

-- | Parse a sequence of inline elements between square brackets,
-- including inlines between balanced pairs of square brackets.
inlinesInBalancedBrackets :: Monad m => MarkdownParser m (F Inlines)
inlinesInBalancedBrackets = charsInBalancedBrackets >>=
  parseFromString (trimInlinesF . mconcat <$> many inline)

charsInBalancedBrackets :: Monad m => MarkdownParser m [Char]
charsInBalancedBrackets = do
  char '['
  result <- manyTill (  many1 (noneOf "`[]\n")
                    <|> (snd <$> withRaw code)
                    <|> ((\xs -> '[' : xs ++ "]") <$> charsInBalancedBrackets)
                    <|> count 1 (satisfy (/='\n'))
                    <|> (newline >> notFollowedBy blankline >> return "\n")
                     ) (char ']')
  return $ concat result

--
-- document structure
--

titleLine :: Monad m => MarkdownParser m (F Inlines)
titleLine = try $ do
  char '%'
  skipSpaces
  res <- many $ (notFollowedBy newline >> inline)
             <|> try (endline >> whitespace)
  newline
  return $ trimInlinesF $ mconcat res

authorsLine :: Monad m => MarkdownParser m (F [Inlines])
authorsLine = try $ do
  char '%'
  skipSpaces
  authors <- sepEndBy (many (notFollowedBy (satisfy $ \c ->
                                c == ';' || c == '\n') >> inline))
                       (char ';' <|>
                        try (newline >> notFollowedBy blankline >> spaceChar))
  newline
  return $ sequence $ filter (not . isNull) $ map (trimInlinesF . mconcat) authors

dateLine :: Monad m => MarkdownParser m (F Inlines)
dateLine = try $ do
  char '%'
  skipSpaces
  trimInlinesF . mconcat <$> manyTill inline newline

titleBlock :: Monad m => MarkdownParser m (F Inlines, F [Inlines], F Inlines)
titleBlock = pandocTitleBlock <|> mmdTitleBlock

pandocTitleBlock :: Monad m => MarkdownParser m (F Inlines, F [Inlines], F Inlines)
pandocTitleBlock = try $ do
  guardEnabled Ext_pandoc_title_block
  title <- option mempty titleLine
  author <- option (return []) authorsLine
  date <- option mempty dateLine
  optional blanklines
  return (title, author, date)

mmdTitleBlock :: Monad m => MarkdownParser m (F Inlines, F [Inlines], F Inlines)
mmdTitleBlock = try $ do
  guardEnabled Ext_mmd_title_block
  kvPairs <- many1 kvPair
  blanklines
  let title = maybe mempty return $ lookup "title" kvPairs
  let author = maybe mempty (\x -> return [x]) $ lookup "author" kvPairs
  let date = maybe mempty return $ lookup "date" kvPairs
  return (title, author, date)

kvPair :: Monad m => MarkdownParser m (String, Inlines)
kvPair = try $ do
  key <- many1Till (alphaNum <|> oneOf "_- ") (char ':')
  val <- manyTill anyChar
          (try $ newline >> lookAhead (blankline <|> nonspaceChar))
  let key' = concat $ words $ map toLower key
  let val' = trimInlines $ B.text val
  return (key',val')

parseMarkdown :: Monad m => MarkdownParser m Pandoc
parseMarkdown = do
  -- markdown allows raw HTML
  updateState $ \state -> state { stateOptions =
                let oldOpts = stateOptions state in
                    oldOpts{ readerParseRaw = True } }
  (title, authors, date) <- option (mempty,return [],mempty) titleBlock
  blocks <- parseBlocks
  st <- getState
  return $ B.setTitle (runF title st)
         $ B.setAuthors (runF authors st)
         $ B.setDate (runF date st)
         $ B.doc $ runF blocks st

referenceKey :: Monad m => MarkdownParser m (F Blocks)
referenceKey = try $ do
  skipNonindentSpaces
  (_,raw) <- reference
  char ':'
  skipSpaces >> optional newline >> skipSpaces >> notFollowedBy (char '[')
  let sourceURL = liftM unwords $ many $ try $ do
                    notFollowedBy' referenceTitle
                    skipMany spaceChar
                    optional $ newline >> notFollowedBy blankline
                    skipMany spaceChar
                    notFollowedBy' (() <$ reference)
                    many1 $ escapedChar' <|> satisfy (not . isBlank)
  let betweenAngles = try $ char '<' >>
                       manyTill (escapedChar' <|> litChar) (char '>')
  src <- try betweenAngles <|> sourceURL
  tit <- option "" referenceTitle
  blanklines
  let target = (escapeURI $ trimr src,  tit)
  st <- getState
  let oldkeys = stateKeys st
  updateState $ \s -> s { stateKeys = M.insert (toKey raw) target oldkeys }
  return $ return mempty

referenceTitle :: Monad m => MarkdownParser m String
referenceTitle = try $ do
  skipSpaces >> optional newline >> skipSpaces
  tit <-    (charsInBalanced '(' ')' litChar >>= return . unwords . words)
        <|> do delim <- char '\'' <|> char '"'
               manyTill litChar (try (char delim >> skipSpaces >>
                                      notFollowedBy (noneOf ")\n")))
  return $ fromEntities tit

-- | PHP Markdown Extra style abbreviation key.  Currently
-- we just skip them, since Pandoc doesn't have an element for
-- an abbreviation.
abbrevKey :: Monad m => MarkdownParser m (F Blocks)
abbrevKey = do
  guardEnabled Ext_abbreviations
  try $ do
    char '*'
    reference
    char ':'
    skipMany (satisfy (/= '\n'))
    blanklines
    return $ return mempty

noteMarker :: Monad m => MarkdownParser m String
noteMarker = string "[^" >> many1Till (satisfy $ not . isBlank) (char ']')

rawLine :: Monad m => MarkdownParser m String
rawLine = try $ do
  notFollowedBy blankline
  notFollowedBy' $ try $ skipNonindentSpaces >> noteMarker
  optional indentSpaces
  anyLine

rawLines :: Monad m => MarkdownParser m String
rawLines = do
  first <- anyLine
  rest <- many rawLine
  return $ unlines (first:rest)

noteBlock :: Monad m => MarkdownParser m (F Blocks)
noteBlock = try $ do
  skipNonindentSpaces
  ref <- noteMarker
  char ':'
  optional blankline
  optional indentSpaces
  first <- rawLines
  rest <- many $ try $ blanklines >> indentSpaces >> rawLines
  let raw = unlines (first:rest) ++ "\n"
  optional blanklines
  parsed <- parseFromString parseBlocks raw
  let newnote = (ref, parsed)
  updateState $ \s -> s { stateNotes' = newnote : stateNotes' s }
  return mempty

--
-- parsing blocks
--

parseBlocks :: Monad m => MarkdownParser m (F Blocks)
parseBlocks = mconcat <$> manyTill block eof

block :: Monad m => MarkdownParser m (F Blocks)
block = choice [ codeBlockFenced
               , codeBlockBackticks
               , guardEnabled Ext_latex_macros *> (mempty <$ macro)
               , header
               , rawTeXBlock
               , htmlBlock
               , table
               , codeBlockIndented
               , lhsCodeBlock
               , blockQuote
               , hrule
               , bulletList
               , orderedList
               , definitionList
               , noteBlock
               , referenceKey
               , abbrevKey
               , para
               , plain
               ] <?> "block"

--
-- header blocks
--

header :: Monad m => MarkdownParser m (F Blocks)
header = setextHeader <|> atxHeader <?> "header"

atxHeader :: Monad m => MarkdownParser m (F Blocks)
atxHeader = try $ do
  level <- many1 (char '#') >>= return . length
  notFollowedBy (char '.' <|> char ')') -- this would be a list
  skipSpaces
  text <- trimInlinesF . mconcat <$> manyTill inline atxClosing
  return $ B.header level <$> text

atxClosing :: Monad m => MarkdownParser m String
atxClosing = try $ skipMany (char '#') >> blanklines

setextHeader :: Monad m => MarkdownParser m (F Blocks)
setextHeader = try $ do
  -- This lookahead prevents us from wasting time parsing Inlines
  -- unless necessary -- it gives a significant performance boost.
  lookAhead $ anyLine >> many1 (oneOf setextHChars) >> blankline
  text <- trimInlinesF . mconcat <$> many1Till inline newline
  underlineChar <- oneOf setextHChars
  many (char underlineChar)
  blanklines
  let level = (fromMaybe 0 $ findIndex (== underlineChar) setextHChars) + 1
  return $ B.header level <$> text

--
-- hrule block
--

hrule :: Monad m => MarkdownParser m (F Blocks)
hrule = try $ do
  skipSpaces
  start <- satisfy isHruleChar
  count 2 (skipSpaces >> char start)
  skipMany (spaceChar <|> char start)
  newline
  optional blanklines
  return $ return B.horizontalRule

--
-- code blocks
--

indentedLine :: Monad m => MarkdownParser m String
indentedLine = indentSpaces >> manyTill anyChar newline >>= return . (++ "\n")

blockDelimiter :: Monad m => (Char -> Bool)
               -> Maybe Int
               -> MarkdownParser m Int
blockDelimiter f len = try $ do
  c <- lookAhead (satisfy f)
  case len of
      Just l  -> count l (char c) >> many (char c) >> return l
      Nothing -> count 3 (char c) >> many (char c) >>=
                 return . (+ 3) . length

attributes :: Monad m => MarkdownParser m (String, [String], [(String, String)])
attributes = try $ do
  char '{'
  spnl
  attrs <- many (attribute >>~ spnl)
  char '}'
  let (ids, classes, keyvals) = unzip3 attrs
  let firstNonNull [] = ""
      firstNonNull (x:xs) | not (null x) = x
                          | otherwise    = firstNonNull xs
  return (firstNonNull $ reverse ids, concat classes, concat keyvals)

attribute :: Monad m => MarkdownParser m (String, [String], [(String, String)])
attribute = identifierAttr <|> classAttr <|> keyValAttr

identifier :: Monad m => MarkdownParser m String
identifier = do
  first <- letter
  rest <- many $ alphaNum <|> oneOf "-_:."
  return (first:rest)

identifierAttr :: Monad m => MarkdownParser m (String, [a], [a1])
identifierAttr = try $ do
  char '#'
  result <- identifier
  return (result,[],[])

classAttr :: Monad m => MarkdownParser m (String, [String], [a])
classAttr = try $ do
  char '.'
  result <- identifier
  return ("",[result],[])

keyValAttr :: Monad m => MarkdownParser m (String, [a], [(String, String)])
keyValAttr = try $ do
  key <- identifier
  char '='
  val <- enclosed (char '"') (char '"') anyChar
     <|> enclosed (char '\'') (char '\'') anyChar
     <|> many nonspaceChar
  return ("",[],[(key,val)])

codeBlockFenced :: Monad m => MarkdownParser m (F Blocks)
codeBlockFenced = try $ do
  guardEnabled Ext_fenced_code_blocks
  size <- blockDelimiter (=='~') Nothing
  skipMany spaceChar
  attr <- option ([],[],[]) $
            guardEnabled Ext_fenced_code_attributes >> attributes
  blankline
  contents <- manyTill anyLine (blockDelimiter (=='~') (Just size))
  blanklines
  return $ return $ B.codeBlockWith attr $ intercalate "\n" contents

codeBlockBackticks :: Monad m => MarkdownParser m (F Blocks)
codeBlockBackticks = try $ do
  guardEnabled Ext_backtick_code_blocks
  blockDelimiter (=='`') (Just 3)
  skipMany spaceChar
  cls <- many1 alphaNum
  blankline
  contents <- manyTill anyLine $ blockDelimiter (=='`') (Just 3)
  blanklines
  return $ return $ B.codeBlockWith ("",[cls],[]) $ intercalate "\n" contents

codeBlockIndented :: Monad m => MarkdownParser m (F Blocks)
codeBlockIndented = do
  contents <- many1 (indentedLine <|>
                     try (do b <- blanklines
                             l <- indentedLine
                             return $ b ++ l))
  optional blanklines
  classes <- getOption readerIndentedCodeClasses
  return $ return $ B.codeBlockWith ("", classes, []) $
           stripTrailingNewlines $ concat contents

lhsCodeBlock :: Monad m => MarkdownParser m (F Blocks)
lhsCodeBlock = do
  guardEnabled Ext_literate_haskell
  (return . B.codeBlockWith ("",["sourceCode","literate","haskell"],[]) <$>
          (lhsCodeBlockBird <|> lhsCodeBlockLaTeX))
    <|> (return . B.codeBlockWith ("",["sourceCode","haskell"],[]) <$>
          lhsCodeBlockInverseBird)

lhsCodeBlockLaTeX :: Monad m => MarkdownParser m String
lhsCodeBlockLaTeX = try $ do
  string "\\begin{code}"
  manyTill spaceChar newline
  contents <- many1Till anyChar (try $ string "\\end{code}")
  blanklines
  return $ stripTrailingNewlines contents

lhsCodeBlockBird :: Monad m => MarkdownParser m String
lhsCodeBlockBird = lhsCodeBlockBirdWith '>'

lhsCodeBlockInverseBird :: Monad m => MarkdownParser m String
lhsCodeBlockInverseBird = lhsCodeBlockBirdWith '<'

lhsCodeBlockBirdWith :: Monad m => Char -> MarkdownParser m String
lhsCodeBlockBirdWith c = try $ do
  pos <- getPosition
  when (sourceColumn pos /= 1) $ fail "Not in first column"
  lns <- many1 $ birdTrackLine c
  -- if (as is normal) there is always a space after >, drop it
  let lns' = if all (\ln -> null ln || take 1 ln == " ") lns
                then map (drop 1) lns
                else lns
  blanklines
  return $ intercalate "\n" lns'

birdTrackLine :: Monad m => Char -> MarkdownParser m String
birdTrackLine c = try $ do
  char c
  -- allow html tags on left margin:
  when (c == '<') $ notFollowedBy letter
  manyTill anyChar newline

--
-- block quotes
--

emailBlockQuoteStart :: Monad m => MarkdownParser m Char
emailBlockQuoteStart = try $ skipNonindentSpaces >> char '>' >>~ optional (char ' ')

emailBlockQuote :: Monad m => MarkdownParser m [String]
emailBlockQuote = try $ do
  emailBlockQuoteStart
  let emailLine = many $ nonEndline <|> try
                         (endline >> notFollowedBy emailBlockQuoteStart >>
                         return '\n')
  let emailSep = try (newline >> emailBlockQuoteStart)
  first <- emailLine
  rest <- many $ try $ emailSep >> emailLine
  let raw = first:rest
  newline <|> (eof >> return '\n')
  optional blanklines
  return raw

blockQuote :: Monad m => MarkdownParser m (F Blocks)
blockQuote = do
  raw <- emailBlockQuote
  -- parse the extracted block, which may contain various block elements:
  contents <- parseFromString parseBlocks $ (intercalate "\n" raw) ++ "\n\n"
  return $ B.blockQuote <$> contents

--
-- list blocks
--

bulletListStart :: Monad m => MarkdownParser m ()
bulletListStart = try $ do
  optional newline -- if preceded by a Plain block in a list context
  skipNonindentSpaces
  notFollowedBy' (() <$ hrule)     -- because hrules start out just like lists
  satisfy isBulletListMarker
  spaceChar
  skipSpaces

anyOrderedListStart :: Monad m => MarkdownParser m (Int, ListNumberStyle, ListNumberDelim)
anyOrderedListStart = try $ do
  optional newline -- if preceded by a Plain block in a list context
  skipNonindentSpaces
  notFollowedBy $ string "p." >> spaceChar >> digit  -- page number
  (guardDisabled Ext_fancy_lists >>
       do many1 digit
          char '.'
          spaceChar
          return (1, DefaultStyle, DefaultDelim))
   <|> do (num, style, delim) <- anyOrderedListMarker
          -- if it could be an abbreviated first name, insist on more than one space
          if delim == Period && (style == UpperAlpha || (style == UpperRoman &&
             num `elem` [1, 5, 10, 50, 100, 500, 1000]))
             then char '\t' <|> (try $ char ' ' >> spaceChar)
             else spaceChar
          skipSpaces
          return (num, style, delim)

listStart :: Monad m => MarkdownParser m ()
listStart = bulletListStart <|> (anyOrderedListStart >> return ())

-- parse a line of a list item (start = parser for beginning of list item)
listLine :: Monad m => MarkdownParser m String
listLine = try $ do
  notFollowedBy blankline
  notFollowedBy' (do indentSpaces
                     many (spaceChar)
                     listStart)
  chunks <- manyTill (liftM snd (htmlTag isCommentTag) <|> count 1 anyChar) newline
  return $ concat chunks ++ "\n"

-- parse raw text for one list item, excluding start marker and continuations
rawListItem :: Monad m => MarkdownParser m a
            -> MarkdownParser m String
rawListItem start = try $ do
  start
  first <- listLine
  rest <- many (notFollowedBy listStart >> listLine)
  blanks <- many blankline
  return $ concat (first:rest)  ++ blanks

-- continuation of a list item - indented and separated by blankline
-- or (in compact lists) endline.
-- note: nested lists are parsed as continuations
listContinuation :: Monad m => MarkdownParser m String
listContinuation = try $ do
  lookAhead indentSpaces
  result <- many1 listContinuationLine
  blanks <- many blankline
  return $ concat result ++ blanks

listContinuationLine :: Monad m => MarkdownParser m String
listContinuationLine = try $ do
  notFollowedBy blankline
  notFollowedBy' listStart
  optional indentSpaces
  result <- manyTill anyChar newline
  return $ result ++ "\n"

listItem :: Monad m => MarkdownParser m a
         -> MarkdownParser m (F Blocks)
listItem start = try $ do
  first <- rawListItem start
  continuations <- many listContinuation
  -- parsing with ListItemState forces markers at beginning of lines to
  -- count as list item markers, even if not separated by blank space.
  -- see definition of "endline"
  state <- getState
  let oldContext = stateParserContext state
  setState $ state {stateParserContext = ListItemState}
  -- parse the extracted block, which may contain various block elements:
  let raw = concat (first:continuations)
  contents <- parseFromString parseBlocks raw
  updateState (\st -> st {stateParserContext = oldContext})
  return contents

orderedList :: Monad m => MarkdownParser m (F Blocks)
orderedList = try $ do
  (start, style, delim) <- lookAhead anyOrderedListStart
  unless ((style == DefaultStyle || style == Decimal || style == Example) &&
          (delim == DefaultDelim || delim == Period)) $
    guardEnabled Ext_fancy_lists
  when (style == Example) $ guardEnabled Ext_example_lists
  items <- fmap sequence $ many1 $ listItem
                 ( try $ do
                     optional newline -- if preceded by Plain block in a list
                     skipNonindentSpaces
                     orderedListMarker style delim )
  start' <- option 1 $ guardEnabled Ext_startnum >> return start
  return $ B.orderedListWith (start', style, delim) <$> fmap compactify' items

bulletList :: Monad m => MarkdownParser m (F Blocks)
bulletList = do
  items <- fmap sequence $ many1 $ listItem  bulletListStart
  return $ B.bulletList <$> fmap compactify' items

-- definition lists

defListMarker :: Monad m => MarkdownParser m ()
defListMarker = do
  sps <- nonindentSpaces
  char ':' <|> char '~'
  tabStop <- getOption readerTabStop
  let remaining = tabStop - (length sps + 1)
  if remaining > 0
     then count remaining (char ' ') <|> string "\t"
     else mzero
  return ()

definitionListItem :: Monad m => MarkdownParser m (F (Inlines, [Blocks]))
definitionListItem = try $ do
  guardEnabled Ext_definition_lists
  -- first, see if this has any chance of being a definition list:
  lookAhead (anyLine >> optional blankline >> defListMarker)
  term <- trimInlinesF . mconcat <$> manyTill inline newline
  optional blankline
  raw <- many1 defRawBlock
  state <- getState
  let oldContext = stateParserContext state
  -- parse the extracted block, which may contain various block elements:
  contents <- mapM (parseFromString parseBlocks) raw
  updateState (\st -> st {stateParserContext = oldContext})
  return $ liftM2 (,) term (sequence contents)

defRawBlock :: Monad m => MarkdownParser m String
defRawBlock = try $ do
  defListMarker
  firstline <- anyLine
  rawlines <- many (notFollowedBy blankline >> indentSpaces >> anyLine)
  trailing <- option "" blanklines
  cont <- liftM concat $ many $ do
            lns <- many1 $ notFollowedBy blankline >> indentSpaces >> anyLine
            trl <- option "" blanklines
            return $ unlines lns ++ trl
  return $ firstline ++ "\n" ++ unlines rawlines ++ trailing ++ cont

definitionList :: Monad m => MarkdownParser m (F Blocks)
definitionList = do
  items <- fmap sequence $ many1 definitionListItem
  return $ B.definitionList <$> fmap compactify'DL items

compactify'DL :: [(Inlines, [Blocks])] -> [(Inlines, [Blocks])]
compactify'DL items =
  let defs = concatMap snd items
      defBlocks = reverse $ concatMap B.toList defs
      isPara (Para _) = True
      isPara _        = False
  in  case defBlocks of
           (Para x:_) -> if not $ any isPara (drop 1 defBlocks)
                            then let (t,ds) = last items
                                     lastDef = B.toList $ last ds
                                     ds' = init ds ++
                                          [B.fromList $ init lastDef ++ [Plain x]]
                                  in init items ++ [(t, ds')]
                            else items
           _          -> items

--
-- paragraph block
--

{-
isHtmlOrBlank :: Inline -> Bool
isHtmlOrBlank (RawInline "html" _) = True
isHtmlOrBlank (Space)         = True
isHtmlOrBlank (LineBreak)     = True
isHtmlOrBlank _               = False
-}

para :: Monad m => MarkdownParser m (F Blocks)
para = try $ do
  result <- trimInlinesF . mconcat <$> many1 inline
  -- TODO remove this if not really needed?  and remove isHtmlOrBlank
  -- guard $ not $ F.all isHtmlOrBlank result
  option (B.plain <$> result) $ try $ do
              newline
              (blanklines >> return mempty)
                <|> (guardDisabled Ext_blank_before_blockquote >> lookAhead blockQuote)
                <|> (guardDisabled Ext_blank_before_header >> lookAhead header)
              return $ B.para <$> result

plain :: Monad m => MarkdownParser m (F Blocks)
plain = fmap B.plain . trimInlinesF . mconcat <$> many1 inline <* spaces

--
-- raw html
--

htmlElement :: Monad m => MarkdownParser m String
htmlElement = strictHtmlBlock <|> liftM snd (htmlTag isBlockTag)

htmlBlock :: Monad m => MarkdownParser m (F Blocks)
htmlBlock = do
  guardEnabled Ext_raw_html
  res <- (guardEnabled Ext_markdown_in_html_blocks >> rawHtmlBlocks)
          <|> htmlBlock'
  return $ return $ B.rawBlock "html" res

htmlBlock' :: Monad m => MarkdownParser m String
htmlBlock' = try $ do
    first <- htmlElement
    finalSpace <- many spaceChar
    finalNewlines <- many newline
    return $ first ++ finalSpace ++ finalNewlines

strictHtmlBlock :: Monad m => MarkdownParser m String
strictHtmlBlock = htmlInBalanced (not . isInlineTag)

rawVerbatimBlock :: Monad m => MarkdownParser m String
rawVerbatimBlock = try $ do
  (TagOpen tag _, open) <- htmlTag (tagOpen (\t ->
                              t == "pre" || t == "style" || t == "script")
                              (const True))
  contents <- manyTill anyChar (htmlTag (~== TagClose tag))
  return $ open ++ contents ++ renderTags [TagClose tag]

rawTeXBlock :: Monad m => MarkdownParser m (F Blocks)
rawTeXBlock = do
  guardEnabled Ext_raw_tex
  result <- (B.rawBlock "latex" <$> rawLaTeXBlock)
        <|> (B.rawBlock "context" <$> rawConTeXtEnvironment)
  spaces
  return $ return result

rawHtmlBlocks :: Monad m => MarkdownParser m String
rawHtmlBlocks = do
  htmlBlocks <- many1 $ try $ do
                          s <- rawVerbatimBlock <|> try (
                                do (t,raw) <- htmlTag isBlockTag
                                   exts <- getOption readerExtensions
                                   -- if open tag, need markdown="1" if
                                   -- markdown_attributes extension is set
                                   case t of
                                        TagOpen _ as
                                          | Ext_markdown_attribute `Set.member`
                                              exts ->
                                                if "markdown" `notElem`
                                                   map fst as
                                                   then mzero
                                                   else return $
                                                     stripMarkdownAttribute raw
                                          | otherwise -> return raw
                                        _ -> return raw )
                          sps <- do sp1 <- many spaceChar
                                    sp2 <- option "" (blankline >> return "\n")
                                    sp3 <- many spaceChar
                                    sp4 <- option "" blanklines
                                    return $ sp1 ++ sp2 ++ sp3 ++ sp4
                          -- note: we want raw html to be able to
                          -- precede a code block, when separated
                          -- by a blank line
                          return $ s ++ sps
  let combined = concat htmlBlocks
  return $ if last combined == '\n' then init combined else combined

-- remove markdown="1" attribute
stripMarkdownAttribute :: String -> String
stripMarkdownAttribute s = renderTags' $ map filterAttrib $ parseTags s
  where filterAttrib (TagOpen t as) = TagOpen t
                                        [(k,v) | (k,v) <- as, k /= "markdown"]
        filterAttrib              x = x

--
-- Tables
--

-- Parse a dashed line with optional trailing spaces; return its length
-- and the length including trailing space.
dashedLine :: Monad m => Char
           -> MarkdownParser m (Int, Int)
dashedLine ch = do
  dashes <- many1 (char ch)
  sp     <- many spaceChar
  return $ (length dashes, length $ dashes ++ sp)

-- Parse a table header with dashed lines of '-' preceded by
-- one (or zero) line of text.
simpleTableHeader :: Monad m => Bool  -- ^ Headerless table
                  -> MarkdownParser m (F [Blocks], [Alignment], [Int])
simpleTableHeader headless = try $ do
  rawContent  <- if headless
                    then return ""
                    else anyLine
  initSp      <- nonindentSpaces
  dashes      <- many1 (dashedLine '-')
  newline
  let (lengths, lines') = unzip dashes
  let indices  = scanl (+) (length initSp) lines'
  -- If no header, calculate alignment on basis of first row of text
  rawHeads <- liftM (tail . splitStringByIndices (init indices)) $
              if headless
                 then lookAhead anyLine
                 else return rawContent
  let aligns   = zipWith alignType (map (\a -> [a]) rawHeads) lengths
  let rawHeads' = if headless
                     then replicate (length dashes) ""
                     else rawHeads
  heads <- fmap sequence
           $ mapM (parseFromString (mconcat <$> many plain))
           $ map trim rawHeads'
  return (heads, aligns, indices)

-- Returns an alignment type for a table, based on a list of strings
-- (the rows of the column header) and a number (the length of the
-- dashed line under the rows.
alignType :: [String]
          -> Int
          -> Alignment
alignType [] _ = AlignDefault
alignType strLst len =
  let nonempties = filter (not . null) $ map trimr strLst
      (leftSpace, rightSpace) =
           case sortBy (comparing length) nonempties of
                 (x:_)  -> (head x `elem` " \t", length x < len)
                 []     -> (False, False)
  in  case (leftSpace, rightSpace) of
        (True,  False)   -> AlignRight
        (False, True)    -> AlignLeft
        (True,  True)    -> AlignCenter
        (False, False)   -> AlignDefault

-- Parse a table footer - dashed lines followed by blank line.
tableFooter :: Monad m => MarkdownParser m String
tableFooter = try $ skipNonindentSpaces >> many1 (dashedLine '-') >> blanklines

-- Parse a table separator - dashed line.
tableSep :: Monad m => MarkdownParser m Char
tableSep = try $ skipNonindentSpaces >> many1 (dashedLine '-') >> char '\n'

-- Parse a raw line and split it into chunks by indices.
rawTableLine :: Monad m => [Int]
             -> MarkdownParser m [String]
rawTableLine indices = do
  notFollowedBy' (blanklines <|> tableFooter)
  line <- many1Till anyChar newline
  return $ map trim $ tail $
           splitStringByIndices (init indices) line

-- Parse a table line and return a list of lists of blocks (columns).
tableLine :: Monad m => [Int]
          -> MarkdownParser m (F [Blocks])
tableLine indices = rawTableLine indices >>=
  fmap sequence . mapM (parseFromString (mconcat <$> many plain))

-- Parse a multiline table row and return a list of blocks (columns).
multilineRow :: Monad m => [Int]
             -> MarkdownParser m (F [Blocks])
multilineRow indices = do
  colLines <- many1 (rawTableLine indices)
  let cols = map unlines $ transpose colLines
  fmap sequence $ mapM (parseFromString (mconcat <$> many plain)) cols

-- Parses a table caption:  inlines beginning with 'Table:'
-- and followed by blank lines.
tableCaption :: Monad m => MarkdownParser m (F Inlines)
tableCaption = try $ do
  guardEnabled Ext_table_captions
  skipNonindentSpaces
  string ":" <|> string "Table:"
  trimInlinesF . mconcat <$> many1 inline <* blanklines

-- Parse a simple table with '---' header and one line per row.
simpleTable :: Monad m => Bool  -- ^ Headerless table
            -> MarkdownParser m ([Alignment], [Double], F [Blocks], F [[Blocks]])
simpleTable headless = do
  (aligns, _widths, heads', lines') <-
       tableWith (simpleTableHeader headless) tableLine
              (return ())
              (if headless then tableFooter else tableFooter <|> blanklines)
  -- Simple tables get 0s for relative column widths (i.e., use default)
  return (aligns, replicate (length aligns) 0, heads', lines')

-- Parse a multiline table:  starts with row of '-' on top, then header
-- (which may be multiline), then the rows,
-- which may be multiline, separated by blank lines, and
-- ending with a footer (dashed line followed by blank line).
multilineTable :: Monad m => Bool -- ^ Headerless table
               -> MarkdownParser m ([Alignment], [Double], F [Blocks], F [[Blocks]])
multilineTable headless =
  tableWith (multilineTableHeader headless) multilineRow blanklines tableFooter

multilineTableHeader :: Monad m => Bool -- ^ Headerless table
                     -> MarkdownParser m (F [Blocks], [Alignment], [Int])
multilineTableHeader headless = try $ do
  if headless
     then return '\n'
     else tableSep >>~ notFollowedBy blankline
  rawContent  <- if headless
                    then return $ repeat ""
                    else many1
                         (notFollowedBy tableSep >> many1Till anyChar newline)
  initSp      <- nonindentSpaces
  dashes      <- many1 (dashedLine '-')
  newline
  let (lengths, lines') = unzip dashes
  let indices  = scanl (+) (length initSp) lines'
  rawHeadsList <- if headless
                     then liftM (map (:[]) . tail .
                              splitStringByIndices (init indices)) $ lookAhead anyLine
                     else return $ transpose $ map
                           (\ln -> tail $ splitStringByIndices (init indices) ln)
                           rawContent
  let aligns   = zipWith alignType rawHeadsList lengths
  let rawHeads = if headless
                    then replicate (length dashes) ""
                    else map (intercalate " ") rawHeadsList
  heads <- fmap sequence $
           mapM (parseFromString (mconcat <$> many plain)) $
             map trim rawHeads
  return (heads, aligns, indices)

-- Parse a grid table:  starts with row of '-' on top, then header
-- (which may be grid), then the rows,
-- which may be grid, separated by blank lines, and
-- ending with a footer (dashed line followed by blank line).
gridTable :: Monad m => Bool -- ^ Headerless table
          -> MarkdownParser m ([Alignment], [Double], F [Blocks], F [[Blocks]])
gridTable headless =
  tableWith (gridTableHeader headless) gridTableRow
            (gridTableSep '-') gridTableFooter

gridTableSplitLine :: [Int] -> String -> [String]
gridTableSplitLine indices line = map removeFinalBar $ tail $
  splitStringByIndices (init indices) $ trimr line

gridPart :: Monad m => Char -> MarkdownParser m (Int, Int)
gridPart ch = do
  dashes <- many1 (char ch)
  char '+'
  return (length dashes, length dashes + 1)

gridDashedLines :: Monad m => Char -> MarkdownParser m [(Int,Int)]
gridDashedLines ch = try $ char '+' >> many1 (gridPart ch) >>~ blankline

removeFinalBar :: String -> String
removeFinalBar =
  reverse . dropWhile (`elem` " \t") . dropWhile (=='|') . reverse

-- | Separator between rows of grid table.
gridTableSep :: Monad m => Char -> MarkdownParser m Char
gridTableSep ch = try $ gridDashedLines ch >> return '\n'

-- | Parse header for a grid table.
gridTableHeader :: Monad m => Bool -- ^ Headerless table
                -> MarkdownParser m (F [Blocks], [Alignment], [Int])
gridTableHeader headless = try $ do
  optional blanklines
  dashes <- gridDashedLines '-'
  rawContent  <- if headless
                    then return $ repeat ""
                    else many1
                         (notFollowedBy (gridTableSep '=') >> char '|' >>
                           many1Till anyChar newline)
  if headless
     then return ()
     else gridTableSep '=' >> return ()
  let lines'   = map snd dashes
  let indices  = scanl (+) 0 lines'
  let aligns   = replicate (length lines') AlignDefault
  -- RST does not have a notion of alignments
  let rawHeads = if headless
                    then replicate (length dashes) ""
                    else map (intercalate " ") $ transpose
                       $ map (gridTableSplitLine indices) rawContent
  heads <- fmap sequence $ mapM (parseFromString block) $
               map trim rawHeads
  return (heads, aligns, indices)

gridTableRawLine :: Monad m => [Int] -> MarkdownParser m [String]
gridTableRawLine indices = do
  char '|'
  line <- many1Till anyChar newline
  return (gridTableSplitLine indices line)

-- | Parse row of grid table.
gridTableRow :: Monad m => [Int]
             -> MarkdownParser m (F [Blocks])
gridTableRow indices = do
  colLines <- many1 (gridTableRawLine indices)
  let cols = map ((++ "\n") . unlines . removeOneLeadingSpace) $
               transpose colLines
  fmap compactify' <$> fmap sequence (mapM (parseFromString block) cols)

removeOneLeadingSpace :: [String] -> [String]
removeOneLeadingSpace xs =
  if all startsWithSpace xs
     then map (drop 1) xs
     else xs
   where startsWithSpace ""     = True
         startsWithSpace (y:_) = y == ' '

-- | Parse footer for a grid table.
gridTableFooter :: Monad m => MarkdownParser m [Char]
gridTableFooter = blanklines

pipeTable :: Monad m => MarkdownParser m ([Alignment], [Double], F [Blocks], F [[Blocks]])
pipeTable = try $ do
  let pipeBreak = nonindentSpaces *> optional (char '|') *>
                      pipeTableHeaderPart `sepBy1` sepPipe <*
                      optional (char '|') <* blankline
  (heads,aligns) <- try ( pipeBreak >>= \als ->
                     return (return $ replicate (length als) mempty, als))
                  <|> ( pipeTableRow >>= \row -> pipeBreak >>= \als ->

                          return (row, als) )
  lines' <- sequence <$> many1 pipeTableRow
  blanklines
  let widths = replicate (length aligns) 0.0
  return $ (aligns, widths, heads, lines')

sepPipe :: Monad m => MarkdownParser m ()
sepPipe = try $ do
  char '|' <|> char '+'
  notFollowedBy blankline

-- parse a row, also returning probable alignments for org-table cells
pipeTableRow :: Monad m => MarkdownParser m (F [Blocks])
pipeTableRow = do
  nonindentSpaces
  optional (char '|')
  let cell = mconcat <$>
                 many (notFollowedBy (blankline <|> char '|') >> inline)
  first <- cell
  sepPipe
  rest <- cell `sepBy1` sepPipe
  optional (char '|')
  blankline
  let cells  = sequence (first:rest)
  return $ do
    cells' <- cells
    return $ map
        (\ils ->
           case trimInlines ils of
                 ils' | B.isNull ils' -> mempty
                      | otherwise   -> B.plain $ ils') cells'

pipeTableHeaderPart :: Monad m => MarkdownParser m Alignment
pipeTableHeaderPart = do
  left <- optionMaybe (char ':')
  many1 (char '-')
  right <- optionMaybe (char ':')
  return $
    case (left,right) of
      (Nothing,Nothing) -> AlignDefault
      (Just _,Nothing)  -> AlignLeft
      (Nothing,Just _)  -> AlignRight
      (Just _,Just _)   -> AlignCenter

-- Succeed only if current line contains a pipe.
scanForPipe :: Monad m => MarkdownParser m ()
scanForPipe = lookAhead (manyTill (satisfy (/='\n')) (char '|')) >> return ()

-- | Parse a table using 'headerParser', 'rowParser',
-- 'lineParser', and 'footerParser'.  Variant of the version in
-- Text.Pandoc.Parsing.
tableWith :: Monad m => MarkdownParser m (F [Blocks], [Alignment], [Int])
          -> ([Int] -> MarkdownParser m (F [Blocks]))
          -> MarkdownParser m sep
          -> MarkdownParser m end
          -> MarkdownParser m ([Alignment], [Double], F [Blocks], F [[Blocks]])
tableWith headerParser rowParser lineParser footerParser = try $ do
    (heads, aligns, indices) <- headerParser
    lines' <- fmap sequence $ rowParser indices `sepEndBy1` lineParser
    footerParser
    numColumns <- getOption readerColumns
    let widths = if (indices == [])
                    then replicate (length aligns) 0.0
                    else widthsFromIndices numColumns indices
    return $ (aligns, widths, heads, lines')

table :: Monad m => MarkdownParser m (F Blocks)
table = try $ do
  frontCaption <- option Nothing (Just <$> tableCaption)
  (aligns, widths, heads, lns) <-
         try (guardEnabled Ext_pipe_tables >> scanForPipe >> pipeTable) <|>
         try (guardEnabled Ext_multiline_tables >>
                multilineTable False) <|>
         try (guardEnabled Ext_simple_tables >>
                (simpleTable True <|> simpleTable False)) <|>
         try (guardEnabled Ext_multiline_tables >>
                multilineTable True) <|>
         try (guardEnabled Ext_grid_tables >>
                (gridTable False <|> gridTable True)) <?> "table"
  optional blanklines
  caption <- case frontCaption of
                  Nothing  -> option (return mempty) tableCaption
                  Just c   -> return c
  return $ do
    caption' <- caption
    heads' <- heads
    lns' <- lns
    return $ B.table caption' (zip aligns widths) heads' lns'

--
-- inline
--

inline :: Monad m => MarkdownParser m (F Inlines)
inline = choice [ whitespace
                , bareURL
                , str
                , endline
                , code
                , fours
                , strong
                , emph
                , note
                , cite
                , link
                , image
                , math
                , strikeout
                , superscript
                , subscript
                , inlineNote  -- after superscript because of ^[link](/foo)^
                , autoLink
                , rawHtmlInline
                , escapedChar
                , rawLaTeXInline'
                , exampleRef
                , smart
                , return . B.singleton <$> charRef
                , symbol
                , ltSign
                ] <?> "inline"

escapedChar' :: Monad m => MarkdownParser m Char
escapedChar' = try $ do
  char '\\'
  (guardEnabled Ext_all_symbols_escapable >> satisfy (not . isAlphaNum))
     <|> oneOf "\\`*_{}[]()>#+-.!~"

escapedChar :: Monad m => MarkdownParser m (F Inlines)
escapedChar = do
  result <- escapedChar'
  case result of
       ' '   -> return $ return $ B.str "\160" -- "\ " is a nonbreaking space
       '\n'  -> guardEnabled Ext_escaped_line_breaks >>
                return (return B.linebreak)  -- "\[newline]" is a linebreak
       _     -> return $ return $ B.str [result]

ltSign :: Monad m => MarkdownParser m (F Inlines)
ltSign = do
  guardDisabled Ext_raw_html
    <|> guardDisabled Ext_markdown_in_html_blocks
    <|> (notFollowedBy' rawHtmlBlocks >> return ())
  char '<'
  return $ return $ B.str "<"

exampleRef :: Monad m => MarkdownParser m (F Inlines)
exampleRef = try $ do
  guardEnabled Ext_example_lists
  char '@'
  lab <- many1 (alphaNum <|> oneOf "-_")
  return $ do
    st <- askF
    return $ case M.lookup lab (stateExamples st) of
                  Just n    -> B.str (show n)
                  Nothing   -> B.str ('@':lab)

symbol :: Monad m => MarkdownParser m (F Inlines)
symbol = do
  result <- noneOf "<\\\n\t "
         <|> try (do lookAhead $ char '\\'
                     notFollowedBy' (() <$ rawTeXBlock)
                     char '\\')
  return $ return $ B.str [result]

-- parses inline code, between n `s and n `s
code :: Monad m => MarkdownParser m (F Inlines)
code = try $ do
  starts <- many1 (char '`')
  skipSpaces
  result <- many1Till (many1 (noneOf "`\n") <|> many1 (char '`') <|>
                       (char '\n' >> notFollowedBy' blankline >> return " "))
                      (try (skipSpaces >> count (length starts) (char '`') >>
                      notFollowedBy (char '`')))
  attr <- option ([],[],[]) (try $ guardEnabled Ext_inline_code_attributes >>
                                   optional whitespace >> attributes)
  return $ return $ B.codeWith attr $ trim $ concat result

math :: Monad m => MarkdownParser m (F Inlines)
math =  (return . B.displayMath <$> (mathDisplay >>= applyMacros'))
     <|> (return . B.math <$> (mathInline >>= applyMacros'))

mathDisplay :: Monad m => MarkdownParser m String
mathDisplay =
      (guardEnabled Ext_tex_math_dollars >> mathDisplayWith "$$" "$$")
  <|> (guardEnabled Ext_tex_math_single_backslash >>
       mathDisplayWith "\\[" "\\]")
  <|> (guardEnabled Ext_tex_math_double_backslash >>
       mathDisplayWith "\\\\[" "\\\\]")

mathDisplayWith :: Monad m => String -> String -> MarkdownParser m String
mathDisplayWith op cl = try $ do
  string op
  many1Till (noneOf "\n" <|> (newline >>~ notFollowedBy' blankline)) (try $ string cl)

mathInline :: Monad m => MarkdownParser m String
mathInline =
      (guardEnabled Ext_tex_math_dollars >> mathInlineWith "$" "$")
  <|> (guardEnabled Ext_tex_math_single_backslash >>
       mathInlineWith "\\(" "\\)")
  <|> (guardEnabled Ext_tex_math_double_backslash >>
       mathInlineWith "\\\\(" "\\\\)")

mathInlineWith :: Monad m => String -> String -> MarkdownParser m String
mathInlineWith op cl = try $ do
  string op
  notFollowedBy space
  words' <- many1Till (count 1 (noneOf "\n\\")
                   <|> (char '\\' >> anyChar >>= \c -> return ['\\',c])
                   <|> count 1 newline <* notFollowedBy' blankline
                       *> return " ")
              (try $ string cl)
  notFollowedBy digit  -- to prevent capture of $5
  return $ concat words'

-- to avoid performance problems, treat 4 or more _ or * or ~ or ^ in a row
-- as a literal rather than attempting to parse for emph/strong/strikeout/super/sub
fours :: Monad m => MarkdownParser m (F Inlines)
fours = try $ do
  x <- char '*' <|> char '_' <|> char '~' <|> char '^'
  count 2 $ satisfy (==x)
  rest <- many1 (satisfy (==x))
  return $ return $ B.str (x:x:x:rest)

-- | Parses a list of inlines between start and end delimiters.
inlinesBetween :: (Monad m, Show b)
               => MarkdownParser m a
               -> MarkdownParser m b
               -> MarkdownParser m (F Inlines)
inlinesBetween start end =
  (trimInlinesF . mconcat) <$> try (start >> many1Till inner end)
    where inner      = innerSpace <|> (notFollowedBy' (() <$ whitespace) >> inline)
          innerSpace = try $ whitespace >>~ notFollowedBy' end

emph :: Monad m => MarkdownParser m (F Inlines)
emph = fmap B.emph <$> nested
  (inlinesBetween starStart starEnd <|> inlinesBetween ulStart ulEnd)
    where starStart = char '*' >> lookAhead nonspaceChar
          starEnd   = notFollowedBy' (() <$ strong) >> char '*'
          ulStart   = char '_' >> lookAhead nonspaceChar
          ulEnd     = notFollowedBy' (() <$ strong) >> char '_'

strong :: Monad m => MarkdownParser m (F Inlines)
strong = fmap B.strong <$> nested
  (inlinesBetween starStart starEnd <|> inlinesBetween ulStart ulEnd)
    where starStart = string "**" >> lookAhead nonspaceChar
          starEnd   = try $ string "**"
          ulStart   = string "__" >> lookAhead nonspaceChar
          ulEnd     = try $ string "__"

strikeout :: Monad m => MarkdownParser m (F Inlines)
strikeout = fmap B.strikeout <$>
 (guardEnabled Ext_strikeout >> inlinesBetween strikeStart strikeEnd)
    where strikeStart = string "~~" >> lookAhead nonspaceChar
                        >> notFollowedBy (char '~')
          strikeEnd   = try $ string "~~"

superscript :: Monad m => MarkdownParser m (F Inlines)
superscript = fmap B.superscript <$> try (do
  guardEnabled Ext_superscript
  char '^'
  mconcat <$> many1Till (notFollowedBy spaceChar >> inline) (char '^'))

subscript :: Monad m => MarkdownParser m (F Inlines)
subscript = fmap B.subscript <$> try (do
  guardEnabled Ext_subscript
  char '~'
  mconcat <$> many1Till (notFollowedBy spaceChar >> inline) (char '~'))

whitespace :: Monad m => MarkdownParser m (F Inlines)
whitespace = spaceChar >> return <$> (lb <|> regsp) <?> "whitespace"
  where lb = spaceChar >> skipMany spaceChar >> option B.space (endline >> return B.linebreak)
        regsp = skipMany spaceChar >> return B.space

nonEndline :: Monad m => MarkdownParser m Char
nonEndline = satisfy (/='\n')

str :: Monad m => MarkdownParser m (F Inlines)
str = do
  isSmart <- readerSmart . stateOptions <$> getState
  a <- alphaNum
  as <- many $ alphaNum
            <|> (guardEnabled Ext_intraword_underscores >>
                 try (char '_' >>~ lookAhead alphaNum))
            <|> if isSmart
                   then (try $ satisfy (\c -> c == '\'' || c == '\x2019') >>
                         lookAhead alphaNum >> return '\x2019')
                         -- for things like l'aide
                   else mzero
  pos <- getPosition
  updateState $ \s -> s{ stateLastStrPos = Just pos }
  let result = a:as
  let spacesToNbr = map (\c -> if c == ' ' then '\160' else c)
  if isSmart
     then case likelyAbbrev result of
               []        -> return $ return $ B.str result
               xs        -> choice (map (\x ->
                               try (string x >> oneOf " \n" >>
                                    lookAhead alphaNum >>
                                    return (return $ B.str
                                                  $ result ++ spacesToNbr x ++ "\160"))) xs)
                           <|> (return $ return $ B.str result)
     else return $ return $ B.str result

-- | if the string matches the beginning of an abbreviation (before
-- the first period, return strings that would finish the abbreviation.
likelyAbbrev :: String -> [String]
likelyAbbrev x =
  let abbrevs = [ "Mr.", "Mrs.", "Ms.", "Capt.", "Dr.", "Prof.",
                  "Gen.", "Gov.", "e.g.", "i.e.", "Sgt.", "St.",
                  "vol.", "vs.", "Sen.", "Rep.", "Pres.", "Hon.",
                  "Rev.", "Ph.D.", "M.D.", "M.A.", "p.", "pp.",
                  "ch.", "sec.", "cf.", "cp."]
      abbrPairs = map (break (=='.')) abbrevs
  in  map snd $ filter (\(y,_) -> y == x) abbrPairs

-- an endline character that can be treated as a space, not a structural break
endline :: Monad m => MarkdownParser m (F Inlines)
endline = try $ do
  newline
  notFollowedBy blankline
  guardEnabled Ext_blank_before_blockquote <|> notFollowedBy emailBlockQuoteStart
  guardEnabled Ext_blank_before_header <|> notFollowedBy (char '#') -- atx header
  -- parse potential list-starts differently if in a list:
  st <- getState
  when (stateParserContext st == ListItemState) $ do
     notFollowedBy' bulletListStart
     notFollowedBy' anyOrderedListStart
  (guardEnabled Ext_hard_line_breaks >> return (return B.linebreak))
    <|> (return $ return B.space)

--
-- links
--

-- a reference label for a link
reference :: Monad m => MarkdownParser m (F Inlines, String)
reference = do notFollowedBy' (string "[^")   -- footnote reference
               withRaw $ trimInlinesF <$> inlinesInBalancedBrackets

-- source for a link, with optional title
source :: Monad m => MarkdownParser m (String, String)
source =
  (try $ charsInBalanced '(' ')' litChar >>= parseFromString source') <|>
  -- the following is needed for cases like:  [ref](/url(a).
  (enclosed (char '(') (char ')') litChar >>= parseFromString source')

-- auxiliary function for source
source' :: Monad m => MarkdownParser m (String, String)
source' = do
  skipSpaces
  let nl = char '\n' >>~ notFollowedBy blankline
  let sourceURL = liftM unwords $ many $ try $ do
                    notFollowedBy' linkTitle
                    skipMany spaceChar
                    optional nl
                    skipMany spaceChar
                    many1 $ escapedChar' <|> satisfy (not . isBlank)
  let betweenAngles = try $
         char '<' >> manyTill (escapedChar' <|> noneOf ">\n" <|> nl) (char '>')
  src <- try betweenAngles <|> sourceURL
  tit <- option "" linkTitle
  skipSpaces
  eof
  return (escapeURI $ trimr src, tit)

linkTitle :: Monad m => MarkdownParser m String
linkTitle = try $ do
  (many1 spaceChar >> option '\n' newline) <|> newline
  skipSpaces
  delim <- oneOf "'\""
  tit <-   manyTill litChar (try (char delim >> skipSpaces >> eof))
  return $ fromEntities tit

link :: Monad m => MarkdownParser m (F Inlines)
link = try $ do
  st <- getState
  guard $ stateAllowLinks st
  setState $ st{ stateAllowLinks = False }
  (lab,raw) <- reference
  setState $ st{ stateAllowLinks = True }
  regLink B.link lab <|> referenceLink B.link (lab,raw)

regLink :: Monad m => (String -> String -> Inlines -> Inlines)
        -> F Inlines -> MarkdownParser m (F Inlines)
regLink constructor lab = try $ do
  (src, tit) <- source
  return $ constructor src tit <$> lab

-- a link like [this][ref] or [this][] or [this]
referenceLink :: Monad m => (String -> String -> Inlines -> Inlines)
              -> (F Inlines, String) -> MarkdownParser m (F Inlines)
referenceLink constructor (lab, raw) = do
  raw' <- try (optional (char ' ') >>
               optional (newline >> skipSpaces) >>
               (snd <$> reference)) <|> return ""
  let key = toKey $ if raw' == "[]" || raw' == "" then raw else raw'
  let dropRB (']':xs) = xs
      dropRB xs = xs
  let dropLB ('[':xs) = xs
      dropLB xs = xs
  let dropBrackets = reverse . dropRB . reverse . dropLB
  fallback <- parseFromString (mconcat <$> many inline) $ dropBrackets raw
  return $ do
    keys <- asksF stateKeys
    case M.lookup key keys of
       Nothing        -> (\x -> B.str "[" <> x <> B.str "]" <> B.str raw') <$> fallback
       Just (src,tit) -> constructor src tit <$> lab

bareURL :: Monad m => MarkdownParser m (F Inlines)
bareURL = try $ do
  guardEnabled Ext_autolink_urls
  (orig, src) <- uri <|> emailAddress
  return $ return $ B.link src "" (B.codeWith ("",["url"],[]) orig)

autoLink :: Monad m => MarkdownParser m (F Inlines)
autoLink = try $ do
  char '<'
  (orig, src) <- uri <|> emailAddress
  char '>'
  return $ return $ B.link src "" (B.codeWith ("",["url"],[]) orig)

image :: Monad m => MarkdownParser m (F Inlines)
image = try $ do
  char '!'
  (lab,raw) <- reference
  regLink B.image lab <|> referenceLink B.image (lab,raw)

note :: Monad m => MarkdownParser m (F Inlines)
note = try $ do
  guardEnabled Ext_footnotes
  ref <- noteMarker
  return $ do
    notes <- asksF stateNotes'
    case lookup ref notes of
        Nothing       -> return $ B.str $ "[^" ++ ref ++ "]"
        Just contents -> do
          st <- askF
          -- process the note in a context that doesn't resolve
          -- notes, to avoid infinite looping with notes inside
          -- notes:
          let contents' = runF contents st{ stateNotes' = [] }
          return $ B.note contents'

inlineNote :: Monad m => MarkdownParser m (F Inlines)
inlineNote = try $ do
  guardEnabled Ext_inline_notes
  char '^'
  contents <- inlinesInBalancedBrackets
  return $ B.note . B.para <$> contents

rawLaTeXInline' :: Monad m => MarkdownParser m (F Inlines)
rawLaTeXInline' = try $ do
  guardEnabled Ext_raw_tex
  lookAhead $ char '\\' >> notFollowedBy' (string "start") -- context env
  RawInline _ s <- rawLaTeXInline
  return $ return $ B.rawInline "tex" s
  -- "tex" because it might be context or latex

rawConTeXtEnvironment :: Monad m => MarkdownParser m String
rawConTeXtEnvironment = try $ do
  string "\\start"
  completion <- inBrackets (letter <|> digit <|> spaceChar)
               <|> (many1 letter)
  contents <- manyTill (rawConTeXtEnvironment <|> (count 1 anyChar))
                       (try $ string "\\stop" >> string completion)
  return $ "\\start" ++ completion ++ concat contents ++ "\\stop" ++ completion

inBrackets :: Monad m => (MarkdownParser m Char) -> MarkdownParser m String
inBrackets parser = do
  char '['
  contents <- many parser
  char ']'
  return $ "[" ++ contents ++ "]"

rawHtmlInline :: Monad m => MarkdownParser m (F Inlines)
rawHtmlInline = do
  guardEnabled Ext_raw_html
  mdInHtml <- option False $
                guardEnabled Ext_markdown_in_html_blocks >> return True
  (_,result) <- if mdInHtml
                   then htmlTag isInlineTag
                   else htmlTag (not . isTextTag)
  return $ return $ B.rawInline "html" result

-- Citations

cite :: Monad m => MarkdownParser m (F Inlines)
cite = do
  guardEnabled Ext_citations
  getOption readerCitations >>= guard . not . null
  citations <- textualCite <|> normalCite
  return $ flip B.cite mempty <$> citations

textualCite :: Monad m => MarkdownParser m (F [Citation])
textualCite = try $ do
  (_, key) <- citeKey
  let first = Citation{ citationId      = key
                      , citationPrefix  = []
                      , citationSuffix  = []
                      , citationMode    = AuthorInText
                      , citationNoteNum = 0
                      , citationHash    = 0
                      }
  mbrest <- option Nothing $ try $ spnl >> Just <$> normalCite
  case mbrest of
       Just rest  -> return $ (first:) <$> rest
       Nothing    -> option (return [first]) $ bareloc first

bareloc :: Monad m => Citation -> MarkdownParser m (F [Citation])
bareloc c = try $ do
  spnl
  char '['
  suff <- suffix
  rest <- option (return []) $ try $ char ';' >> citeList
  spnl
  char ']'
  return $ do
    suff' <- suff
    rest' <- rest
    return $ c{ citationSuffix = B.toList suff' } : rest'

normalCite :: Monad m => MarkdownParser m (F [Citation])
normalCite = try $ do
  char '['
  spnl
  citations <- citeList
  spnl
  char ']'
  return citations

citeKey :: Monad m => MarkdownParser m (Bool, String)
citeKey = try $ do
  suppress_author <- option False (char '-' >> return True)
  char '@'
  first <- letter
  let internal p = try $ p >>~ lookAhead (letter <|> digit)
  rest <- many $ letter <|> digit <|> internal (oneOf ":.#$%&-_?<>~")
  let key = first:rest
  citations' <- getOption readerCitations
  guard $ key `elem` citations'
  return (suppress_author, key)

suffix :: Monad m => MarkdownParser m (F Inlines)
suffix = try $ do
  hasSpace <- option False (notFollowedBy nonspaceChar >> return True)
  spnl
  rest <- trimInlinesF . mconcat <$> many (notFollowedBy (oneOf ";]") >> inline)
  return $ if hasSpace
              then (B.space <>) <$> rest
              else rest

prefix :: Monad m => MarkdownParser m (F Inlines)
prefix = trimInlinesF . mconcat <$>
  manyTill inline (char ']' <|> liftM (const ']') (lookAhead citeKey))

citeList :: Monad m => MarkdownParser m (F [Citation])
citeList = fmap sequence $ sepBy1 citation (try $ char ';' >> spnl)

citation :: Monad m => MarkdownParser m (F Citation)
citation = try $ do
  pref <- prefix
  (suppress_author, key) <- citeKey
  suff <- suffix
  return $ do
    x <- pref
    y <- suff
    return $ Citation{ citationId      = key
                     , citationPrefix  = B.toList x
                     , citationSuffix  = B.toList y
                     , citationMode    = if suppress_author
                                            then SuppressAuthor
                                            else NormalCitation
                     , citationNoteNum = 0
                     , citationHash    = 0
                     }

smart :: Monad m => MarkdownParser m (F Inlines)
smart = do
  getOption readerSmart >>= guard
  doubleQuoted <|> singleQuoted <|>
    choice (map (return . B.singleton <$>) [apostrophe, dash, ellipses])

singleQuoted :: Monad m => MarkdownParser m (F Inlines)
singleQuoted = try $ do
  singleQuoteStart
  withQuoteContext InSingleQuote $
    fmap B.singleQuoted . trimInlinesF . mconcat <$>
      many1Till inline singleQuoteEnd

doubleQuoted :: Monad m => MarkdownParser m (F Inlines)
doubleQuoted = try $ do
  doubleQuoteStart
  withQuoteContext InDoubleQuote $
    fmap B.doubleQuoted . trimInlinesF . mconcat <$>
      many1Till inline doubleQuoteEnd
