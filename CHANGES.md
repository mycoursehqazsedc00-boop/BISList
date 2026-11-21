# BISList improvements

This is a **patch set of 3 files** (`Core.lua`, `ContextMenu.lua`,
`MinimapButton.lua`), not the full addon - I didn't touch `UI.lua`,
`ItemDatabase.lua`, `SourceMap.lua`, `BISList.toc`, or `Bindings.xml`, so
drop these three in over your existing copies and leave the rest as-is.

I read the source from GitHub's web view rather than your actual repo
files, so formatting/whitespace won't match your original byte-for-byte -
but the logic in each fix below was checked directly against the code you
have live, not guessed.

## Confirmed bugs (high confidence - traced through the actual logic)

### 1. Bank items lose their "acquired" checkmark when you close the bank
**File:** `Core.lua`, `CheckItemAcquired`

The bank is only scanned `if BankFrame and BankFrame:IsVisible()`. The
function always **overwrites** `item.acquired` with whatever it just
computed - so for an item that lives only in your bank, closing the bank
window makes the next scan see "not equipped, not in bags" and set
`acquired = false`, erasing a previously-confirmed true status. Reopening
the bank sets it back to true, so it flickers based on whether the bank
happens to be open at scan time.

**Fix:** Split the acquisition check into a pure `IsItemAcquired(itemId)`
that also reports whether the bank was actually checked this pass
(`bankChecked`). A new `ApplyAcquiredResult` helper only ever *upgrades* to
true, or downgrades to false when the bank was actually checked (or the
item has never been scored before) - otherwise it leaves the existing
value alone. No more flicker.

### 2. Other lists go stale while you're viewing one list
**File:** `Core.lua`, `ScanAllItems`

`ScanAllItems` looped over `self.Data`, which is only the **currently
selected** list. The `BAG_UPDATE`/`UNIT_INVENTORY_CHANGED` handler calls
this on a 2-second throttle, but if you're looking at "PvE", your "PvP"
list's checkmarks never update in the background - they only refresh once
you switch to viewing that list, and even switching lists doesn't trigger
a rescan.

**Fix:** `ScanAllItems` now iterates every list in `self.DB.lists`, so all
three (or however many you have) stay current regardless of which one is
open. This required updating each item directly (rather than going through
`self.Data`, which only ever points at the current list) - see
`IsItemAcquired`/`ApplyAcquiredResult` above.

## Confirmed design gap (high confidence - the intended code already exists, just unreachable)

### 3. One-hand weapons never get the "Main Hand or Off Hand" prompt
**File:** `ContextMenu.lua`, `GetItemSlot` / `OnMenuClick`

Your README says *"One-hand weapons will prompt you to choose Main Hand or
Off Hand"*, and `ShowWeaponSlotDialog` (fully built, does exactly that) is
in the file - but `GetItemSlot` returns slot `19` ("One-Hand") directly for
every `INVTYPE_WEAPON` item, before the weapon-dialog check is ever
reached. So every one-hander added via ALT-B (or the context menu) gets
silently filed into a separate "One-Hand" bucket instead of prompting, and
its acquisition status is then tracked separately from wherever it's
actually equipped (Main Hand or Off Hand).

**Fix:** `GetItemSlot` now returns `nil` for `INVTYPE_WEAPON`, which makes
the ALT-B path's existing fallback logic (already written, just
unreachable before) correctly detect the weapon and call
`ShowWeaponSlotDialog`. I also added the same `INVTYPE_WEAPON` check to
`OnMenuClick` so the context-menu path behaves consistently, in case it's
wired up elsewhere.

Existing items already saved under the old "One-Hand" slot (19) are
untouched - `BISList.Slots` still lists that entry so they keep displaying
- this only changes where **new** one-handers get filed going forward.

## Suspected bug (medium confidence - I can't run WoW to confirm)

### 4. Minimap button drag may move the button to the mirrored position
**File:** `MinimapButton.lua`, `OnDragStart`

The original math derives the button's angle from `Minimap:GetLeft()` /
`Minimap:GetBottom()` with a hardcoded `+70`/`-70` offset and a
`xmin - xpos/scale` subtraction order. Compared against the standard
formula used by essentially every other minimap-button addon
(`Minimap:GetCenter()`, then `atan2(cursorY - centerY, cursorX - centerX)`),
the sign ordering looks flipped, which would mean dragging the button
right visually moves it to a position that's actually mirrored to the
left (or similar mismatch), and the `+70` also hardcodes an assumption
about minimap radius that breaks if minimap size/scale changes.

**Fix:** Replaced with the standard `Minimap:GetCenter()`-based formula,
which is scale-safe and doesn't hardcode a radius. **I'd treat this one as
"please test before trusting"** - if your original actually worked fine
in-game, it's possible I'm misreading the coordinate space and you should
revert this one file.

## ClassicAPI integration (optional - auto-detected, falls back cleanly)

Both of these use ClassicAPI (<https://github.com/brues-code/ClassicAPI>)
when it's installed, and fall back to the original behavior when it isn't.
Nothing here is required.

### 5. Bank items now show as acquired from login, not just at the bank
**File:** `Core.lua`, `IsItemAcquired`

Fix #1 above stops the *flicker*, but it can't fix the underlying
limitation: the stock API genuinely can't see bank contents unless the
bank window is open, so a bank-only item stays "unknown" until you visit a
banker.

ClassicAPI's `C_Item.GetItemCount(itemID, true)` covers equipped + bags +
bank in one call, and its docs state the bank read **works cold** - no
banker visit required, correct from session start (it reads the bank GUID
array out of the player invMgr directly rather than going through the
engine's window-gated `GetItemBySlot`). So with ClassicAPI installed, a BIS
item sitting in your bank correctly shows acquired immediately at login.

The manual equipped/bags/bank scan is kept intact as the fallback, and is
still used if `GetItemCount` returns nil for any reason.

### 6. Adding an uncached item no longer fails silently
**File:** `ContextMenu.lua`

`GetItemSlot` depends on `GetItemInfo`, which returns nothing for items
the client has never seen. This is common when adding gear from AtlasLoot
that you don't own - the add just fails, with nothing but a debug line
(invisible unless `/bisdebug` is on) to explain why.

With ClassicAPI, `C_Item.RequestLoadItemDataByID` asks the server for the
data and fires `ITEM_DATA_LOAD_RESULT` when it lands, so BISList now
requests the item and completes the add automatically once it arrives.
Without ClassicAPI you now at least get a visible chat message explaining
what happened instead of silence.

Note: `ITEM_DATA_LOAD_RESULT` fires *synchronously* if the item turned out
to be cached already, so the pending-request bookkeeping is set before the
request call and the "loading..." message is suppressed if the add already
completed. Per ClassicAPI's docs, `success` is `1`/`nil` rather than
`true`/`false`, which the handler accounts for.

### What I checked and did NOT use
- `C_Item.GetItemInfoInstant` looks like a drop-in upgrade for
  `GetItemInfo` in `GetItemSlot`, but its docs are explicit that it
  **does not warm the cache** on a miss. Swapping it in would make the
  uncached case worse, not better, so `GetItemInfo` (which does warm) is
  kept and `RequestLoadItemDataByID` handles the miss.
- `C_Container.GetContainerItemID` would tidy the manual bag-scan loop,
  but the `GetItemCount` path already skips that loop entirely when
  ClassicAPI is present, so it'd be churn with no behavioral gain.
- **SuperWoW, Nampower, UnitXP SP3, VanillaHelpers, WeirdUtils:** nothing
  applicable. This addon does no casting, no combat timing, no unit
  queries, and no rendering - it's a bag/bank/equipment inventory tracker,
  which is squarely ClassicAPI's domain and nobody else's here. Nampower's
  cooldown APIs, UnitXP's unit/timer calls, and SuperWoW's GUID/casting
  extensions have no bearing on "do I own this item."

## Not reviewed

`UI.lua` (1434 lines, I only read the first ~700), `ItemDatabase.lua`, and
`SourceMap.lua` (large embedded data tables) weren't audited - happy to
look at those too if you want, just flag it.
