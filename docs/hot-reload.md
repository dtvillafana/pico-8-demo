# Experimental PICO-8 live reload

## Supported runtime

Linux x86-64 `pico8_dyn`, version string `pico-8 0.2.7`, SHA-256:

```text
ca4e55eda8933a83315d9012de268c4d7dc3d204ba65d19905dccdb882b7a416
```

The executable is not stripped, is not PIE, and embeds its modified Lua
implementation. Its dynamic dependencies do not include a Lua library.
The hook refuses other binary hashes, even if the advertised version matches.
No executable is modified on disk. The opt-in native library installs a
registration detour in process memory before PICO-8 starts. No GDB process,
breakpoints, stepping, or frame-loop detours are needed.

## Running through Nix

```sh
nix run .#hot-reload
```

With arguments, pass the cartridge explicitly:

```sh
nix run .#hot-reload -- -run "$PWD/carts/main.p8" -software_blit 1
```

Inside `nix develop`, `pico8-hot-reload` launches the demo; ordinary `pico8`
does not enable the bridge unless `PICO8_HOT_RELOAD=1` is set. The native
library is available as `nix build .#native-bridge`. Licensed runtime files
stay outside the Nix store.

Drop the licensed Linux distribution's `pico8_dyn` and `pico8.dat` into the
repository root and make `pico8_dyn` executable, or set `PICO8_RUNTIME_DIR`
to an installation directory. These files are Git-ignored, are not flake
inputs, and are not required at build/evaluation time. The native library's
source is restricted to `native/`; the launcher resolves runtime paths only
when executed. The inspected dynamic build is required: the static `pico8`
executable has not been verified against the bridge's addresses.

## Verified binary bindings

| Symbol / location | Role |
| --- | --- |
| `run_program` (`0x441c50`) | Compiles cart or console code using the embedded compiler |
| `run_program + 0xac7` (`0x442717`) | Conditional branch rejecting cartridges above 8192 tokens |
| `luaL_loadbufferx` (`0x420220`) | Compiles a buffer and attaches the shared global environment |
| `add_c_functions` (`0x46ad10`) | Registers native APIs whenever a new Lua VM is initialized |
| `luaB_pcall` (`0x4359b0`) | Lua-callable protected execution, including the embedded runtime's continuation handling |
| `lua_pcallk` (`0x4354a0`) | Executes a chunk with protected error handling |
| `run_slice` (`0x443a30`) | Runs outside Lua before resuming the cartridge/command coroutine |
| `L0_cart` (`0x79a378`) | Cartridge coroutine / VM root |
| `L0_command` (`0x79a370`) | Separate command coroutine sharing the VM globals |
| `pstate + 0x255ec` | Cart-running flag; distinguishes gameplay from console execution |
| `pstate + 0x36730` | Flag that `run_program` sets around compilation |

`run_cart` has a close-and-recreate path. Hot reload never calls it,
`run_program`, `_init`, or `lua_reset_call_state_pico8`.

In hot-reload mode, the bridge replaces the six-byte rejection branch at
`0x442717` with NOPs after verifying its original bytes and the binary hash.
`count_tokens()` still returns the real count: memory accounting and editor
statistics are not falsified. This disables the token execution cap on initial
launch and Ctrl+R as well as allowing reloads through the compiler API. Editor
displays may still indicate the official 8192-token threshold. Ordinary launches
retain the original limit; no executable bytes on disk are changed.

The hook uses Lua 5.2 C API signatures checked against disassembly and runtime
experiments, not inferred types alone.

## Reload mechanism

1. The FHS launcher preloads `native/bridge.c`'s compiled library only in
   hot-reload mode. The constructor verifies the executable's full SHA-256
   before using internal addresses or changing process memory.
2. A hash/prologue-guarded detour wraps `add_c_functions`. Its trampoline
   preserves five complete position-independent instructions. It calls the
   original registration function, then registers three development APIs.
   This also works when PICO-8 later recreates its VM.
3. `carts/dev_reload.lua` polls every 12 updates (200 ms at 60 updates/sec).
   It requires the same content hash on two polls, ignores unchanged content,
   and handles ordinary saves and atomic file replacement.
4. Lua requests compilation through the native compiler callback, then runs
   the resulting chunk through the embedded protected-call implementation.
   All of this executes on the interpreter's own thread, as ordinary Lua-to-C
   calls; there is no second interpreter or background VM mutation.
5. Only after successful execution and validation does Lua assign
   `game=replacement`. The current update and subsequent draw use the new
   functions. Persistent `state` is not reinitialized.

### Development APIs

```lua
source,revision,read_error=dev_read_changed("game.lua",previous_revision)
chunk,compile_error=dev_compile(source)
ok,result=dev_pcall(chunk)
```

The reader permits only the virtual name `game.lua`, mapped to the single
configured absolute file. Revisions are SHA-256 strings, not numeric timestamps.
An unchanged file returns `nil,revision`; read errors return `nil,nil,error`.
It rejects final-component symlinks, nonregular files, unstable reads, oversized
source, and non-ASCII/NUL bytes. Native file descriptors and hashing resources
are released before Lua allocation routines can raise errors.

The compiler uses PICO-8's existing `luaL_loadbufferx` and temporarily sets
and restores its compilation flag. It returns a compiled chunk or `nil,error`.
`dev_pcall` exposes the existing protected-call implementation. No system Lua
library is linked, and no numeric Lua values cross the bridge's C API boundary.
The runtime's normal execution and CPU budgeting remain in place.

The cartridge includes the same module inside `build_game()` for ordinary
launches and exports. The reload manager is inert without the bridge. The module
returns functions and does not initialize mutable game state. `_init` owns
`state`; module reloads do not call its reset function.

## Limits and safety

- This is a binary-specific development bridge, not an official runtime
  feature. File reads, hashing, and compilation can affect frame timing.
  The native registration hook briefly requires a writable executable page
  during startup; systems enforcing stricter memory protections may reject it.
- Only `game.lua` is watched, not cartridge assets or the wrapper callbacks.
  Set `PICO8_HOT_SOURCE` to another absolute module path if needed. The Lua
  reader still uses the virtual name `game.lua`; it cannot choose other files.
  `PICO8_CART_ROOT` optionally overrides the launcher's virtual cartridge drive.
- ASCII-only source, at most 65536 bytes; no nested `#include` preprocessing.
  The bridge disables the loader's token execution cap but does not disable
  character, compiler, memory, CPU, or compressed cartridge-format limits.
  Exported cartridges intended for an unmodified runtime still need to satisfy
  all normal PICO-8 limits, including the token limit.
- The manager swaps before `game.update(state)` in this cart. Cached function
  references, other suspended coroutines, and old module upvalues are not
  migrated. Keep calls late-bound through the global `game` table.
- New state fields need explicit migration/defaults. Keep persistent state
  out of reloadable module-local variables.
- Module top-level code is **not sandboxed**: global/state mutations made
  before an initialization error cannot be undone. Keep module construction
  free of side effects. Update/draw runtime errors are not rolled back.
- Protected calls are not a sandbox or an execution timeout. Infinite loops,
  excessive allocations, or yielding module constructors can still disrupt
  gameplay. Use trusted, side-effect-free module constructors and avoid running
  untrusted BBS carts with development APIs enabled.
- Fixing an error that already stopped gameplay, or changing `main.p8`, may
  require Ctrl+R. Valid module edits during play do not restart anything.
- The bundled license restricts derivative works and redistribution. Review
  permission/applicable legal exceptions before extending or distributing
  runtime modifications; do not distribute proprietary binaries or analysis
  databases.

The earlier debugger prototype remains in `tools/hot_reload.py` as research
material; it is not used by either launcher. A different binary version needs
fresh ABI/prologue verification, not merely a replacement hash.
