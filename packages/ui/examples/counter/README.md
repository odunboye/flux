# One counter, three runners

`Counter.idr` owns the model, messages, update, view and commands. Only the entry
module changes between terminal, DOM and Canvas. No credentials or database are
needed. Controls use each runner's input behavior; this example does not assert
identical layout or lifecycle guarantees.

From the Flux repository root:

```sh
pack --no-prompt install flux-ui
pack --no-prompt build packages/ui/examples/counter/terminal.ipkg
./packages/ui/examples/counter/build/exec/counter-terminal
pack --no-prompt --cg javascript build packages/ui/examples/counter/web.ipkg
pack --no-prompt --cg javascript build packages/ui/examples/counter/canvas.ipkg
python3 -m http.server 8080 --directory packages/ui/examples/counter
```

Open http://127.0.0.1:8080/index.html for DOM or
http://127.0.0.1:8080/canvas.html for Canvas. Use the Increment button or press `i` to change the count; Quit or `q`
stops the runner. Terminal Ctrl+C also exits.

See [capabilities](../../CAPABILITIES.md) for backend differences and
[the Todo application](../todo/src/TodoApp.idr) for a larger shared application.
