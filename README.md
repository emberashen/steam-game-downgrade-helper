# Steam Game Downgrade Helper

Roll a Steam game back to an earlier patch, without disturbing your mods.

Steam updates games automatically and offers no supported way to decline an
update or reverse one. That is fine until a patch breaks a mod you rely on — and
most games have no "previous version" beta branch to fall back to.

This tool downloads the older version from Valve's own servers, using your own
account and Valve's own command-line tool, and puts it back over your install.

**Double-click `Downgrade.bat`.** That is the whole thing.

---

## What it does

- Finds Steam, your library folders and your games — wherever they are, on any drive
- Lists the versions **your PC has actually had installed**, read from Steam's own logs
- Shows how many times you played each one, so you can pick the version that worked
  rather than having to know patch numbers
- Installs SteamCMD if you do not have it, **where you choose**
- Downloads only the parts of the game that actually differ between versions
- Shows you exactly which files will change, and waits for you to agree
- Replaces only those files, **never deleting anything**, so mod folders survive
- Verifies afterwards that every file matches the version you asked for

**It does not touch save files, and does not try to back them up.** Every game
handles saves differently and there is no general rule a script can follow, so
guessing would eventually go wrong.

Many games keep saves on a server or in Steam Cloud, where a version change
makes no difference. If the game you are reverting keeps them on your PC, look
up where and copy them somewhere safe first — searching the game's name plus
"save file location" normally finds it.

## Requirements

Windows 10 or 11, Steam, and the account that owns the game.

Nothing else. No Python, no runtime, no dependencies — it is Windows PowerShell
5.1, which ships with Windows.

You will need enough disk space for the older version, which for a large game
can be 50 GB or more. The tool checks first and refuses rather than filling your
drive.

## Your password

**This tool never asks for, stores or sees your Steam password.**

It opens Valve's own SteamCMD in a separate window and you type your password
into that, once. SteamCMD then caches a login token, and every later run needs
no password and no Steam Guard code.

One thing catches everybody out, so it is worth saying twice: **nothing appears
on screen while you type your password.** No dots, no asterisks. That is
deliberate on Valve's part, not a frozen prompt. This is covered properly in
[`how-to-use-me.txt`](how-to-use-me.txt).

## Steam may go offline afterwards

Signing SteamCMD in can knock the Steam client off its connection. You may see
`NO CONNECTION`, or a warning that Steam cannot sync your saves with Steam
Cloud, or an update that fails instantly with "No connection".

Nothing is broken. **Fix: Steam menu → Exit for a full quit, then start Steam
again.** Do that before playing. If you get the cloud-sync warning, click
Cancel rather than "Play anyway" — playing with sync broken can overwrite good
cloud saves.

## Three things that undo a downgrade

1. **"Verify integrity of game files"** — compares against the *newest* patch,
   decides your older files are damaged, and re-downloads them. One click undoes
   everything. It catches the change even when every altered file is the same
   size as the new one (tested, not assumed).

   That also makes it the correct way to undo a downgrade **deliberately**:
   right-click the game → Properties → Installed Files → Verify integrity of
   game files, and Steam re-downloads only what changed.
2. **Launching from Steam** — start the game from its mod loader instead. Once a
   newer patch exists, launching from Steam is what triggers the update.
3. **Automatic updates left on** — set the game to "Only update this game when I
   launch it" in Steam. There is no "never update" option; that is the strongest
   setting available.

## Why it keeps the download

The downloaded version is kept on purpose. When the game is patched again — and
it will be — running this a second time takes about two minutes instead of
another hour, because there is nothing left to fetch.

It lives inside the SteamCMD folder, which is why the tool asks where to put
SteamCMD and suggests the same drive as the game. Delete it whenever you like;
the only cost is doing the download again.

If you already downloaded a version before running this tool, it will find it
and use it rather than downloading again.

## Limitations, stated plainly

- **Only versions your PC has installed can be listed automatically.** Steam's
  logs are the only machine-readable source that records both a build and the
  manifest IDs needed to fetch it. A fresh Steam install has no history.
- **Valve eventually removes very old versions** from their servers. The tool
  checks availability early, using the smallest download, so you find out in
  seconds rather than after a long wait.
- A shipped list of known builds fills some of the gap, and you can enter details
  manually from [SteamDB](https://steamdb.info) for anything not covered.

## Is this legitimate?

Yes. It downloads games you own, from Valve's official servers, through Valve's
official SteamCMD tool, signed in with your own account. No piracy, no cracked
files, no third-party hosting. It only ever fetches a version of a game your
account already owns.

## Files

| File | What |
|---|---|
| `Downgrade.bat` | Double-click this |
| `Downgrade.ps1` | The tool |
| `how-to-use-me.txt` | Full instructions in plain English |
| `lib/` | Steam discovery, build history, SteamCMD, file swapping |
| `data/known-builds.json` | Shipped list of known builds and version labels |

## Contributing a game

`data/known-builds.json` maps build IDs to friendly version names. Manifest IDs
are global addresses on Valve's CDN, not per-machine values, so an entry
harvested on one PC works for everyone.

Adding a game means adding its app ID and any builds you know about.
The file must never contain account names, SteamIDs or install paths.

## Licence

MIT — see [LICENSE](LICENSE).

Provided as-is. It shows you every change before making it and never deletes
files, but you are modifying your own game install, and your saves are your own
responsibility. You do so at your own risk.
