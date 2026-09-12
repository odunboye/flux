||| Flux.UI.Backend.Terminal.FFI
||| Foreign-function bindings to fluxuitui.c.
|||
||| The compiled shared library (libfluxuitui.dylib / libfluxuitui.so) is placed
||| in build/exec/<app>_app/ by the ipkg prebuild script, which is already on
||| DYLD_LIBRARY_PATH / LD_LIBRARY_PATH thanks to the Idris2 wrapper script.
|||
||| macOS: cc -dynamiclib c/fluxuitui.c -o <app_dir>/libfluxuitui.dylib
||| Linux: cc -shared -fPIC c/fluxuitui.c -o <app_dir>/libfluxuitui.so
module Flux.UI.Backend.Terminal.FFI

-- ─── Raw mode ────────────────────────────────────────────────────────────────

%foreign "C:flux_ui_tui_raw_on,libfluxuitui"
prim_rawOn : PrimIO ()

%foreign "C:flux_ui_tui_raw_off,libfluxuitui"
prim_rawOff : PrimIO ()

-- ─── Terminal size ────────────────────────────────────────────────────────────

%foreign "C:flux_ui_tui_cols,libfluxuitui"
prim_cols : PrimIO Int

%foreign "C:flux_ui_tui_rows,libfluxuitui"
prim_rows : PrimIO Int

-- ─── Stdin / stdout ──────────────────────────────────────────────────────────

%foreign "C:flux_ui_tui_read,libfluxuitui"
prim_read : PrimIO String

%foreign "C:flux_ui_tui_write,libfluxuitui"
prim_write : String -> PrimIO ()

-- ─── Sleep ───────────────────────────────────────────────────────────────────

%foreign "C:flux_ui_tui_sleep_ms,libfluxuitui"
prim_sleepMs : Int -> PrimIO ()

-- ─── IO wrappers ─────────────────────────────────────────────────────────────

public export
rawModeOn : IO ()
rawModeOn = primIO prim_rawOn

public export
rawModeOff : IO ()
rawModeOff = primIO prim_rawOff

public export
termCols : IO Nat
termCols = map cast (primIO prim_cols)

public export
termRows : IO Nat
termRows = map cast (primIO prim_rows)

||| Non-blocking stdin read. Returns "" when no input is available.
public export
termRead : IO String
termRead = primIO prim_read

public export
termWrite : String -> IO ()
termWrite s = primIO (prim_write s)

public export
sleepMs : Int -> IO ()
sleepMs ms = primIO (prim_sleepMs ms)
