-----------------------------------------------------------------------------
-- |
-- Module       : XMonad.Hooks.EwmhDesktops
-- Description  : Make xmonad use the extended window manager hints (EWMH).
-- Copyright    : (c) 2007, 2008 Joachim Breitner <mail@joachim-breitner.de>
-- License      : BSD
--
-- Maintainer   : Joachim Breitner <mail@joachim-breitner.de>
-- Stability    : unstable
-- Portability  : unportable
--
-- Makes xmonad use the
-- <https://specifications.freedesktop.org/wm/latest/ EWMH>
-- hints to tell panel applications about its workspaces and the windows
-- therein. It also allows the user to interact with xmonad by clicking on
-- panels and window lists.
--
-- Under river it does none of that.  Every name is here, every config that
-- applies them still compiles, and each says once on stderr that it is doing
-- nothing.  See $river for why that is the shape chosen, and for the one entry
-- where "doing nothing" is a gap rather than a fact about Wayland.
-----------------------------------------------------------------------------
module XMonad.Hooks.EwmhDesktops (
    -- * Usage
    -- $usage
    ewmh,
    ewmhFullscreen,
    ewmhDesktopsManageHook,
    ewmhDesktopsMaybeManageHook,

    -- * Customization
    addEwmhWorkspaceSort, setEwmhWorkspaceSort,
    addEwmhWorkspaceRename, setEwmhWorkspaceRename,
    setEwmhActivateHook,
    setEwmhSwitchDesktopHook,
    setEwmhFullscreenHooks,
    disableEwmhManageDesktopViewport,
    setEwmhHiddenWorkspaceToScreenMapping,
    enableEwmhManageAboveBelowState,

    -- * Standalone hooks (deprecated)
    ewmhDesktopsStartup,
    ewmhDesktopsLogHook,
    ewmhDesktopsLogHookCustom,
    ewmhDesktopsEventHook,
    ewmhDesktopsEventHookCustom,
    fullscreenEventHook,
    fullscreenStartup,

    -- * Differences under river
    -- $river
    ) where

import XMonad
import XMonad.Prelude
import XMonad.Hooks.ManageHelpers (MaybeManageHook)
import XMonad.River (informFullscreen, warnUnimplemented)
import qualified XMonad.StackSet as W
import XMonad.Util.WorkspaceCompare (WorkspaceSort)

-- $usage
-- To use this module, add 'ewmh' to your config:
--
-- > main = xmonad $ ewmh def
--
-- It will build, run, and tell you once that it is inert.  What it used to buy
-- -- a panel that lists your workspaces, and a taskbar you can click -- has to
-- come from "XMonad.Hooks.StatusBar" instead:
--
-- > main = do
-- >   sb <- statusBarPipe "xmobar" (pure xmobarPP)
-- >   xmonad $ withSB sb def
--
-- See $river.

-- $river
--
-- EWMH is two channels, and Wayland has neither.
--
-- Outbound, it is properties on the X root window -- @_NET_CLIENT_LIST@,
-- @_NET_NUMBER_OF_DESKTOPS@, @_NET_DESKTOP_NAMES@, @_NET_CURRENT_DESKTOP@,
-- @_NET_WM_DESKTOP@, @_NET_ACTIVE_WINDOW@ -- which a panel or pager reads to
-- draw itself.  There is no root window and no properties, and river offers
-- nothing in their place: it binds three protocols to the window manager, none
-- of which is a status channel, and xmonad's workspaces are not river's tags.
--
-- Inbound, it is client messages a pager sends back for the window manager to
-- act on: switch to desktop N, move this window there, activate that window,
-- close it.  Wayland has no way for one client to address another, and river
-- forwards nothing of the kind.
--
-- So these functions are not silently failing at their job.  There is no
-- request that arrives and gets dropped, and no property whose absence changes
-- how xmonad behaves -- the inbound set is empty and the outbound one has
-- nowhere to go.  They are kept, rather than removed, because @ewmh@ appears in
-- very nearly every xmonad config in existence and deleting it would break all
-- of them to say something a one-line warning says better.  That is the same
-- judgement "XMonad.Hooks.ManageDocks" makes about @docks@, with one
-- difference worth being honest about: @docks@ still gets you the outcome it
-- asks for, by another route, and this does not.  A panel really will not know
-- your workspaces.  Hence the warning, which is what separates this from a
-- no-op that lies.
--
-- Each name warns once per process, on stderr, under one of three headings, so
-- a config applying several of them does not produce a wall of text:
--
-- [@ewmh@] everything on the publish-and-command side above.
--
-- [@ewmhFullscreen@] __works.__  River sends @fullscreen_requested@ and
-- @exit_fullscreen_requested@, the backend reports them as
-- @WindowFullscreenChanged@, and 'fullscreenEventHook' does what upstream's
-- does: floats the window over the whole screen and sinks it again, and --
-- through 'XMonad.River.informFullscreen' -- tells the client, so it drops
-- its toolbars.  For fullscreen inside a tiled layout use
-- "XMonad.Layout.Fullscreen" instead, as under X11.  'setEwmhFullscreenHooks'
-- alone is inert: the hooks it would install are the ones above.
--
-- [@setEwmhActivateHook@] __a gap, not a fact about Wayland.__  River
-- implements @xdg-activation-v1@, but its @handleRequestActivate@ does nothing
-- for a window yet, so no activation reaches this hook.  Written up in
-- @future-work.md@ §5; it is the only one of the three that is waiting on
-- anything.

ewmhWarning :: MonadIO m => m ()
ewmhWarning = warnUnimplemented "ewmh" $
    "EWMH publishes workspace and window state as X root-window properties and "
    ++ "reads pager requests back as client messages; Wayland has neither and "
    ++ "river offers nothing in their place. Nothing xmonad does changes -- no "
    ++ "request can arrive to be dropped -- but a panel will not learn your "
    ++ "workspaces. Feed it with XMonad.Hooks.StatusBar.statusBarPipe instead."

fullscreenWarning :: MonadIO m => m ()
fullscreenWarning = warnUnimplemented "setEwmhFullscreenHooks" $
    "ewmhFullscreen floats a fullscreen window over the screen and sinks it "
    ++ "again; the hooks that would customise that are not configurable here."

activateWarning :: MonadIO m => m ()
activateWarning = warnUnimplemented "setEwmhActivateHook" $
    "Activation exists here -- river implements xdg-activation-v1 -- but its "
    ++ "handleRequestActivate does nothing for a window yet, so no activation "
    ++ "reaches this hook. See future-work.md section 5."

-- | Run an action once at startup, in addition to whatever the config already
-- does.  Every config combinator in this module is this and nothing else.
atStartup :: X () -> XConfig l -> XConfig l
atStartup warn c = c{ startupHook = startupHook c <> warn }

-- | Add EWMH support to the given config.  Inert; see $river.
ewmh :: XConfig a -> XConfig a
ewmh = atStartup ewmhWarning

-- | Add fullscreen support to the given config: a client asking for
-- fullscreen floats over the whole screen and is told it is fullscreen; one
-- asking to leave is sunk.  See $river.
ewmhFullscreen :: XConfig a -> XConfig a
ewmhFullscreen c = c { handleEventHook = handleEventHook c <> fullscreenEventHook }

-- | Add (compose after) a function to sort/filter the workspace list before
-- publishing it.  There is nothing to publish; see $river.
addEwmhWorkspaceSort :: X WorkspaceSort -> XConfig l -> XConfig l
addEwmhWorkspaceSort _ = atStartup ewmhWarning

-- | Like 'addEwmhWorkspaceSort', but replace rather than compose.
setEwmhWorkspaceSort :: X WorkspaceSort -> XConfig l -> XConfig l
setEwmhWorkspaceSort _ = atStartup ewmhWarning

-- | Add (compose after) a function to rename workspaces in
-- @_NET_DESKTOP_NAMES@.  There is no such property; see $river.
addEwmhWorkspaceRename :: X (String -> WindowSpace -> String) -> XConfig l -> XConfig l
addEwmhWorkspaceRename _ = atStartup ewmhWarning

-- | Like 'addEwmhWorkspaceRename', but replace rather than compose.
setEwmhWorkspaceRename :: X (String -> WindowSpace -> String) -> XConfig l -> XConfig l
setEwmhWorkspaceRename _ = atStartup ewmhWarning

-- | Set what happens when a client asks to be activated.  Nothing does; see
-- $river.
setEwmhActivateHook :: ManageHook -> XConfig l -> XConfig l
setEwmhActivateHook _ = atStartup activateWarning

-- | Set what happens when a pager asks to switch desktop.  No pager can ask;
-- see $river.
setEwmhSwitchDesktopHook :: (WorkspaceId -> WindowSet -> WindowSet) -> XConfig l -> XConfig l
setEwmhSwitchDesktopHook _ = atStartup ewmhWarning

-- | Set what happens when a window enters and leaves fullscreen.  Nothing
-- routes the transition through /this/ module; see $river.
setEwmhFullscreenHooks :: ManageHook -> ManageHook -> XConfig l -> XConfig l
setEwmhFullscreenHooks _ _ = atStartup fullscreenWarning

-- | Disable @_NET_DESKTOP_VIEWPORT@ management.  It is not managed; see $river.
disableEwmhManageDesktopViewport :: XConfig l -> XConfig l
disableEwmhManageDesktopViewport = atStartup ewmhWarning

-- | Set the mapping of hidden workspaces to screens used when publishing
-- @_NET_DESKTOP_VIEWPORT@.  There is nothing to publish; see $river.
setEwmhHiddenWorkspaceToScreenMapping :: (WindowSet -> (WindowSpace -> WindowScreen))
                                      -> XConfig l -> XConfig l
setEwmhHiddenWorkspaceToScreenMapping _ = atStartup ewmhWarning

-- | Enable @_NET_WM_STATE_ABOVE@ and @_NET_WM_STATE_BELOW@ management.  There
-- is no such state to manage; see $river.
enableEwmhManageAboveBelowState :: XConfig l -> XConfig l
enableEwmhManageAboveBelowState = atStartup ewmhWarning

-- | A 'ManageHook' that shifts windows to the workspace they ask for in
-- @_NET_WM_DESKTOP@.  No window can ask; see $river.
ewmhDesktopsManageHook :: ManageHook
ewmhDesktopsManageHook = liftX ewmhWarning >> mempty

-- | 'ewmhDesktopsManageHook' as a 'MaybeManageHook'.
ewmhDesktopsMaybeManageHook :: MaybeManageHook
ewmhDesktopsMaybeManageHook = liftX ewmhWarning >> mempty

-- | Advertise EWMH support.  There is nothing to advertise it to; see $river.
{-# DEPRECATED ewmhDesktopsStartup "Use ewmh instead." #-}
ewmhDesktopsStartup :: X ()
ewmhDesktopsStartup = ewmhWarning

-- | Notify pagers and window lists of the current state.  There are none to
-- notify; see $river.
{-# DEPRECATED ewmhDesktopsLogHook "Use ewmh instead." #-}
ewmhDesktopsLogHook :: X ()
ewmhDesktopsLogHook = ewmhWarning

-- | 'ewmhDesktopsLogHook' with a workspace sort.
{-# DEPRECATED ewmhDesktopsLogHookCustom "Use ewmh and addEwmhWorkspaceSort instead." #-}
ewmhDesktopsLogHookCustom :: WorkspaceSort -> X ()
ewmhDesktopsLogHookCustom _ = ewmhWarning

-- | Intercept messages from pagers and act on them.  None arrive; see $river.
{-# DEPRECATED ewmhDesktopsEventHook "Use ewmh instead." #-}
ewmhDesktopsEventHook :: Event -> X All
ewmhDesktopsEventHook _ = ewmhWarning >> mempty

-- | 'ewmhDesktopsEventHook' with a workspace sort.
{-# DEPRECATED ewmhDesktopsEventHookCustom "Use ewmh and addEwmhWorkspaceSort instead." #-}
ewmhDesktopsEventHookCustom :: WorkspaceSort -> Event -> X All
ewmhDesktopsEventHookCustom _ _ = ewmhWarning >> mempty

-- | Advertise fullscreen support.  Nothing to advertise: river asks the
-- window manager about every fullscreen request regardless.
{-# DEPRECATED fullscreenStartup "Use ewmhFullscreen instead." #-}
fullscreenStartup :: X ()
fullscreenStartup = pure ()

-- | Act on a client's request to be fullscreen: float it over the screen, or
-- sink it, and tell it which.  What 'ewmhFullscreen' installs.
{-# DEPRECATED fullscreenEventHook "Use ewmhFullscreen instead." #-}
fullscreenEventHook :: Event -> X All
fullscreenEventHook WindowFullscreenChanged{ev_window = w, ev_fullscreen = full} = do
    windows $ if full then W.float w (W.RationalRect 0 0 1 1) else W.sink w
    informFullscreen w full
    pure (All True)
fullscreenEventHook _ = pure (All True)
