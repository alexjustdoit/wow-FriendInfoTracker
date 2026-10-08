# WoW Forever

A WoW addon + companion services for tracking account-level and character-level
data (names, levels, professions, location) across your own characters and
opted-in friends', viewable in-game and on a shared web dashboard.

**Status:** planning only — nothing has been built yet.

## Hard constraint that shapes everything

WoW's Lua addon sandbox cannot make network calls or write arbitrary files.
It can only read/write its own SavedVariables, and only at `/reload` or
logout. Any "push to an external service" feature therefore always requires
a second piece of software outside the game — there is no single-file
solution.

## Architecture

```
[WoW Addon]  (Lua, in-game, opted-in friends only)
     |  writes to local SavedVariables on /reload or logout
     v
[Uploader Agent]  (small background script, opted-in friends' own machines)
     |  reads that file, POSTs to the ingest API with a personal token
     v
[Central Web Server]  (runs on your Mac, exposed via Cloudflare Tunnel)
     ^
     |  pulls on a schedule, no install needed by anyone
[Roster Puller]  (your server, queries Blizzard's Profile API for every known character+realm)
```

Three independent pieces, replaceable without touching the others.

## Data tiers, per friend

- **Tier 1 (always on, zero install):** name, class, race, level,
  professions — pulled from Blizzard's official Game Data/Profile API on a
  schedule (e.g. hourly). No addon, no agent, nothing on the friend's
  machine. Just needs their character name + realm + region added to a
  roster.
- **Tier 2 (opt-in):** current/last-known location, and anything else only
  visible in-game — requires that friend to install the WoW addon *and* the
  uploader agent. Each opted-in friend gets their own upload token so one
  friend's agent can never overwrite another's data.

"Mixed, opt-in per friend" = every friend gets Tier 1 automatically; Tier 2
is opt-in on top.

## Server hosting & access

- Server runs locally (your own Mac), exposed to friends via **Cloudflare
  Tunnel** — no open router ports, no VPN for friends to install, just a
  normal HTTPS URL.
- Auth is a single shared password for v1, implemented as app-level
  middleware (not Cloudflare Access) so it's a clean seam to swap in
  per-user accounts/permissions later without a rewrite.
- v1 behavior: everyone who has the password sees everyone's data. Per-user
  visibility rules are a planned v2 addition, not a v1 feature.

## Addon internal data model

One account-wide SavedVariables table, `WoWForeverDB` (declared via
`## SavedVariables: WoWForeverDB` in the TOC — not per-character, so every
alt on the account can see every other alt's last-captured data). A second,
per-character table (`WoWForeverCharDB`) holds pure UI prefs, kept separate
so the uploader agent only ever has to parse one well-defined data table.

```lua
WoWForeverDB = {
  schemaVersion = 1,
  characters = {
    ["Thrall-StormrageUS-US"] = {
      identity = {
        name = "Thrall", realm = "StormrageUS", realmDisplay = "Stormrage",
        region = "US", class = "WARRIOR", race = "Orc", faction = "Horde",
        guid = "Player-1234-00001234",
      },
      level = { value = 80, updatedAt = 1759903200 },
      professions = {
        ["164"] = { name = "Blacksmithing", type = "primary", rank = 100, maxRank = 100 },
        ["185"] = { name = "Cooking", type = "secondary", rank = 75, maxRank = 100 },
        updatedAt = 1759900000,
      },
      location = {
        zone = "Stormwind City", subzone = "Trade District", mapID = 84,
        inInstance = false, instanceType = nil, updatedAt = 1759903180,
      },
      meta = { addonVersion = "1.0.0", lastLogout = 1759903200 },
    },
  },
}
```

Design rules chosen so the Python uploader agent can parse this reliably:

- String keys everywhere (characters keyed by `name-realm-region`,
  professions keyed by stable `skillLineID`) — never relying on Lua's
  array/hash ambiguity or table order.
- Flat-ish nesting, no functions/metatables.
- Normalized realm name (`GetNormalizedRealmName()`) in the id, with the
  pretty display name stored separately.
- `schemaVersion` at the root so the agent can version its parsing logic as
  fields are added in v1.5/v2.

### Capture triggers

| Event | Updates |
|---|---|
| `PLAYER_LOGIN` | full snapshot: identity, level, professions, location |
| `PLAYER_LEVEL_UP` | level |
| `SKILL_LINES_CHANGED` | professions |
| `TRADE_SKILL_SHOW` (profession window opened) | professions (catches max-rank increases) |
| `ZONE_CHANGED_NEW_AREA` / `ZONE_CHANGED` | location |
| `PLAYER_LOGOUT` | final location snapshot |

## Central web server: data store & API

**Data store:** SQLite — single host, friend-group scale, low write volume,
zero ops, trivial to back up. Keeps the whole server a single process,
matching the "locally hosted, low friction" goal.

**Schema:**

```
friends            id, display_name, created_at

characters         id, friend_id (FK), name, realm, realm_display, region,
                    class, race, faction, guid,
                    level, level_updated_at, level_source,       -- tier1 | tier2
                    zone, subzone, map_id, in_instance, instance_type,
                    location_updated_at,                          -- tier2 only
                    created_at

professions        id, character_id (FK), skill_line_id, name, type,
                    rank, max_rank, updated_at

upload_tokens      token_hash, friend_id (FK), created_at, revoked_at

roster_entries     name, realm, region, friend_id (pre-ingest roster list
                    the puller job walks; becomes a `characters` row once
                    first pulled)
```

`characters` holds both tiers' data in one row per character —
`location_*` fields stay null until that friend opts into Tier 2.
`professions` is its own table since the count varies per character.

**Conflict rule between tiers:** per field, the most recent `updated_at`
wins regardless of source, and the UI shows which source it came from
(API vs. in-game) so staleness is never hidden.

**API surface:**

| Endpoint | Caller | Purpose |
|---|---|---|
| `POST /api/login` | browser | password check → signed session cookie |
| `GET /api/characters` | browser (dashboard) | unified read of all characters + professions, session-gated |
| `POST /api/roster` | browser (host, or self-service later) | add a friend + character name/realm/region for Tier 1 pulling |
| `GET /api/roster` | browser | list current roster for management UI |
| `POST /api/ingest` | uploader agent | upsert Tier 2 data, `Authorization: Bearer <token>` → resolves to a friend, validated against that friend's known characters |
| *(internal, no route)* | scheduled job | roster puller — walks `roster_entries`, calls Blizzard's Profile API, upserts with `level_source = tier1` |

**Stack:** Python (FastAPI + SQLite) — consistent with the Python tooling
already used elsewhere, and FastAPI's request validation keeps the ingest
endpoint (the one surface untrusted friend-run agents talk to) robust by
default. Frontend for v1 can be one static HTML page fetching
`/api/characters` and rendering a table — no JS framework needed at this
scale.

**Security:**

- Shared password stored as a bcrypt hash, not plaintext.
- Session cookie: signed, `HttpOnly`, `Secure` (real HTTPS via Cloudflare
  Tunnel's TLS termination).
- Upload tokens: random, stored hashed server-side, individually revocable
  per friend from the dashboard.
- Cloudflare Tunnel credentials/config live outside the repo, never
  committed.

## Uploader agent packaging

**Language/build:** Python + PyInstaller, built via a GitHub Actions matrix
(`macos-latest` + `windows-latest` runners) triggered on release — one
codebase shared with the server, and CI solves the cross-build problem
without needing to own a Windows machine.

**Distribution:** not GitHub Releases — served from your own web
dashboard's onboarding page so non-technical friends never need a GitHub
account. The page generates a **personalized bundle per friend**: clicking
"opt in for live location" creates their upload token and hands back a zip
with the binary + a `config.json` pre-filled with their token and server
URL — no manual copy-pasting.

**OS security warnings — accept them, don't pay to remove them:** macOS
Gatekeeper and Windows SmartScreen will both flag an unsigned/unrecognized
binary once per machine (right-click → Open; "More info" → "Run anyway").
Real signing/notarization costs ~$99/yr (Apple) and ~$100–400/yr (Windows
cert) — not worth it for a friend-group tool. The onboarding page should
show these click-through steps up front so they're not alarming.

**Finding the SavedVariables file:** auto-detect common install paths
(Mac: `/Applications/World of Warcraft`; Windows: default path or the
registry key Battle.net's installer writes), then scan all
`WTF/Account/*/SavedVariables/WoWForever.lua` paths under that install
(friends can have more than one WoW account and won't know the internal
account folder name). Only ask for a manual path if auto-detect fails.

**Trigger:** poll the file's mtime every few minutes rather than OS-level
file-watching — simpler, no platform-specific quirks, and no responsiveness
lost since the source data only changes on `/reload`/logout anyway.

**Run mode:** manual launch for v1, not auto-start on login — a background
process that silently reads files and phones home benefits from being
visible while trust in the tool is still new. Auto-start (LaunchAgent /
Startup folder) is reasonable v1.5 polish. Either way, show a minimal
status indicator (tray icon or simple log: "last upload: success at
3:41pm") so no one is left wondering if it's working.

**Failure handling:** retry with backoff and fail silently if the server's
unreachable (tunnel down, host's Mac asleep); show a clear "waiting for
WoW Forever addon data..." state if the SavedVariables file doesn't exist
yet.

**Trust/privacy messaging:** the onboarding page should plainly state what
it reads (only the `WoWForeverDB` table) and doesn't (nothing else on their
computer), plus how to stop — delete the app locally, or you revoke their
token from the dashboard instantly.

## Roster puller (Blizzard API integration)

**Open question to settle first (a 10-minute spike, not a build phase):**
do the character profile/professions endpoints work with app-level client
credentials for any public character (Branch A — what the whole Tier 1
"zero friction" design assumes), or do they require each character
owner's own Battle.net OAuth consent (Branch B — would make Tier 1 a
one-time "log in with Battle.net" click instead of fully zero-friction)?
Rest of this section assumes Branch A.

**One-time setup:** register an application at Blizzard's developer
portal for a `client_id`/`client_secret`, stored outside the repo like the
Tunnel credentials.

**Token handling:** client-credentials grant, cached and refreshed
(~24h lifetime) rather than fetched per call.

**Per-character calls:** Character Profile Summary (level, class, race,
faction, guild) and Character Professions Summary (primary/secondary with
tiers), both against region-specific hosts (`us.api.blizzard.com`, etc.)
picked from the roster entry's region. Both need the realm **slug**
(lowercase, hyphenated), resolved once via the Realm Index endpoint and
cached rather than guessed, since some realm names don't transform
predictably. Character name must be lowercased in the URL path.

**Scheduled job:** runs inside the same FastAPI process (e.g. APScheduler),
hourly by default — far under Blizzard's rate limits even with a generous
roster. Small delay between calls to be a polite API citizen.

**Per-character error handling:**

| Response | Meaning | Handling |
|---|---|---|
| 404 | Name/realm/region typo, or character doesn't exist | Surface in roster UI as "not found — check spelling/realm" |
| Empty/hidden profile | Character has armory visibility disabled in-game | Surface distinctly as "profile hidden by privacy setting" |
| Expired token mid-run | Normal token lifecycle | Refresh once, retry |
| Transient network error | — | Skip this character this cycle, retry next run, log it |

## In-game addon UI

**Scope boundary:** shows only *this account's* characters — the addon has
no network access, so it can only render what's in its own local
`WoWForeverDB`. Seeing everyone is the web dashboard's job. (Future idea,
not v1: the uploader agent could download the aggregated dashboard data and
inject it as a second, read-only SavedVariables table the addon also
displays — closing the loop back into the game.)

**Entry points:** slash command (`/wowf`) plus a minimap button. No
auto-popup on login — data capture stays silent; the window only appears
on demand.

**Window & layout:** built with Blizzard's own shared UI templates
(`BackdropTemplateMixin`, `UIPanelTemplates`, inset frame templates) rather
than a UI library — fewer embedded dependencies to maintain, and it stays
visually consistent with the game automatically across expansions.

**Content:** one row per character — name (class-colored), level,
current/last-known zone, a condensed profession summary, and a relative
last-updated time. Sortable by column. Clicking a row opens a side detail
pane with the full profession breakdown (using Blizzard's own profession
icons). The currently-logged-in character's row is visually distinct;
stale rows get a visual de-emphasis, mirroring the freshness concept from
the data model.

**Technical hygiene:** frame created lazily on first `/wowf` call, not at
load; standalone frame only, no hooking into Blizzard's default UI — avoids
addon taint entirely.

**Ongoing maintenance:** the TOC's `## Interface:` version needs a one-line
bump on major patches or the addon gets disabled as "out of date," even
when no Lua logic is affected. Not a design flaw, just a recurring chore.

## Things to verify before building (not blockers, just unknowns)

- **Armory privacy setting:** if a friend has WoW's armory/profile
  visibility toggle off, Blizzard's Profile API may return nothing for them
  regardless of our API credentials.
- **Auth type for the Profile API:** need to confirm app-level client
  credentials are sufficient for character profile/professions endpoints
  (Branch A above), vs. requiring each friend's own Battle.net OAuth
  consent (Branch B).
- **Blizzard API rate limits** across a whole friend roster — fine at
  friend-group scale with sane polling intervals (hourly, not per-minute).
- **SavedVariables write cadence** — Tier 2 location data is only as fresh
  as a friend's last `/reload`/logout, not truly live.

## Roadmap

- **v1:** roster-based Tier 1 dashboard (name/level/professions) behind the
  shared password, Cloudflare Tunnel exposure, schema ready for Tier 2 and
  future permissions.
- **v1.5:** addon + uploader agent for opted-in friends (adds location),
  packaged low-friction for Mac/Windows.
- **v2:** per-user accounts/permissions, more fields (gold, bags, M+/raid
  progress — the latter maybe better sourced from Raider.io's API than the
  addon), nicer UI.
