"""GDB-hosted, development-only hot reload for the inspected PICO-8 binary."""

from __future__ import annotations

import hashlib
import os
import time
from pathlib import Path

import gdb

SUPPORTED_SHA256 = "ca4e55eda8933a83315d9012de268c4d7dc3d204ba65d19905dccdb882b7a416"
POLL_SECONDS = 0.2
COMPILING_OFFSET = 0x36730
CART_RUNNING_OFFSET = 0x255EC
CPU_SYMBOLS = (
    "cpu_cycles_slice",
    "cpu_cycles_frame",
    "cpu_cycles_slice_max",
    "cpu_superyield",
)


def pointer(symbol: str) -> int:
    return int(gdb.parse_and_eval(f"*(void **)&{symbol}"))


def state_int(offset: int) -> int:
    return int(gdb.parse_and_eval(f"*(int *)((char *)&pstate + {offset})"))


def call(name: str, result: str, arguments: str, values: str) -> gdb.Value:
    return gdb.parse_and_eval(f"(({result} (*)({arguments})){name})({values})")


def message(text: str) -> None:
    gdb.write(f"[hot-reload] {text}\n")


def replace_game(source: bytes) -> None:
    """Use a fresh, rooted coroutine; never touch the suspended cart's stack."""
    command_state = pointer("L0_command")
    top = int(call("lua_gettop", "int", "void *", str(command_state)))
    compiling = state_int(COMPILING_OFFSET)
    cpu_state = {
        symbol: int(gdb.parse_and_eval(f"*(int *)&{symbol}")) for symbol in CPU_SYMBOLS
    }
    allocation = 0
    try:
        for symbol in CPU_SYMBOLS:
            value = 0x800000 if symbol == "cpu_cycles_slice_max" else 0
            gdb.execute(f"set {{int}}&{symbol} = {value}")
        thread = int(call("lua_newthread", "void *", "void *", str(command_state)))
        payload = source + b"\0@hot/game.lua\0t\0game\0update\0draw\0"
        allocation = int(call("malloc", "void *", "unsigned long", str(len(payload))))
        if not allocation:
            raise gdb.GdbError("Could not allocate source buffer")
        gdb.selected_inferior().write_memory(allocation, payload)
        name = allocation + len(source) + 1
        mode = name + len(b"@hot/game.lua\0")
        global_name = mode + 2
        update_name = global_name + 5
        draw_name = update_name + 7

        # run_program sets this flag around compilation (verified PICO-8 0.2.7).
        gdb.execute(f"set {{int}}((char *)&pstate + {COMPILING_OFFSET}) = 1")
        status = int(
            call(
                "luaL_loadbufferx",
                "int",
                "void *, void *, unsigned long, void *, void *",
                f"{thread}, {allocation}, {len(source)}, {name}, {mode}",
            )
        )
        gdb.execute(f"set {{int}}((char *)&pstate + {COMPILING_OFFSET}) = {compiling}")
        if status == 0:
            status = int(
                call(
                    "lua_pcallk",
                    "int",
                    "void *, int, int, int, int, void *",
                    f"{thread}, 0, 1, 0, 0, 0",
                )
            )
        if status != 0:
            error = call(
                "lua_tolstring", "char *", "void *, int, void *", f"{thread}, -1, 0"
            )
            message(
                f"Rejected change: {error.string(errors='replace') if int(error) else 'Lua error'}"
            )
            return

        # LUA_TTABLE = 5, LUA_TFUNCTION = 6 in this embedded Lua 5.2 ABI.
        if int(call("lua_type", "int", "void *, int", f"{thread}, -1")) != 5:
            message("Rejected change: game.lua must return a table")
            return
        for field in (update_name, draw_name):
            call(
                "lua_getfield", "void", "void *, int, void *", f"{thread}, -1, {field}"
            )
            valid = int(call("lua_type", "int", "void *, int", f"{thread}, -1")) == 6
            call("lua_settop", "void", "void *, int", f"{thread}, -2")
            if not valid:
                message(
                    "Rejected change: returned table needs update and draw functions"
                )
                return
        call("lua_setglobal", "void", "void *, void *", f"{thread}, {global_name}")
        message("Replaced game functions; cartridge state preserved")
    finally:
        gdb.execute(f"set {{int}}((char *)&pstate + {COMPILING_OFFSET}) = {compiling}")
        call("lua_settop", "void", "void *, int", f"{command_state}, {top}")
        if allocation:
            call("free", "void", "void *", str(allocation))
        for symbol, value in cpu_state.items():
            gdb.execute(f"set {{int}}&{symbol} = {value}")


class SourceChange(gdb.Breakpoint):
    def __init__(self, source: Path) -> None:
        super().__init__("run_slice")
        self.source = source
        self.digest = hashlib.sha256(source.read_bytes()).digest()
        self.pending_source: bytes | None = None
        self.observed: tuple[int, int] | None = None
        self.last_poll = 0.0
        self.read_error: str | None = None

    def stop(self) -> bool:
        # Do not make inferior calls inside Breakpoint.stop. The breakpoint's
        # command list invokes them after GDB has completed stopping the target.
        now = time.monotonic()
        if now - self.last_poll < POLL_SECONDS:
            return False
        self.last_poll = now
        if (
            not pointer("L0_cart")
            or pointer("L0") != pointer("L0_cart")
            or state_int(CART_RUNNING_OFFSET) != 1
        ):
            return False
        try:
            stat = self.source.stat()
            observed = (stat.st_mtime_ns, stat.st_size)
            if observed != self.observed:
                self.observed = observed
                return False
            source = self.source.read_bytes()
        except OSError as error:
            if str(error) != self.read_error:
                message(f"Cannot read {self.source}: {error}")
                self.read_error = str(error)
            return False
        self.read_error = None
        digest = hashlib.sha256(source).digest()
        if digest == self.digest:
            return False
        self.digest = digest
        if len(source) > 65536:
            message("Rejected change: source exceeds 65536 bytes")
            return False
        if b"\0" in source or not source.isascii():
            message(
                "Rejected change: this prototype requires ASCII Lua without NUL bytes"
            )
            return False
        self.pending_source = source
        return True


class ReloadCommand(gdb.Command):
    def __init__(self, watcher: SourceChange) -> None:
        super().__init__("pico8-reload-pending", gdb.COMMAND_USER)
        self.watcher = watcher

    def invoke(self, argument: str, from_tty: bool) -> None:
        source = self.watcher.pending_source
        self.watcher.pending_source = None
        if source is not None:
            replace_game(source)


def install() -> None:
    executable = gdb.current_progspace().filename
    if executable is None:
        raise gdb.GdbError("Load pico8_dyn before sourcing this script")
    digest = hashlib.sha256(Path(executable).read_bytes()).hexdigest()
    if digest != SUPPORTED_SHA256:
        raise gdb.GdbError(f"Unsupported PICO-8 binary SHA-256: {digest}")
    root = Path(os.environ.get("PICO8_PROJECT_ROOT", os.getcwd()))
    source = Path(os.environ.get("PICO8_HOT_SOURCE", str(root / "carts/game.lua")))
    watcher = SourceChange(source)
    ReloadCommand(watcher)
    gdb.execute("set pagination off")
    gdb.execute("set confirm off")
    gdb.execute("set print thread-events off")
    gdb.execute("set unwind-on-signal on")
    gdb.execute("set direct-call-timeout 3")
    gdb.execute("set unwind-on-timeout on")
    gdb.execute(
        f"commands {watcher.number}\nsilent\npico8-reload-pending\ncontinue\nend"
    )
    message(f"Watching {source}; compiler hook enabled for verified PICO-8 0.2.7")


try:
    install()
except (gdb.error, gdb.GdbError, OSError, ValueError) as error:
    message(f"Cannot enable hot reload: {error}")
    gdb.execute("quit 1")
