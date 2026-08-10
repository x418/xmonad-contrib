# Future work

Things known to be wrong or missing, with enough detail to act on without
re-deriving the analysis. Each says where the fix goes: most of these live in
the fork (`../xmonad-river`) rather than here, because the failure is in the
backend that contrib sits on.

*Which* modules do not compile is in [SURVEY.md](SURVEY.md), which is generated
and stays current; §6 says *why*, once per module, because a generated
first-error line does not distinguish "nobody has done this yet" from "this
cannot be done". §1–§5 are about things that do compile and are wrong. §7 is
one entry from §6 written out at length, because three modules share it and it
is the largest piece of unblocked work left.

---

## 1. A wedged prompt is still undetectable — NARROWED

**Repo:** `../xmonad-river` — `src-river/XMonad/River/Client.hs`

A prompt is a `zwlr_layer_surface_v1` with `keyboard_interactivity = exclusive`,
so the compositor delivers every keystroke to it for as long as its surface
exists. Three paths used to end the owning thread without destroying the
surface, and each left a session whose keyboard went somewhere nothing was
reading. Those are fixed: `clientMain` tears down under a handler, `csDraw` and
`csOnKey` are caught, and `XMonad/Prompt.hs` closes the client in a `finally`.

**Since closed: a prompt that was never able to read the keyboard at all.**
`watchStartup` gives a client `startupDeadlineMicros` — ten seconds — to become
usable, and closes it with a reason if it has not: the surface was never
configured, the seat has no keyboard, focus was never granted, or the keymap
never arrived. All four are settled within a round trip of the surface being
created, so none of them needs anyone to type; a prompt sitting in front of
someone reading it is untouched, which was the whole objection to a timeout.
Escalation is `Close` first, then `killThread` if the loop does not answer
within a second.

That work turned up a real bug in the same function: `setupKeyboard` called
`wl_seat.get_keyboard` unconditionally, which is a protocol error on a seat with
no keyboard capability, and the compositor answers it by dropping the
connection. A prompt opened before any input device existed died with a raw
`ProtocolError` traceback. It now waits for `wl_seat.capabilities`.

Also closed, and adjacent: `XMonad/Prompt.hs` blocked forever in `readChan` when
its client went away — compositor close, watchdog, or `closeAllPrompts` — so the
prompt thread leaked with its state. `keyChan` now carries `Maybe`, `csOnClose`
writes `Nothing`, and the loop stops with `successful` still `False`, so a
prompt closed out from under the user does not run its action.

**What is still not covered is a thread that is alive but never returns.** A
deadlock, a blocking read that never completes, an infinite loop in a completion
function — the thread exists, so no handler runs, and the grab persists exactly
as before. The startup watchdog does not see it: by then the prompt has proved
it *can* read the keyboard, and the watchdog is a one-shot. Nothing detects it.

### Sketch

Have the client record when it last completed a pass through its loop, and have
the window manager notice when a client holding a keyboard grab has stopped
making progress *while keys are arriving for it*.

Both halves of that condition matter. Elapsed time alone is not evidence: a
prompt waiting for someone to finish reading the screen is idle for minutes and
is working perfectly. What distinguishes wedged from idle is that keystrokes are
being delivered and not consumed.

- Client side: a timestamp bumped at the top of `loop`, and another bumped after
  `csOnKey` returns. Both in the registry that `closeAllClients` already walks,
  so no new plumbing.
- Window manager side: a periodic check — the mailbox loop already wakes on a
  timer-friendly `waitEither`, so this can ride along rather than needing a
  thread. If a client's key-handled timestamp has not moved in N seconds *and*
  its loop timestamp has not either, it is not merely waiting for input.
- On detection: log loudly, then close it. Closing a working prompt by mistake
  is a nuisance; leaving a wedged one is a session.

### Difficulty

The detection rule is the whole problem; the mechanism is easy. Getting it wrong
in the paranoid direction closes prompts people are using, which is worse than
the bug. Consider shipping it in log-only mode first and looking at whether it
ever fires.

### What would prove it

Extend the test in §3 to make the callback block forever rather than throw, and
assert the surface is destroyed anyway.

---

## 2. `mouseDrag` can leave a drag that never ends

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

---

## 3. A prompt is now tested against a live river — PARTLY CLOSED

**Repo:** `../xmonad-river` — `tests/headless-prompt.sh`,
`tests/river-prompt-spec.hs`

The guarantee that a prompt cannot leave the keyboard grabbed used to rest on
reading the code. That is exactly how the bug got there: every path *looked*
like it terminated.

`tests/headless-prompt.sh` now starts a headless river with a window manager
beside it and runs `river-prompt-spec` inside, which drives `startClient`
directly. Four cases pass:

- a surface that never asked for a keyboard is not closed by the watchdog;
- a prompt that can never read the keyboard *is* closed, within its deadline;
- a `csDraw` that throws does not take the client down;
- `closeAllClients` closes a client — the escape hatch, fired rather than
  assumed.

River's own log is the independent oracle, as sketched below: the run
fails if `'xmonad-prompt' mapped` is not matched by a `destroyed`.

### What is still missing

**An idle prompt on a seat that has a keyboard.** The false-positive risk the
watchdog introduces is that it closes a working prompt, and the case above only
covers the half of that with `csKeyboard = False`. A headless seat has no
keyboard capability, so the real case cannot be staged: it needs a
`virtual-keyboard-unstable-v1` client to give the seat one, and this repo
generates no bindings for that protocol. The XML is in wlroots and `codegen/`
already knows how to consume one, so this is a contained piece of work rather
than a hard one.

**A callback that blocks forever** (§1) — still nothing to test against.

### The oracle, as designed and as built

River logs, at `-log-level debug`:

```
layer surface 'xmonad-prompt' mapped
layer surface 'xmonad-prompt' destroyed
```

The namespace is set by `clientMain` in `Client.hs`. `mapped` proves the grab was
actually taken — without it the test passes vacuously on a prompt that never
opened, which is the failure mode to design against here. `destroyed` proves it
was released.

### Two things the build of it learned

**The window manager has to be running.** River closes a layer surface whose
namespace no window manager has claimed — `window manager did not bind
river_layer_shell_v1, closing layer surface` — so the first version of the
harness, which ran the spec alone, failed every case for a reason that had
nothing to do with prompts. It starts xmonad beside the spec now.

**Do not try to synthesise input, and do not need to.** The watchdog's checks
are all answerable without a keystroke, which is what makes them testable at
all in a session that has no input device.

---

## 4. GridSelect's interaction model — INVERTED

**Repo:** here — `XMonad/Actions/GridSelect.hs`

Done, along with the twelve modules it gated: `Actions.WindowMenu`,
`Layout.ButtonDecoration`, `Layout.DecorationAddons`,
`Layout.ImageButtonDecoration`, `Layout.WindowSwitcherDecoration` and all of
`DecorationEx`.

What the port amounted to, for anyone converting a config or a similar module:

- `gs_navigate` is now `(KeySym, String, KeyMask) -> TwoD a (Navigation a)` --
  a handler for one key rather than the whole event loop. Keymap entries drop
  their `>> myNavigation` tail and end `>> pure Continue`.
- `Navigation a = Continue | Cancel | Select a` replaces the `Maybe a` that a
  returning loop used to mean. `select` with nothing under the cursor is
  `Cancel`, which is what `Nothing` meant.
- `makeXEventhandler` is gone; `shadowWithKeymap` stays, retyped.
- `substringSearch` is a mode rather than a nested loop: `td_searching` in
  `TwoDState`, which the top-level dispatch consults.
- `gridselect` and `gridselectWindow` take a continuation. Every other public
  wrapper already ended in `X ()` and consumed the result immediately, so their
  signatures did not change.
- `gs_cancelOnEmptyClick` is gone with the clicks; see §5.
- The surface is `startClient` with `csKeyboard = True` and an offscreen pixmap
  replayed by `csDraw`, exactly as `XMonad.Prompt` does it, and `drawWinBox`
  draws through `XMonad.Util.River.Compat` rather than Xlib.

### What is left

**A key event carries no modifier mask — CLOSED.** `csOnKey` reported a keysym
and the text it produces and nothing else, and `XMonad.Prompt` filled the gap
with a literal `KeyPressed 0 ks`, so every keymap entry qualified by a modifier
silently never fired -- including its own default `prevCompletionKey =
(shiftMask, xK_Tab)`.

`csOnKey` now takes a `KeyMask` first. It is assembled by
`Client.activeKeyMask` from `Xkb.modifierActive`, which asks
`xkb_state_mod_name_is_active` by name -- `"Shift"`, `"Control"`, `"Mod1"`,
`"Mod3"`, `"Mod4"`, `"Mod5"` -- because a modifier's *index* is a property of
the keymap and the same bit means different things under different layouts.
`lockMask` and `mod2Mask` are deliberately not asked for: they are caps and num
lock, and `cleanMask` exists to strip them.

GridSelect's `(shiftMask, xK_Tab)` bindings are back in `defaultNavigation` and
`navNSearch`.

**No test drives it.** It takes an exclusive keyboard grab, so §1 and §3 apply
to it exactly as they do to a prompt: a `gs_colorizer` or a custom navigation
that throws leaves the grab held. `gridselect` closes the client from a
single-shot `finish`, which covers the paths that end normally, but nothing
detects a handler that hangs.

## 5. Smaller things

- **`XMonad.Layout.Decoration` clicks — CLOSED, and the analysis above it was
  wrong.** This used to say river attributes a click on a decoration to no
  window, and that correlating a press with a position was guesswork. Neither
  holds. River has `river_seat_v1.shell_surface_interaction`, which fires for
  exactly a surface the window manager drew and carries its
  `river_shell_surface_v1` id -- and that id *is* the `Window` a decoration is
  known by here, because `createNewWindow` returns `surfShell`. It was decoded
  by the protocol layer and simply never handled. The position is not guesswork
  either: the protocol requires every event in a sequence to precede its
  `manage_start`, so `rsPointer` is the position at the moment of the press by
  construction.

  It is now `SurfaceClicked { ev_window, ev_x, ev_y }`, and both
  `Decoration.handleMouseFocusDrag` and `DecorationEx.Engine`'s are ports of
  upstream rather than stubs. Title-bar dragging works, `decorationCatchClicksHook`
  fires, and the button widgets in `ButtonDecoration` and `DecorationEx` work.

  What is genuinely absent is the **button number**: river reports that an
  interaction happened and deliberately not what caused it, since it may have
  been touch or a tablet tool. `DecorationEx` therefore passes `1` always, so a
  theme binding `onDecorationClick` to button 2 or 3 will not see it fire.
  `GridSelect`'s `gs_cancelOnEmptyClick` stays gone for the same reason -- it is
  about a click on *no* widget, which is a press with no surface to report.

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

- **A config is told when a window's fullscreen state changes — CLOSED.**
  `WindowFullscreenChanged { ev_window, ev_fullscreen }` is sent from the two
  sites that already updated the flag, and after they update it, so a handler
  reading `isFullscreen` for the window it was just told about sees the new
  answer. `XMonad.Layout.Fullscreen` builds on it and is much simpler than
  upstream's: there is no `_NET_WM_STATE` property to write back and no
  add/remove/**toggle** to resolve, because the answer is in the event.

  `ewmhFullscreen` still warns — `XMonad.Hooks.EwmhDesktops` is inert whatever
  happens here — but the thing it points people at now exists.

  What is *not* closed is the other half: nothing tells river that the window
  manager has honoured the request. `river_window_v1.inform_fullscreen` exists
  and is not sent, so a client that asked to be fullscreen is given the screen
  by the layout but never told it got it. Clients that adjust their own
  rendering on that signal -- hiding controls, changing scaling -- will not.

- **`XMonad.Layout.Decoration` clicks — CLOSED, and the analysis above it was
  wrong.** This used to say river attributes a click on a decoration to no
  window, and that correlating a press with a position was guesswork. Neither
  holds. River has `river_seat_v1.shell_surface_interaction`, which fires for
  exactly a surface the window manager drew and carries its
  `river_shell_surface_v1` id -- and that id *is* the `Window` a decoration is
  known by here, because `createNewWindow` returns `surfShell`. It was decoded
  by the protocol layer and simply never handled. The position is not guesswork
  either: the protocol requires every event in a sequence to precede its
  `manage_start`, so `rsPointer` is the position at the moment of the press by
  construction.

  It is now `SurfaceClicked { ev_window, ev_x, ev_y }`, and both
  `Decoration.handleMouseFocusDrag` and `DecorationEx.Engine`'s are ports of
  upstream rather than stubs. Title-bar dragging works, `decorationCatchClicksHook`
  fires, and the button widgets in `ButtonDecoration` and `DecorationEx` work.

  What is genuinely absent is the **button number**: river reports that an
  interaction happened and deliberately not what caused it, since it may have
  been touch or a tablet tool. `DecorationEx` therefore passes `1` always, so a
  theme binding `onDecorationClick` to button 2 or 3 will not see it fire.
  `GridSelect`'s `gs_cancelOnEmptyClick` stays gone for the same reason -- it is
  about a click on *no* widget, which is a press with no surface to report.

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

- **A config is told when a window's fullscreen state changes — CLOSED.**
  `WindowFullscreenChanged { ev_window, ev_fullscreen }` is sent from the two
  sites that already updated the flag, and after they update it, so a handler
  reading `isFullscreen` for the window it was just told about sees the new
  answer. `XMonad.Layout.Fullscreen` builds on it and is much simpler than
  upstream's: there is no `_NET_WM_STATE` property to write back and no
  add/remove/**toggle** to resolve, because the answer is in the event.

  `ewmhFullscreen` still warns — `XMonad.Hooks.EwmhDesktops` is inert whatever
  happens here — but the thing it points people at now exists.

  For the record, the original analysis: River sends `fullscreen_requested` and
  `exit_fullscreen_requested`, and
  `XMonad/River/WM.hs` records both in `rwFullscreen` — which is what
  `XMonad.Hooks.ManageHelpers.isFullscreen` reads, so a *manage hook* sees the
  right answer for a window that is fullscreen when it first appears. What is
  missing is the change: a window that goes fullscreen later, or leaves it,
  updates `rwFullscreen` and reaches no hook. That is the whole of what keeps
  `XMonad.Layout.Fullscreen` from compiling — its `fullscreenEventHook`
  broadcasts `AddFullscreen`/`RemoveFullscreen` to layouts off a `_NET_WM_STATE`
  client message, and there is no event here to hang it on. The fix is two
  constructors on `Event` in `XMonad/River/Types.hs` and a `broadcastEvent` at
  the two sites in `WM.hs` that already `adjust` the flag; then the hook is a
  rename rather than a rewrite. It is the largest single module left, and unlike
  the rest of §6 it is unblocked work rather than a missing capability.

- **`tests/api/check-subset.sh` compares names, not declarations.** A record
  field can be added to or dropped from a type both sides export and nothing
  notices — `XMonad.Layout.Monitor`'s `opacity` is exactly that, and is recorded
  as prose in `unportable.txt` because it has no entry to live in. The
  declaration text is already in the goldens, so a diff of it is available;
  what is missing is a rule for which declaration changes are drift and which
  are the port doing its job.

- **The `tests` test-suite builds and passes — 95 examples, 0 failures.** It
  had never been ported: the stanza still `build-depends` on `X11` and lacked
  `cairo`/`pango`, and the tests wrote window ids as numeric literals, which a
  Wayland object id is not. The dependency list is fixed; `Utils` and
  `Instances` take `Rectangle` from `XMonad`; `WindowNavigation` and
  `NoBorders` convert ids at their helper boundaries (`w`, `wins`, `rects`,
  and `mkws` taking `Word32`) so the tests still read as "windows 1 and 2"; and
  `Instances` grows an `Arbitrary ObjectId` that never generates `nullObject`.
  The dead `ManageDocks` property tests -- for `r2c`/`c2r`, which the strut port
  removed -- are gone.

  **No new tests were added.** This restores the suite upstream ships; it does
  not cover anything river-specific, and nothing here exercises the 299 modules
  at runtime.

---

## 6. The 21 modules that still do not compile

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

---

## 7. Resize handles need an input-only window, and Wayland has none

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
