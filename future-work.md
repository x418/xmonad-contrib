## 1. `mouseDrag` can leave a drag that never ends

**Repo:** `../xmonad-river` — `src-river/XMonad/Operations.hs` (`mouseDrag`),
`src-river/XMonad/River/WM.hs` (`addSeat`, `reapClosed`)

`mouseDrag` records `dragging = Just (motion, cleanup)` in `XState` and the only
thing that clears it is `river_seat_v1.op_release`:

```haskell
RiverSeatV1OpRelease -> do
  riverSeatV1OpEnd conn seat
  queueAction rt $ do
    drag <- gets dragging
    whenJust drag $ \(_, cleanup) -> cleanup
```

If that event never arrives, `dragging` stays `Just` forever. `mouseDrag` opens
with

```haskell
drag <- gets dragging
case drag of
    Just _ -> return () -- already dragging
```

so **every subsequent drag in the session is silently ignored**. Mouse-driven
move and resize stop working, with no error and nothing on screen to explain it.
The only recovery is a restart, and since the symptom is "dragging stopped
working" rather than "something broke", the connection to a drag that ended
badly minutes earlier is not obvious.

Ways `op_release` can fail to arrive:

- the seat is removed mid-drag (`rsRemoved`), which `reapClosed` handles by
  destroying the seat object — without clearing `dragging`;
- the dragged window closes mid-drag;
- any protocol-level unhappiness that makes river drop the operation.

There is a second, smaller bug in the same function: it picks the drag seat with
`M.elems seats` and takes the head **without filtering `rsRemoved`**, so a drag
can be started against a seat that is on its way out.

### Sketch

Cheap and worth doing regardless of the above:

- Clear `dragging` in `reapClosed` when the seat that owns it goes away, running
  `cleanup` so the caller's `done` action still fires. Callers use it to commit
  the float geometry, so skipping it loses the drag rather than merely ending it.
- Filter `rsRemoved` in `mouseDrag`'s seat selection.
- Consider a deadline, as `submapNextKey` now has: a drag that has not seen a
  delta in some generous interval is over, whatever river thinks. Less clearly
  correct than the submap case — a slow drag is real, where an abandoned submap
  is not — so this one may be better left out.

Severity is well below the keyboard case: it degrades one input path rather than
locking the session. But it is the same shape of bug, it is cheap, and the
diagnosis cost is high because the symptom appears long after the cause.

## 2. Smaller things

- **`XMonad.Hooks.UrgencyHook` has no input path.** Only `askUrgent` and
  `doAskUrgent` can mark a window urgent; a window cannot mark itself. Wayland's
  equivalent of the `WM_HINTS` urgency flag is `xdg-activation-v1`, which river
  implements — but `handleRequestActivate` does nothing for a window, with the
  comment `TODO support xdg-activation with a rwm extension protocol`. When river
  grows that, the fix here is one event handler calling `markUrgent`.

  The same hole is what `XMonad.Hooks.EwmhDesktops`'s `setEwmhActivateHook`
  warns about, and the two should be closed together: one forwarded activation
  feeds both the urgency hook and the activate hook.

- **Submap deadline is a fixed 60s.** `submapDeadlineMicros` in
  `src-river/XMonad/River.hs`. Fine for chords, arguably wrong for a config using
  a submap as a mode. Making it configurable means threading it through
  `XMonad.Actions.Submap`, which currently has no place to put it.

- **`tests/api/check-subset.sh` compares names, not declarations.** A record
  field can be added to or dropped from a type both sides export and nothing
  notices — `XMonad.Layout.Monitor`'s `opacity` is exactly that, and is recorded
  as prose in `unportable.txt` because it has no entry to live in. The
  declaration text is already in the goldens, so a diff of it is available;
  what is missing is a rule for which declaration changes are drift and which
  are the port doing its job.

## 3. The 21 modules that still do not compile

One line each for every module SURVEY.md lists as failing, grouped by what
would have to change. The point of the grouping is that most of these are not
independent pieces of work: three are waiting on §7, and the rest are about
pieces of X11 that Wayland does not have.

`EwmhDesktops` used to head this section as the largest lever, gating eleven
further modules. It is not here any more, and the way it left is worth
recording because the same reasoning will come up again.

Nothing it does is possible: there is no root window to publish hints on and no
client message to read back. But nothing it does is *wrong* either. The
outbound half writes properties nobody can read, and the inbound half handles a
set of client messages that is empty rather than ignored — no request arrives
and gets dropped. So every name is kept and each warns once on stderr, rather
than the module being dropped and eleven dependents edited to stop calling it.
`ewmh` appears in very nearly every xmonad config in existence, and making all
of them fail to build says nothing a one-line warning does not say better.

This is the same judgement `XMonad.Hooks.ManageDocks` makes about `docks`, with
one difference stated plainly in both places: `docks` still gets you the
outcome it asks for, by another route, and this does not. A panel really will
not learn your workspaces; `statusBarPipe` is where that moved. The warning is
what separates the two cases from a no-op that lies.

Two of its names are *not* in that category and warn separately, because
calling them a fact about Wayland would misdiagnose a backend TODO as a
platform limit — `ewmhFullscreen` and `setEwmhActivateHook`, both in §5.

The eleven modules behind it are all building. Only `XMonad.Layout.Fullscreen`
ever had a real dependency, and it is still failing, on something else.

### Waiting on a capability river could plausibly grow — 3 modules

**An input-only window** — see §7, which is the whole of what these three need.

- `XMonad.Actions.MouseResize`, `XMonad.Layout.BorderResize`,
  `XMonad.Layout.MouseResizableTile`.

Three others used to be in this section and are now building.
`XMonad.Layout.Fullscreen` needed the fullscreen event, which §5 describes and
which the backend now sends. `XMonad.Actions.EasyMotion` and
`XMonad.Actions.TreeSelect` were the same shape as `GridSelect` in §4 -- a
keyboard grab and a blocking read -- and inverted the same way, onto
`XMonad.River.submapNextKey` and a continuation. TreeSelect's private Xlib/Xft
drawing moved onto `XMonad.Util.Font`, which is the only thing that ever
wanted it: it reimplemented `printStringXMF` solely to take colours as `Pixel`
rather than by name, so the port converts instead.

### No Wayland counterpart, and no prospect of one — 17 modules

Not "unfinished". Each of these is *about* a piece of X11 that Wayland does not
have, so there is nothing to port them onto. They stay in the tree, disabled,
because upstream owns them and a rebase should not have to think about them.

**X properties as a public data channel.** A window's properties were readable
and writable by any client, which made them an IPC mechanism as much as a
description. Wayland has nothing of the kind — a compositor tells a client what
it needs to know and clients do not read each other's state.

- `XMonad.Util.StringProp`, `XMonad.Hooks.XPropManage` — read or write
  arbitrary properties. `XMonad.Util.DebugWindow` was on this line and is not
  any more: what it exists to do is describe a window for a human, and river
  knows a window's title, `app_id`, pid, parent and geometry. It reports those
  instead, which released `XMonad.Hooks.DebugStack` and
  `XMonad.Hooks.ManageDebug` behind it. The X-only fields — resource name,
  `WM_COMMAND`, `WM_CLIENT_MACHINE`, override-redirect, window type — are gone
  from the line it prints, and the module says so.
- `XMonad.Hooks.TaffybarPagerHints` — publishes the EWMH pager hints, and
  unlike `XMonad.Hooks.EwmhDesktops` it does not survive as a warning: it reads
  and writes atoms directly rather than through config combinators, so there is
  no shape left to keep once the properties are gone.
- `XMonad.Util.NoTaskbar` — sets `_NET_WM_STATE_SKIP_TASKBAR`.
- `XMonad.Hooks.FadeInactive` — sets `_NET_WM_WINDOW_OPACITY`, a convention
  between an X client and a compositing manager. River composites and offers
  the window manager no say in per-window opacity.
- `XMonad.Util.RemoteWindows` — decides whether a window is local by comparing
  `WM_CLIENT_MACHINE` against the hostname. Wayland has no network
  transparency to detect, which is also why `XMonad.Layout.Stoppable` no longer
  needs it: every window is local, so it signals them all, and it gets the pid
  from `ManageHelpers.pid` rather than `_NET_WM_PID`.
- `XMonad.Hooks.Qubes` — reads the `_QUBES_*` properties the Qubes GUI daemon
  sets on X windows. It is a port of Qubes' X integration, and would have to be
  rewritten against whatever Qubes does for Wayland.

**Clients talking to the window manager.** X11 let a client send the window
manager a message and let the window manager veto a client's own requests.
River is the only thing clients talk to.

- `XMonad.Hooks.ServerMode` — treats client messages as a command channel;
  `xmonadctl` is its client.
- `XMonad.Hooks.Minimize` — acts on a client's request to be iconified.
- `XMonad.Hooks.FloatConfigureReq` — intercepts a client's `ConfigureRequest`.
  River's `pointer_move_requested` / `pointer_resize_requested` are the
  client-initiated half of this and are unexercised (see the repo's `GAPS.md`),
  so there may be something here eventually, but not this module's shape.
- `XMonad.Util.Paste` — synthesises key events and sends them to a window.
  Wayland has no way to inject input; that is the point of its input model.

**Pointer crossing.** X11 reported the pointer entering and leaving each window
and let the window manager act on it. River settles focus-follows-mouse itself
and reports the result, so there is no crossing to intercept and nothing to
override.

- `XMonad.Actions.UpdateFocus`, `XMonad.Hooks.ScreenCorners`. The same wall
  took `promoteWarp` and `followOnlyIf` out of `XMonad.Layout.MagicFocus`,
  which otherwise compiles.

**Other.**

- `XMonad.Util.Ungrab` — a one-name re-export of `unGrab`, which
  `tests/api/unportable.txt` withholds deliberately: succeeding silently would
  be true about grabs and false about handing the keyboard to a screen locker.
  Deprecated upstream in any case.
- `XMonad.Util.Replace` — takes the `WM_S<n>` selection from a running X11
  window manager. River permits one window manager and answers a second with
  `unavailable`; there is no selection to steal.
- `XMonad.Hooks.DebugKeyEvents` — dumps the fields of an `XKeyEvent`. River's
  `KeyPressed` carries a keysym and a mask and would fill most of them, but the
  module exists to answer "is xmonad seeing my key presses at all", and here it
  only ever sees keys it has already bound. A port would print nothing in
  exactly the case it is reached for, which is worse than not being there. It
  is the only thing still blocking `XMonad.Hooks.DebugEvents`.
- `XMonad.Hooks.DynamicBars` — driven by XRandR screen-change notifications.
  `XMonad.Hooks.Rescreen` is the ported equivalent of the mechanism and is what
  a rewrite would sit on, but the module's interface is XRandR's.

### Not about river at all — 1 module

- `XMonad.Config.Monad` — needs the `data-accessor` package, which is not in
  the resolver. It does not build against upstream xmonad here either.

## 4. Resize handles need an input-only window, and Wayland has none

**Repo:** here — `XMonad/Actions/MouseResize.hs`,
`XMonad/Layout/BorderResize.hs`, `XMonad/Layout/MouseResizableTile.hs`

Three modules do not compile for one shared reason, and it is the last thing
standing between them and working. Two more are skipped behind `MouseResize`
and would come with them: `XMonad.Layout.SimpleFloat` and
`XMonad.Layout.DecorationMadness`.

`XMonad.Config.Arossato` and `XMonad.Config.Bluetile` are also skipped behind
these, but would *not* come with them -- Arossato additionally needs
`XMonad.Hooks.ServerMode` and Bluetile that plus `XMonad.Hooks.Minimize`, both
of which are in §6's no-prospect list. Five modules are blocked; three are
recoverable.

### What they do

Each one puts a grab handle somewhere and waits to be clicked on it:

- **`MouseResize`** — one handle in the bottom-right corner of every window,
  with an `xC_bottom_right_corner` cursor. `createInputWindow` builds it.
- **`BorderResize`** — eight, one per edge and corner, each with its own
  directional cursor glyph. `createBorder` builds them from a
  `BorderBlueprint`.
- **`MouseResizableTile`** — a dragger between each pair of panes, in two
  flavours (`FixedDragger`, with a configurable gap and dragger width, and
  `BordersDragger`, which overlaps the window borders), each carrying a `Glyph`
  for its cursor.

All three build the handle the same way, with a local copy of the same
function:

```haskell
mkInputWindow d (Rectangle x y w h) = do
  rw <- asks theRoot
  ...
  createWindow d rw x y w h 0 0 inputOnly visual attrmask attributes
```

An X11 `inputOnly` window is invisible, has no contents and no buffer, is not
composited, and exists solely to collect clicks in a region. It is
override-redirect, so the window manager does not manage it, and it is a child
of the root, so it floats over whatever is beneath.

### Why it does not port

**Wayland has no invisible clickable region.** A surface that receives pointer
input must have a buffer attached and be mapped; input regions
(`wl_surface.set_input_region`) can only *subtract* from a surface that already
exists visually. There is no compositor-side equivalent of `inputOnly`, on
river or anywhere else, and there is no root window to parent one to.

The click half of this is no longer a problem — §5 is closed, and
`SurfaceClicked` delivers a press on a window-manager surface with the position
it happened at, which is exactly what these modules' event hooks want.

### Sketch

Build the handles as ordinary window-manager surfaces —
`XMonad.Util.XUtils.createNewWindow`, the same call `XMonad.Layout.Decoration`
uses — and let `SurfaceClicked` deliver to them. Mechanically this is a
rewrite of `createInputWindow` / `createBorder` in each module and nothing
more; the geometry, the drag logic and the layout arithmetic are all pure and
unchanged.

Three decisions come with it, and they are the actual work:

1. **The handles become visible.** They have to be painted, because a surface
   with no buffer receives nothing. So each module needs an appearance: a
   colour at minimum, and probably a theme field, for something that was
   previously invisible by design. `BorderResize`'s eight-handles-per-window
   is the case where this is most likely to look wrong.

2. **The cursor cannot change per handle.** Every one of these sets a cursor
   glyph — that is how a user knows a border is draggable before pressing it.
   `XMonad.River.setCursorTheme` picks a theme for the whole session and there
   is no per-surface shape; that would need `wp_cursor_shape_device_v1`, for
   which this repo generates no bindings. Without it the handles are silent:
   nothing indicates they are there until one is dragged. Worth deciding
   whether that is acceptable before doing the rest.

3. **No button number.** `SurfaceClicked` carries none, for the reason in §5,
   so a module distinguishing button 1 from button 3 on a handle cannot.
   Checked: none of these three does.

### Difficulty

Low risk, moderate volume, and gated on a look-and-feel decision rather than on
anything technical. Point 2 is the one that could make the result unsatisfying
regardless of how well the rest is done — a resize border nobody can see and
whose cursor never changes is discoverable only by having read the config.
Generating `wp_cursor_shape_device_v1` bindings in `../xmonad-river` first
would remove that, and `codegen/` already knows how to consume a protocol XML.
