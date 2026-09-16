# BISList

A Best-in-Slot list addon for World of Warcraft 1.12.1 (vanilla / Turtle WoW).
Track the gear you want for every equipment slot, across multiple lists
(Leveling / PvE / PvP or your own), and have the addon automatically mark
items as acquired once they're equipped, in your bags, or in your bank.

Original addon by **gabcinder2004**. This is a patched build - see
[What's changed in this build](#whats-changed-in-this-build) for the full
list of fixes and why each one matters.

---

## Features

- **Multiple lists per character** - Leveling, PvE, PvP by default; create,
  rename, delete, and reorder your own
- **Auto acquisition tracking** - items you own are marked automatically by
  scanning equipped gear, bags, and bank
- **One-key adding** - hover any item and press `ALT-B` to add it to the
  right slot, or press again to remove it
- **AtlasLoot integration** - hover an item in AtlasLoot and press `ALT-B`;
  the item name and its source (dungeon/boss) are captured automatically
- **Works from anywhere** - chat links, bag items, equipped items, loot
  windows, and AtlasLoot tooltips are all supported
- **Move items between lists** without re-adding them
- **Minimap button** - draggable, pfUI-compatible
- **Progress stats** - acquired vs. total at a glance

---

## Installation

1. Extract the `BISList` folder into `Interface/AddOns/`
2. Restart WoW, or `/reload` if you're already logged in
3. Type `/bis` to open the window

Optionally install **ClassicAPI** (see below) for improved bank detection
and automatic item-data loading. It is not required.

---

## Optional: ClassicAPI

| DLL | What BISList uses it for | Get it |
|---|---|---|
| **ClassicAPI** | Reads your bank without needing to visit a banker, and fetches item data from the server for items your client has never cached | <https://github.com/brues-code/ClassicAPI> |

**Not required.** BISList works fully on a stock client - ClassicAPI is
auto-detected at login and everything falls back to the original behavior
when it's absent. Install it per its own repo's instructions (typically:
drop the `.dll` next to `WoW.exe` and add it to your launcher's DLL list).

No other client mod is used. Nampower, SuperWoW, UnitXP SP3, VanillaHelpers,
and WeirdUtils were each checked and have nothing applicable - BISList does
no casting, combat timing, unit queries, or rendering, so their APIs have no
bearing on "do I own this item."

---

## Usage

### Adding items

Hover over an item anywhere - your bags, your character sheet, a chat link,
a loot window, or an AtlasLoot tooltip - and press **`ALT-B`**.

The addon figures out which equipment slot the item belongs to and files it
there. Press `ALT-B` on an item that's already in your list to remove it.

One-hand weapons will prompt you to choose **Main Hand** or **Off Hand**,
since either is valid.

You can also `ALT-click` an item link in chat to add it.

### Slash commands

| Command | Description |
|---------|-------------|
| `/bis` or `/bislist` | Toggle the BISList window |
| `/bistest` | Manually add the currently hovered item (same as `ALT-B`) |
| `/bisdebug` | Toggle verbose debug logging (off by default) |
| `/bischeck` | Dump diagnostic info about whatever is under your cursor - useful when an item won't add and you want to report why |

### Keybindings

`ALT-B` is bound automatically on first login if you have no existing
binding. You can rebind it under **Key Bindings → BISList** in the standard
WoW interface options.

---

## What's changed in this build

Six changes. Four are bug fixes to behavior that was demonstrably wrong,
one restores a documented feature that was unreachable, and one is a
suspected fix that needs testing.

### Summary

| # | Change | Type | Impact |
|---|--------|------|--------|
| 1 | Bank items no longer lose their acquired checkmark | Bug fix | **High** - affected every bank-stored item, constantly |
| 2 | All lists stay current, not just the one you're viewing | Bug fix | **High** - silently wrong data on any list you weren't looking at |
| 3 | One-hand weapons prompt for Main/Off Hand again | Restored feature | **Medium** - documented behavior that never ran |
| 4 | Bank detected without visiting a banker *(ClassicAPI)* | Enhancement | **High** - removes the limitation behind #1 entirely |
| 5 | Uncached items no longer fail silently *(ClassicAPI)* | Bug fix | **Medium-High** - common with AtlasLoot gear you don't own |
| 6 | Minimap button drag math | Suspected fix | **Low** - cosmetic, and unverified |

### 1. Bank items no longer lose their acquired checkmark

**Was:** `CheckItemAcquired` only scanned the bank when the bank window was
open, but it always *overwrote* `item.acquired` with whatever it computed.
So for an item stored only in your bank, closing the bank window made the
next scan see "not equipped, not in bags" and set `acquired = false`,
erasing a previously-correct result. Reopening the bank set it back to
true. The checkmark flickered based on whether the bank happened to be open.

**Now:** The acquisition check is split into a pure `IsItemAcquired(itemId)`
that also reports whether the bank was genuinely checked this pass. A new
`ApplyAcquiredResult` helper only ever upgrades to `true`, and only
downgrades to `false` when the bank was actually checked. Incomplete
information never overwrites a confirmed result.

### 2. All lists stay current, not just the one you're viewing

**Was:** `ScanAllItems` looped over `self.Data`, which points only at the
**currently selected** list. The `BAG_UPDATE` handler calls it on a
2-second throttle, so if you were viewing PvE, your PvP list's checkmarks
never updated in the background - and switching lists didn't trigger a
rescan either. You'd see stale data without any indication it was stale.

**Now:** `ScanAllItems` iterates every list in `self.DB.lists`, so all of
them stay current regardless of which one is open.

### 3. One-hand weapons prompt for Main Hand / Off Hand again

**Was:** The original README documents that one-hand weapons prompt you to
choose a hand, and `ShowWeaponSlotDialog` is present in the source and
written correctly - but `GetItemSlot` returned slot `19` ("One-Hand")
directly for every `INVTYPE_WEAPON` item, before the weapon check was ever
reached. The dialog was dead code. Every one-hander was silently filed into
a separate "One-Hand" bucket, and its acquisition status was tracked apart
from wherever it actually gets equipped.

**Now:** `GetItemSlot` returns `nil` for `INVTYPE_WEAPON`, which lets the
already-written fallback logic detect the weapon and call the dialog. The
same check was added to the context-menu path for consistency.

**Existing data is safe** - items already saved under the old "One-Hand"
slot are untouched and still display, since that slot entry is kept. Only
where *new* one-handers get filed has changed.

### 4. Bank detected without visiting a banker *(requires ClassicAPI)*

Fix #1 stops the flicker, but it can't remove the underlying limitation:
the stock API genuinely cannot read bank contents unless the bank window is
open, so a bank-only item stays *unknown* until you visit a banker.

ClassicAPI's `C_Item.GetItemCount(itemID, true)` covers equipped + bags +
bank in a single call, and its bank read **works cold** - no banker visit
required, correct from session start, because it reads the bank GUID array
out of the player inventory manager directly instead of going through the
engine's window-gated path. With ClassicAPI installed, bank items resolve
correctly the moment you log in.

The manual scan is kept intact as the fallback and is still used if the
call returns nothing.

### 5. Uncached items no longer fail silently *(requires ClassicAPI)*

**Was:** `GetItemSlot` depends on `GetItemInfo`, which returns nothing for
items your client has never seen - very common when adding gear from
AtlasLoot that you don't own. The add simply failed, with nothing but a
debug line you'd never see unless `/bisdebug` was already on.

**Now:** With ClassicAPI, `C_Item.RequestLoadItemDataByID` requests the data
from the server and the add completes automatically when it arrives.
Without ClassicAPI you now at least get a visible chat message explaining
what happened instead of silence.

Implementation note: `ITEM_DATA_LOAD_RESULT` fires *synchronously* when the
item turns out to already be cached, so the pending-request bookkeeping is
set before the request call - otherwise the handler would find no pending
entry and drop the add. Per ClassicAPI's docs, `success` is `1`/`nil`
rather than `true`/`false`, which the handler accounts for.

### 6. Minimap button drag math *(suspected - please test)*

The original derives the button's angle from `Minimap:GetLeft()` /
`GetBottom()` with a hardcoded `±70` offset and a subtraction order that
appears mirrored relative to the standard formula used by other minimap-button
addons. It also hardcodes an assumption about minimap radius that breaks if
minimap size or scale changes.

Replaced with the conventional `Minimap:GetCenter()`-based calculation,
which is scale-safe and doesn't assume a radius.

**Treat this one as unverified.** If dragging worked fine for you before,
it's possible the original coordinate space was correct and this file
should be reverted.

---

## Honest notes on scope

- **Not benchmarked.** The impact ratings above describe how often and how
  visibly each bug affected correctness, based on reading the code paths -
  they are not measured performance numbers. Nothing here is a speed
  optimization; #4 is the only change that touches how much work a scan
  does, and it reduces it by replacing manual slot loops with one call.
- **Not tested in-game.** Every fix was traced through the actual logic, and
  the ClassicAPI calls were verified against ClassicAPI's own API reference
  rather than guessed - but none of it has been run in a live client. Please
  test before relying on it, particularly #6.
- **Files changed:** `Core.lua`, `ContextMenu.lua`, `MinimapButton.lua`.
  `UI.lua`, `ItemDatabase.lua`, `SourceMap.lua`, `BISList.toc`, and
  `Bindings.xml` are untouched.
- **Not audited:** `UI.lua`, `ItemDatabase.lua`, and `SourceMap.lua` were not
  reviewed. There may be further issues there.
- **Saved data is compatible.** No `BISListDB` format changes - existing
  lists, items, and settings carry over untouched.

---

## Credits

Original addon by **gabcinder2004**.
ClassicAPI by **brues-code** - <https://github.com/brues-code/ClassicAPI>.
