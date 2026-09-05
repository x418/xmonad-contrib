{-# LANGUAGE LambdaCase #-}
----------------------------------------------------------------------------
-- |
-- Module      :  XMonad.Util.River.Overlay
-- Description :  A window-manager surface with a client of its own.
-- License     :  BSD-style (see xmonad/LICENSE)
--
-- What a prompt, a completion list and a grid selector share: an offscreen
-- frame composed with the Xlib vocabulary of "XMonad.Util.River.Compat", a
-- layer-shell client on a connection of its own that presents that frame,
-- and a teardown that runs once however the surface goes away.
--
-- The frame is where two threads meet -- the module's own logic draws into
-- it, the client thread drains it -- and nowhere else.  A caller draws with
-- 'ovFrame' and 'ovGC', presents with 'redrawOverlay', and closes with
-- 'closeOverlay'; the client's own close (the compositor took the surface,
-- the startup watchdog gave up, the panic chord) reaches the caller through
-- 'osOnClose'.
-----------------------------------------------------------------------------
module XMonad.Util.River.Overlay
    ( Overlay(..)
    , OverlaySpec(..)
    , startOverlay
    , startOverlayOn
    , redrawOverlay
    , closeOverlay
    ) where

import Control.Monad (unless)
import Data.IORef (IORef, atomicModifyIORef', newIORef)

import XMonad.River (Anchor(..), ClientHandle(..), ClientSpec(..), startClient)
import XMonad.River.Types (Dimension, KeyMask, KeySym)
import XMonad.Util.River.Compat
    ( Drawable, GC, createGC, createPixmap, freeGC, freePixmap, renderDrawableInto )

-- | What to start.
data OverlaySpec = OverlaySpec
    { osWidth    :: !Dimension
    , osHeight   :: !Dimension
    , osAnchor   :: !Anchor
    , osMargin   :: !(Int, Int, Int, Int)
      -- ^ Top, right, bottom, left, as the layer shell takes them.
    , osKeyboard :: !Bool
      -- ^ Ask for exclusive keyboard interactivity.  One surface at a time
      -- should: two asking would fight over focus.
    , osOnKey    :: KeyMask -> KeySym -> String -> IO ()
      -- ^ A key, on the client's thread.
    , osOnClose  :: IO ()
      -- ^ The client went away on its own, on the client's thread.
    }

-- | A running overlay.
data Overlay = Overlay
    { ovFrame  :: !Drawable
      -- ^ Draw here, with the Compat vocabulary.
    , ovGC     :: !GC
    , ovHandle :: !ClientHandle
    , ovClosed :: !(IORef Bool)
    }

-- | Compose a frame and start the client that presents it.
startOverlay :: OverlaySpec -> IO Overlay
startOverlay spec = do
    frame <- createPixmap (osWidth spec) (osHeight spec)
    gc <- createGC
    startOverlayOn frame gc spec

-- | As 'startOverlay', over a frame and GC the caller already made (and
-- perhaps already drew into); the overlay owns them from here and
-- 'closeOverlay' frees them.
startOverlayOn :: Drawable -> GC -> OverlaySpec -> IO Overlay
startOverlayOn frame gc spec = do
    h <- startClient ClientSpec
        { csWidth  = fromIntegral (osWidth spec)
        , csHeight = fromIntegral (osHeight spec)
        , csAnchor = osAnchor spec
        , csMargin = osMargin spec
        , csKeyboard = osKeyboard spec
        , csDraw    = renderDrawableInto frame
        , csOnKey   = osOnKey spec
        , csOnClose = osOnClose spec
        }
    Overlay frame gc h <$> newIORef False

-- | Present what has been drawn into the frame.
redrawOverlay :: Overlay -> IO ()
redrawOverlay = chRedraw . ovHandle

-- | Tear the overlay down: the client, the frame and its GC.  Once only,
-- whichever route arrives first -- a selection made, the client's own
-- close, an exception unwinding the caller.
closeOverlay :: Overlay -> IO ()
closeOverlay ov = do
    already <- atomicModifyIORef' (ovClosed ov) (\was -> (True, was))
    unless already $ do
        chClose (ovHandle ov)
        freeGC (ovGC ov)
        freePixmap (ovFrame ov)
