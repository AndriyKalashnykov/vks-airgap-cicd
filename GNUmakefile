# GNUmakefile — read by GNU make BEFORE Makefile, so a plain `make` works on macOS.
#
# macOS ships GNU Make 3.81 as /usr/bin/make. The Makefile needs >= 3.82 (.SHELLFLAGS, so recipes
# run under -eu -o pipefail) and refuses 3.81. This file is the only thing 3.81 has to parse, so it
# must stay 3.81-safe: on an old make it hands every goal to Homebrew's `gmake` (installing it with
# brew if it is missing); on a new make (Linux, CI, gmake itself) it just includes the Makefile.
# Test the FEATURE, not the version string — `oneshell` arrived together with .SHELLFLAGS in 3.82.
ifeq ($(filter oneshell,$(.FEATURES)),)

GMAKE := $(firstword $(shell command -v gmake 2>/dev/null) $(wildcard /opt/homebrew/bin/gmake /usr/local/bin/gmake))
BREW  := $(firstword $(shell command -v brew 2>/dev/null) $(wildcard /opt/homebrew/bin/brew /usr/local/bin/brew))

# A `gmake` that is itself old (some distros symlink gmake -> make 3.81) would re-read this file and
# delegate to itself forever. The marker below turns that into one clear error instead.
ifneq ($(VKS_GMAKE_DELEGATED),)
GMAKE_TOO_OLD := 1
endif
export VKS_GMAKE_DELEGATED := 1

.PHONY: _delegate
_delegate:
ifneq ($(GMAKE_TOO_OLD),)
	@echo "GNU make >= 3.82 is required, but the gmake found ($(GMAKE)) is also $(MAKE_VERSION). Install a newer GNU make." >&2; exit 1
else ifeq ($(GMAKE),)
ifeq ($(BREW),)
	@echo "GNU make >= 3.82 is required; this is $(MAKE_VERSION). Install GNU make (on macOS: Homebrew, then 'brew install make')." >&2; exit 1
else
	@echo "GNU make >= 3.82 is required and this is $(MAKE_VERSION): installing Homebrew's GNU make (gmake) first." >&2
	@HOMEBREW_NO_AUTO_UPDATE=1 "$(BREW)" install make >&2
	+@"$$("$(BREW)" --prefix)/bin/gmake" --no-print-directory $(MAKECMDGOALS)
endif
else
	+@"$(GMAKE)" --no-print-directory $(MAKECMDGOALS)
endif

# Never try to (re)make the makefiles themselves through the catch-all below.
GNUmakefile Makefile: ;

# Every goal (`make deps`, `make ci X=1`) runs ONCE, via _delegate. Command-line variables and
# flags reach gmake through MAKEFLAGS; the `+` makes -n/-j/-t/-q apply to it as a recursive make.
%: _delegate ; @:

else
# The marker is only for the 3.81 -> old-gmake hop. Do not hand it to recipes: a script that runs a
# plain `make` (resolving to Apple's 3.81) must be able to delegate again.
unexport VKS_GMAKE_DELEGATED
include Makefile
endif
