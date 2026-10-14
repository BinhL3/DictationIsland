.PHONY: app install dmg run demo clean

app:      ## Build build/DictationIsland.app
	scripts/bundle.sh release

install:  ## Build and install to /Applications, then launch
	scripts/install.sh

dmg:      ## Build build/DictationIsland-<version>.dmg
	scripts/dmg.sh

run: app  ## Build and run from build/
	open build/DictationIsland.app

demo: app ## Run the UI demo loop (no mic needed)
	open build/DictationIsland.app --args --demo

clean:
	rm -rf .build build
