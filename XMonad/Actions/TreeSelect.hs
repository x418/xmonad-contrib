{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE CPP #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE MultiWayIf #-}
{-# LANGUAGE LambdaCase #-}
-----------------------------------------------------------------------------
-- |
-- Module      :  XMonad.Actions.TreeSelect
-- Description :  Display workspaces or actions in a tree-like format.
-- Copyright   :  (c) Tom Smeets <tom.tsmeets@gmail.com>
-- License     :  BSD3-style (see LICENSE)
--
-- Maintainer  :  Tom Smeets <tom.tsmeets@gmail.com>
-- Stability   :  unstable
-- Portability :  unportable
--
--
-- TreeSelect displays your workspaces or actions in a Tree-like format.
-- You can select the desired workspace/action with the cursor or hjkl keys.
--
-- This module is fully configurable and very useful if you like to have a
-- lot of workspaces.
--
-- Only the nodes up to the currently selected are displayed.
-- This will be configurable in the near future by changing 'ts_hidechildren' to @False@, this is not yet implemented.
--
-- <<https://wiki.haskell.org/wikiupload/thumb/0/0b/Treeselect-Workspace.png/800px-Treeselect-Workspace.png>>
--
-----------------------------------------------------------------------------
module XMonad.Actions.TreeSelect
    (
      -- * Usage
      -- $usage
      treeselectWorkspace
    , toWorkspaces
    , treeselectAction

      -- * Configuring
      -- $config
    , Pixel
      -- $river
--
-- Two things differ from the X11 original.
--
-- __'treeselect', 'treeselectAt' and 'treeselectWorkspace' take a
-- continuation__ rather than returning what was selected, and an entry in
-- 'ts_navigate' returns a 'TSNavigation' rather than tail-calling the loop.
-- Both come from the same fact: upstream grabs the keyboard and blocks in
-- @maskEvent@, so it can return an answer and an action can recurse into the
-- read. A key binding here may only be created during a manage sequence and
-- does not fire until that sequence has finished, so waiting inside one for a
-- key would be waiting for something the compositor is not permitted to send.
-- 'XMonad.River.submapNextKey' reads a key and returns immediately.
--
-- So a custom navigation entry that was
--
-- > moveWith parent >> redraw >> navigate
--
-- becomes
--
-- > moveWith parent >> redraw >> return TSContinue
--
-- and @select@ and @cancel@ return 'TSSelect' and 'TSCancel' where they
-- returned @Just@ and @Nothing@. 'XMonad.Actions.GridSelect' was inverted the
-- same way and for the same reason.
--
-- __A key with no binding ends the selection__, where upstream ignores it and
-- keeps waiting. It cannot here: 'XMonad.River.submapNextKey' reports an
-- unbound key and its 60-second abandonment deadline through the same
-- callback, and treating an unbound key as \"keep waiting\" would treat the
-- deadline that way too -- leaving a full-screen overlay on screen for the
-- rest of the session with no way to remove it.
--
-- One smaller thing: upstream builds its window with a 32-bit visual and a
-- private colormap so that 'ts_background' can be translucent. This draws on
-- an ordinary window manager surface, as "XMonad.Layout.Decoration" does, and
-- the alpha byte of 'ts_background' is ignored. Translucency would have to
-- come from the compositor.

-- $pixel

    , TSConfig(..)
    , tsDefaultConfig
    , def

      -- * Navigation
      -- $navigation
    , TSNavigation(..)
    , defaultNavigation
    , select
    , cancel
    , moveParent
    , moveChild
    , moveNext
    , movePrev
    , moveHistBack
    , moveHistForward
    , moveTo

      -- * Differences under river
      -- $river

      -- * Advanced usage
      -- $advusage
    , TSNode(..)
    , treeselect
    , treeselectAt
    ) where

import Control.Monad.Reader
import Control.Monad.State
import Data.Tree
import Foreign (shiftL, shiftR, (.&.))
import System.IO
import XMonad hiding (liftX)
import XMonad.Prelude
import XMonad.StackSet as W
import XMonad.Util.Font
import XMonad.Util.NamedWindows
import XMonad.Util.TreeZipper
import XMonad.Hooks.WorkspaceHistory
import qualified Data.Map as M
import Data.IORef (newIORef, readIORef, writeIORef)
import Text.Printf (printf)
import XMonad.River (submapNextKey)
import XMonad.Util.River.Compat (GC, createGC, freeGC, fillRectangle, setForeground)
import XMonad.Util.XUtils (createNewWindow, deleteWindow, showWindow)

-- $usage
--
-- These imports are used in the following example
--
-- > import Data.Tree
-- > import XMonad.Actions.TreeSelect
-- > import XMonad.Hooks.WorkspaceHistory
-- > import qualified XMonad.StackSet as W
--
-- For selecting Workspaces, you need to define them in a tree structure using 'Data.Tree.Node' instead of just a standard list
--
-- Here is an example workspace-tree
--
-- > myWorkspaces :: Forest String
-- > myWorkspaces = [ Node "Browser" [] -- a workspace for your browser
-- >                , Node "Home"       -- for everyday activity's
-- >                    [ Node "1" []   --  with 4 extra sub-workspaces, for even more activity's
-- >                    , Node "2" []
-- >                    , Node "3" []
-- >                    , Node "4" []
-- >                    ]
-- >                , Node "Programming" -- for all your programming needs
-- >                    [ Node "Haskell" []
-- >                    , Node "Docs"    [] -- documentation
-- >                    ]
-- >                ]
--
-- Then add it to your 'XMonad.Core.workspaces' using the 'toWorkspaces' function.
--
-- Optionally, if you add 'workspaceHistoryHook' to your 'logHook' you can use the \'o\' and \'i\' keys to select from previously-visited workspaces
--
-- > xmonad $ def { ...
-- >              , workspaces = toWorkspaces myWorkspaces
-- >              , logHook = workspaceHistoryHook
-- >              }
--
-- After that you still need to bind buttons to 'treeselectWorkspace' to start selecting a workspaces and moving windows
--
-- you could bind @Mod-f@ to switch workspace
--
-- >  , ((modMask, xK_f), treeselectWorkspace myTreeConf myWorkspaces W.greedyView)
--
-- and bind @Mod-Shift-f@ to moving the focused windows to a workspace
--
-- >  , ((modMask .|. shiftMask, xK_f), treeselectWorkspace myTreeConf myWorkspaces W.shift)

-- $config
-- The selection menu is very configurable, you can change the font, all colors and the sizes of the boxes.
--
-- The default config defined as 'def'
--
-- > def = TSConfig { ts_hidechildren = True
-- >                , ts_background   = 0xc0c0c0c0
-- >                , ts_font         = "xft:Sans-16"
-- >                , ts_node         = (0xff000000, 0xff50d0db)
-- >                , ts_nodealt      = (0xff000000, 0xff10b8d6)
-- >                , ts_highlight    = (0xffffffff, 0xffff0000)
-- >                , ts_extra        = 0xff000000
-- >                , ts_node_width   = 200
-- >                , ts_node_height  = 30
-- >                , ts_originX      = 0
-- >                , ts_originY      = 0
-- >                , ts_indent       = 80
-- >                , ts_navigate     = defaultNavigation
-- >                }

-- $river
--
-- Two things differ from the X11 original.
--
-- __'treeselect', 'treeselectAt' and 'treeselectWorkspace' take a
-- continuation__ rather than returning what was selected, and an entry in
-- 'ts_navigate' returns a 'TSNavigation' rather than tail-calling the loop.
-- Both come from the same fact: upstream grabs the keyboard and blocks in
-- @maskEvent@, so it can return an answer and an action can recurse into the
-- read. A key binding here may only be created during a manage sequence and
-- does not fire until that sequence has finished, so waiting inside one for a
-- key would be waiting for something the compositor is not permitted to send.
-- 'XMonad.River.submapNextKey' reads a key and returns immediately.
--
-- So a custom navigation entry that was
--
-- > moveWith parent >> redraw >> navigate
--
-- becomes
--
-- > moveWith parent >> redraw >> return TSContinue
--
-- and @select@ and @cancel@ return 'TSSelect' and 'TSCancel' where they
-- returned @Just@ and @Nothing@. 'XMonad.Actions.GridSelect' was inverted the
-- same way and for the same reason.
--
-- __A key with no binding ends the selection__, where upstream ignores it and
-- keeps waiting. It cannot here: 'XMonad.River.submapNextKey' reports an
-- unbound key and its 60-second abandonment deadline through the same
-- callback, and treating an unbound key as \"keep waiting\" would treat the
-- deadline that way too -- leaving a full-screen overlay on screen for the
-- rest of the session with no way to remove it.
--
-- One smaller thing: upstream builds its window with a 32-bit visual and a
-- private colormap so that 'ts_background' can be translucent. This draws on
-- an ordinary window manager surface, as "XMonad.Layout.Decoration" does, and
-- the alpha byte of 'ts_background' is ignored. Translucency would have to
-- come from the compositor.

-- $pixel
--
-- The 'Pixel' Color format is in the form of @0xaarrggbb@.
--
-- Note that transparency is only supported if you have a window compositor
-- such as <https://github.com/yshui/picom picom> running.
--
-- Some Examples:
--
-- @
-- white       = 0xffffffff
-- black       = 0xff000000
-- red         = 0xffff0000
-- green       = 0xff00ff00
-- blue        = 0xff0000ff
-- transparent = 0x00000000
-- @

-- $navigation
--
-- Keybindings for navigations can also be modified
--
-- This is the definition of 'defaultNavigation'
--
-- > defaultNavigation :: M.Map (KeyMask, KeySym) (TreeSelect a (TSNavigation a))
-- > defaultNavigation = M.fromList
-- >     [ ((0, xK_Escape), cancel)
-- >     , ((0, xK_Return), select)
-- >     , ((0, xK_space),  select)
-- >     , ((0, xK_Up),     movePrev)
-- >     , ((0, xK_Down),   moveNext)
-- >     , ((0, xK_Left),   moveParent)
-- >     , ((0, xK_Right),  moveChild)
-- >     , ((0, xK_k),      movePrev)
-- >     , ((0, xK_j),      moveNext)
-- >     , ((0, xK_h),      moveParent)
-- >     , ((0, xK_l),      moveChild)
-- >     , ((0, xK_o),      moveHistBack)
-- >     , ((0, xK_i),      moveHistForward)
-- >     ]

-- $advusage
-- This module can also be used to select any other action

-- | Extensive configuration for displaying the tree.
--
-- This class also has a 'Default' instance
data TSConfig a = TSConfig { ts_hidechildren :: Bool -- ^ when enabled, only the parents (and their first children) of the current node will be shown (This feature is not yet implemented!)
                           , ts_background :: Pixel -- ^ background color filling the entire screen.

                           , ts_font :: String -- ^ XMF font for drawing the node name extra text

                           , ts_node      :: (Pixel, Pixel) -- ^ node foreground (text) and background color when not selected
                           , ts_nodealt   :: (Pixel, Pixel) -- ^ every other node will use this color instead of 'ts_node'
                           , ts_highlight :: (Pixel, Pixel) -- ^ node foreground (text) and background color when selected

                           , ts_extra :: Pixel -- ^ extra text color

                           , ts_node_width   :: Int -- ^ node width in pixels
                           , ts_node_height  :: Int -- ^ node height in pixels
                           , ts_originX :: Int -- ^ tree X position on the screen in pixels
                           , ts_originY :: Int -- ^ tree Y position on the screen in pixels

                           , ts_indent :: Int -- ^ indentation amount for each level in pixels

                           , ts_navigate :: M.Map (KeyMask, KeySym) (TreeSelect a (TSNavigation a)) -- ^ key bindings for navigating the tree
                           }

instance Default (TSConfig a) where
    def = TSConfig { ts_hidechildren = True
                   , ts_background   = 0xc0c0c0c0
                   , ts_font         = "xft:Sans-16"
                   , ts_node         = (0xff000000, 0xff50d0db)
                   , ts_nodealt      = (0xff000000, 0xff10b8d6)
                   , ts_highlight    = (0xffffffff, 0xffff0000)
                   , ts_extra        = 0xff000000
                   , ts_node_width   = 200
                   , ts_node_height  = 30
                   , ts_originX      = 0
                   , ts_originY      = 0
                   , ts_indent       = 80
                   , ts_navigate     = defaultNavigation
                   }

-- | What a navigation action asks the selection loop to do next.
--
-- Upstream has no such type: an entry in 'ts_navigate' either returns a
-- @Maybe a@ to stop, or tail-calls @navigate@ to keep going, because the loop
-- is a blocking read it can recurse into. There is no blocking read here, so
-- an action says what should happen and the loop does it. See $river.
--
-- @'TSSelect' a@ is upstream's @return (Just a)@, 'TSCancel' its
-- @return Nothing@, and 'TSContinue' its @navigate@.
data TSNavigation a = TSContinue      -- ^ redraw and wait for the next key
                    | TSCancel        -- ^ stop, selecting nothing
                    | TSSelect a      -- ^ stop, selecting this

-- | Default navigation
--
-- * navigation using either arrow key or vi style hjkl
-- * Return or Space to confirm
-- * Escape or Backspace to cancel to
defaultNavigation :: M.Map (KeyMask, KeySym) (TreeSelect a (TSNavigation a))
defaultNavigation = M.fromList
    [ ((0, xK_Escape), cancel)
    , ((0, xK_Return), select)
    , ((0, xK_space),  select)
    , ((0, xK_Up),     movePrev)
    , ((0, xK_Down),   moveNext)
    , ((0, xK_Left),   moveParent)
    , ((0, xK_Right),  moveChild)
    , ((0, xK_k),      movePrev)
    , ((0, xK_j),      moveNext)
    , ((0, xK_h),      moveParent)
    , ((0, xK_l),      moveChild)
    , ((0, xK_o),      moveHistBack)
    , ((0, xK_i),      moveHistForward)
    ]

-- | Default configuration.
--
-- Using nice alternating blue nodes
tsDefaultConfig :: TSConfig a
tsDefaultConfig = def
{-# DEPRECATED tsDefaultConfig "Use def (from Data.Default, and re-exported by XMonad.Actions.TreeSelect) instead." #-}

-- | Tree Node With a name and extra text
data TSNode a = TSNode { tsn_name  :: String
                       , tsn_extra :: String -- ^ extra text, displayed next to the node name
                       , tsn_value :: a      -- ^ value to return when this node is selected
                       }

-- | State used by TreeSelect.
--
-- Contains all needed information such as the window, font and a zipper over the tree.
data TSState a = TSState { tss_tree     :: TreeZipper (TSNode a)
                         , tss_window   :: Window
                         , tss_size     :: (Int, Int) -- ^ size of 'tz_window'
                         , tss_xfont    :: XMonadFont
                         , tss_gc       :: GC
                         , tss_history  :: ([[String]], [[String]]) -- ^ history zipper, navigated with 'moveHistBack' and 'moveHistForward'
                         }

-- | State monad transformer using 'TSState'
newtype TreeSelect a b = TreeSelect { runTreeSelect :: ReaderT (TSConfig a) (StateT (TSState a) X) b }
    deriving (Monad, Applicative, Functor, MonadState (TSState a),  MonadReader (TSConfig a), MonadIO)

-- | Lift the 'X' action into the 'XMonad.Actions.TreeSelect.TreeSelect' monad
liftX :: X a -> TreeSelect b a
liftX = TreeSelect . lift . lift

-- | Run Treeselect with a given config and tree.
-- This can be used for selectiong anything
--
-- * for switching workspaces and moving windows use 'treeselectWorkspace'
-- * for selecting actions use 'treeselectAction'
treeselect :: TSConfig a         -- ^ config file
           -> Forest (TSNode a)  -- ^ a list of 'Data.Tree.Tree's to select from.
           -> (Maybe a -> X ())  -- ^ what to do with the selection; see $river
           -> X ()
treeselect c t = treeselectAt c (fromForest t) []

-- | Same as 'treeselect' but ad a specific starting position
treeselectAt :: TSConfig a         -- ^ config file
             -> TreeZipper (TSNode a)  -- ^ tree structure with a cursor position (starting node)
             -> [[String]] -- ^ list of paths that can be navigated with 'moveHistBack' and 'moveHistForward' (bound to the 'o' and 'i' keys)
             -> (Maybe a -> X ())  -- ^ what to do with the selection; see $river
             -> X ()
treeselectAt conf@TSConfig{..} zipper hist k = do
    -- Upstream builds an override-redirect window on the root with a 32-bit
    -- visual and its own colormap, so that ts_background can be translucent.
    -- There is no root to parent to and no visual to match: this is a window
    -- manager surface, the same kind XMonad.Layout.Decoration draws on, sized
    -- to the focused screen.  Translucency would have to come from the
    -- compositor rather than from a visual; see $river.
    Rectangle{..} <- gets $ screenRect . W.screenDetail . W.current . windowset
    let r = Rectangle rect_x rect_y rect_width rect_height
    win <- createNewWindow r Nothing (pixelToHex ts_background) True
    showWindow win

    gc <- liftIO createGC
    xfont <- initXMF ts_font

    ref <- liftIO $ newIORef TSState
        { tss_tree     = zipper
        , tss_window   = win
        , tss_xfont    = xfont
        , tss_size     = (fromIntegral rect_width, fromIntegral rect_height)
        , tss_gc       = gc
        , tss_history  = ([], hist)
        }

    let finish result = do
            releaseXMF xfont
            liftIO $ freeGC gc
            deleteWindow win
            k result

        -- One step of the loop: read a key, run what it selects, and either
        -- stop or arm the next one.  Upstream is a blocking maskEvent loop and
        -- this cannot be; see $river.
        step = do
            st <- liftIO (readIORef ref)
            let run act = do
                    (nav, st') <- runStateT (runReaderT (runTreeSelect act) conf) st
                    liftIO (writeIORef ref st')
                    case nav of
                        TSContinue -> step
                        TSCancel   -> finish Nothing
                        TSSelect a -> finish (Just a)
            -- An unbound key ends the selection rather than being ignored,
            -- and so does submapNextKey's abandonment deadline, which arrives
            -- through the same callback.  See $river.
            submapNextKey (M.map run ts_navigate) (finish Nothing)

    _ <- runStateT (runReaderT (runTreeSelect redraw) conf) =<< liftIO (readIORef ref)
    step

-- | Select a workspace and execute a \"view\" function from "XMonad.StackSet" on it.
treeselectWorkspace :: TSConfig WorkspaceId
                    -> Forest String -- ^ your tree of workspace-names
                    -> (WorkspaceId -> WindowSet -> WindowSet) -- ^ the \"view\" function.
                                                               -- Instances can be 'W.greedyView' for switching to a workspace
                                                               -- and/or 'W.shift' for moving the focused window to a selected workspace.
                                                               --
                                                               -- These actions can also be combined by doing
                                                               --
                                                               -- > \i -> W.greedyView i . W.shift i
                    -> X ()
treeselectWorkspace c xs f = do
    -- get all defined workspaces
    -- They have to be set with 'toWorkspaces'!
    ws <- gets (W.workspaces . windowset)

    -- check the 'XConfig.workspaces'
    if all (`elem` map tag ws) (toWorkspaces xs)
      then do
        -- convert the 'Forest WorkspaceId' to 'Forest (TSNode WorkspaceId)'
        wsf <- forMForest (mkPaths xs) $ \(n, i) -> maybe (return (TSNode n "Does not exist!" "")) (mkNode n) (find (\w -> i == tag w) ws)

        -- get the current workspace path
        me <- gets (W.tag . W.workspace . W.current . windowset)
        hist <- workspaceHistory
        treeselectAt c (fromJust $ followPath tsn_name (splitPath me) $ fromForest wsf) (map splitPath hist) $
            maybe (return ()) (windows . f)

      else liftIO $ do
        -- error!
        let msg = unlines $ [ "Please add:"
                            , "    workspaces = toWorkspaces myWorkspaces"
                            , "to your XMonad config!"
                            , ""
                            , "XConfig.workspaces: "
                            ] ++ map tag ws
        -- Upstream also pops this up with xmessage.  That name is not part of
        -- this fork -- it spawned an X11 helper -- so a misconfigured config
        -- is reported to the log only.
        hPutStrLn stderr msg
  where
    mkNode n w = do
        -- find the focused window's name on this workspace
        name <- maybe (return "") (fmap show . getName . W.focus) $ stack w
        return $ TSNode n name (tag w)

-- | Convert the workspace-tree to a flat list of paths such that XMonad can use them
--
-- The Nodes will be separated by a dot (\'.\') character
toWorkspaces :: Forest String -> [WorkspaceId]
toWorkspaces = map snd . concatMap flatten . mkPaths

mkPaths :: Forest String -> Forest (String, WorkspaceId)
mkPaths = map (\(Node n ns) -> Node (n, n) (map (f n) ns))
  where
    f pth (Node x xs) = let pth' = pth ++ '.' : x
                         in Node (x, pth') (map (f pth') xs)

splitPath :: WorkspaceId -> [String]
splitPath i = case break (== '.') i of
    (x,   []) -> [x]
    (x, _:xs) -> x : splitPath xs

-- | Select from a Tree of 'X' actions
--
-- <<https://wiki.haskell.org/wikiupload/thumb/9/9b/Treeselect-Action.png/800px-Treeselect-Action.png>>
--
-- Each of these actions have to be specified inside a 'TSNode'
--
-- Example
--
-- > treeselectAction myTreeConf
-- >    [ Node (TSNode "Hello"    "displays hello"      (spawn "xmessage hello!")) []
-- >    , Node (TSNode "Shutdown" "Poweroff the system" (spawn "shutdown")) []
-- >    , Node (TSNode "Brightness" "Sets screen brightness using xbacklight" (return ()))
-- >        [ Node (TSNode "Bright" "FULL POWER!!"            (spawn "xbacklight -set 100")) []
-- >        , Node (TSNode "Normal" "Normal Brightness (50%)" (spawn "xbacklight -set 50"))  []
-- >        , Node (TSNode "Dim"    "Quite dark"              (spawn "xbacklight -set 10"))  []
-- >        ]
-- >    ]
treeselectAction :: TSConfig (X a) -> Forest (TSNode (X a)) -> X ()
treeselectAction c xs = treeselect c xs $ \case
    Just a  -> void a
    Nothing -> return ()

forMForest :: (Functor m, Applicative m, Monad m) => [Tree a] -> (a -> m b) -> m [Tree b]
forMForest x g = mapM (mapMTree g) x

mapMTree :: (Functor m, Applicative m, Monad m) => (a -> m b) -> Tree a -> m (Tree b)
mapMTree f (Node x xs) = Node <$> f x <*>  mapM (mapMTree f) xs


-- | Quit returning the currently selected node
select :: TreeSelect a (TSNavigation a)
select = gets (TSSelect . tsn_value . cursor . tss_tree)

-- | Quit without returning anything
cancel :: TreeSelect a (TSNavigation a)
cancel = return TSCancel

-- TODO: redraw only what is necessary.
-- Examples: redrawAboveCursor, redrawBelowCursor and redrawCursor

-- | Move the cursor to its parent node
moveParent :: TreeSelect a (TSNavigation a)
moveParent = moveWith parent >> redraw >> return TSContinue

-- | Move the cursor one level down, highlighting its first child-node
moveChild :: TreeSelect a (TSNavigation a)
moveChild = moveWith children >> redraw >> return TSContinue

-- | Move the cursor to the next child-node
moveNext :: TreeSelect a (TSNavigation a)
moveNext = moveWith nextChild >> redraw >> return TSContinue

-- | Move the cursor to the previous child-node
movePrev :: TreeSelect a (TSNavigation a)
movePrev = moveWith previousChild >> redraw >> return TSContinue

-- | Move backwards in history
moveHistBack :: TreeSelect a (TSNavigation a)
moveHistBack = do
    s <- get
    case tss_history s of
        (xs, a:y:ys) -> do
            put s{tss_history = (a:xs, y:ys)}
            moveTo y
        _ -> return TSContinue

-- | Move forward in history
moveHistForward :: TreeSelect a (TSNavigation a)
moveHistForward = do
    s <- get
    case tss_history s of
        (x:xs, ys) -> do
            put s{tss_history = (xs, x:ys)}
            moveTo x
        _ -> return TSContinue

-- | Move to a specific node
moveTo :: [String] -- ^ path, always starting from the top
       -> TreeSelect a (TSNavigation a)
moveTo i = moveWith (followPath tsn_name i . rootNode) >> redraw >> return TSContinue

-- | Apply a transformation on the internal 'XMonad.Util.TreeZipper.TreeZipper'.
moveWith :: (TreeZipper (TSNode a) -> Maybe (TreeZipper (TSNode a))) -> TreeSelect a ()
moveWith f = do
    s <- get
    case f (tss_tree s) of
        -- TODO: redraw cursor only?
        Just t -> put s{ tss_tree = t }
        Nothing -> return ()

-- Upstream also has `navigate`, the blocking maskEvent loop that read a key,
-- looked it up in ts_navigate and recursed.  Its replacement is the `step`
-- function inside 'treeselectAt': the same dispatch, driven by
-- 'XMonad.River.submapNextKey' and continuation-passing rather than by
-- recursion into a blocking read.  See $river.

-- | Request a full redraw
redraw :: TreeSelect a ()
redraw = do
    win <- gets tss_window
    TSConfig{..} <- ask
    (w, h) <- gets tss_size

    -- clear window
    -- TODO: not always needed!
    gc <- gets tss_gc
    liftIO $ do
      setForeground gc ts_background
      fillRectangle win gc 0 0 (fromIntegral w) (fromIntegral h)

    t <- gets tss_tree
    _ <- drawLayers 0 0 (reverse $ (tz_before t, cursor t, tz_after t) : tz_parents t)
    return ()

drawLayers :: Int -- ^ indentation level
           -> Int -- ^ height
           -> [(Forest (TSNode a), TSNode a, Forest (TSNode a))] -- ^ node layers (from top to bottom!)
           -> TreeSelect a Int
drawLayers _ yl [] = return yl
drawLayers xl yl ((bs, c, as):xs) = do
    TSConfig{..} <- ask

    let nodeColor y = if odd y then ts_node else ts_nodealt

    -- draw nodes above
    forM_ (zip [yl ..] (reverse bs)) $ \(y, Node n _) ->
        drawNode xl y n (nodeColor y)
        -- drawLayers (xl + 1) (y + 1) ns
        -- TODO: draw rest? if not ts_hidechildren
        -- drawLayers (xl + 1) (y + 1) ns

    -- draw the current / parent node
    -- if this is the last (currently focused) we use the 'ts_highlight' color
    let current_level = yl + length bs
    drawNode xl current_level c $
        if null xs then ts_highlight
                   else nodeColor current_level

    l2 <- drawLayers (xl + 1) (current_level + 1) xs

    -- draw nodes below
    forM_ (zip [l2 ..] as) $ \(y, Node n _) ->
        drawNode xl y n (nodeColor y)
        -- TODO: draw rest? if not ts_hidechildren
        -- drawLayers (xl + 1) (y + 1) ns
    return (l2 + length as)


-- | Draw a node at a given indentation and height level
drawNode :: Int -- ^ indentation level (not in pixels)
         -> Int -- ^ height level (not in pixels)
         -> TSNode a -- ^ node to draw
         -> (Pixel, Pixel) -- ^ node foreground (font) and background color
         -> TreeSelect a ()
drawNode ix iy TSNode{..} col = do
    TSConfig{..} <- ask
    window       <- gets tss_window
    font         <- gets tss_xfont
    gc           <- gets tss_gc
    display      <- liftX (asks display)
    liftIO $ drawWinBox display window gc font col tsn_name ts_extra tsn_extra
        (ix * ts_indent + ts_originX) (iy * ts_node_height + ts_originY)
        ts_node_width ts_node_height

    -- TODO: draw extra text (transparent background? or ts_background)
    -- drawWinBox window fnt col2 nodeH (scW-x) (mes) (x+nodeW) y 8

-- | Draw a simple box with text
--
-- Upstream reaches for Xlib and Xft directly here, because it wants colours as
-- 'Pixel' where 'XMonad.Util.Font.printStringXMF' takes them as names.  That
-- was the only reason for the private copy, so this converts instead: there is
-- one text-drawing path here and it goes through 'XMonad.Util.Font', which is
-- built on "XMonad.Util.River.Draw".
drawWinBox :: Display -> Window -> GC -> XMonadFont -> (Pixel, Pixel) -> String -> Pixel -> String
           -> Int -> Int -> Int -> Int -> IO ()
drawWinBox dpy win gc font (fg, bg) text fg2 text2 x y w h = do
    -- draw box
    setForeground gc bg
    fillRectangle win gc (fromIntegral x) (fromIntegral y) (fromIntegral w) (fromIntegral h)

    -- draw text
    printStringXMF dpy win font gc (pixelToHex fg) (pixelToHex bg)
        (fromIntegral $ x + 8)
        (fromIntegral $ y + h - 8)
        text

    -- draw extra text
    printStringXMF dpy win font gc (pixelToHex fg2) (pixelToHex bg)
        (fromIntegral $ x + w + 8)
        (fromIntegral $ y + h - 8)
        text2

-- | A 'Pixel' as the @\"#rrggbb\"@ string the drawing layer takes.
--
-- The one adapter this port needs: TreeSelect's config is entirely in 'Pixel'
-- -- see $pixel -- and nothing below 'XMonad.Util.Font' speaks that.
pixelToHex :: Pixel -> String
pixelToHex p = printf "#%02x%02x%02x"
    ((p `shiftR` 16) .&. 0xff) ((p `shiftR` 8) .&. 0xff) (p .&. 0xff)
