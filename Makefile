all: format check test build run

INSTALL_DIR := /usr/local/bin
TEMPLATES_DIR := /usr/local/etc/glm_freebsd_package

.PHONY:path
path:
	echo "PATH=${PATH}"

.PHONY:clean
clean:
	gleam clean

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
build:
	gleam build --target erlang

.PHONY:shipment
shipment:build
	gleam export erlang-shipment


.PHONY:run
run:
	gleam run -- --help

.PHONY:manual_test
manual_test:
	echo "this target requires FreeBSD to run"
	rm -rf ./tmp
	sudo service example stop || true
	cd ./priv/example; gleam export erlang-shipment
	gleam run -- -a $(PWD)/priv/example -s $(PWD)/tmp/staging -t $(PWD)/priv/example/priv/custom/templates -o $(PWD)/tmp/output
	sudo pkg install -y $(PWD)/tmp/output/example-1.0.0.pkg
	sudo service example start
	sudo service example status
	sudo cat /var/log/example.log
	sudo service example stop
	sudo pkg remove -y example

.PHONY:bird
bird:
	gleam run -m birdie

.PHONY:package
package:shipment
	# generate the single file gleescript.
	# this uses the older way to generate the gleescript.
	# TODO: https://gleam.run/writing-gleam/
	# TODO: once 1.17.0 is available on FreeBSD, then replace this with
	#     ```gleam export escript```
	gleam run -m gleescript -- --out=./staging

.PHONY:install
install:package
	# # generate the single file escript, named as the package name in the gleam.toml
	# copy the escript to the installation directory, typically /usr/local/bin/glm_freebsd_package
	sudo cp ./staging/glm_freebsd_package $(INSTALL_DIR)
	# copy the default templates to a standard location, typically /usr/local/etc/glm_freebsd_package/templates
	sudo mkdir -p $(TEMPLATES_DIR)
	sudo cp -rv ./priv/templates $(TEMPLATES_DIR)
	sudo find /usr/local/etc/glm_freebsd_package -type dir -exec sudo chmod ugo=rx {} \;
	sudo find /usr/local/etc/glm_freebsd_package -type file -exec sudo chmod ugo=r {} \;

