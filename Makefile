.PHONY: generate build test run clean

generate:
	xcodegen generate

build: generate
	xcodebuild -project RiepilogoIliad.xcodeproj -scheme RiepilogoIliad \
		-configuration Debug -derivedDataPath build build

test: generate
	xcodebuild -project RiepilogoIliad.xcodeproj -scheme RiepilogoIliad \
		-configuration Debug -derivedDataPath build test

run: build
	open build/Build/Products/Debug/RiepilogoIliad.app

clean:
	rm -rf build RiepilogoIliad.xcodeproj
