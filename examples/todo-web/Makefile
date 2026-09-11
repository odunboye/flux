.PHONY: build install-iris install-todo run clean

IRIS_ROOT  := ../..
TODO_DIR   := ../todo
OUT_JS     := build/exec/iris-todo-web

# ─── Default ───────────────────────────────────────────────────────────────
build: install-todo
	idris2 --cg javascript --build iris-todo-web.ipkg

# ─── Dependency chain ──────────────────────────────────────────────────────
install-iris:
	cd $(IRIS_ROOT) && idris2 --install iris.ipkg

install-todo: install-iris
	cd $(TODO_DIR) && idris2 --install iris-todo.ipkg

# ─── Open in browser ───────────────────────────────────────────────────────
run: build
	@echo "Opening index.html in the default browser…"
	open index.html 2>/dev/null || xdg-open index.html 2>/dev/null || \
	  echo "Open file://$(realpath index.html) in your browser."

# ─── Cleanup ───────────────────────────────────────────────────────────────
clean:
	rm -rf build
