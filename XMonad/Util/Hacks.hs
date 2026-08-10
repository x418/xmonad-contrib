-----------------------------------------------------------------------------
-- |
-- Module      :  XMonad.Util.Hacks
-- Description :  A collection of small fixes and utilities with possibly hacky implementations.
-- Copyright   :  (c) 2020 Leon Kowarschick
-- License     :  BSD3-style (see LICENSE)
--
-- Maintainer  :  Leon Kowarschick. <thereal.elkowar@gmail.com>
-- Stability   :  unstable
-- Portability :  unportable
--
-- This module is a collection of random fixes, workarounds and other functions
-- that rely on somewhat hacky implementations which may have unwanted side effects
-- and/or are small enough to not warrant a separate module.
--
-- Import this module as qualified like so:
--
-- > import qualified XMonad.Util.Hacks as Hacks
--
-- and then use the functions you want as described in their respective documentation.
--
-----------------------------------------------------------------------------

module XMonad.Util.Hacks (
  -- * Java Hack
  -- $java
  javaHack,

  -- * What upstream has and this does not
  -- $unportable
  ) where


import XMonad (XConfig (..), io)
import System.Posix.Env (putEnv)


-- $java
-- Some java Applications might not work with xmonad. A common workaround would be to set the environment
-- variable @_JAVA_AWT_WM_NONREPARENTING@ to 1. The function 'javaHack' does exactly that.
-- Example usage:
--
-- > main = xmonad $ Hacks.javaHack (def {...})
--

-- | Fixes Java applications that don't work well with xmonad, by setting @_JAVA_AWT_WM_NONREPARENTING=1@
javaHack :: XConfig l -> XConfig l
javaHack conf = conf
  { startupHook = startupHook conf
                    *> io (putEnv "_JAVA_AWT_WM_NONREPARENTING=1")
  }


-- $unportable
-- Upstream also has @windowedFullscreenFixEventHook@,
-- @trayerAboveXmobarEventHook@, @trayAbovePanelEventHook@,
-- @trayerPaddingXmobarEventHook@, @trayPaddingXmobarEventHook@,
-- @trayPaddingEventHook@ and @fixSteamFlicker@.  Each is a workaround for
-- something X11 let a window manager reach into and Wayland does not:
--
-- * the windowed-fullscreen and Steam fixes answer a @_NET_WM_STATE@ client
--   message by resizing a window behind its back.  Neither the message nor
--   the resize exists here -- a river client negotiates its own size with the
--   compositor;
--
-- * the tray stacking hook walks @queryTree@ and calls @lowerWindow@.  River
--   restacks from the layout on every frame, so there is no persistent
--   stacking order to poke at, and no tree to walk;
--
-- * the tray padding hooks are driven by @ConfigureNotify@ on another
--   client's window, and report the new width through a root-window property
--   for xmobar to read.  A window manager under Wayland is not told when a
--   client resizes itself, and there is no root window.
--
-- 'javaHack' is what is left, because it was never about X11 in the first
-- place: it sets an environment variable, and the AWT toolkit it aims at
-- still reads it when running under XWayland.
