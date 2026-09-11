.PHONY: build test check clean

build:
	idris2 --build iris.ipkg

test: build
	idris2 --install iris.ipkg
	cd tests && idris2 -p iris EventWireTest.idr -o event-wire-tests
	cd tests && idris2 -p iris RuntimeTest.idr -o runtime-tests
	cd tests && idris2 -p iris CanvasLayoutTest.idr -o canvas-layout-tests
	cd tests && idris2 -p iris RouterTest.idr -o router-tests
	./tests/build/exec/event-wire-tests
	./tests/build/exec/runtime-tests
	./tests/build/exec/canvas-layout-tests
	./tests/build/exec/router-tests

check: test
	$(MAKE) -C examples/todo check

clean:
	rm -rf build tests/build
	$(MAKE) -C examples/todo clean
