module RiverDefects (spec) where

import Data.IORef (newIORef, readIORef)
import qualified Data.Map.Strict as M
import Test.Hspec

import XMonad (KeyMask, Rectangle (..), Window, mod1Mask, shiftMask, xK_Alt_L, xK_Alt_R, xK_Shift_L)
import XMonad.Hooks.EwmhDesktops (applyFullscreenTransition)
import XMonad.Prompt (cleanupPromptFrame)
import qualified XMonad.StackSet as W
import XMonad.Util.River.Compat
    ( copyArea, createPixmap, drawOn, drawableSize, freePixmap, isDrawable
    , moveResizeDrawable, pendingOps, pixmapIdTop )
import XMonad.Actions.Repeatable (modifierMask)
import XMonad.Util.XUtils (recordOverlayPosition)
import XMonad.River.Wire (ObjectId (..))

spec :: Spec
spec = do
    describe "reused drawable geometry" $
        it "updates the rectangle used by subsequent buffer commits" $ do
            drawable <- createPixmap 20 10
            let resized = Rectangle 30 40 200 50
            moveResizeDrawable drawable resized
            drawableSize drawable `shouldReturn` Just resized
            positions <- newIORef (M.singleton node (0, 0))
            recordOverlayPosition positions node resized
            readIORef positions `shouldReturn` M.singleton node (30, 40)
            freePixmap drawable

    describe "fullscreen transitions" $ do
        it "restores a tiled window and ignores repeated requests" $ do
            let (entered, saved) =
                    applyFullscreenTransition True window M.empty M.empty
                repeated = applyFullscreenTransition True window entered saved
                exited = uncurry (applyFullscreenTransition False window) repeated
            M.lookup window entered `shouldBe` Just fullRect
            repeated `shouldBe` (entered, saved)
            exited `shouldBe` (M.empty, M.empty)

        it "restores a previous floating rectangle" $ do
            let floats = M.singleton window floatedRect
                entered = applyFullscreenTransition True window floats M.empty
                exited = uncurry (applyFullscreenTransition False window) entered
            exited `shouldBe` (floats, M.empty)

        it "does not sink a float that was never fullscreen" $
            applyFullscreenTransition False window floats M.empty
                `shouldBe` (floats, M.empty)

        it "reapplies fullscreen after a manual sink without losing saved geometry" $ do
            let (_, saved) = applyFullscreenTransition True window floats M.empty
                refullscreened = applyFullscreenTransition True window M.empty saved
                exited = uncurry (applyFullscreenTransition False window) refullscreened
            M.lookup window (fst refullscreened) `shouldBe` Just fullRect
            exited `shouldBe` (floats, M.empty)

    describe "pixmap ids" $ do
        it "never look like a server-allocated object" $ do
            ps <- mapM (const (createPixmap 1 1)) [1 .. 8 :: Int]
            mapM_ (\p -> p `shouldSatisfy` (< ObjectId 0xff000000)) ps
            mapM_ (\p -> p `shouldSatisfy` (<= ObjectId pixmapIdTop)) ps
            mapM_ freePixmap ps
        it "are distinct" $ do
            a <- createPixmap 1 1
            b <- createPixmap 1 1
            a `shouldNotBe` b
            mapM_ freePixmap [a, b]

    describe "modifierMask" $ do
        it "is a union, so both Alts are one bit" $
            modifierMask [xK_Alt_L, xK_Alt_R] `shouldBe` mod1Mask
        it "combines distinct modifiers" $
            modifierMask [xK_Shift_L, xK_Alt_L] `shouldBe` (shiftMask + mod1Mask :: KeyMask)

    describe "drawable operation queues" $ do
        it "copyArea appends the source's operations without disturbing them" $ do
            src <- createPixmap 4 4
            dst <- createPixmap 4 4
            drawOn src (\_ -> pure ())
            drawOn src (\_ -> pure ())
            pendingOps src `shouldReturn` 2
            pendingOps dst `shouldReturn` 0
            copyArea src dst 0 0
            pendingOps dst `shouldReturn` 2
            pendingOps src `shouldReturn` 2
            mapM_ freePixmap [src, dst]

    describe "prompt frame cleanup" $
        it "frees the frame even when earlier cleanup throws" $ do
            frame <- createPixmap 20 10
            cleanupPromptFrame frame (ioError (userError "client cleanup failed"))
                `shouldThrow` anyIOException
            isDrawable frame `shouldReturn` False
  where
    window :: Window
    window = ObjectId 42
    node = ObjectId 84
    fullRect = W.RationalRect 0 0 1 1
    floatedRect = W.RationalRect (1 / 10) (1 / 5) (1 / 2) (3 / 5)
    floats = M.singleton window floatedRect
