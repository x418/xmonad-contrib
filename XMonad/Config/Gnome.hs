{-# OPTIONS_GHC -fno-warn-missing-signatures #-}

-----------------------------------------------------------------------------
-- |
-- Module       : XMonad.Config.Gnome
-- Description  : Config for integrating xmonad with GNOME.
-- Copyright    : (c) Spencer Janssen <spencerjanssen@gmail.com>
-- License      : BSD
--
-- Maintainer   : Spencer Janssen <spencerjanssen@gmail.com>
-- Stability    :  unstable
-- Portability  :  unportable
--
-- This module provides a config suitable for use with the GNOME desktop
-- environment.

module XMonad.Config.Gnome (
    -- * Usage
    -- $usage
    gnomeConfig,
    gnomeRegister,
    desktopLayoutModifiers
    ) where

import XMonad
import XMonad.Config.Desktop
import XMonad.Util.Run (safeSpawn)

import qualified Data.Map as M

import System.Environment (getEnvironment)

-- $usage
-- To use this module, start with the following @xmonad.hs@:
--
-- > import XMonad
-- > import XMonad.Config.Gnome
-- >
-- > main = xmonad gnomeConfig
--
-- For examples of how to further customize @gnomeConfig@ see "XMonad.Config.Desktop".

gnomeConfig = desktopConfig
    { terminal = "gnome-terminal"
    , keys     = gnomeKeys <> keys desktopConfig
    , startupHook = gnomeRegister >> startupHook desktopConfig }

-- | Upstream also binds mod-p to @gnomeRun@, which asks gnome-panel to open
-- its "Run Application" dialog by sending a @_GNOME_PANEL_ACTION@ client
-- message to the root window.  There is no root window to send it to and no
-- gnome-panel to receive it, so that binding is gone; bind mod-p to
-- @spawn "..."@ for whatever launcher the session actually runs.
gnomeKeys XConfig{modMask = modm} = M.fromList
    [ ((modm .|. shiftMask, xK_q), spawn "gnome-session-quit --logout") ]

-- | Register xmonad with gnome. 'dbus-send' must be in the $PATH with which
-- xmonad is started.
--
-- This action reduces a delay on startup only only if you have configured
-- gnome-session>=2.26: to start xmonad with a command as such:
--
-- > gconftool-2 -s /desktop/gnome/session/required_components/windowmanager xmonad --type string
gnomeRegister :: MonadIO m => m ()
gnomeRegister = io $ do
    x <- lookup "DESKTOP_AUTOSTART_ID" <$> getEnvironment
    whenJust x $ \sessionId -> safeSpawn "dbus-send"
            ["--session"
            ,"--print-reply=literal"
            ,"--dest=org.gnome.SessionManager"
            ,"/org/gnome/SessionManager"
            ,"org.gnome.SessionManager.RegisterClient"
            ,"string:xmonad"
            ,"string:"++sessionId]
