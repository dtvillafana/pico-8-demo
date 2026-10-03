# pico-8-demo

A small PICO-8 project with a Nix development shell for x86_64 Linux/NixOS.

## Setup

Extract your licensed Linux PICO-8 download into this directory. The launcher
needs `pico8_dyn` (executable) and `pico8.dat` alongside it. These proprietary
files are ignored by Git and are not copied into the Nix store.

Alternatively, set `PICO8_RUNTIME_DIR` to the absolute path of an existing
PICO-8 installation. Nix builds the public launcher and native bridge without
needing those files; they are checked and loaded only when launching the game.

```sh
chmod +x pico8_dyn
nix develop
pico8 -run "$PICO8_PROJECT_ROOT/carts/main.p8"
```

**Crownfall** is a trebuchet siege game inspired by Crush the Castle. Topple
every red guard across six increasingly fortified castles, earning gold for
destroyed blocks, guards, and unused shots. Between castles, buy heavier stones,
fire ammo, grapeshot, or permanent trebuchet power upgrades.
Grapeshot releases five small balls in a spread. Each deals direct-hit damage,
with no area explosion; one purchase supplies three volleys.
Each fire shot ignites its struck block and randomly two or three touching
blocks (or fewer if not enough are touching);
the flames do not spread further.
Basic stones are unlimited, but each castle has a limited number of launches.
Level 3 grants eight shots. Firing starts a short counterweight-driven swing;
the projectile leaves the sling at its release point after one third of a second.
Stones and heavy balls bounce and roll along the ground until they stop or
strike a target. Heavy balls bounce less; fire ammo ignites on impact.
Heavy ammo needs a high arc: aim around 60 degrees to reach the castle's
left edge on any level. Shallow shots have less launch energy, and heavy
balls lose speed quickly while rolling. The aim guide uses this same trajectory.
Heavy hits break two connected pieces, with a 30% chance of breaking three
(or fewer if not enough connected pieces remain).
Failed sieges can be retried with starting gold and ammunition restored.
Aim freely through all 360 degrees. Angle controls step by one degree and
repeat every 0.05 seconds when held, without an initial repeat delay.
Hitting your own trebuchet destroys it and ends the siege after a two-second
explosion.

Self-hit explosions produce 100 full-screen color changes over two seconds,
cycling through PICO-8's 32 palette colors. The pause menu's **rapid flash**
option can disable the flashing and show colored debris instead.

| Controls | Siege | Workshop |
| --- | --- | --- |
| Up / Down or W / S | Raise / lower launch angle | Select upgrade |
| Left / Right or A / D | Select ammunition | |
| Space | Launch / confirm / retry | Buy |
| Z | Confirm / retry (does not launch) | Buy |
| X | | Next castle |

The fixed stage camera shows the battlefield side-on, with castles anchored
near the right edge and a small margin for falling rubble.

Escape opens the PICO-8 editor. The cartridge is `carts/main.p8`; game logic lives in
`carts/game.lua`, included inside a factory function. Edit Lua externally and
use PICO-8 for cartridge assets. In PICO-8, `load main`, `run`, and `save main`
use the project's `carts/` directory.

From the repository root, you can also run without entering the shell:

```sh
nix run . -- -run "$PWD/carts/main.p8"
```

The launcher defaults to a windowed display and uses an FHS environment to
provide the Linux loader, SDL2, graphics/audio libraries, and `wget` for BBS
downloads. Run the shell from the repository root, or set
`PICO8_PROJECT_ROOT` to its absolute path before entering it.

## Live code reload (experimental)

### Bring your own PICO-8 runtime

You need Nix with flakes enabled on x86_64 Linux and your own licensed
**Linux x86-64 PICO-8 0.2.7** download. Use its dynamic executable
`pico8_dyn`, not the static `pico8` binary. From the repository root:

```sh
# Replace this path with your extracted Linux PICO-8 download.
cp /path/to/pico-8/pico8_dyn /path/to/pico-8/pico8.dat .
chmod +x pico8_dyn
sha256sum pico8_dyn
```

The supported executable's SHA-256 is:

```text
ca4e55eda8933a83315d9012de268c4d7dc3d204ba65d19905dccdb882b7a416
```

The bridge refuses any other hash, even if the version is also 0.2.7. Do not
replace the hash check to force an unsupported build: its internal addresses
and instructions need separate verification.

Launch with **both hot reload and the 8192-token execution-limit bypass**:

```sh
nix run .#hot-reload
```

No manual patching or separate bridge installation is needed: Nix builds the
bridge and the launcher applies the patches in memory. Your binary on disk
stays unchanged. `pico8_dyn` and `pico8.dat` are Git-ignored; never commit or
redistribute them. The runtime is not copied into the Nix store.

To use an existing installation without copying its files, instead run:

```sh
PICO8_RUNTIME_DIR=/absolute/path/to/pico-8 nix run .#hot-reload
```

Or inside the development shell:

```sh
nix develop
pico8-hot-reload
```

On startup, look for `[hot-reload] Native Lua bridge enabled; token limit
disabled` in the terminal. A missing-runtime error means the launcher cannot
find an executable `pico8_dyn` and its companion `pico8.dat`; an unsupported
SHA-256 error means you need the exact build listed above.

### Editing and limits

Edit and save `carts/game.lua` while playing. Its returned `game` table is
replaced in the **existing Lua VM**; the cartridge does not restart and
`_init` is not rerun. Position, score, and other data in `state` survive.
Try changing colors in `game.draw` to see it happen.

This uses a small native bridge plus `carts/dev_reload.lua` for polling,
compilation, and swapping. **No debugger or frame breakpoints are involved.**
The bridge hooks API registration in process memory; the executable on disk
is unchanged. Hot-reload mode also disables the 8192-token execution limit;
character, memory, and cartridge-format limits remain. Ordinary launches are
unmodified (`nix run . -- -run "$PWD/carts/main.p8"`). The bypass applies to
initial launch and Ctrl+R, but does not change the editor's token count.
Cartridges shared with users of an unmodified runtime must still meet the
normal token limit. It only supports the inspected Linux x86-64 PICO-8 0.2.7 binary
(verified by SHA-256) and ASCII source in this single Lua module. Invalid
syntax, module-initialization errors, and invalid returned tables leave
the old game functions installed. Errors inside new update/draw functions
are not automatically rolled back.

Neither the launcher nor the development shell needs a debugger or decompiler.
The shell includes Python, Ruff, and clang-format. Nix builds
the bridge without copying the licensed runtime into the Nix store.
See [the implementation notes](docs/hot-reload.md) for native bindings,
limitations, and the licensing caveat.

## Checks and formatting

```sh
nix flake check
nix build .#native-bridge .#hot-reload --no-link
nix fmt
ruff check tools
ruff format --check tools
clang-format --dry-run --Werror native/bridge.c
```

When adding this scaffold to Git, include `flake.nix`, `flake.lock`, `carts/`,
`native/`, `tools/`, and `docs/` so Git-backed flake commands can see the new files.
Never commit the licensed PICO-8 distribution.
