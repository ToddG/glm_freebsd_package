# glm_freebsd_package

A Gleam CLI tool that allows you to easily package Gleam Applications as FreeBSD packages. The FreeBSD
packages install as FreeBSD services, including service scripts to manage the application (e.g. start|stop).

[![Package Version](https://img.shields.io/hexpm/v/glm_freebsd)](https://hex.pm/packages/glm_freebsd)
[![Hex Docs](https://img.shields.io/badge/hex-docs-ffaff3)](https://hexdocs.pm/glm_freebsd/)

This tool is inspired by [ex_freebsd](https://github.com/patmaddox/ex_freebsd).

This is an opinionated tool:
* gleam apps are converted to FreeBSD services wrapped in FreeBSD packages
* services run as non-root accounts
* services use external configuration, see [12 factor app principals](https://12factor.net/)

Customization is provided via:
* support for custom templates
* support for custom key/value pairs

Further documentation can be found at <https://hexdocs.pm/glm_freebsd_package>.

## Quickstart

### Dependencies
 
* [gleam >= 1.14](https://www.freshports.org/lang/gleam/)
* [erlang >= erlang28](https://www.freshports.org/lang/erlang-runtime28/)
* make // seems to be installed by default

#### Install gleam and erlang

Use `latest` to get erlang 28

```shell
sudo mkdir -p /usr/local/etc/pkg/repos
sudo touch /usr/local/etc/pkg/repos/FreeBSD.conf
sudo echo 'FreeBSD-ports: { url: "pkg+https://pkg.FreeBSD.org/${ABI}/latest" }' > /usr/local/etc/pkg/repos/FreeBSD.conf
sudo pkg update
sudo pkg install -y erlang-runtime28 gleam rebar3
```

#### Update path and exec as normal user
```
PATH=/usr/local/lib/erlang28/bin:$PATH
./make
```

## Usage

### Install

```bash
# GFPTOOL could be '~/bin/gfptool' or any other path you like
$ export GFPTOOL=~/bin/gfptool
$ cd ~/bin
# clone this repo into directory GFPTOOL
(~/bin) $ git clone git@github.com:ToddG/glm_freebsd_package.git gfptool
(~/bin) $ cd gfptool
(~/bin/gfptool) $ make install
(~/bin/gfptool) $ cd ~
(~/) $
```

### Help

```bash
(~/) $ glm_freebsd_package --help
package

  package target gleam application as a FreeBSD package with service scripts

Usage:

  package [OPTIONS]

Options:

  (--application,-a APPLICATION)        gleam target application directory (location of the target app's gleam.toml file)
  [--templates,-t TEMPLATES]            path to custom templates directory (default: "./priv/templates/freebsd")
  (--staging,-s STAGING)                path to place intermediate (staging) files (will create directory)
  (--output,-o OUTPUT)                  path to place generated (output) files (will create directory)
  [--help,-h]                           Print this help
```


## Tutorial

### 1. Create a new gleam app


Create new gleam app that will subsequently be packaged as a FreeBSD service package:

```bash
(~/gfptool) $ cd ~/
(~/) $ mkdir apps && cd apps
(~/apps) $ gleam new APPNAME && cd APPNAME
(~/apps/APPNAME) $ gleam test
```

Init the app as a git repository:

```bash
(~/apps/APPNAME) $ git init
(~/apps/APPNAME) $ git remote add origin [your git repo url here]
(~/apps/APPNAME) $ git add .
(~/apps/APPNAME) $ git commit -am "initial commit"
(~/apps/APPNAME) $ git push --set-upstream origin main
```

### 2. Update the APPNAME/gleam.toml

Add the relevant FreeBSD package info to the ./gleam.toml

See [this example gleam.toml](https://github.com/ToddG/glm_freebsd/blob/11baaee2805705182346730b43a31bfb21ad9349/priv/example/gleam.toml#L16).

```toml
[freebsd]
pkg_origin = "example_company/example"
pkg_comment = "A simple one-line comment about this package."
# optional
pkg_arch = "freebsd:15:x86:64"
pkg_www = "https://github.com/toddg/some_repo"
# optional
pkg_license_logic = "single"
# optional
pkg_licenses = ["MIT"]
pkg_description = """
    line 01 : multi-line-package description....
    line 02 : multi-line-package description....
    line 03 : multi-line-package description....
    line 04 : multi-line-package description....
    line 05 : multi-line-package description....
    """
pkg_maintainer = "package_maintainer@example.com"
# optional
pkg_config_dir = "/tmp/example"
# optional
pkg_env_file = "example.env"
# optional
pkg_user_name = "example"
pkg_user_uid = "1234"
# optional
pkg_proc_name = "/usr/local/lib/erlang28/*/bin/beam.smp"
# optional
pkg_path_extensions = "/usr/local/lib/erlang28/bin"
# optional
pkg_var_dir = "/var/example"
# optional
pkg_prefix = "/usr/local"
# optional
pkg_command = "entrypoint.sh"
# optional
pkg_command_args = "run"
# optional
pkg_daemon_flags = ""
pkg_plist_lines = [
    { type = "file", src = "priv/data/wibble.txt", dest = "/usr/local/wibble/wibble.txt", mode = "0700", owner = "", group = "" },
    { type = "directory", src_dir = "priv/data/wobble_dir", dest_dir = "/usr/local/wobble", mode = "0700", owner = "", group = "" },
    { type = "dir_directive", path = "/usr/local/wibble" },
    { type = "dir_directive", path = "/usr/local/wobble" },
]

# optional
[[freebsd.dependencies]]
name = "vim"
version = "9.2.0204"
origin = "editors/vim"

# optional
[[freebsd.dependencies]]
name = "tree"
version = "2.2.1"
origin = "sysutils/tree"

# optional
[[freebsd.pairs]]
key = "key1"
value = "value1"

# optional
[[freebsd.pairs]]
key = "key2"
value = "value2"

# optional
[[freebsd.pairs]]
key = "custom_temp_dir"
value = "/tmp/example_temp_dir"
```

### Add this Makefile

Copy this makefile to ~/apps/APPNAME/Makefile

```make
all: format check build shipment test package

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
shipment:
	gleam export erlang-shipment

.PHONY:package
package:
    glm_freebsd_package

```

### Create an erlang-shipment

```bash
make
```

### Create a FreeBSD package

See the [Makefile](https://github.com/ToddG/glm_freebsd/blob/main/Makefile) for more examples.

```bash
# run this cli tool
(~/apps/APPNAME) $ glm_freebsd_package
(~/apps/APPNAME) $ ls packages
> APPNAME-1.0.0.pkg

# add staging and packages to your .gitignore
echo "/staging" >> ~/apps/APPNAME/.gitignore
echo "/packages" >> ~/apps/APPNAME/.gitignore

# install the generated package, note the default VERSION for gleam apps is 1.0.0
# sudo pkg install -y ~/apps/APPNAME/packages/APPNAME-[VERSION]
(~/apps/APPNAME) $ sudo pkg install -y ~/apps/APPNAME/packages/APPNAME-1.0.0
(~/apps/APPNAME) $ sudo pkg install -y ./packages/APPNAME-1.0.0.pkg

# start the service
(~/apps/APPNAME) $ sudo service APPNAME start
```

### Create a FreeBSD package with custom templates

... same as above, but just add a `-t [some templates directory]` to the glm_freebsd_package command:

```bash
(~/apps/APPNAME) $ glm_freebsd_package -t [some templates directory]
```

#### Custom Templates and Custom Vars

As mentioned above, arbitrary key/value pairs can be added to the gleam.toml file and referenced by the custom templates.

```toml
[[freebsd.pairs]]
key = "key2"
value = "value2"
```

## Environment Files and 12 Factor Apps

Applications being bundled into a FreeBSD Service will almost certainly require some sort of configuration. Per the
concept of 12 factor apps, this configuration should be external to the app and be _provided_ to the application 
by the runtime.

The location that the service management looks for the configuration file can be configured via these fields in gleam.toml:

```toml
[freebsd]
pkg_config_dir = "some dir"
pkg_env_file = "some file"
```

The configuration file can be placed in the correct location by your infrastructure as code (IAC), e.g. ansible, chef, puppet, etc.

When the service manager launches the service, it reads this environment file and includes these environment key/value pairs in the
process environment the service instance is started with.

## Toml Elements

Package name and version are extracted from the top of the toml here:
```toml
name = "example"
version = "1.0.0"
```

The rest of the data comes from the [freebsd] sections. This is fully documented in the [Config type](https://github.com/ToddG/glm_freebsd/blob/11baaee2805705182346730b43a31bfb21ad9349/src/glm_freebsd/packager.gleam#L160-L228):

```gleam
/// Configuration object built from the gleam.toml.
pub type Config {
  Config(
  /// Gleam application name, used in template(s): +MANIFEST, required (no default).
  app_name: String,
  /// Gleam application version, used in template(s): +MANIFEST, required (no default).
  app_version: String,
  /// Freebsd package user name, used in +POST_INSTALL and rc, defaults to `app_name`.
  pkg_user_name: String,
  /// Freebsd package user uid, used in +POST_INSTALL and rc, required (no default).
  pkg_user_uid: String,
  /// Freebsd package long description, used in +DESC, required (no default).
  pkg_description: String,
  /// Freebsd package maintainer email address, used in +MANIFEST, required (no default).
  pkg_maintainer: String,
  /// Freebsd package dependencies, used in +MANIFEST, required (no default).
  pkg_dependencies: List(DependencyConfig),
  /// Variable used in template(s): rc.conf; the process name to be used when looking for this package,
  /// defaults to /usr/local/lib/erlang28/*/bin/beam.smp.
  pkg_proc_name: String,
  /// Variable used in template(s): +POST_INSTALL, +PRE_DEINSTALL, rc; the package configuration directory,
  /// required (no default). Directory is NOT automatically created by the package installation. It is
  /// expected that this configuration directory and file will be provided by an orchestration service or
  /// manually by a system administrator. Service configuration is separate from service installation.
  pkg_config_dir: String,
  /// Variable used in template(s): rc; config; path_extensions are ":" delimited paths to prepend to the
  /// PATH variable, defaults to /usr/local/lib/erlang28/bin.
  pkg_path_extensions: String,
  /// Variable used in template(s): +PRE_DEINSTALL; var_dir is the data dir for this package, defaults to "/var/APP_NAME". This directory is NOT created by the installer.
  pkg_var_dir: String,
  /// Variable used in template(s): rc; defaults to APP_NAME.env.
  pkg_env_file: String,
  /// The path where the files contained in this package are installed, used in template(s): rc, +MANIFEST,
  /// defaults to /usr/local.
  pkg_prefix: String,
  /// Variable used in template(s): rc; defaults to 'entrypoint.sh'.
  pkg_command: String,
  /// Variable used in template(s): rc; defaults to 'run'.
  pkg_command_args: String,
  /// Variable used in template(s): rc; defaults to ''.
  pkg_daemon_flags: String,
  /// Plist line entries, details files to copy into the target system, plus keywords to
  /// control how those files are copied, permissions, etc, defaults to [].
  pkg_plist_lines: List(PlistLine),
  /// This entry sets the	freebsd package's origin to pkg-origin.
  /// This is a string of	the form category/port-dir which designates the port
  ///	this package was built from, used in template(s): rc; defaults to 'private/APP_NAME'
  pkg_origin: String,
  /// Comment-string is a	one-line description of	this package.	it is
  /// the	equivalent of the comment variable for a port, not a	way to
  /// put	comments in a +manifest	file, used in template(s): +MANIFEST, required (no default).
  pkg_comment: String,
  /// The	architecture of the	machine	the package was built on.
  /// cpu-type takes values like x86, amd64, freebsd:15:x86:64,
  /// used in template(s): +MANIFEST, defaults to 'freebsd:15:x86:64'.
  pkg_arch: String,
  /// The	software's official website, used in template(s): +MANIFEST, +DISPLAY, required, no default.
  pkg_www: String,
  /// Package license, used in template(s): +MANIFEST, defaults to 'single'.
  pkg_license_logic: String,
  /// Package licenses, e.g. licenses: ["MIT"], used in template(s): +MANIFEST, defaults to 'PRIVATE'.
  pkg_licenses: List(String),
  /// Unstructured key/value pairs to enable sending any string data to the templating system, useful for custom
  /// templates, can be used in any custom template. You can elect to use custom templates instead of the default
  /// templates by passing the `templates` parameter to the CLI. If you need templates to start out with, copy
  /// the default templates from ./priv/templates/freebsd to a directory of your choosing. Modify the copied
  /// templates as you wish, and then specify that directory on the CLI as previously mentioned.
  pkg_pairs: List(ConfigPair),
  )
}
```

## Links

* https://siberoloji.com/how-to-create-a-freebsd-package-with-pkg-create-on-freebsd-operating-system/
* https://man.freebsd.org/cgi/man.cgi?query=pkg&sektion=8
* https://man.freebsd.org/cgi/man.cgi?query=pkg_create&sektion=3&apropos=0&manpath=FreeBSD+15.0-RELEASE+and+Ports.quarterly
