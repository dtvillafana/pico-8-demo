# Agent development guide

## Hot-reload workflow

- Launch from the repository root with `nix run .#hot-reload`, or use
  `pico8-hot-reload` inside `nix develop`. Keep the game running while editing.
- This requires the supported licensed Linux x86-64 PICO-8 0.2.7 runtime:
  executable `pico8_dyn` and companion `pico8.dat` in the repository root, or
  an installation selected by `PICO8_RUNTIME_DIR=/absolute/path/to/pico-8`.
  See `README.md` for the required executable SHA-256. Do not bypass the check.
- Confirm the terminal reports `[hot-reload] Native Lua bridge enabled; token
  limit disabled` before relying on hot reload or the token-limit bypass.
- Edit and save `carts/game.lua` for live game-logic changes. The reload poller
  automatically compiles and swaps this module after its contents stabilize;
  no debugger, manual reload, or cartridge restart is needed.
- Keep the module ASCII and return a `game` table with `update(state)` and
  `draw(state)` functions. Keep persistent mutable data in `state`, not module
  locals: reload replaces the game table in the existing Lua VM, preserves
  `state`, and does not rerun `_init` or `game.reset`.
- Initialize newly added state fields lazily or tolerate their absence so a
  running game can adopt changes without resetting. Use Ctrl+R when you need
  a fresh initialization or change `carts/main.p8` / `carts/dev_reload.lua`;
  only `carts/game.lua` is hot-reloaded.
- Check the running game and terminal after edits. Syntax errors, module
  initialization errors, or an invalid returned table leave the previous game
  functions installed. Errors during a new `update` or `draw` are not
  automatically rolled back; fix and save the module again.

## Token limits

**Hot-reload mode has no 8192-token execution limit.** Do not shorten or
contort game code just to satisfy that limit when targeting this launcher.
The bypass applies both to initial launch and Ctrl+R, not only live swaps.

The editor still displays its token count, and character, memory, and
cartridge-format limits still apply. Ordinary PICO-8 launches are unmodified;
cartridges intended for an unmodified runtime must satisfy the normal token
limit. See `docs/hot-reload.md` for implementation details and limitations.

## Repository care

- Never commit or redistribute the licensed PICO-8 runtime files.
- Follow existing code style and keep changes focused. Use PICO-8 for
  cartridge assets and external edits for Lua game logic.
- For infrastructure changes, use the relevant formatting/check commands in
  `README.md`. For game changes, validate behavior in the running game; do not
  claim live testing if no runtime was launched.
- Don't make tests.
