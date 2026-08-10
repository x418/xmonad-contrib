{-# OPTIONS_GHC -fno-warn-missing-signatures #-}
-- TODO: Remove when we depend on a version of xmonad that has unGrab.
{-# OPTIONS_GHC -Wno-deprecations  #-}
{-# OPTIONS_GHC -Wno-dodgy-imports #-}
-----------------------------------------------------------------------------
-- |
-- Module       : XMonad.Config.Mate
-- Description  : Config for integrating xmonad with MATE.
-- Copyright    : (c) Brandon S Allbery KF8NH, 2014
-- License      : BSD
--
-- Maintainer   : allbery.b@gmail.com
-- Stability    :  unstable
-- Portability  :  unportable
--
-- This module provides a config suitable for use with the MATE desktop
-- environment.
--
-----------------------------------------------------------------------------

module XMonad.Config.Mate (
    -- * Usage
    -- $usage
    mateConfig,
    mateRegister,
    mateLogout,
    mateShutdown,
    desktopLayoutModifiers
    ) where

import System.Environment (getEnvironment)
import qualified Data.Map as M

import XMonad
import XMonad.Config.Desktop
import XMonad.Util.Run (safeSpawn)

-- $usage
-- To use this module, start with the following @xmonad.hs@:
--
-- > import XMonad
-- > import XMonad.Config.Mate
-- >
-- > main = xmonad mateConfig
--
-- For examples of how to further customize @mateConfig@ see "XMonad.Config.Desktop".

mateConfig = desktopConfig
    { terminal = "mate-terminal"
    , keys     = mateKeys <> keys desktopConfig
    , startupHook = mateRegister >> startupHook desktopConfig }

-- Upstream also binds mod-p and mod-d to @mateRun@ and @matePanel@, which ask
-- mate-panel to open its run dialog or main menu by sending a
-- @_MATE_PANEL_ACTION@ client message to the root window.  There is no root
-- window to send it to and no client reading one, so both are gone along with
-- their bindings; bind mod-p to @spawn "..."@ for whatever launcher the
-- session actually runs.  Losing @matePanel@ takes the @unGrab@ that guarded
-- it with them, which is just as well -- see "XMonad.Util.Ungrab".
mateKeys XConfig{modMask = modm} = M.fromList
    [ ((modm .|. shiftMask, xK_q), mateLogout) ]

-- | Register xmonad with mate. 'dbus-send' must be in the $PATH with which
-- xmonad is started.
--
-- This action reduces a delay on startup only if you have configured
-- mate-session to start xmonad with a command such as (check local
-- documentation):
--
-- > dconf write /org/mate/desktop/session/required_components/windowmanager "'xmonad'"
--
-- (the extra quotes are required by dconf)
mateRegister :: MonadIO m => m ()
mateRegister = io $ do
    x <- lookup "DESKTOP_AUTOSTART_ID" <$> getEnvironment
    whenJust x $ \sessionId -> safeSpawn "dbus-send"
            ["--session"
            ,"--print-reply=literal"
            ,"--dest=org.mate.SessionManager"
            ,"/org/mate/SessionManager"
            ,"org.mate.SessionManager.RegisterClient"
            ,"string:xmonad"
            ,"string:"++sessionId]

-- | Display MATE logout dialog. This is the default mod-q action.
mateLogout :: MonadIO m => m ()
mateLogout = spawn "mate-session-save --logout-dialog"

-- | Display MATE shutdown dialog. You can override mod-q to invoke this, or bind it
-- to another key if you prefer.
mateShutdown :: MonadIO m => m ()
mateShutdown = spawn "mate-session-save --shutdown-dialog"
