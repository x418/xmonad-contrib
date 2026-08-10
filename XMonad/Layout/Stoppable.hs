{-# LANGUAGE MultiParamTypeClasses, TypeSynonymInstances #-}
{-# LANGUAGE PatternGuards #-}
-----------------------------------------------------------------------------
-- |
-- Module      :  XMonad.Layout.Stoppable
-- Description :  A layout modifier to stop all non-visible processes.
-- Copyright   :  (c) Anton Vorontsov <anton@enomsg.org> 2014
-- License     :  BSD-style (as xmonad)
--
-- Maintainer  :  Anton Vorontsov <anton@enomsg.org>
-- Stability   :  unstable
-- Portability :  unportable
--
-- This module implements a special kind of layout modifier, which when
-- applied to a layout, causes xmonad to stop all non-visible processes.
-- In a way, this is a sledge-hammer for applications that drain power.
-- For example, given a web browser on a stoppable workspace, once the
-- workspace is hidden the web browser will be stopped.
--
-- Note that the stopped application won't be able to communicate with X11
-- clipboard. For this, the module actually stops applications after a
-- certain delay, giving a chance for a user to complete copy-paste
-- sequence. By default, the delay equals to 15 seconds, it is
-- configurable via 'Stoppable' constructor.
--
-- The stoppable modifier prepends a mark (by default equals to
-- \"Stoppable\") to the layout description (alternatively, you can choose
-- your own mark and use it with 'Stoppable' constructor). The stoppable
-- layout (identified by a mark) spans to multiple workspaces, letting you
-- to create groups of stoppable workspaces that only stop processes when
-- none of the workspaces are visible, and conversely, unfreezing all
-- processes even if one of the stoppable workspaces are visible.
--
-- To stop the process we use signals, which works for most cases. For
-- processes that tinker with signal handling (debuggers), another
-- (Linux-centric) approach may be used. See
-- <https://www.kernel.org/doc/Documentation/cgroups/freezer-subsystem.txt>
--
-- * Note
-- This module doesn't work on programs that do fancy things with processes
-- (such as Chromium) and programs whose pid river does not know.
-----------------------------------------------------------------------------

module XMonad.Layout.Stoppable
    ( -- $usage
      Stoppable(..)
    , stoppable
    ) where

import XMonad
import XMonad.Prelude
import XMonad.Actions.WithAll
import XMonad.Hooks.ManageHelpers (pid)
import XMonad.Util.Timer
import XMonad.StackSet hiding (filter)
import XMonad.Layout.LayoutModifier
import System.Posix.Signals

-- $usage
-- You can use this module with the following in your @xmonad.hs@:
--
-- > import XMonad
-- > import XMonad.Layout.Stoppable
-- >
-- > main = xmonad def
-- >    { layoutHook = layoutHook def ||| stoppable (layoutHook def) }
--
-- Upstream signals only windows it decides are local, by comparing a window's
-- @WM_CLIENT_MACHINE@ against the hostname -- an X client could be running on
-- another machine, where sending it a signal would be meaningless.  Wayland
-- has no network transparency, so every window here belongs to a process on
-- this machine and the distinction, along with "XMonad.Util.RemoteWindows",
-- has nothing left to describe.
--
-- For more detailed instructions on editing the layoutHook see
-- <https://xmonad.org/TUTORIAL.html#customizing-xmonad the tutorial> and
-- "XMonad.Doc.Extending#Editing_the_layout_hook".

-- | Signal the process that created a window, if river knows which one that
-- is.  @river_window_v1.unreliable_pid@ is what @_NET_WM_PID@ was, with the
-- same caveat under both: a client may lie about it, and a pid may have been
-- reused since.
signalWindow :: Signal -> Window -> X ()
signalWindow s w = do
    p <- runQuery pid w
    io $ signalProcess s `mapM_` p

withAllOn :: (a -> X ()) -> Workspace i l a -> X ()
withAllOn f wspc = f `mapM_` integrate' (stack wspc)

withAllFiltered :: (Workspace i l a -> Bool)
                -> [Workspace i l a]
                -> (a -> X ()) -> X ()
withAllFiltered p wspcs f = withAllOn f `mapM_` filter p wspcs

sigStoppableWorkspacesHook :: String -> X ()
sigStoppableWorkspacesHook k = do
    ws <- gets windowset
    withAllFiltered isStoppable (hidden ws) (signalWindow sigSTOP)
  where
    isStoppable ws = k `elem` words (description $ layout ws)

-- | Data type for ModifiedLayout. The constructor lets you to specify a
-- custom mark/description modifier and a delay. You can also use
-- 'stoppable' helper function.
data Stoppable a = Stoppable
    { mark :: String
    , delay :: Rational
    , timer :: Maybe TimerId
    } deriving (Show,Read)

instance LayoutModifier Stoppable Window where
    modifierDescription = mark

    hook _   = withAll $ signalWindow sigCONT

    handleMess (Stoppable m _ (Just tid)) msg
        | Just ev <- fromMessage msg = handleTimer tid ev run
          where run = sigStoppableWorkspacesHook m >> return Nothing
    handleMess (Stoppable m d _) msg
        | Just Hide <- fromMessage msg =
            Just . Stoppable m d . Just <$> startTimer d
        | otherwise = return Nothing

-- | Convert a layout to a stoppable layout using the default mark
-- (\"Stoppable\") and a delay of 15 seconds.
stoppable :: l a -> ModifiedLayout Stoppable l a
stoppable = ModifiedLayout (Stoppable "Stoppable" 15 Nothing)
