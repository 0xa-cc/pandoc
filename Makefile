version=$(shell grep '^Version:' pandoc.cabal | awk '{print $$2;}')
makemanpages=$(shell find dist -type f -name make-pandoc-man-pages)
debpkgver?=1
debpkg=pandoc-${version}-${debpkgver}
ifeq "${makemanpages}" ""
	makemanpages=@echo "You need to 'cabal configure -fmake-pandoc-man-pages && cabal build'" && exit 1
endif
setup=dist/setup/setup
MANPAGES=man/man1/pandoc.1 man/man5/pandoc_markdown.5

quick:
	cabal configure --enable-tests --disable-optimization
	cabal build

full:
	cabal configure --enable-tests --enable-optimization -ftrypandoc -fmake-pandoc-man-pages -fembed_data_files --enable-benchmarks
	cabal build
	cabal haddock

deps:
	cabal install --only-dependencies --enable-tests -ftrypandoc -fmake-pandoc-man-pages -fembed_data_files --enable-benchmarks

prof:
	cabal configure --enable-library-profiling --enable-executable-profiling --enable-optimization --enable-tests
	cabal build

test:
	cabal test

bench:
	cabal bench

install: full
	cabal install

# note: cabal sdist doesn't work well with preprocessors for some cabal versions
sdist: man
	${setup} sdist

dist: sdist
	rm -rf "pandoc-${version}"
	tar xvzf dist/pandoc-${version}.tar.gz
	cd pandoc-${version}
	cabal configure ${CABALARGS} && cabal build && cabal test && cd .. && rm -rf "pandoc-${version}"

man: ${MANPAGES}

osxpkg:
	./make_osx_package.sh

static:
	cabal configure --enable-optimization -fmake-pandoc-man-pages -fstatic --prefix=/usr/local
	cabal build

deb: static ${MANPAGES}
	rm -r ${debpkg}
	cabal copy --destdir=${debpkg}
	rm -r ${debpkg}/usr/local/lib
	for i in ${MANPAGES}; do install -D $$i ${debpkg}/usr/local/share/$$i; gzip ${debpkg}/usr/local/share/$$i; done
	mkdir ${debpkg}/DEBIAN
	perl -pe 's/VERSION/${version}-${debpkgver}/' deb/control.in > ${debpkg}/DEBIAN/control
	dpkg-deb --build ${debpkg}

%.1: %.1.template
	${makemanpages}

%.5: %.5.template
	${makemanpages}

clean:
	cabal clean
	-rm ${MANPAGES}

.PHONY: deps quick full install man clean test bench haddock sdist osxpkg dist prof deb
