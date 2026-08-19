.PHONY: generate test schema render build crds push check clean

APIS := app sqlinstance kvstore inferenceservice epi
PKGS := core aws
# v-prefixed to match the git tag, the OCI tag crossplane expects, and the
# `>=v0.1.0` constraints in packages/*/crossplane.yaml. The release workflow
# passes the git tag through verbatim.
VERSION ?= v0.1.0
REGISTRY ?= ghcr.io/smana

generate:
	python3 scripts/generate.py

# `kcl fmt` has no --check flag (0.11.3), so format in place and require the tree
# to be unchanged — the same approach cloud-native-ref's validator uses. A dirty
# diff here means someone committed unformatted KCL.
test:
	@for a in $(APIS); do \
	  echo "==> $$a"; \
	  (cd apis/$$a/kcl && kcl fmt . >/dev/null) || exit 1; \
	  git diff --quiet -- apis/$$a/kcl \
	    || { echo "ERROR: apis/$$a/kcl is not kcl-fmt clean. Commit the reformat."; \
	         git diff --stat -- apis/$$a/kcl; exit 1; }; \
	  (cd apis/$$a/kcl && kcl test . -Y settings-example.yaml) || exit 1; \
	done

schema:
	./scripts/validate-schemas.sh

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

# The release asset consumers pin. cloud-native-ref's gen-catalog.sh reads it via
# XRD_CRDS_FILE, so one version string drives both the installed Configuration
# and the schemas its claims are validated against.
#
# Uses the same converter `make schema` runs, so the published artifact cannot
# diverge from the one CI validated the examples against.
crds:
	@mkdir -p build
	python3 scripts/xrd-to-crd.py apis/*/definition.yaml > build/xrd-crds.yaml
	@echo "wrote build/xrd-crds.yaml ($$(grep -c '^kind: CustomResourceDefinition' build/xrd-crds.yaml) CRDs)"

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
	$(MAKE) schema
	$(MAKE) render

clean:
	rm -rf build/
