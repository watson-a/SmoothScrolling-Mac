PREFIX ?= $(HOME)/.local
BIN     = .build/smoothscroll

$(BIN): Sources/main.swift
	@mkdir -p .build
	swiftc -O -swift-version 5 -target x86_64-apple-macos11 $< -o $@
	codesign --force --sign - --identifier local.smoothscroll $@

install: $(BIN)
	install -d $(PREFIX)/bin
	install -m 755 $(BIN) $(PREFIX)/bin/smoothscroll

clean:
	rm -rf .build

.PHONY: install clean
