.PHONY: build test app install run screenshots icon clean

build:        ## Debug build
	swift build

test:         ## Run the test suite
	swift test

app:          ## Build build/ClaudeBar.app
	./scripts/build-app.sh

install:      ## Build, copy to ~/Applications and launch
	./scripts/build-app.sh --install

run: build    ## Run from the terminal (logs to stdout)
	"$$(swift build --show-bin-path)/ClaudeBar"

screenshots:  ## Regenerate README screenshots from demo data
	swift build -c release
	"$$(swift build -c release --show-bin-path)/ClaudeBar" --snapshot docs/screenshot-light.png --demo -AppleLocale en_US -AppleLanguages "(en)"
	"$$(swift build -c release --show-bin-path)/ClaudeBar" --snapshot docs/screenshot-dark.png --demo --dark -AppleLocale en_US -AppleLanguages "(en)"

icon:         ## Regenerate Resources/AppIcon.icns
	swift scripts/make-icon.swift

clean:
	rm -rf .build build
