# Loki Android — UX Improvement Plan

## P1 — Blocking Issues (User Stuck / Data Loss Risk)

### P1.1 — Back + Retry on `sync_result` failure
Currently the failure state draws an error message and nothing else — the user has no escape except killing the app.
- **Draw**: add "Retry" button and "Back" button when `g_status == .failed`
- **Input – Back**: `phase = .sync_setup; sync_err = null`
- **Input – Retry**: re-copy `g_ip`/`g_pw`, reset `g_status = .connecting`, spawn a new `syncThread`, `phase = .sync_running`

### P1.2 — Back button on `sync_setup` when reached from browser
Tapping Sync in the browser nulls out `db` and `rows`, then there's no way to cancel back.
- Add `sync_from_browser: bool`; set it when transitioning from browser
- **Simpler fix**: don't null out `db`/`rows` when entering `sync_setup`; only clear them on successful sync. Then Back just sets `phase = .browser`

### P1.3 — Confirmation before "Delete DB"
One misclick on the red button wipes all local data immediately.
- Add `delete_confirm_pending: bool` + 3-second countdown timer
- First tap: set flag, change label to "Tap again to confirm", change colour to bright red
- Second tap within timeout: actually call `deleteDb()`
- Timer expiry: reset flag

---

## P2 — Common-Path Friction (Missing Core Features)

### P2.1 — Clipboard copy in detail view
The most common password manager action (copy password → paste into browser) requires zero extra taps after opening the detail view, but currently tapping a value does nothing.
- Tap any field row in detail → `rl.setClipboardText(value)`
- Draw a brief "Copied!" toast at the bottom (`copy_feedback_timer: f32` counting down via `rl.getFrameTime()`)
- On Android verify `rl.setClipboardText` works; if not, add a JNI helper in `android_keyboard.c` / `TextInput.java`

### P2.2 — Create new entry
No path to create an entry exists at all — `createEntry` is never called from the UI.
- Add a "+" FAB button in the browser (bottom-right, `sky_blue` circle)
- On tap: clear `edit_fields`, set `edit_is_new = true`, `phase = .edit`
- In the edit save block: when `edit_is_new`, call `db.createEntry(new_entry)` instead of `db.updateEntry`

### P2.3 — Delete entry from detail
No delete operation exists at all.
- Add a red "Delete" button at the bottom of the detail view
- Use the same two-tap confirmation pattern as P1.3 (`detail_delete_confirm_pending: bool`)
- On confirmed: `db.deleteEntry(detail_entry_id)` → `db.save()` → `repopulateRows` → `phase = .browser`

### P2.4 — Persist server IP across launches
The IP is hard-coded as `"192.168.1.100"` — users retype it every launch.
- On startup: read a file `loki_prefs` from `openBaseDir()`; if present, use it to seed `ip_field`
- On sync submit: write `ip_field.slice()` to that file
- Helpers: `fn loadPrefs(base, ip)` and `fn savePrefs(base, ip)` — one line per file, no encryption needed

### P2.5 — Return to detail after Save (not browser)
After editing, the user lands in the browser and must tap the entry again to verify the change (e.g. to immediately copy the new password).
- After `updateEntry` + `save` + `repopulateRows`: re-fetch via `d.getEntry(detail_entry_id)`, update `detail_head_hash`, set `phase = .detail`
- Only jump to browser when `edit_is_new` (new entry has no detail to return to)

### P2.6 — Background thread for KDF / DB open
`openDbAndPopulate` runs synchronously on the render thread. The KDF stretch can freeze the UI for several seconds with no feedback.
- Add a `db_opening` phase with its own atomic status
- Move the open call off the render thread; draw "Unlocking… please wait" during the wait
- This also covers the auto-open after sync (currently at the top of `sync_running` input)

---

## P3 — Polish

| ID  | Change | Key symbols |
|-----|--------|-------------|
| 3.1 | Animated dots on `sync_running` ("Connecting" + pulsing `...` via `@intFromFloat(rl.getTime() * 3) % 4`) | `sync_running` draw |
| 3.2 | Search/filter bar in browser (magnifying-glass icon in header, `search_field: TextField`, filter `rows.items` each frame) | `browser` draw + input |
| 3.3 | Show/Hide password toggle in the **edit** view on Android (currently always `****`) | `edit` draw, add `edit_show_pw: bool` |
| 3.4 | Highlight empty required fields in red border when sync_setup submit fails | `drawTextField` gains `err: bool` param |
| 3.5 | Explain conflict count in sync_result ("N entries had conflicts — server version kept") | `sync_result` draw |
| 3.6 | Increase Notes field limit (currently capped at 127 chars like all fields) | `TextField` or separate `NoteTextField` variant |
| 3.7 | Create empty local DB on first launch ("Create new" alongside "Fetch") | `sync_setup` draw + input, loki `createEntry` API |
| 3.8 | `Enter` key saves in edit (desktop) | `edit` input, `do_save_key` condition |

---

## Files

- `src/main.zig` — all phase logic, state, input, draw
- `android/java/com/zig/loki/TextInput.java` — native dialogs; clipboard JNI if needed for P2.1
- `src/android_keyboard.c` — JNI glue; new exported function pair if clipboard requires it
