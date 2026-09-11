||| Iris.Backend.Terminal.FFI
||| Foreign-function bindings to iristui.c.
|||
||| The compiled shared library (libiristui.dylib / libiristui.so) is placed
||| in build/exec/<app>_app/ by the ipkg prebuild script, which is already on
||| DYLD_LIBRARY_PATH / LD_LIBRARY_PATH thanks to the Idris2 wrapper script.
|||
||| macOS: cc -dynamiclib c/iristui.c -o <app_dir>/libiristui.dylib
||| Linux: cc -shared -fPIC c/iristui.c -o <app_dir>/libiristui.so
module Iris.Backend.Terminal.FFI

-- ─── Raw mode ────────────────────────────────────────────────────────────────

%foreign "C:iris_tui_raw_on,libiristui"
prim_rawOn : PrimIO ()

%foreign "C:iris_tui_raw_off,libiristui"
prim_rawOff : PrimIO ()

-- ─── Terminal size ────────────────────────────────────────────────────────────

%foreign "C:iris_tui_cols,libiristui"
prim_cols : PrimIO Int

%foreign "C:iris_tui_rows,libiristui"
prim_rows : PrimIO Int

-- ─── Stdin / stdout ──────────────────────────────────────────────────────────

%foreign "C:iris_tui_read,libiristui"
prim_read : PrimIO String

%foreign "C:iris_tui_write,libiristui"
prim_write : String -> PrimIO ()

-- ─── Sleep ───────────────────────────────────────────────────────────────────

%foreign "C:iris_tui_sleep_ms,libiristui"
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
