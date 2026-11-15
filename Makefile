NIM ?= nim
BIN := build/motionwallpaper
FLAGS := -d:release --opt:speed --mm:orc --hints:off --path:src

.PHONY: all build run test install clean

all: build

build:
	mkdir -p build
	$(NIM) c $(FLAGS) -o:$(BIN) src/motionwallpaper.nim

run: build
	./$(BIN)

test:
	mkdir -p build
	$(NIM) c -r --hints:off --path:src -o:build/test_core tests/test_core.nim

install: build
	./install.sh

clean:
	rm -rf build
