.PHONY: generate test render build push check clean

APIS := app sqlinstance kvstore inferenceservice epi
PKGS := core aws
VERSION ?= 0.1.0
REGISTRY ?= ghcr.io/smana

generate:
	python3 scripts/generate.py

test:
	@for a in $(APIS); do \
	  echo "==> $$a"; \
	  (cd apis/$$a/kcl && kcl fmt --check . && kcl test . -Y settings-example.yaml) || exit 1; \
	done

render:
	python3 scripts/render_check.py

build: generate
	./scripts/assemble.sh
	@for p in $(PKGS); do \
	  crossplane xpkg build \
	    --package-root=build/$$p \
	    --examples-root=build/$$p/examples \
	    --package-file=build/crossplane-configuration-$$p.xpkg || exit 1; \
	done

push:
	@for p in $(PKGS); do \
	  crossplane xpkg push \
	    -f build/crossplane-configuration-$$p.xpkg \
	    $(REGISTRY)/crossplane-configuration-$$p:$(VERSION) || exit 1; \
	done

check: generate
	@git diff --exit-code -- apis/ \
	  || { echo "ERROR: composition.yaml is stale. Run 'make generate' and commit."; exit 1; }
	$(MAKE) test
	$(MAKE) render

clean:
	rm -rf build/
