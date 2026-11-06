# Changelog

All notable changes to FriendInfoTracker. Releases are on the
[GitHub releases page](https://github.com/alexjustdoit/wow-FriendInfoTracker/releases).

## [0.7.3] - 2026-11-06

### Added
- A copy button next to each character name opens a popup with the full `Name-Realm` pre-selected for Ctrl+C, for pasting into the mail "To:" field (#2).

## [0.7.2] - 2026-11-06

### Added
- The main window can be resized by dragging the bottom-right corner; the size is remembered.
- `/fit status` now shows, per friend, when their addon was last heard from and when it last sent data.
- `/fit dump <name>` prints the stored records for a character (id, owner, sources) to help debug duplicates.

### Changed
- Changes are pushed to friends after 5 seconds instead of 30, and pending changes are sent on logout and `/reload`.

### Fixed
- Characters belonging to friends-of-friends (relayed through your friends) no longer appear; only your own and your Battle.net friends' characters are listed.
- Characters sent without an owner BattleTag (shown under "?") are no longer accepted or sent. The addon now stamps your characters with your BattleTag as soon as Battle.net connects.

## [0.7.1] - 2026-11-05

### Changed
- Real names are now entered manually in Settings (a text box under each friend) instead of read from Battle.net, which returned unreadable ids. Names are stored locally only.
- Tooltip no longer shows the realm line.

### Fixed
- Release packaging workflow (the v0.7.0 tag was never published).

## [0.7.0] - 2026-11-05

### Added
- Friends' Battle.net real names are shown next to their BattleTag (Real ID friends only). They are stored locally and never synced.
- MIT license and automated packaging for CurseForge releases.

### Changed
- Tooltip order is now Class, Level, Location.

## [0.6.0] - 2026-11-05

### Added
- Hover tooltip shows the character's class (class-colored) between Level and Location.

## [0.5.0] - 2026-10-15

### Added
- Recipe capture and a recipe fold-out panel with collapsible professions, search, and finer scrolling.
- Column-based UI.
- Per-friend hiding with a collapsible Hidden section, managed from a Settings panel.
- Command reference in the README.

### Changed
- Renamed the addon to FriendInfoTracker and added an icon.

## [0.1.0] - 2026-10-14

### Added
- Addon-only v1: Battle.net peer sync, passive capture of friends who don't run the addon, and a minimap button.
- Manual install and testing instructions in the README.
- Level, profession, and location capture with an in-game UI.

### Changed
- TOC interface version updated to 16001 to match the live client.
