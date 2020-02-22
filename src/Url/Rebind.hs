{-# LANGUAGE
    OverloadedStrings
  , BangPatterns
  , UnboxedTuples
  , UnboxedSums
  , MagicHash
  , RebindableSyntax
  , ScopedTypeVariables
  , LambdaCase
  , RecordWildCards
  , NamedFieldPuns
  , ApplicativeDo
#-}

-- The parser lives in its own module because it uses RebindableSyntax,
-- which adversely affects inference and error messages.
module Url.Rebind
  ( parserUrl
  ) where

import Prelude hiding ((>>=),(>>),pure)
import Data.Bytes.Parser.Rebindable ((>>),(>>=),pure)

import Url.Unsafe (Url(..),ParseError(..))
import Data.Char (ord)
import Data.Word (Word8)
import Data.Bytes.Types (Bytes(..))
import GHC.Exts (Int(I#),Int#,Word#,(+#),(<#),(-#),orI#,(>=#),(==#),(>#))
import GHC.Word (Word(W#),Word16(W16#))
import qualified Data.Bytes as Bytes
import qualified Data.Bytes.Parser as P
import qualified Data.Bytes.Parser.Latin as P (skipUntil, char2, decWord16)
import qualified Data.Bytes.Parser.Unsafe as PU
import qualified GHC.Exts as Exts

-- | Parser type from @bytesmith@
-- Note: non-hierarchical Urls (such as relative paths) will not currently parse.
parserUrl :: Bytes -> P.Parser ParseError s Url
parserUrl urlSerialization = let !(I# len) = Bytes.length urlSerialization in
  -- TODO: use skipTrailedByEither later
  P.measure
    ( P.skipTrailedBy2 EndOfInput (c2w ':') (c2w '/')
      `P.orElse`
      pure False
    )
  >>= \(I# i1, !colonFirst) ->
    ( case colonFirst of
        False ->
          P.char2 InvalidAuthority '/' '/' >> pure (i1 -# 1# )
        True ->
          -- Jump to position zero is unsound!!!
          PU.jump 0 >> pure 0#
    )
  >>= \urlSchemeEnd -> PU.cursor#
  >>= \userStart -> P.measure_# (P.skipUntil ':')
  >>= \i3 -> PU.unconsume (I# i3)
  >>  P.measure_# (P.skipUntil '@')
  >>= \i4 -> PU.unconsume (I# i4)
  >>  P.measure_# (P.skipUntil '/')
  >>= \i5 -> PU.unconsume (I# i5)
  >>  ( case (i4 >=# i5) `orI#` (i3 ==# i4) of
          1# -> PU.jump (I# userStart) >> pure userStart
          _ -> let jumpi = i4 in
            case i3 <# i4 of
              1# -> PU.jump (I# (userStart +# jumpi +# 1# )) >> pure (userStart +# i3)
              _ -> PU.jump (I# (userStart +# jumpi +# 1# )) >> pure (userStart +# i4)
      )
  >>= \urlUsernameEnd -> PU.cursor#
  >>= \urlHostStart ->
    ( P.skipTrailedBy2# EndOfInput (c2w ':') (c2w '/')
      -- Why was this orElse here? When it is commented out,
      -- all tests still pass.
      -- `P.orElse`
      -- pure False
    )
  >>= \colonFirst2 ->
    ( case colonFirst2 of
        0# -> PU.cursor#
          >>= \urlHostEnd -> P.decWord16 InvalidPort
          >>= \(W16# urlPort) ->
          pure (# urlHostEnd -# 1#, Exts.word2Int# urlPort #)
        _ -> -- PU.jump (I# ((urlHostStart +# i6) -# 1# ))
              PU.cursor#
          >>= \urlHostEnd' ->
              -- Backing up by one since we want to put the slash back
              -- to let it be part of the path.
              let urlHostEnd = urlHostEnd' -# 1# in
              PU.jump (I# urlHostEnd)
          >>  pure (# urlHostEnd, 0x10000# #)
    )
  >>= \(# !urlHostEnd, !urlPort #) -> PU.cursor#
  >>= \urlPathStart -> P.measure_# (P.skipUntil '?')
  >>= \i8 -> PU.unconsume (I# i8)
  >>  P.measure_# (P.skipUntil '#')
  >>= \i9 -> PU.unconsume (I# i9)
  >>  ( case intCompare# i8 i9 of
          EQ -> pure (# len, len #)
          LT -> P.skipUntil '#'
            >>  P.isEndOfInput
            >>= \eoi -> 
            let !urlFragmentStart = case eoi of
                  True -> len
                  False -> i9 +# urlPathStart
             in pure (# (i8 +# urlPathStart), urlFragmentStart #)
          GT -> P.skipUntil '#'
            >>  P.isEndOfInput
            >>= \eoi ->
            let !urlFragmentStart = case eoi of
                  True -> len
                  False -> i9 +# urlPathStart
             in pure (# urlFragmentStart, urlFragmentStart #)
      )
  >>= \(# !urlQueryStart, !urlFragmentStart #) ->
  pure (Url {..})

intCompare# :: Int# -> Int# -> Ordering
intCompare# a b = case a ==# b of
  0# -> case a ># b of
    0# -> LT
    _ -> GT
  _ -> EQ

-- | Unsafe conversion between 'Char' and 'Word8'. This is a no-op and
-- silently truncates to 8 bits Chars > '\255'. It is provided as
-- convenience for ByteString construction.
c2w :: Char -> Word8
c2w = fromIntegral . ord
{-# INLINE c2w #-}
