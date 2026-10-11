all: clean format check test install

PKG_NAME := glm_freebsd_package
PKG_VERSION := 1.0.0
PREFIX_DIR := /usr/local
TEMPLATES_DIR := /usr/local/etc/glm_freebsd_package
STAGE_DIR := ./staging
BIN_DIR := $(STAGE_DIR)/bin
PACKAGE_DIR := ./packages
REPO_DIR := /opt/builds

.PHONY:init
init:
	sudo mkdir -p ${REPO_DIR}

.PHONY:path
path:
	echo "PATH=${PATH}"

.PHONY:clean
clean:
	gleam clean
	rm -rf $(STAGE_DIR)
	rm -rf $(PACKAGE_DIR)

.PHONY:format
format:
	gleam format

.PHONY:check
check:
	gleam check

.PHONY:test
test:
	gleam "test"

.PHONY:build
build:clean
	gleam build --target erlang

	# generate the single file gleescript.
	# this uses the older way to generate the gleescript.
	# TODO: https://gleam.run/writing-gleam/
	# TODO: once 1.17.0 is available on FreeBSD, then replace this with
	#     ```gleam export escript```
	gleam run -m gleescript -- --out=$(BIN_DIR)

.PHONY:shipment
shipment:build
	gleam export erlang-shipment

.PHONY:run
run:
	gleam run -- --help

.PHONY:bird
bird:
	gleam run -m birdie

.PHONY:package
package:shipment
	./bootstrap.sh $(STAGE_DIR) $(PACKAGE_DIR) $(PKG_VERSION) $(BIN_DIR) $(PREFIX_DIR) $(TEMPLATES_DIR)

.PHONY:publish
publish:package
	sudo cp $(PACKAGE_DIR)/$(PKG_NAME)-$(PKG_VERSION).pkg $(REPO_DIR)
	sudo pkg repo $(REPO_DIR)

.PHONY: install:
install:publish
	sudo pkg install -y -r glbrepo $(PKG_NAME)-$(PKG_VERSION) || sudo pkg install -y ${REPO_DIR}/$(PKG_NAME)-$(PKG_VERSION).pkg

.PHONY:manual_test
manual_test:
	rm -rf ./tmp
	sudo service example stop || true
	cd ./priv/example && gleam export erlang-shipment
	cd ./priv/example && glm_freebsd_package -t $(PWD)/priv/example/priv/custom/templates
	sudo pkg install -y ./priv/example/packages/example-1.0.0.pkg
	sudo service example start
	sudo service example status
	sudo cat /var/log/example.log
	sudo service example stop
	sudo pkg remove -y example

