# FriendInfoTracker

A WoW addon for tracking character data (names, levels, professions,
location) across your own characters and your Battle.net friends'. Everything
can be viewed in-game.

**Status:** v1 (addon-only) built, but not yet tested in a live client.
v2 (uploader agent + web dashboard) is planned only.

## Manual install & testing

### Install

1. Find your AddOns folder. Use the folder for the game flavor you play
   (`_retail_`, `_classic_`, etc.):
   - **Mac:** `/Applications/World of Warcraft/_retail_/Interface/AddOns/`
   - **Windows:** `C:\Program Files (x86)\World of Warcraft\_retail_\Interface\AddOns\`
   - Create `Interface/AddOns` if it doesn't exist yet.
2. Copy the `FriendInfoTracker` folder from this repo into it. The folder name must
   stay exactly `FriendInfoTracker` (it has to match the `.toc` file), and the `.toc`
   must sit directly inside it:
   `.../Interface/AddOns/FriendInfoTracker/FriendInfoTracker.toc`.
   - **Developer alternative:** symlink it so edits apply without copying:
     `ln -s "$(pwd)/FriendInfoTracker" "/Applications/World of Warcraft/_retail_/Interface/AddOns/FriendInfoTracker"`
3. Restart WoW completely. A `/reload` doesn't pick up a newly added addon or
   new files listed in the `.toc`.
4. At character select, click **AddOns** and check that **FriendInfoTracker** is
   enabled. If it's listed as out of date, tick **Load out of date AddOns**,
   or bump `## Interface:` in the `.toc` to the client's current version.
5. **Recommended while testing:** run `/console scriptErrors 1` once so Lua
   errors pop up instead of failing silently.

**Updating:** copy the new files over the old ones, then `/reload`. Restart
the game instead if the `.toc` changed or files were added.

### Test solo

1. Log in. Type `/fit`, or click the minimap button. Your current
   character should appear under "Your characters", highlighted.
2. Hover the row. The tooltip should list your professions with source
   "this account".
3. Log in on an alt and open `/fit`. Both characters should be listed.
4. `/reload`, then open
   `World of Warcraft/_retail_/WTF/Account/<ACCOUNT>/SavedVariables/FriendInfoTracker.lua`.
   It should contain a `FriendInfoTrackerDB` table with your characters.

### Test with a friend

1. You and a Battle.net friend both install the addon and log in to the same
   game flavor.
2. Wait about a minute, then both run `/fit status`. Each of you should see
   the other listed as running the addon. If not, run `/fit sync`.
3. Open `/fit`. The friend's characters should appear under their BattleTag
   name, with the tooltip source "their addon".
4. **Live push:** have the friend change zones. It should show up in your
   window within about 30 seconds.
5. **Relay (needs 3 people):** A and C are each friends with B, but not with
   each other. A and B overlap, then A logs off and C logs on. C should see
   A's characters with "relayed via B".
6. **Friend without the addon:** any online Battle.net friend in WoW who
   isn't running the addon should appear within 1–2 minutes, with level and
   zone but no professions, and source "friend list".

Note anything that doesn't match. These tests also cover the items under
"Verify in a live client" below.

## Commands

`/friendinfotracker` works anywhere `/fit` does.

| Command | What it does |
|---|---|
| `/fit` | Opens or closes the main window: your characters and every cached friend's characters, grouped by owner. Clicking the minimap button does the same. |
| `/fit sync` | Re-syncs with all online friends now: re-greets everyone and exchanges data again. Use it if a friend's data looks out of date while they're online. |
| `/fit status` | Prints how many friends are online in WoW, and which of them are running the addon. |
| `/fit settings` | Opens or closes the Settings panel (same as the window's **Settings** button). |
| `/fit minimap` | Shows or hides the minimap button (saved per character). |
| `/fit help` | Lists these commands. Any unrecognized subcommand does the same. |

## v1 principle: the addon is the whole product

Installing the addon is the only setup. There's no companion app, server or
account.

WoW's Lua sandbox can't make network calls or write files outside its own
SavedVariables. So in v1 the data never leaves the game. It moves between
friends' copies of the addon over Battle.net's in-game addon messaging, and
each player keeps a local cache. A web view (and anything else outside the
game) needs a separate program, which is what v2 adds.

## How data moves (v1)

```
 [Alice's addon] <--BNet--> [Bob's addon] <--BNet--> [Cara's addon]
   cache: A, B, C              cache: A, B, C           cache: A, B, C
```

- **Capture:** each addon records its own account's characters on login,
  level-up, profession change and zone change (see capture triggers below).
- **Sync:** when two Battle.net friends running the addon are online at the
  same time, they swap everything they know. That includes data relayed from
  other friends.
- **Relay (store-and-forward):** Alice and Cara never need to be online
  together. If Bob overlaps with each of them, Alice's data reaches Cara
  through Bob. Records keep the timestamp of when the *owner's* addon captured
  them, so relayed data is never mistaken for newer than it is.
- **Cache:** everything received is stored in the local `FriendInfoTrackerDB`. The
  window reads from that cache, so it works when nobody else is online.
- **Freshness:** each record is only as current as the newest copy held by
  anyone you overlap with. If nobody connects you to a friend, their data goes
  stale. The UI always shows how old each record is and where it came from.

### Who you sync with

There's no setup and no group configuration: **every Battle.net friend running
the addon** syncs automatically, over Battle.net only (no guild channel).
Because data is relayed, it can reach friends-of-friends you aren't directly
connected to.

### Friends without the addon (passive capture)

For online Battle.net friends who don't run the addon, the friend list gives
the current character's **name, realm, level, class, race and zone**. That data
is cached and relayed the same way. **Professions and recipes are never
available** for these friends: no in-game API exposes them.

A friend only falls back to friend-list capture after they've ignored a PING
for 30 seconds. Capturing them earlier would stamp friend-list data as newer
than their real addon data, which is about to arrive.

### Sync protocol

All messages go over `BNSendGameData` with prefix `FIT`, as
`<protocol>:<TYPE>:<msgID>:<seq>:<total>:<chunk>`. Payloads are serialized
tables (see `Serialize.lua`), split into chunks of up to 3800 bytes on UTF-8
boundaries and sent through a paced queue. Large record sets (for example,
many characters with long recipe lists) are split into several `DATA`
messages of about 32KB each. The current protocol version is `2`.

| Message | Meaning |
|---|---|
| `PING` | Sent once per session to every online WoW friend |
| `PONG` | Reply to a `PING`: "I run the addon" |
| `DIGEST` | `{ [characterID] = { identityAt, levelAt, professionsAt, locationAt, recipesAt } }` |
| `DATA` | `{ [characterID] = record }`, only what's newer than the peer's digest |

After a `PING`/`PONG` both sides send their digest, and each side sends what
the other is missing. Later changes (your own captures, or newly merged data)
are pushed as `DATA` to every online peer after a 30-second debounce. That
push is what relays data onward. Once both sides are in sync no more messages
are sent, because a merge only accepts strictly newer data.

**Merge rule:** per section (identity / level / professions / location /
recipes), the newer `updatedAt` wins. Data from others never overwrites your own account's
characters.

**Untrusted input:** everything received is parsed by a non-executing
deserializer with depth and size limits. Each record is then rebuilt from
known fields only, with type checks, string length caps, timestamps clamped
to at most 1 hour in the future, and identity checked against the record id.
UI markup (`|`) is escaped when displayed. The sender's identity is
authenticated by Battle.net, but relayed data is only as honest as whoever
relayed it. That's acceptable for a friend group.

## Addon data model

`FriendInfoTrackerDB` is account-wide (`## SavedVariables`) and holds your own
characters and every cached friend character. The other two tables hold UI
preferences only, so the data table stays pure character data:

- `FriendInfoTrackerSettings` (account-wide): `hiddenFriends`, a set of
  BattleTags moved to the Hidden section.
- `FriendInfoTrackerCharDB` (per character): minimap button position and
  visibility.

```lua
FriendInfoTrackerDB = {
  schemaVersion = 3,
  myBattleTag = "Thrall#1234",
  characters = {
    ["Thrall-Stormrage-US"] = {
      isMine = true,                    -- local only, never sent
      owner = "Thrall#1234",
      identity = {
        name = "Thrall", realm = "Stormrage", realmDisplay = "Stormrage",
        region = "US", class = "WARRIOR", race = "Orc", faction = "Horde",
        guid = "Player-1234-00001234", updatedAt = 1759903200, source = "self",
      },
      level = { value = 80, updatedAt = 1759903200, source = "self" },
      professions = {
        ["Blacksmithing"] = { name = "Blacksmithing", type = "primary", rank = 100, maxRank = 100, skillLine = 164 },
        ["Cooking"] = { name = "Cooking", type = "secondary", rank = 75, maxRank = 100 },
        updatedAt = 1759900000, source = "self",
      },
      recipes = {                         -- only professions whose window was opened
        ["Blacksmithing"] = { "Copper Chain Belt", "Rough Bronze Leggings" },
        updatedAt = 1759900000, source = "self",
      },
      location = {
        zone = "Stormwind City", subzone = "Trade District", mapID = 84,
        inInstance = false, updatedAt = 1759903180, source = "self",
      },
      meta = { addonVersion = "0.4.0", lastLogout = 1759903200 },  -- local only
    },
    ["Jaina-Proudmoore-US"] = {
      owner = "Jaina#5678",
      receivedFrom = "Bob#2222",          -- relayed: receivedFrom ~= owner
      receivedAt = 1759904000,
      level = { value = 80, updatedAt = 1759899000, source = "addon" },
      -- ...same sections as above
    },
  },
}
```

- `source` is per section: `self` (captured on this account), `addon`
  (captured by the owner's addon), or `bnet` (seen in the friend list).
- Characters are keyed `Name-NormalizedRealm-Region`. Professions and
  recipe lists are keyed by profession name, because Vanilla-based clients
  have no `skillLineID`; `skillLine` is stored too when the client provides
  it. String keys everywhere, flat nesting, no functions or metatables, so
  the v2 agent can parse the file reliably.
- Migrations run on load. v1 → v2: existing records are marked `isMine`,
  sections get `source = "self"`, and identity gets an `updatedAt`. v2 → v3:
  professions are re-keyed from `skillLineID` to name.

### Professions on different clients

`CaptureProfessions` uses `GetProfessions()` when the client has it (modern
clients). Otherwise it falls back to the Skills list
(`GetNumSkillLines`/`GetSkillLineInfo`), where professions sit under the
"Professions" and "Secondary Skills" headers (Vanilla-based clients, such as
the 1.x Classic beta). If one of those headers is collapsed, the capture is
skipped, because collapsed sections hide their skills and would look
unlearned.

### Recipes

WoW only exposes a profession's recipe list while that profession's window is
open. So recipes are recorded the first time each profession window is opened
on a character, and updated whenever it's opened again.

- **Grow-only:** each capture is merged into the stored list, so a filtered
  search or a collapsed category never erases recipes.
- **Pruned on unlearn:** if the character drops a profession, its recipe list
  is removed.
- **Three APIs, picked by feature detection:** the Craft API (Vanilla
  Enchanting), `C_TradeSkillUI` (modern clients), and
  `GetTradeSkillLine`/`GetTradeSkillInfo` (Vanilla trade skills).
- Reopening a window with nothing new doesn't bump `updatedAt`, so it
  doesn't trigger a sync.

### Capture triggers

| Event | Updates |
|---|---|
| `PLAYER_LOGIN` | full snapshot: identity, level, professions, location |
| `SKILL_LINES_CHANGED` | professions |
| `PLAYER_LEVEL_UP` | level (uses the event's new-level argument) |
| `TRADE_SKILL_SHOW` (profession window opened) | professions (catches max-rank increases) + recipes |
| `TRADE_SKILL_UPDATE` / `TRADE_SKILL_LIST_UPDATE` / `NEW_RECIPE_LEARNED` | recipes (debounced 0.5s) |
| `CRAFT_SHOW` / `CRAFT_UPDATE` (Vanilla Enchanting window) | recipes (debounced 0.5s) |
| `ZONE_CHANGED_NEW_AREA` / `ZONE_CHANGED` | location |
| `PLAYER_LOGOUT` | final location snapshot (stored locally; too late to send) |

## In-game UI

- **Entry points:** `/fit` (or `/friendinfotracker`) and a draggable minimap
  button. Data capture is silent, and the window only opens on demand.
- **Commands:** see [Commands](#commands).
- **Layout:** a 780px-wide window with column headers: Character, Level,
  Zone, Primary, Secondary, Updated. Rows are grouped by owner ("Your
  characters" first, then each friend by BattleTag), with gold section
  headers. The Primary and Secondary columns list one profession and rank
  per line, and each row grows to fit. The current character is tinted gold,
  the selected character blue, and rows older than 7 days are dimmed.
  Escape closes the window.
- **Recipe panel:** click a character to open a panel that folds out to the
  right of the main window. It lists recipes grouped by profession, with a
  count per profession and one recipe per line, and scrolls. Click the same
  row again, or the panel's close button, to fold it away. Rows with
  recorded recipes show a small arrow. If no recipes are recorded yet, the
  panel says how to record them, or that the friend doesn't run the addon.
- **Hiding friends:** each friend's group header has a **Hide** button.
  Hidden friends and their characters move to a **Hidden** section at the
  bottom of the list. It's collapsed by default each session; click its
  header to expand it, where hidden friends appear dimmed with a **Show**
  button. Hiding is account-wide, by BattleTag, and only affects the display:
  hidden friends' data is still captured, synced and relayed.
- **Settings panel:** the **Settings** button (bottom-left, or
  `/fit settings`) folds out a panel on the right with all options:
  - *General:* show minimap button.
  - *Friends:* one checkbox per known friend, with their character count.
    Unchecked friends are hidden.

  The Settings and recipe panels share that space, so opening one closes the
  other.
- **Row tooltip:** realm, owner, subzone, and each section's age and source
  ("this account", "their addon", "relayed via Bob", "friend list").
- **Hygiene:** Blizzard's own templates (no UI library), frame created
  lazily, standalone frame only, no hooks into Blizzard UI, so no taint.

## Files

| File | Purpose |
|---|---|
| `FriendInfoTracker/Core.lua` | DB init/migration, capture of own characters |
| `FriendInfoTracker/Serialize.lua` | Dependency-free serializer and defensive deserializer |
| `FriendInfoTracker/Sync.lua` | Friend scan, passive capture, sync protocol, merge |
| `FriendInfoTracker/UI.lua` | Main window, tooltips, slash commands |
| `FriendInfoTracker/Minimap.lua` | Minimap button |
| `tests/sim.lua` | Out-of-game simulation: several stubbed clients wired over a fake Battle.net transport |

Run the simulation with `lua tests/sim.lua FriendInfoTracker` from the repo root.
It covers direct sync, relay without overlap, passive capture, live pushes,
own-record protection, hostile and malformed input, large multi-chunk syncs,
no traffic once in sync, recipe capture (grow-only, pruning, Craft window,
sync), the Vanilla skill-line profession path, splitting large payloads into
batches, and a UI smoke test (rows, columns, recipe panel) against stubbed
frames, plus hiding friends, the Hidden section and the Settings panel. It runs on desktop Lua, not WoW's client, so it
checks the logic but not the WoW API behaviour.

## Verify in a live client

These API assumptions can't be tested outside the game:

- `BN_CHAT_MSG_ADDON` args are `(prefix, text, channel, senderGameAccountID)`
  and `BNSendGameData(gameAccountID, prefix, text)` is still the send call.
  The ~4KB message cap and Battle.net's throttle limits (the queue sends one
  message every 0.3s) also need checking.
- Whether `C_ChatInfo.RegisterAddonMessagePrefix` is needed for Battle.net
  game data (it's called anyway).
- `C_BattleNet.GetFriendGameAccountInfo` fields used: `gameAccountID`,
  `isOnline`, `clientProgram`, `wowProjectID`, `isInCurrentRegion`,
  `characterName`, `realmName`, `regionID`, `characterLevel`, `className`,
  `raceName`, `factionName`, `areaName`, `playerGuid`.
- Passive capture builds realm keys by removing spaces and hyphens from
  `realmName`. That has to match `GetNormalizedRealmName()`, or a friend who
  later installs the addon will show up twice.
- **Vanilla-based (1.x) client:** whether `GetProfessions` exists, the exact
  Skills-list header names ("Professions", "Secondary Skills"), and whether
  Mining's smelting window reports itself as "Mining" (recipes are matched
  to professions by name).
- **Recipe APIs:** `GetTradeSkillLine`/`GetTradeSkillInfo` and the Craft API
  (`GetCraftDisplaySkillLine`, `GetNumCrafts`, `GetCraftInfo`) on the 1.x
  client; `C_TradeSkillUI.GetBaseProfessionInfo`/`GetAllRecipeIDs` on modern
  clients.
- **UI appearance:** layout, font sizes, and multi-line profession cells.
  The simulation only checks that the code runs, not how it looks.
- TOC `## Interface:` needs a bump on major patches.

## Roadmap

- **v1 (built):** addon-only. Own capture, Battle.net peer sync with relay,
  passive friend-list capture, grouped in-game window with profession
  columns, recipe fold-out panel, minimap button.
- **v1.x ideas:** export window (copyable CSV for spreadsheets), recipe
  search across all characters ("who can make X?"), sortable columns, `/fit forget <BattleTag>` to clear a friend's
  cached data.
- **v2:** uploader agent + central server + web dashboard (below).

---

# v2 plan: uploader agent, server, web dashboard

v2 is an **optional** layer on top of the addon. It doesn't change v1: friends
who only install the addon keep working exactly as before. v2 adds a web view
outside the game and Blizzard-API data that doesn't need anyone online.

## Architecture

```
[WoW Addon]  (unchanged from v1; syncs in-game with BNet friends)
     |  writes FriendInfoTrackerDB on /reload or logout
     v
[Uploader Agent]  (each opted-in friend's own machine)
     |  reads its own account's records, POSTs to the ingest API with a personal token
     v
[Central Web Server]  (runs on your Mac, exposed via Cloudflare Tunnel)
     ^
     |  pulls on a schedule, no install needed by anyone
[Roster Puller]  (queries Blizzard's Profile API for every known character+realm)
```

## Who runs the agent: every opted-in friend

Each friend who wants their data on the dashboard runs their own agent. The
agent uploads **only that account's own records** (`isMine = true`). It
doesn't upload the relayed cache, even though the cache holds other friends'
data too. Reasons:

- Each upload token is bound to one friend, and the server checks uploads
  against that friend's known characters. Relayed records belong to someone
  else and can't be checked that way.
- Data on the dashboard always comes straight from its owner's machine, so
  relayed data can't spoof it.
- Freshness: a friend's dashboard data updates on their own `/reload`/logout,
  without waiting for someone to relay it.

Friends who don't run the agent still appear on the dashboard through the
roster puller (Blizzard API: level, class, professions), just without
location.

## Data tiers on the dashboard

- **Tier 1 (zero install):** name, class, race, level, professions from
  Blizzard's Profile API, pulled hourly from a roster of name + realm +
  region.
- **Tier 2 (opt-in agent):** adds last-known location and anything else only
  visible in-game, uploaded by that friend's agent.

**Conflict rule:** per field, the most recent `updated_at` wins regardless of
source, and the UI shows the source (API vs. in-game), so staleness is never
hidden. This is the same per-section rule the addon uses.

## Server hosting & access

- Runs on your Mac, exposed via **Cloudflare Tunnel**: no open router ports,
  no VPN for friends, just an HTTPS URL.
- A single shared password for v2.0, implemented as app-level middleware
  (not Cloudflare Access) so it can become per-user accounts later.
- Everyone with the password sees everyone's data. Per-user visibility is a
  later addition.

## Data store & API

**SQLite**: single host, friend-group scale, low write volume, zero ops.

```
friends            id, display_name, battle_tag, created_at

characters         id, friend_id (FK), name, realm, realm_display, region,
                    class, race, faction, guid,
                    level, level_updated_at, level_source,       -- api | addon
                    zone, subzone, map_id, in_instance, instance_type,
                    location_updated_at,                          -- addon only
                    created_at

professions        id, character_id (FK), skill_line_id, name, type,
                    rank, max_rank, updated_at, source

upload_tokens      token_hash, friend_id (FK), created_at, revoked_at

roster_entries     name, realm, region, friend_id
```

| Endpoint | Caller | Purpose |
|---|---|---|
| `POST /api/login` | browser | password → signed session cookie |
| `GET /api/characters` | dashboard | all characters + professions, session-gated |
| `POST /api/roster` / `GET /api/roster` | browser | manage Tier 1 roster |
| `POST /api/ingest` | uploader agent | upsert the friend's own records, `Authorization: Bearer <token>`; rejects characters not belonging to that friend |
| *(internal)* | scheduled job | roster puller |

**Stack:** Python (FastAPI + SQLite). FastAPI's request validation protects
the ingest endpoint, which is the one surface untrusted agents talk to. The
frontend is one static HTML page rendering `/api/characters`.

**Security:** password stored as a bcrypt hash; signed `HttpOnly` + `Secure`
cookie; upload tokens random, stored hashed, revocable per friend; Tunnel
credentials kept outside the repo.

## Uploader agent

- **Build:** Python + PyInstaller via a GitHub Actions matrix
  (`macos-latest`, `windows-latest`), triggered on release.
- **Distribution:** from the dashboard's onboarding page, not GitHub
  Releases. "Opt in" creates the friend's token and returns a zip with the
  binary plus a pre-filled `config.json` (token + server URL).
- **OS warnings:** unsigned. Accept the one-time Gatekeeper/SmartScreen
  click-through and document it on the onboarding page, rather than paying
  ~$200–500/yr for signing.
- **Finding the file:** auto-detect the install (Mac
  `/Applications/World of Warcraft`; Windows default path or the Battle.net
  registry key), then scan `WTF/Account/*/SavedVariables/FriendInfoTracker.lua`
  (there may be several accounts). Ask for a path only if detection fails.
- **Parsing:** a minimal Lua-table parser for the SavedVariables format,
  driven by `schemaVersion`. Upload only `isMine` records.
- **Trigger:** poll the file's mtime every few minutes. The data only changes
  on `/reload`/logout anyway.
- **Run mode:** manual launch at first, with a visible status ("last upload:
  success at 3:41pm"). Auto-start (LaunchAgent / Startup folder) later.
- **Failures:** retry with backoff, and fail silently if the server is
  unreachable. Show a clear "waiting for FriendInfoTracker addon data..." state if
  the file doesn't exist yet.
- **Trust messaging:** the onboarding page states plainly that the agent
  reads only `FriendInfoTrackerDB` and uploads only your own characters. To stop,
  delete the app, or the host revokes the token.

## Roster puller (Blizzard API)

**Settle first (10-minute spike):** do the character profile and professions
endpoints work with app-level client credentials (Branch A, assumed here),
or do they need each owner's Battle.net OAuth consent (Branch B, a one-time
"log in with Battle.net" click)?

- Register a Blizzard developer app (`client_id`/`client_secret` kept
  outside the repo). Use the client-credentials grant, with the ~24h token
  cached and refreshed.
- Per character: Profile Summary + Professions Summary on the region host
  (`us.api.blizzard.com`, …). Realm **slug** resolved via the Realm Index and
  cached; character name lowercased.
- Hourly via APScheduler in the FastAPI process, with a small delay between
  calls.

| Response | Handling |
|---|---|
| 404 | Roster UI: "not found — check spelling/realm" |
| Empty/hidden profile | Roster UI: "profile hidden by privacy setting" |
| Expired token | Refresh once, retry |
| Transient error | Skip this cycle, log, retry next run |

## Closing the loop (v2+ idea)

The agent could also download the dashboard's aggregated data and write it
into a second, read-only SavedVariables table for the addon to show. That
would merge API-sourced professions for non-addon friends into the in-game
window.

## Open questions for v2

- Branch A vs. B for the Profile API (above).
- Armory privacy toggle: hidden profiles may return nothing from the API.
- Whether dashboard visibility should follow Battle.net friendships
  (matching in-game sharing) or stay "everyone with the password".
