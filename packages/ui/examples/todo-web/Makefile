.PHONY: build install-flux-ui install-todo run clean

FLUX_UI_ROOT  := ../..
TODO_DIR   := ../todo
OUT_JS     := build/exec/flux-ui-todo-web

# ─── Default ───────────────────────────────────────────────────────────────
build: install-todo
	idris2 --cg javascript --build flux-ui-todo-web.ipkg

# ─── Dependency chain ──────────────────────────────────────────────────────
install-flux-ui:
	cd $(FLUX_UI_ROOT) && idris2 --install flux-ui.ipkg

install-todo: install-flux-ui
	cd $(TODO_DIR) && idris2 --install flux-ui-todo.ipkg

# ─── Open in browser ───────────────────────────────────────────────────────
run: build
	@echo "Opening index.html in the default browser…"
	open index.html 2>/dev/null || xdg-open index.html 2>/dev/null || \
	  echo "Open file://$(realpath index.html) in your browser."

# ─── Cleanup ───────────────────────────────────────────────────────────────
clean:
	rm -rf build
