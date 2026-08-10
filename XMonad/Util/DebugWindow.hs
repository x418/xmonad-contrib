-----------------------------------------------------------------------------
-- |
-- Module      :  XMonad.Util.DebugWindow
-- Description :  Dump window information for diagnostic\/debugging purposes.
-- Copyright   :  (c) Brandon S Allbery KF8NH, 2014
-- License     :  BSD3-style (see LICENSE)
--
-- Maintainer  :  allbery.b@gmail.com
-- Stability   :  unstable
-- Portability :  not portable
--
-- Module to dump window information for diagnostic/debugging purposes. See
-- "XMonad.Hooks.DebugStack" for practical uses.
--
-- Upstream builds its line by reading the window's X properties: @WM_CLASS@,
-- @WM_NAME@ and its EWMH replacements, @WM_COMMAND@, @WM_CLIENT_MACHINE@,
-- @_NET_WM_PID@, @_NET_WM_WINDOW_TYPE@ and @_NET_WM_STATE@, plus the geometry
-- and map state from @XGetWindowAttributes@.  None of that is readable here --
-- a Wayland client's identity is whatever it told the compositor, and the
-- compositor forwards a fixed set of it.
--
-- So this reports what river actually knows, in the same shape: the window id,
-- its title, the rectangle the last layout gave it, its @app_id@, and the pid
-- of the process that created it.  What is gone with the properties:
--
-- * the ICCCM resource /name/ -- river has one @app_id@ where X11 had an
--   instance and a class, so one string is printed rather than @name\/class@;
--
-- * @WM_COMMAND@ and @WM_CLIENT_MACHINE@.  Nothing carries a client's argv,
--   and Wayland has no network transparency for a hostname to distinguish;
--
-- * the override-redirect marker.  There is no such flag: a Wayland client
--   cannot opt out of window management, it can only use a different shell;
--
-- * the EWMH window type.  'XMonad.Hooks.ManageHelpers.isDialog' answers the
--   one question it was usually asked, from @xdg_toplevel.set_parent@, so a
--   window with a parent is reported as transient instead.
--
-----------------------------------------------------------------------------

module XMonad.Util.DebugWindow (debugWindow) where

import           Prelude

import           XMonad
import           XMonad.Prelude
import           XMonad.River                    (windowRect)
import           XMonad.Hooks.ManageHelpers      (isFullscreen, isMinimized, pid, transientTo)
import qualified XMonad.StackSet                 as W
import qualified Data.Map                        as M

-- | Output a window by ID, its title if available, the rectangle the last
--   layout run gave it, its @app_id@, and the pid of its client.  Wrap in
--   brackets if the window is not currently placed on a screen -- which is
--   this backend's version of unmapped, and covers a window on a hidden
--   workspace as well as one that has just appeared and not yet been laid out.
--
--   The id is shown as river's own logs and @wayland-debug@ spell it -- @#12@
--   rather than upstream's zero-padded hex -- so that a line here can be
--   matched against a river log by eye.  There is no null window to special
--   case: upstream's @debugWindow 0@ answered for X11's @none@, and a
--   'Window' here is a Wayland object id, which is only ever one river sent.
debugWindow   :: Window -> X String
debugWindow w =  do
  let wx = show w
  known <- withWindowSet $ return . W.member w
  r <- windowRect w
  if not known && isNothing r
    then return $ "(unknown window " ++ wx ++ ")"
    else do
      t  <- runQuery title w
      c  <- runQuery className w
      p  <- runQuery pid w
      tr <- runQuery transientTo w
      st <- windowState w
      let (lb,rb) = if isJust r then ("","") else ("[","]")
      return $ concat [lb
                      ,wx
                      ,if null t then "" else wrap t
                      ,maybe "" geometry r
                      ,if null c then "" else ' ':c
                      ,maybe "" (\p' -> "(" ++ show p' ++ ")") p
                      ,maybe "" (\tw -> " ->" ++ show tw) tr
                      ,st
                      ,rb
                      ]

geometry :: Rectangle -> String
geometry (Rectangle x y wid ht) =
  ' ' : show wid ++ 'x' : show ht ++ '@' : show x ++ ',' : show y

-- | The window state river reports, in the slot upstream fills with the EWMH
--   window type and @_NET_WM_STATE@.
windowState   :: Window -> X String
windowState w =  do
  f <- runQuery isFullscreen w
  m <- runQuery isMinimized w
  flt <- withWindowSet $ return . M.member w . W.floating
  let ss = ["fullscreen" | f] ++ ["minimized" | m] ++ ["floating" | flt]
  return $ if null ss then "" else " (" ++ unwords ss ++ ")"

wrap   :: String -> String
wrap s =  ' ' : '"' : wrap' s ++ "\""
  where
    wrap' (s':ss) | s' == '"'  = '\\' : s' : wrap' ss
                  | s' == '\\' = '\\' : s' : wrap' ss
                  | otherwise  =        s' : wrap' ss
    wrap' ""                   =             ""
