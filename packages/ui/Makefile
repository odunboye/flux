.PHONY: build test browser-test check release-check native-check clean

build:
	idris2 --build flux-ui.ipkg

test: build
	idris2 --install flux-ui.ipkg
	cd tests && idris2 -p flux-ui PublicAPITest.idr -o public-api-tests
	cd tests && idris2 -p flux-ui EventWireTest.idr -o event-wire-tests
	cd tests && idris2 -p flux-ui RuntimeTest.idr -o runtime-tests
	cd tests && idris2 -p flux-ui CanvasLayoutTest.idr -o canvas-layout-tests
	cd tests && idris2 -p flux-ui RouterTest.idr -o router-tests
	cd tests && idris2 -p flux-ui DOMRenderTest.idr -o dom-render-tests
	cd tests && idris2 -p flux-ui HttpTest.idr -o http-tests
	./tests/build/exec/public-api-tests
	./tests/build/exec/event-wire-tests
	./tests/build/exec/runtime-tests
	./tests/build/exec/canvas-layout-tests
	./tests/build/exec/router-tests
	./tests/build/exec/dom-render-tests
	./tests/build/exec/http-tests

browser-test:
	npm run test:browser

check: test
	cd tests && idris2 --cg node -p flux-ui PublicAPITest.idr -o public-api-node
	node ./tests/build/exec/public-api-node
	$(MAKE) -C examples/todo check
	./scripts/validate-release.sh

release-check:
	$(MAKE) -C examples/todo check
	./scripts/validate-release.sh

native-check:
	./scripts/validate-native.sh all

clean:
	rm -rf build tests/build
	$(MAKE) -C examples/todo clean
