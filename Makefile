PWD := $(shell pwd)

ifndef NOFIND
	DART_FILES := $(shell find example lib test -name "*.dart" -not -path "lib/gen/*")
	V23_GO_FILES := $(shell find $(JIRI_ROOT) -name "*.go")
endif

include ../shared/mojo.mk

# Flags for Syncbase service running as Mojo service.
V23_MOJO_FLAGS := --v=0

MOJOM_FILE := mojom/syncbase.mojom

ifdef ANDROID
	SYNCBASE_BUILD_DIR := $(PWD)/gen/mojo/android

	# NOTE(nlacasse): Trying to write to a directory that the app does not have
	# permission to causes a crash with no stack trace.  Because of this, we
	# set logtostderr=true to prevent vlog from writing logs to directories we
	# don't have permissions on.  (Alternatively, we could set --log_dir to a
	# directory inside APP_HOME_DIR.)  We set syncbase root-dir inside
	# APP_HOME_DIR for the same reason.
	APP_HOME_DIR = /data/data/org.chromium.mojo.shell/app_home
	SYNCBASE_ROOT_DIR=$(APP_HOME_DIR)/syncbase_data
	ANDROID_CREDS_DIR := /sdcard/v23creds
	V23_MOJO_FLAGS += --logtostderr=true --root-dir=$(SYNCBASE_ROOT_DIR) --v23.credentials=$(ANDROID_CREDS_DIR)

	# For some reason we need to set the origin flag when running on Android,
	# but setting it on Linux causes errors.
	ORIGIN_FLAG := --origin $(MOJO_SERVICES)
else
	SYNCBASE_BUILD_DIR := $(PWD)/gen/mojo/linux_amd64
	SYNCBASE_ROOT_DIR := $(PWD)/tmp/syncbase_data
	V23_MOJO_FLAGS += --root-dir=$(SYNCBASE_ROOT_DIR) --v23.credentials=$(PWD)/creds
endif

# NOTE(nlacasse): Running Go Mojo services requires passing the
# --enable-multiprocess flag to mojo_shell.  This is because the Go runtime is
# very large, and can interfere with C++ memory if they are in the same
# process.
MOJO_SHELL_FLAGS := $(MOJO_SHELL_FLAGS) \
	--enable-multiprocess \
	--config-alias SYNCBASE_DIR=$(PWD) \
	--config-alias SYNCBASE_BUILD_DIR=$(SYNCBASE_BUILD_DIR) \
	"--args-for=https://mojo.v.io/syncbase_server.mojo $(V23_MOJO_FLAGS)" \
	"--args-for=mojo:dart_content_handler --enable-strict-mode" \
	$(ORIGIN_FLAG)

.DELETE_ON_ERROR:

all: test

.PHONY: build
build: $(SYNCBASE_BUILD_DIR)/syncbase_server.mojo gen-mojom

# Builds mounttabled, principal, and syncbased.
bin: $(V23_GO_FILES) | mojo-env-check
	jiri go build -a -o $@/mounttabled v.io/x/ref/services/mounttable/mounttabled
	jiri go build -a -o $@/principal v.io/x/ref/cmd/principal
	jiri go build -a -o $@/syncbased v.io/x/ref/services/syncbase/syncbased
	touch $@

# Mints credentials.
creds: | bin
	./bin/principal seekblessings --v23.credentials creds
	touch $@

# TODO(nlacasse): These target-specific variables will affect this task and all
# pre-requisite tasks.  Luckily none of the prerequisites require that these
# variables have their original value, so everything works.  Once we have a
# prereq that requires the original value, we will need to re-work these
# variables.
$(SYNCBASE_BUILD_DIR)/syncbase_server.mojo: $(V23_GO_FILES) gen/go/src/mojom/syncbase/syncbase.mojom.go | mojo-env-check
	$(call MOGO_BUILD,v.io/x/ref/services/syncbase/syncbased,$@)

# Formats dart files to follow dart style conventions.
.PHONY: dartfmt
dartfmt: packages
	dartfmt --overwrite $(DART_FILES)

# Lints src and test files with dartanalyzer. This takes a few seconds.
.PHONY: dartanalyzer
dartanalyzer: packages gen-mojom
# TODO(nlacasse): Fix dart mojom binding generator so it does not produce files
# that violate dartanalyzer. For now, we use "grep -v" to hide all hints and
# warnings from *.mojom.dart files.
	dartanalyzer example/*.dart lib/*.dart test/**/*.dart | grep -v "\.mojom\.dart, line"

# Installs dart dependencies.
.PHONY: packages
packages:
	pub upgrade

.PHONY: gen-mojom
gen-mojom: lib/gen/dart-gen/mojom/lib/mojo/syncbase.mojom.dart gen/go/src/mojom/syncbase/syncbase.mojom.go

# TODO(aghassemi): The mojom compiler is in flux, and updates to it are
# typically not backwards-compatible, so for now we mark this rule as .PHONY in
# order to force recompilation of mojom files with every build. Once the mojom
# compiler stabilizes, we can remove the .PHONY label and avoid recompiling our
# mojom files unnecessarily.
.PHONY: gen/go/src/mojom/syncbase/syncbase.mojom.go
gen/go/src/mojom/syncbase/syncbase.mojom.go: | mojo-env-check
	$(call MOJOM_GEN,$(MOJOM_FILE),.,gen,go)
	gofmt -w $@

.PHONY: lib/gen/dart-gen/mojom/lib/mojo/syncbase.mojom.dart
lib/gen/dart-gen/mojom/lib/mojo/syncbase.mojom.dart: | mojo-env-check
	$(call MOJOM_GEN,$(MOJOM_FILE),.,lib/gen,dart)
# TODO(nlacasse): mojom_bindings_generator creates bad symlinks on dart files,
# so we delete them. Stop doing this once the generator is fixed. See
# https://github.com/domokit/mojo/issues/386
	rm -f lib/gen/mojom/$(notdir $@)

# TODO(sadovsky): Wipe any existing Syncbase data, as done in test-integration.
.PHONY: run-syncbase-example
run-syncbase-example: $(SYNCBASE_BUILD_DIR)/syncbase_server.mojo packages lib/gen/dart-gen/mojom/lib/mojo/syncbase.mojom.dart | mojo-env-check creds
ifdef ANDROID
	adb push -p $(PWD)/creds $(ANDROID_CREDS_DIR)
endif
	$(call MOJO_RUN,"https://mojo.v.io/syncbase_example.dart")

# Note: If "make test" fails with "Connection error to the shell" messages, it
# could be that the Dart VM has crashed (e.g. due to a missing import). In this
# case, "make dartanalyzer" often reveals the problem.
.PHONY: test
test: test-unit test-integration

.PHONY: test-unit
test-unit: packages
	pub run test test/unit/*.dart

.PHONY: test-integration
test-integration: packages $(SYNCBASE_BUILD_DIR)/syncbase_server.mojo gen-mojom | mojo-env-check
ifdef MOUNTTABLE_ADDR
	$(error please unset MOUNTTABLE_ADDR before running the tests)
endif
# Delete the 'creds' dir to make sure we are running with in-memory credentials.
# Otherwise tests time out.
# TODO(nlacasse): Figure out why tests time out with dev.v.io credentials. Maybe
# caveat validation?
	rm -rf $(PWD)/creds
# Make sure Syncbase starts from a clean slate.
ifdef ANDROID
	adb shell run-as org.chromium.mojo.shell rm -rf $(SYNCBASE_ROOT_DIR)
else
	rm -rf $(SYNCBASE_ROOT_DIR)
endif
# NOTE(nlacasse): The "tests" argument must come before the "MOJO_SHELL_FLAGS"
# flags, otherwise mojo_test's argument parser gets confused and exits with an
# error.
	$(MOJO_DEVTOOLS)/mojo_test tests --config-file $(PWD)/mojoconfig --shell-path $(MOJO_SHELL) $(MOJO_ANDROID_FLAGS) $(MOJO_SHELL_FLAGS)

.PHONY: publish
# NOTE(aghassemi): This must be inside lib in order to be accessible.
PACKAGE_MOJO_BIN_DIR := lib/mojo_services
ifdef DRYRUN
	PUBLISH_FLAGS := --dry-run
endif
# NOTE(aghassemi): Publishing will fail unless you increment the version number
# in pubspec.yaml. See https://www.dartlang.org/tools/pub/versioning.html for
# guidelines.
# TODO(nlacasse): Generate a MOJO_VERSION file and publish that as part of the
# package.
publish: veryclean packages
	$(MAKE) test  # Build and test on Linux.
	ANDROID=1 $(MAKE) build  # Cross-compile for Android.
	mkdir -p $(PACKAGE_MOJO_BIN_DIR)
	cp -r gen/mojo/* $(PACKAGE_MOJO_BIN_DIR)
# Note: The '-' at the beginning of the following command tells make to ignore
# failures and always continue to the next command.
	-pub publish $(PUBLISH_FLAGS)
	rm -rf $(PACKAGE_MOJO_BIN_DIR)

# Prepares a local version of the syncbase package that can be accessed via a
# pubspec path. For example, if this is release/projects/croupier, its
# pubspec.yaml will include a syncbase path dependency pointing at
# ../../mojo/syncbase.
# This is helpful when testing local changes to syncbase or a version that has
# not been published on pub yet.
.PHONY: local-publish
local-publish: veryclean packages
	$(MAKE) build  # Build on Linux.
	ANDROID=1 $(MAKE) build  # Cross-compile for Android.
	mkdir -p $(PACKAGE_MOJO_BIN_DIR)
	cp -r gen/mojo/* $(PACKAGE_MOJO_BIN_DIR)

# TODO(aghassemi): Why does mojo generate dart-pkg and mojom dirs?
.PHONY: clean
clean:
	rm -rf bin creds gen tmp
	rm -rf lib/gen/dart-pkg
	rm -rf lib/gen/mojom
	rm -rf $(PACKAGE_MOJO_BIN_DIR)

.PHONY: veryclean
veryclean: clean
	rm -rf {.packages,pubspec.lock,packages}
	jiri goext distclean
