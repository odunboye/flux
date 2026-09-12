||| A small library for managing Docker containers from Idris2 - the
||| common dev-workflow need of "make sure this one dependency container
||| (a database, a queue, ...) is running before my app/tests start",
||| not a general Docker API client.
|||
||| Built entirely on `System.Escaped.run`/`System.Escaped.system`
||| (Idris2 `base`, `popen`- and libc-`system()`-backed respectively) -
||| no new dependency beyond `base` itself, no FFI of its own. Every
||| operation here is a one-shot blocking CLI invocation, appropriate
||| since these are meant to run once at startup, not inside an async
||| event loop.
module Docker

import public Data.List1
import Data.String
import System

%default covering

||| One container's desired configuration - just enough to express "run
||| this image, under this name, with these env vars and port
||| mappings", the common shape for a dev-dependency container.
||| Volumes, networks, and other `docker run` flags are deliberately out
||| of scope - see this library's own README for why, and what to do if
||| you need them (shell out yourself; this library doesn't try to be a
||| complete Docker CLI wrapper).
public export
record ContainerSpec where
  constructor MkContainerSpec
  name  : String
  image : String
  env   : List (String, String)
  ports : List (Nat, Nat) -- (hostPort, containerPort)

public export
data ContainerState = NotFound | Stopped | Running

public export
Eq ContainerState where
  NotFound == NotFound = True
  Stopped  == Stopped  = True
  Running  == Running  = True
  _        == _        = False

public export
Show ContainerState where
  show NotFound = "NotFound"
  show Stopped  = "Stopped"
  show Running  = "Running"

envArgs : List (String, String) -> List String
envArgs = concatMap (\(k,v) => ["-e", "\{k}=\{v}"])

portArgs : List (Nat, Nat) -> List String
portArgs = concatMap (\(h,c) => ["-p", "\{show h}:\{show c}"])

||| Is the `docker` CLI installed *and* the daemon reachable? (`docker
||| info` - its multi-line output is captured and discarded via
||| `Escaped.run`, rather than `Escaped.system`, specifically so it
||| doesn't print to the terminal on every call.)
|||
||| The load-bearing check that lets a caller degrade gracefully -
||| skip Docker management entirely - instead of hanging or erroring
||| when Docker just isn't in the picture at all (no CLI installed, or
||| the daemon isn't running). Every other function in this module will
||| still *try* to shell out to `docker` regardless of what this
||| returns - checking first is the caller's job, exactly like
||| `inspect` returning `NotFound` doesn't distinguish "no such
||| container" from "docker itself isn't usable" (see its own doc).
export
available : IO Bool
available = do
  (_, code) <- System.Escaped.run ["docker", "info"]
  pure (code == 0)

||| Current state of a named container. `NotFound` covers both "no
||| container by this name exists" and "docker itself isn't usable
||| right now" - check `available` first if you need to tell those
||| apart.
export
inspect : String -> IO ContainerState
inspect name = do
  (out, code) <- System.Escaped.run ["docker", "inspect", "-f", "{{.State.Running}}", name]
  pure $ if code /= 0 then NotFound
         else if trim out == "true" then Running else Stopped

||| `docker run -d --name <spec.name> -e K=V ... -p H:C ... <spec.image>`.
||| Via `Escaped.system`, not `Escaped.run`: its own one-line output (a
||| container id) is fine to let print directly, matching what running
||| the command by hand would show - and so is any error `docker` itself
||| prints (e.g. "port is already allocated"), which reaches the
||| terminal uncaptured.
export
run : ContainerSpec -> IO (Either Int ())
run spec = do
  code <- System.Escaped.system $
    ["docker", "run", "-d", "--name", spec.name]
    ++ envArgs spec.env
    ++ portArgs spec.ports
    ++ [spec.image]
  pure (if code == 0 then Right () else Left code)

export
start : String -> IO (Either Int ())
start name = do
  code <- System.Escaped.system ["docker", "start", name]
  pure (if code == 0 then Right () else Left code)

export
stop : String -> IO (Either Int ())
stop name = do
  code <- System.Escaped.system ["docker", "stop", name]
  pure (if code == 0 then Right () else Left code)

export
remove : String -> IO (Either Int ())
remove name = do
  code <- System.Escaped.system ["docker", "rm", "-f", name]
  pure (if code == 0 then Right () else Left code)

||| The host port Docker published for a given container port, if the
||| container is running and that mapping exists - `docker port <name>
||| <containerPort>/tcp`, whose stdout looks like `0.0.0.0:5432` (or
||| `Nothing` if there's no such mapping, or the container isn't
||| running). Lets a caller notice "this container is up, but bound to
||| a different port than I expected" - a stale container left over
||| from a previous config, say - rather than a silent, confusing
||| connection timeout later.
export
publishedPort : (name : String) -> (containerPort : Nat) -> IO (Maybe Nat)
publishedPort name containerPort = do
  (out, code) <- System.Escaped.run ["docker", "port", name, "\{show containerPort}/tcp"]
  pure $ if code /= 0 then Nothing
         else parsePositive {a = Nat} (Data.List1.last (Data.String.split (== ':') (trim out)))

||| Creates a container matching `spec` if none by that name exists,
||| starts it if it exists but is stopped, does nothing if it's already
||| running. Idempotent - safe to call on every startup.
export
ensureRunning : ContainerSpec -> IO (Either Int ())
ensureRunning spec = case !(inspect spec.name) of
  Running  => pure (Right ())
  Stopped  => start spec.name
  NotFound => run spec
