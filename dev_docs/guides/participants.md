# Participants, locations and the other modules' tables

How the calendar reads staff, CRM and location data without depending on those modules, and how participants grant visibility.
Rules for this live in [AGENTS.md](../../AGENTS.md) → Conventions and Feature notes.

**Standalone by construction:** every integration reads the PHYSICAL sibling tables (they exist in every install via core migrations) with SCHEMALESS queries — no sibling module code is ever required; unused modules mean empty tables mean no-ops. A source is OFFERED only when its module is enabled (`Permissions.feature_enabled?/1`, false when the module code is absent) AND the viewer holds the invite sub-permission (composes, never substitutes).

## Participant kinds

| kind | target_uuid | grants visibility to | invite needs |
|------|-------------|----------------------|--------------|
| `user` | a `phoenix_kit_users` uuid | that user | `calendar.invite_platform_users` |
| `staff_person` | a `phoenix_kit_staff_people` uuid | the person's linked user (live) | `calendar.invite_staff` + staff module enabled |
| `crm_contact` | a `phoenix_kit_crm_contacts` uuid | the contact's linked user, when any (live) | `calendar.invite_crm` + CRM module enabled |
| `crm_company` | a `phoenix_kit_crm_companies` uuid | every CURRENT member contact's linked user (live) | `calendar.invite_crm` + CRM module enabled |
| `free_text` | NULL | nobody — display only | event edit access only |

`Schemas.Participant` mirrors the DB CHECKs (`calendar_participant_kind`, `calendar_participant_shape`: free_text has no target, every other kind must) and the two unique indexes (`idx_calendar_participants_target` on event+kind+target, `idx_calendar_participants_free_text` on event+`LOWER(display_name)`).

## Location

Core `<.search_picker mode="single">` under the date fields (search-on-focus: clicking shows the stored list; falls back to a plain input when the locations module is off); exact-match text links `location_uuid` (`link_location/2`), and the context snapshots the NAME into the `location` string at save (`snapshot_location/1` — an unknown or trashed uuid is dropped, free text always works). On READ, `resolve_live_locations/1` rewrites the display `location` to the linked row's CURRENT name (schemaless batch lookup, trashed rows excluded), so renaming a location propagates to every event linked by uuid; the stored string is only the fallback when the row is gone. A failed lookup never breaks listing — the snapshots suffice.

## Participants

`Participants.replace_participants/3` (full-replace-with-diff, one transaction; removal revokes instantly; unchanged rows are kept untouched; only NEWLY added entries notify via Activity `calendar_event.participant_added` with `target_uuid` → core notifications; each is live-resolved to a platform user by `Sources.resolve_user/1`, and company adds fan out to nobody). Per-kind gating via the three invite subs (`invite_platform_users` / `invite_staff` / `invite_crm`; free text needs only event edit access) is validated in the CONTEXT, not just the UI. Existing rows of a kind the editor can't grant are preserved — an editor without `invite_crm` can't add clients but doesn't silently strip someone else's. `added_by_uuid` audits.

`Participants.list_for_event/2` returns `[]` unless the scope may read the event (owner-view or participant, module enabled) — the same boundary as `Events.get_event/2`, so it can't enumerate a disabled module's participants. The unscoped raw read is private; never expose it.

## LIVE visibility

A person's schedule = events they OWN plus events they currently RESOLVE as participating in — `participant_visible_dynamic/1` is one EXISTS fragment joining `phoenix_kit_staff_people` (user_uuid link), `phoenix_kit_crm_contacts` (optional user_uuid), and company MEMBERSHIPS (`phoenix_kit_crm_company_memberships`: company participant = whoever is a member NOW; joining a company grants visibility to existing events, leaving revokes it — regression-tested by mutating membership rows directly). Live resolution is the deliberate choice over save-time snapshots. Participants may open THEIR event (`Events.participant?/2` path in `get_event/2` / `readable?/2`) but never the owner's calendar. `display_name` is the only snapshot; soft-deleted (`status = 'trashed'`) staff/contacts don't resolve.

## Picker UI

Core `<.search_picker>` (multi mode, `direction="up"`, search-on-focus): the dropdown is client-rendered/instant and OPENS ON CLICK with a browsable first page (empty query = browse mode — a picker must offer options before any typing; per-source invite permissions + 8/source pages (`@per_source_cap`) remain the leak control, no min-length rule). Pages grow via the picker's Load more (`limit` param, clamped 8..60 → `Sources.search_participants/3` fetches limit+1 per source → real `has_more`, computed from RAW counts before dedup so a source that still holds rows is never reported exhausted). **Cross-source dedup**: rows are collapsed by linked `user_uuid` — the `user` kind shadows staff/CRM mirrors of the same account, a staff row shadows a contact, unlinked rows always stay; each row carries an opaque hashed `dedup_id` (linked account when there is one, else kind:target) so the same human doesn't reappear across Load more pages and no linked-account uuid is exposed. The LV only answers `participant_search` with flattened icon+sublabel name-only rows. Searches return only `{kind, target uuid, display name}` — no phones or profile data beyond the label; a user's label falls back to their email when no name is set, exactly as far as the rest of the admin already exposes emails. Chips with kind icons; free-text rows/chips are explicitly marked "won't see this event" (people otherwise believe typing a name invites them).

## The standalone proof

The participants test suite seeds the physical staff/CRM/locations tables schemaless (`Repo.insert_all/2` on the table name) with NO module code loaded — keep it that way.
