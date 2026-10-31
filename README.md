# photo-import

A friendly terminal app for photographers who shoot RAW + JPEG. It imports
photos from an SD card into a tidy, per-camera library — one dated album per
shoot — and helps you clean up afterward by finding JPEGs whose RAW you've
already culled in Lightroom.

- **Import** — pick the card, the camera, and the day(s) to import; albums are
  named `YYYY-MM-DD Description` so they sort chronologically in Finder.
- **Cull** — find albums where the RAW and JPEG counts no longer match, then
  delete the orphaned JPEGs (with a big red confirmation).
- **Configure** — add or edit camera profiles from inside the app. No config
  file editing required.
- A colorful dashboard shows SD-card capacity and your library's total size
  and RAW/JPEG counts.

> **macOS only.** It relies on macOS tools (`osascript`, BSD `date`/`stat`,
> Terminal.app). Linux/Windows aren't supported.

```
2026-06-06 Yosemite Day 1/
├── raws/   DSC00001.ARW  DSC00002.ARW  …
└── jpgs/   DSC00001.JPG  DSC00002.JPG  …
```

## Requirements

- macOS
- Bash 3.2+ (the version macOS ships — no upgrade needed)
- [gum](https://github.com/charmbracelet/gum): `brew install gum`

Without gum the app falls back to a plainer arrow-key interface
(`--terminal`), but the full experience needs gum.

## Install

```bash
git clone https://github.com/drthvdr/photo-import.git ~/code/photo-import
mkdir -p ~/bin
ln -s ~/code/photo-import/photo-import ~/bin/photo-import
```

Make sure `~/bin` is on your `PATH`, then run:

```bash
photo-import
```

The first time, an interactive setup asks about your camera(s) and writes
`~/.config/photo-import/cameras.conf` (see [Camera profiles](#camera-profiles)).

### Optional: a Dock icon

```bash
~/code/photo-import/install-launcher.sh
```

This builds **Photo Import.app** in `/Applications` (pass a different folder as
an argument to put it elsewhere). It opens Terminal, runs the app, and closes
the window when you quit. The icon comes from [`icon.png`](icon.png) — drop in
your own PNG and re-run the script to change it. The app points at the folder
you ran the installer from, so re-run it if you move the project.

## Using it

Run `photo-import` and pick a mode:

| Mode | What it does |
|------|--------------|
| 📷 **Import Photos from SD Card or File** | Copy a card (or any folder with a `DCIM/` directory) into your library |
| 🗑️ **Cull orphan JPGs** | Delete JPEGs that no longer have a matching RAW |
| ⚙️ **Configure profiles** | Add, edit, or remove camera profiles |

After each action you're asked whether to do another, so you can import, cull,
and tweak settings in one session.

### Import

1. **Card** — auto-detected when one is mounted. If none is (unmounted card,
   importing from a backup, …) you can pick a folder in Finder or type a path.
   The folder just needs a `DCIM/` directory in it.
2. **Camera** — matched automatically by RAW extension; you're only asked
   when it can't tell (several cameras match, or none do).
3. **Days** — a multi-select of the card's DCIM folders, newest first, with the
   newest pre-selected. Each shows its date and file count.
4. **Album name** — pre-filled with the date, e.g. `2026-09-05 `; you type the
   description. Picking several days uses the earliest date.
5. **Plan & confirm** — file counts, sizes, and destination, then it copies.

Safe by design: import only **copies**. It never touches the card's contents,
and it never overwrites a file that already exists in the destination, so you
can re-import into the same album to top it up.

> **About the automatic date:** Sony cameras name DCIM folders `NNNYMMDD`
> (e.g. `10860905` = 2026-09-05), which the app decodes. Cameras with other
> folder schemes (`100CANON`, `100NIKON`, …) get no automatic date — you type
> the whole album name. Contributions for other brands are welcome.

### Cull

Scans your library for albums where the RAW and JPEG counts differ — the
signature of "I deleted RAWs in Lightroom but the JPEGs are still here" — and
lets you pick which to clean. For each one it shows the numbers, then asks for
confirmation with **No** as the default. Only JPEGs with no same-named RAW are
removed.

Use `--dry-run` to see what would be deleted without deleting anything.

### Keys

| Where | Move | Select | Confirm | Cancel |
|-------|------|--------|---------|--------|
| Single-choice menus | ↑ ↓ | — | Enter | Esc |
| Multi-select lists | ↑ ↓ | `x` | Enter | Esc |
| Text prompts | type | — | Enter | Esc |
| Yes/No dialogs | ← → | — | Enter | Esc (`y` / `n` work too) |

Esc or Ctrl-C anywhere asks **Exit Photo Import?** (default No). Closing the
window exits cleanly. Quitting from Terminal.app closes its window too.

## Camera profiles

A profile tells the app how to recognize a camera and where its albums go.
They live in `~/.config/photo-import/cameras.conf`, one per line:

```
Name | raw_exts | jpeg_exts | split_folders | output_base_dir
```

See [`examples/cameras.conf.example`](examples/cameras.conf.example). Use
absolute paths (no `~`).

| Field | Meaning |
|-------|---------|
| `raw_exts` / `jpeg_exts` | Comma-separated, case-insensitive. Either may be blank. |
| `split_folders` | `true` → `raws/` and `jpgs/` subfolders; `false` → everything in the album root |
| `output_base_dir` | Where this camera's albums are created |

How blank extension fields behave:

| RAW | JPEG | Result |
|-----|------|--------|
| set | set | Files route by extension |
| set | blank | Only RAW-type files are copied (e.g. a TIFF film scanner) |
| blank | set | Only JPEG-type files are copied |
| blank | blank | Catch-all: every file is copied to the album root |

Splitting is only offered when both are set.

### Editing profiles

You rarely need to touch the file. Choose **Configure profiles** in the menu,
or use the flags below.

- **`--config-update`** — a multi-select of your profiles plus
  *+ Add a new profile*. For each profile you tick, choose which fields to
  change (name, RAW/JPEG extensions, split, output folder) or delete it.
  Profiles whose output folder is missing on disk are tagged `(missing)` so
  you can fix or remove them. If nothing actually changed, it won't ask to save.
- **`--config-reset`** — backs your config up to
  `cameras.conf.<timestamp>.bak`, then runs the setup wizard from scratch.
  Your current config is replaced only if you confirm the result; quit
  partway and it's left untouched.
- **Nothing is written until you confirm** the final summary table (the
  one exception is that reset saves its `.bak` backup up front).

Add `--dry-run` (or use `--config-dry-run` / `--config-update-dry-run`) to walk
through any of these without writing anything:

```bash
photo-import --dry-run --config-update    # same as --config-update-dry-run
photo-import --dry-run --config-reset     # simulate a reset: no backup, no wipe
```

## Command-line options

```
photo-import [OPTIONS] ["Album description"]

  -n, --dry-run             Show the plan; copy/delete nothing
  -a, --all                 Import every DCIM folder on the card
  -f, --folder NAME         Import one DCIM folder by name
  -v, --volume PATH         Use this card/folder instead of auto-detecting
      --cull-jpgs           Jump straight to cull mode
      --terminal            Use the plain (no-gum) interface
  -h, --help                Show help

      --config-update            Edit/add/delete camera profiles
      --config-reset             Back up the config and rebuild it
      --config-dry-run           Simulate first-run setup
      --config-update-dry-run    Simulate --config-update
```

```bash
photo-import "Cougar Crest Trail"            # → 2026-09-05 Cougar Crest Trail
photo-import --folder 10260801 "Big Bear"    # one specific day
photo-import --all "Denver - Week 1"         # whole card
```

A description you pass on the command line gets the date prefix added
automatically unless it already starts with one.

## Customizing the look

Every color lives in [`lib/theme.sh`](lib/theme.sh). Widgets use only the
semantic names at the bottom (`THEME_BORDER`, `THEME_LABEL`, …), so re-pointing
those reskins the whole app.

## Project layout

```
photo-import            entrypoint: loads modules, picks TUI or plain CLI
install-launcher.sh     builds the optional Photo Import.app
icon.png                icon used by the launcher
examples/               sample cameras.conf
lib/
  config.sh             profile storage + the setup/update wizard
  sdcard.sh             card detection, DCIM folders, Sony date decoding
  importer.sh           collecting/sizing/copying files
  culler.sh             finding orphaned JPEGs
  theme.sh              color palette
  dashboard*.sh         the SD Card / Library widgets
ui/
  tui.sh                the gum interface (default)
  cli.sh                plain-terminal fallback
```

Each file opens with a plain-English header explaining its job, and each
function has a short comment above it — a good way to get oriented.

## Contributing

Issues and pull requests are welcome — especially:

- Date decoding for non-Sony DCIM folder schemes
- Reading the capture date from EXIF when the folder name has none
- Linux support

Please keep it Bash 3.2-compatible (no `declare -A`, no `${var^^}`, no
`${arr[-1]}`) and check changes with `bash -n` before opening a PR.

## Uninstall

Delete the `~/bin/photo-import` symlink, drag **Photo Import.app** to the
Trash, and remove `~/.config/photo-import/` if you want the config gone. Your
photo libraries are never touched.

## License

[MIT](LICENSE) © 2026 Jared Rodriguez-Perez
