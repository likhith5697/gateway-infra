# Lambda authorizer build. Run from this folder: make zip | make test | make clean

# Use python3 if it actually runs (on Windows, "python3" can be a Microsoft Store stub), else python.
PYTHON ?= $(shell python3 -c "print('python3')" 2>/dev/null || echo python)

BUILD_DIR := build
ZIP       := $(BUILD_DIR)/authorizer.zip
SOURCES   := handler.py   # only the runtime code: no tests, no make_token.py

.PHONY: zip test clean

## zip: package the Lambda into build/authorizer.zip (rebuilt only when sources change)
zip: $(ZIP)

$(ZIP): $(SOURCES) package.py
	$(PYTHON) package.py $@ $(SOURCES)
	@$(PYTHON) -c "import hashlib,base64,sys; d=open('$@','rb').read(); print('built $@', len(d), 'bytes, sha256 (base64) =', base64.b64encode(hashlib.sha256(d).digest()).decode())"

## test: run unit tests
test:
	$(PYTHON) -m pytest -q -p no:cacheprovider

## clean: remove build output
clean:
	$(PYTHON) -c "import shutil; shutil.rmtree('$(BUILD_DIR)', ignore_errors=True)"
