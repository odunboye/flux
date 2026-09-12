# ─── Iris Todo — multi-platform Makefile ───────────────────────────────────
#
#  make terminal     build + run in the terminal  (Chez Scheme backend)
#  make web          build + open in browser      (Idris2 JS backend)
#  make desktop      (future) SDL2 / OpenGL
#  make mobile       (future) iOS / Android via cross-compile
#
#  make build-terminal   build only
#  make build-web        build only
#  make install-iris     install the iris library
# ───────────────────────────────────────────────────────────────────────────

IRIS_ROOT := ../..

.PHONY: all terminal web desktop mobile check \
        build-terminal build-web \
        install-iris clean help

# ─── Default ───────────────────────────────────────────────────────────────
all: help

# ─── Web/mobile acceptance check ───────────────────────────────────────────
# Builds every currently supported browser target and verifies that the
# Capacitor web asset was produced. This is intentionally non-interactive so
# it can run in CI or before a native platform sync.
check: build-web build-mobile
	@test -s mobile/www/app.js
	@echo "  Iris web + hybrid-mobile checks passed"

# ─── Install iris library ──────────────────────────────────────────────────
install-iris:
	cd $(IRIS_ROOT) && idris2 --install iris.ipkg

# ─── Terminal (Chez Scheme) ────────────────────────────────────────────────
build-terminal: install-iris
	idris2 --build iris-todo.ipkg

terminal: build-terminal
	@echo ""
	@echo "  ▶ Running iris-todo in the terminal …"
	@echo "  (q to quit)"
	@echo ""
	./build/exec/iris-todo

# ─── Web / DOM (JavaScript backend) ───────────────────────────────────────
build-web: install-iris
	idris2 --cg javascript --build iris-todo-web.ipkg

web: build-web
	@echo ""
	@echo "  ▶ Opening iris-todo-web in the browser …"
	@echo "  (edit index.html to customise the page shell)"
	@echo ""
	open index.html 2>/dev/null || xdg-open index.html 2>/dev/null || \
	  echo "  Open file://$(realpath index.html) in your browser."

# ─── Canvas — compile Idris2 JS and copy into mobile/app.js —————————————
build-canvas: install-iris
	idris2 --cg javascript --build iris-todo-mobile.ipkg
	cp build/exec/iris-todo-mobile mobile/www/app.js
	@echo "  Wrote mobile/www/app.js  (open mobile/www/index.html in any browser)"

build-mobile: build-canvas

# ─── Mobile preview — open canvas app in browser (no Xcode needed) ——————
mobile-preview: build-canvas
	open mobile/www/index.html 2>/dev/null || xdg-open mobile/www/index.html || \
	  echo "Open file://$(realpath mobile/www/index.html) in your browser"

# ─── Mobile — native iOS build via Capacitor ——————————————————————
mobile-ios: build-canvas
	cd mobile && npm install
	@if [ ! -d ios ]; then \
	  echo "  First time: running npx cap add ios ..."; \
	  npx cap add ios; \
	fi
	cd mobile && npx cap sync ios
	cd mobile && npx cap open ios

# ─── Mobile — native Android build via Capacitor ———————————————————
mobile-android: build-canvas
	cd mobile && npm install
	@if [ ! -d android ]; then \
	  echo "  First time: running npx cap add android ..."; \
	  npx cap add android; \
	fi
	cd mobile && npx cap sync android
	cd mobile && npx cap open android

# Aliases
mobile: mobile-preview
	@echo ""
	@echo "  To ship as a native app:"
	@echo "    make mobile-ios       (Mac + Xcode required)"
	@echo "    make mobile-android   (Android Studio required)"

canvas: mobile-preview

# ─── Desktop (SDL2 / OpenGL — future) ─────────────────────────────────────
desktop:
	@echo "Desktop backend: --cg chez + SDL2 renderer (coming next)."
	@echo "Entry point: src/MainDesktop.idr  →  main = runDesktop todoApp"

# ─── Install the todo library (for iris-todo-web to import) ───────────────
install-todo: install-iris
	idris2 --install iris-todo.ipkg

# ─── Clean ─────────────────────────────────────────────────────────────────
clean:
	rm -rf build

# ─── Help ──────────────────────────────────────────────────────────────────
help:
	@echo ""
	@echo "  Iris Todo — write once, run anywhere"
	@echo ""
	@echo "  make terminal   Build + run in the terminal"
	@echo "  make web        Build + open in browser"
	@echo "  make desktop    (future) SDL2 desktop window"
	@echo "  make mobile     (future) iOS / Android"
	@echo ""
	@echo "  Source files:"
	@echo "    src/Todo/       Pure business logic  (shared by ALL targets)"
	@echo "    src/TodoApp.idr Shared app definition (shared by ALL targets)"
	@echo "    src/Main.idr         → runTUI todoApp   (terminal)"
	@echo "    src/MainWeb.idr      → runWeb todoApp   (browser)"
	@echo "    src/MainDesktop.idr  → runDesktop todoApp (future)"
	@echo "    src/MainMobile.idr   → runMobile todoApp  (future)"
	@echo ""
