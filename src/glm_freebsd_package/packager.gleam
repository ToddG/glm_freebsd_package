/// # Package a gleam application into a FreeBSD Package
///
/// ## Design
/// The process consists of:
///
///   ```gleam.toml -> Config -> gen staging artifacts -> gen package -> return path to package```
///
///   1. read gleam.toml
///   2. create an internal Config instance
///   3. use the Config instance and the commandline params to generate staging artifacts
///   4. staging artifacts consist of:
///     * +MANIFEST
///     * +PRE_DEINSTALL
///     * +POST_INSTALL
///     * plist (text file listing all other files to be installed)
///     * [and all the other files copied into staging and listed in `plist`]
///   5. run the FreeBSD `pkg` command to generate the final FreeBSD package artifact
///   6. return the path to the final FreeBSD package artifact
///
/// Links
/// * https://lastsummer.de/creating-custom-packages-on-freebsd/
/// * https://gist.github.com/matthewp/431e0c89d9492ea5601ce9c01a5676af
///
import filepath
import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/string_tree
import handles
import handles/ctx
import handles/error as handles_error
import logging
import shellout
import simplifile
import tom.{type Toml}

const pkg_plist = "pkg-plist"

pub type AppError {
  AppError(String)
  UnableToReadTomlFile(simplifile.FileError)
  UnableToParseTomlText(tom.ParseError)
  KeyNotFoundInToml(List(String), List(String))
  UnexpectedTomlType(Toml)
  UnableToCreateStagingDir(simplifile.FileError)
  UnableToGetTemplates(simplifile.FileError)
  UnableToReadTemplate(String, simplifile.FileError)
  UnableToPrepareTemplate(String, handles_error.TokenizerError)
  UnableToProjectTemplate(String, String, handles_error.RuntimeError)
  UnableToCreateProjectTemplateDir(String, String, simplifile.FileError)
  UnableToCreateOutputDir(simplifile.FileError)
  UnableToAppendPlistFile(String, String, simplifile.FileError)
  UnableToBuildPackage(#(Int, String))
  UnexpectedPlistLineType(String)
  UnableToGetPlistFiles(String, String, simplifile.FileError)
  UnableToConvertToString(tom.GetError)
  UnableToCompilePartialTemplate(handles_error.TokenizerError)
  UnableToCopyPlistDirectory(String, String, String, simplifile.FileError)
  UnableToCopyTemplatesToDirectory(String, simplifile.FileError)
  UnableToGetTemplatesFromDirectory(String, simplifile.FileError)
  UnableToWriteProjectedTemplate(String, String, simplifile.FileError)
  UnableToCopyPlistFile(String, String, simplifile.FileError)
  UnableToCreateMetadatDir(simplifile.FileError)
  UnableToListBuiltPackages(#(Int, String))
  UnableToCreatePlistFileDirective(String, simplifile.FileError)
  MissingGleamTomlFile(String)
  UnableToCheckForMissingGleamTomlFile(String, simplifile.FileError)
  MissingDefaultTemplatesDir(String)
  UnableToCheckForMissingDefaultTemplatesDir(String, simplifile.FileError)
  MissingErlangShipmentDir(String)
  UnableToCheckForMissingErlangShipmentDir(String, simplifile.FileError)
  UnableToCreateDirectory(String, simplifile.FileError)
  MissingSourceFile(String)
  UnableToCheckForMissingSourceFile(String, simplifile.FileError)
  MissingProjectedTemplateDirectory(String)
  UnableToCheckForMissingProjectedTemplateDirectory(
    String,
    simplifile.FileError,
  )
  UnableToCreateProjectedTemplateDirectory(String, simplifile.FileError)
}

/// use this template to create dependency entries within +MANIFEST deps stanza
pub const dependency_partial_template = "   {{ dep_name }}: {origin: \"{{ dep_origin }}\", version: \"{{ dep_version }}\"}"

/// DependencyConfig fully describes a package dependency so that it can be installed
/// as part of installing this package.
///
/// Note:
///
/// This information can be found using:
///
///   ```$ pkg query "  %n: { version: \"%v\", origin: %o }" [PACKAGE NAME]```
pub type DependencyConfig {
  DependencyConfig(
    // freebsd package dependency name
    name: String,
    // freebsd package dependency version
    version: String,
    // freebsd package dependency origin
    origin: String,
  )
}

/// FreeBSD Pairs are key (String) / value (String) pairs that provide unstructed data that
/// can be passed through to the templating system to support custom templates.
pub type ConfigPair {
  ConfigPair(key: String, value: String)
}

/// PlistFile maps a source file to a target destination, such that a local file
/// (on the machine building the package) gets copied into the package staging area
/// and listed in the plist file manifest.
///
/// https://man.freebsd.org/cgi/man.cgi?query=pkg-create
/// """
///       The plist is a  sequential  list	 of  lines  which  can	have  keywords
///       prepended. A  keyword	starts with an `@'.  Lines not starting	with a
///       keyword are considered as paths to a file.  If started with a `/'  then
///       it is considered	an absolute path.  Otherwise the file is considered as
///       relative to PREFIX.
/// """
///
/// Note:
///   The dest will be prepended with the staging_directory path when it is copied on the
///   local filesystem. But the reference to this file in the `plist` file will be the path
///   provided.
pub type PlistLine {
  PlistFile(
    /// The fully qualified path to the source file (on the local host building the FreeBSD package).
    src: String,
    /// The path for the source file on the target host (where the package will be installed).
    dest: String,
    /// Format is	the same as that used by the chmod command. Blank string sets to default.
    mode: String,
    /// Set ownership file to user. Blank string sets to default (root) ownership.
    owner: String,
    /// Set group ownership to	group. Blank string sets to default (wheel) group	owner-ship.
    group: String,
  )
  PlistDirDirective(
    /// Declare directory name to be deleted at deinstall time. By default, most
    /// directories created by a package installation are deleted automatically when
    /// the package is deinstalled, so this directive is only needed for empty
    /// directories or directories outside of PREFIX. These directives should appear at
    /// the end of the package list. If the directory is not empty a warning will be
    /// printed, and the directory will not be removed.  (Subdirectories should be
    /// listed before parent directories.)
    path: String,
  )
  PlistIncludeDirective(
    /// Include	the name plist file	to the plist currently being parsed. the name will
    /// be opened relatively to the main plist file being parsed. Note: only one level
    /// of @include is allowed.
    path: String,
  )
  PlistDirectory(
    /// Include these source files recursively.
    src_dir: String,
    /// Base directory for source files.
    dest_dir: String,
    /// Mode same as for PlistFile.
    mode: String,
    /// Owner same as for PlistFile.
    owner: String,
    /// Group same as for PlistFile.
    group: String,
  )
}

/// Configuration object built from the gleam.toml.
pub type Config {
  Config(
    /// Gleam application name, used in template(s): +MANIFEST, required (no default).
    app_name: String,
    /// Gleam application version, used in template(s): +MANIFEST, required (no default).
    app_version: String,
    /// Freebsd package user name, used in +POST_INSTALL and rc, defaults to `app_name`.
    pkg_user_name: String,
    /// Freebsd package user uid, used in +POST_INSTALL and rc. If not provided, then no new users
    /// will be created.
    pkg_user_uid: Option(String),
    /// Freebsd root directory, used in +POST_INSTALL defaults to not using `-R PKG_ROOT_DIR` in commands using `pw`.
    pkg_root_dir: Option(String),
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

pub fn run(
  app_dir: String,
  default_templates_dir: String,
  user_templates_dir: Result(String, Nil),
  staging_dir: String,
  output_dir: String,
) -> Result(String, AppError) {
  logging.log(logging.Debug, "packaging...")
  logging.log(logging.Debug, "app_dir: " <> app_dir)
  logging.log(logging.Debug, "default_templates_dir: " <> default_templates_dir)
  let metadata_dir = filepath.join(staging_dir, "metadata")
  let staging_dir = filepath.join(staging_dir, "staging")
  let erlang_shipment_dir = filepath.join(app_dir, "build/erlang-shipment")
  let _ = case user_templates_dir {
    Ok(dir) -> logging.log(logging.Debug, "user_templates_dir: " <> dir)
    Error(_) -> Nil
  }
  logging.log(logging.Debug, "metadata_dir: " <> metadata_dir)
  logging.log(logging.Debug, "staging_dir: " <> staging_dir)
  logging.log(logging.Debug, "output_dir: " <> output_dir)
  logging.log(logging.Debug, "erlang_shipment_dir: " <> erlang_shipment_dir)
  let toml_file = filepath.join(app_dir, "gleam.toml")
  use _ <- result.try(case simplifile.is_file(toml_file) {
    Ok(True) -> Nil |> Ok
    Ok(False) -> Error(MissingGleamTomlFile(toml_file))
    Error(e) -> Error(UnableToCheckForMissingGleamTomlFile(toml_file, e))
  })
  use _ <- result.try(case simplifile.is_directory(default_templates_dir) {
    Ok(True) -> Nil |> Ok
    Ok(False) -> Error(MissingDefaultTemplatesDir(default_templates_dir))
    Error(e) ->
      Error(UnableToCheckForMissingDefaultTemplatesDir(default_templates_dir, e))
  })
  use _ <- result.try(case simplifile.is_directory(erlang_shipment_dir) {
    Ok(True) -> Nil |> Ok
    Ok(False) -> Error(MissingErlangShipmentDir(erlang_shipment_dir))
    Error(e) ->
      Error(UnableToCheckForMissingErlangShipmentDir(erlang_shipment_dir, e))
  })
  staging_dir
  |> simplifile.create_directory_all
  |> result.map_error(UnableToCreateStagingDir)
  |> result.try(fn(_) {
    output_dir
    |> simplifile.create_directory_all
    |> result.map_error(UnableToCreateOutputDir)
  })
  |> result.try(fn(_) {
    metadata_dir
    |> simplifile.create_directory_all
    |> result.map_error(UnableToCreateMetadatDir)
  })
  |> result.try(fn(_) { toml_file |> load_toml })
  |> result.try(new_config)
  |> result.try(gen_staging(
    _,
    app_dir,
    metadata_dir,
    staging_dir,
    default_templates_dir,
    user_templates_dir,
    erlang_shipment_dir,
  ))
  |> result.try(fn(_) { build_package(metadata_dir, staging_dir, output_dir) })
}

/// Read the `gleam.toml` file and parse it into toml.
/// Any valid (parsable) toml will succeed here.
pub fn load_toml(
  toml_file: String,
) -> Result(dict.Dict(String, Toml), AppError) {
  toml_file
  |> simplifile.read
  |> result.map_error(UnableToReadTomlFile)
  |> result.try(fn(text) {
    tom.parse(text) |> result.map_error(UnableToParseTomlText)
  })
}

/// Extract the values from the provided toml dict and generate a Config instance.
/// If any of the required fields are not present in the toml, this function will fail.
pub fn new_config(toml: Dict(String, Toml)) -> Result(Config, AppError) {
  use app_name <- result.try(get_string(toml, "name"))
  use app_version <- result.try(get_string(toml, "version"))
  use pkg_user_name <- result.try(get_optional_string(
    toml,
    "freebsd.pkg_user_name",
    app_name,
  ))
  use pkg_user_uid <- result.try(case get_string(toml, "freebsd.pkg_user_uid") {
    Ok(uid) -> uid |> Some |> Ok
    Error(_) -> None |> Ok
  })
  let pkg_root_dir = case get_string(toml, "freebsd.pkg_root_dir") {
    Ok(s) -> Some(s)
    Error(_) -> None
  }
  use pkg_description <- result.try(get_string(toml, "freebsd.pkg_description"))
  use pkg_maintainer <- result.try(get_string(toml, "freebsd.pkg_maintainer"))
  use pkg_dependencies <- result.try(new_pkg_dependencies(toml))
  use pkg_proc_name <- result.try(get_optional_string(
    toml,
    "freebsd.pkg_proc_name",
    "/usr/local/lib/erlang28/*/bin/beam.smp",
  ))
  use pkg_config_dir <- result.try(get_string(toml, "freebsd.pkg_config_dir"))
  use pkg_path_extensions <- result.try(get_optional_string(
    toml,
    "freebsd.pkg_path_extensions",
    "/usr/local/lib/erlang28/bin",
  ))
  use pkg_var_dir <- result.try(get_optional_string(
    toml,
    "freebsd.pkg_var_dir",
    filepath.join("/var", app_name),
  ))
  use pkg_env_file <- result.try(get_optional_string(
    toml,
    "freebsd.pkg_env_file",
    app_name <> ".env",
  ))
  use pkg_prefix <- result.try(get_optional_string(
    toml,
    "freebsd.pkg_prefix",
    "/usr/local",
  ))
  use pkg_command <- result.try(get_optional_string(
    toml,
    "freebsd.pkg_command",
    "entrypoint.sh",
  ))
  use pkg_command_args <- result.try(get_optional_string(
    toml,
    "freebsd.pkg_command_args",
    "run",
  ))
  use pkg_daemon_flags <- result.try(get_optional_string(
    toml,
    "freebsd.pkg_daemon_flags",
    "",
  ))
  use pkg_plist_lines <- result.try(new_pkg_plist_lines(toml))

  use pkg_origin <- result.try(get_optional_string(
    toml,
    "freebsd.pkg_origin",
    "private/" <> app_name,
  ))
  use pkg_comment <- result.try(get_string(toml, "freebsd.pkg_comment"))
  use pkg_arch <- result.try(get_optional_string(
    toml,
    "freebsd.pkg_arch",
    "freebsd:15:x86:64",
  ))
  use pkg_www <- result.try(get_string(toml, "freebsd.pkg_www"))
  use pkg_license_logic <- result.try(get_optional_string(
    toml,
    "freebsd.pkg_license_logic",
    "single",
  ))
  use pkg_licenses <- result.try(
    get_optional_strings(toml, "freebsd.pkg_licenses", ["PRIVATE"]),
  )
  use pkg_pairs <- result.try(get_pairs(toml))

  let config =
    Config(
      app_name:,
      app_version:,
      pkg_user_name:,
      pkg_user_uid:,
      pkg_description:,
      pkg_maintainer:,
      pkg_dependencies:,
      pkg_proc_name:,
      pkg_config_dir:,
      pkg_path_extensions:,
      pkg_var_dir:,
      pkg_env_file:,
      pkg_prefix:,
      pkg_command:,
      pkg_command_args:,
      pkg_daemon_flags:,
      pkg_plist_lines:,
      pkg_origin:,
      pkg_comment:,
      pkg_arch:,
      pkg_www:,
      pkg_license_logic:,
      pkg_licenses:,
      pkg_pairs:,
      pkg_root_dir:,
    )
  logging.log(logging.Debug, config |> string.inspect)
  Ok(config)
}

/// Return a list of PlistLines from the toml dict.
fn new_pkg_plist_lines(
  d: Dict(String, Toml),
) -> Result(List(PlistLine), AppError) {
  let key = "freebsd.pkg_plist_lines" |> string.split(".")
  new_toml_element_list(d, key, fn(toml) {
    case toml {
      tom.InlineTable(t) -> {
        use plist_line_type <- result.try(get_string(t, "type"))
        case plist_line_type {
          "file" -> {
            use src <- result.try(get_string(t, "src"))
            use dest <- result.try(get_string(t, "dest"))
            use mode <- result.try(get_string(t, "mode"))
            use owner <- result.try(get_string(t, "owner"))
            use group <- result.try(get_string(t, "group"))
            let src = src |> normalize_file_path
            let dest = dest |> normalize_file_path
            Ok(PlistFile(src:, dest:, mode:, owner:, group:))
          }
          "directory" -> {
            use src_dir <- result.try(get_string(t, "src_dir"))
            use dest_dir <- result.try(get_string(t, "dest_dir"))
            use mode <- result.try(get_string(t, "mode"))
            use owner <- result.try(get_string(t, "owner"))
            use group <- result.try(get_string(t, "group"))
            let src_dir = src_dir |> normalize_file_path
            let dest_dir = dest_dir |> normalize_file_path
            Ok(PlistDirectory(src_dir:, dest_dir:, mode:, owner:, group:))
          }
          "dir_directive" -> {
            use path <- result.try(get_string(t, "path"))
            let path = path |> normalize_file_path
            Ok(PlistDirDirective(path:))
          }
          "include_directive" -> {
            use path <- result.try(get_string(t, "path"))
            let path = path |> normalize_file_path
            Ok(PlistIncludeDirective(path:))
          }
          _ -> {
            Error(UnexpectedPlistLineType(plist_line_type))
          }
        }
      }
      t -> Error(UnexpectedTomlType(t))
    }
  })
}

/// Return a list of package dependencies from the toml dict.
fn new_pkg_dependencies(
  d: Dict(String, Toml),
) -> Result(List(DependencyConfig), AppError) {
  let key = "freebsd.dependencies" |> string.split(".")
  new_toml_element_list(d, key, fn(toml) {
    case toml {
      tom.Table(t) -> {
        use name <- result.try(get_string(t, "name"))
        use version <- result.try(get_string(t, "version"))
        use origin <- result.try(get_string(t, "origin"))
        DependencyConfig(name:, version:, origin:) |> Ok
      }
      t -> Error(UnexpectedTomlType(t))
    }
  })
}

/// Extract a list of elements from a toml dict.
fn new_toml_element_list(
  d: Dict(String, Toml),
  key: List(String),
  func: fn(Toml) -> Result(element, AppError),
) -> Result(List(element), AppError) {
  case tom.get_array(d, key) {
    Error(_) -> Ok([])
    Ok(toml_list) -> {
      toml_list
      |> list.map(func)
      |> result.all
    }
  }
}

/// Extract a string from a toml dict.
pub fn get_string(
  toml: Dict(String, Toml),
  key: String,
) -> Result(String, AppError) {
  let key = string.split(key, ".")
  tom.get_string(toml, key)
  |> result.map_error(fn(_) { KeyNotFoundInToml(key, dict.keys(toml)) })
}

/// Extract list of strings from a toml dict.
pub fn get_strings(
  toml: Dict(String, Toml),
  key: String,
) -> Result(List(String), AppError) {
  let key = string.split(key, ".")
  tom.get_array(toml, key)
  |> result.map_error(fn(_) { KeyNotFoundInToml(key, dict.keys(toml)) })
  |> result.try(fn(data) {
    data
    |> list.map(tom.as_string)
    |> result.all
    |> result.map_error(UnableToConvertToString)
  })
}

/// Extract list of config pairs from a toml dict.
fn get_pairs(d: Dict(String, Toml)) -> Result(List(ConfigPair), AppError) {
  let key = "freebsd.pairs" |> string.split(".")
  new_toml_element_list(d, key, fn(toml) {
    case toml {
      tom.Table(t) -> {
        use key <- result.try(get_string(t, "key"))
        use value <- result.try(get_string(t, "value"))
        ConfigPair(key, value) |> Ok
      }
      t -> Error(UnexpectedTomlType(t))
    }
  })
}

/// Extract a string from a toml dict, use the default value if the key is missing.
pub fn get_optional_string(
  toml: Dict(String, Toml),
  key: String,
  default: String,
) -> Result(String, AppError) {
  case get_string(toml, key) {
    Error(_) -> Ok(default)
    Ok(s) -> Ok(s)
  }
}

/// Extract a list of strings from a toml dict, use the default value if the key is missing.
pub fn get_optional_strings(
  toml: Dict(String, Toml),
  key: String,
  default: List(String),
) -> Result(List(String), AppError) {
  case get_strings(toml, key) {
    Error(_) -> Ok(default)
    Ok(s) -> Ok(s)
  }
}

/// Generate the templates from the source templates and the config instance, and write into the metadata dir.
fn gen_templates(
  cfg: Config,
  default_templates_dir: String,
  user_templates_dir: Result(String, Nil),
  metadata_dir: String,
) -> Result(Config, AppError) {
  // templates: create the context for template projection (reification)
  let context = new_context(cfg)
  // load partial templates
  use dep_template <- result.try(
    handles.prepare(dependency_partial_template)
    |> result.map_error(UnableToCompilePartialTemplate),
  )
  let partial_templates = [#("dependency", dep_template)]
  // templates: project (reify) the templates into their final form
  default_templates_dir
  |> project_templates(context, metadata_dir, partial_templates)
  |> result.try(fn(_) {
    case user_templates_dir {
      Ok(dir) -> {
        dir |> project_templates(context, metadata_dir, partial_templates)
      }
      Error(_) -> Ok([])
    }
  })
  |> result.map(fn(_) { cfg })
}

fn project_templates(
  templates_dir: String,
  context: ctx.Value,
  metadata_dir: String,
  partial_templates: List(#(String, handles.Template)),
) {
  templates_dir
  |> simplifile.get_files
  |> result.map_error(UnableToGetTemplates)
  |> result.try(fn(templates) {
    templates
    |> list.map(project_template(_, context, metadata_dir, partial_templates))
    |> result.all
  })
}

/// Write the plist include directive to the plist file.
fn process_plist_include_directive(
  plist_file,
  path,
) -> Result(String, AppError) {
  let line = "@include " <> path
  append_string_to_plist(plist_file, line)
}

/// Write the plist dir directive to the plist file.
fn process_plist_dir_directive(plist_file, path) -> Result(String, AppError) {
  let line = "@dir " <> path
  append_string_to_plist(plist_file, line)
}

fn normalize_file_path(path: String) -> String {
  case path |> string.starts_with("/"), path |> string.starts_with("./") {
    // absolute path
    True, _ -> path
    // relative path, but strip off the './' b/c `pkg` doesn't recognize these paths in the generated plist file
    _, True -> path |> string.drop_start(2) |> normalize_file_path
    // relative path
    _, _ -> path
  }
}

/// Copy the plist file to the staging directory, and append an entry to the plist file.
fn process_plist_file_directive(
  app_dir,
  staging_dir,
  plist_file,
  src,
  dest,
  mode,
  owner,
  group,
) -> Result(String, AppError) {
  logging.log(logging.Debug, "process_plist_file_directive")
  logging.log(logging.Debug, "app_dir: " <> app_dir)
  logging.log(logging.Debug, "staging_dir: " <> staging_dir)
  logging.log(logging.Debug, "plist_file: " <> plist_file)
  logging.log(logging.Debug, "src: " <> src)
  logging.log(logging.Debug, "dest: " <> dest)
  logging.log(logging.Debug, "mode: " <> mode)
  logging.log(logging.Debug, "owner: " <> owner)
  logging.log(logging.Debug, "group: " <> group)
  let target_path = filepath.join(staging_dir, dest)
  let target_path_dir = filepath.directory_name(target_path)
  use _ <- result.try(case simplifile.create_directory_all(target_path_dir) {
    Ok(_) -> Nil |> Ok
    Error(e) -> Error(UnableToCreateDirectory(target_path_dir, e))
  })
  let source_file_path = case filepath.is_absolute(src) {
    True -> src
    False -> filepath.join(app_dir, src)
  }
  use _ <- result.try(case simplifile.is_file(source_file_path) {
    Ok(True) -> Nil |> Ok
    Ok(False) -> Error(MissingSourceFile(source_file_path))
    Error(e) -> Error(UnableToCheckForMissingSourceFile(source_file_path, e))
  })
  simplifile.copy_file(source_file_path, target_path)
  |> result.map(fn(_) {
    logging.log(
      logging.Debug,
      "copied file src: " <> source_file_path <> ", dest: " <> target_path,
    )
  })
  |> result.map_error(UnableToCopyPlistFile(source_file_path, target_path, _))
  |> result.try(fn(_) {
    let lines = [
      "@mode " <> mode,
      "@owner " <> owner,
      "@group " <> group,
      dest,
    ]
    append_strings_to_plist(plist_file, lines)
    |> result.map(fn(lines) { lines |> string.join("\n") })
  })
}

fn append_string_to_plist(
  file: String,
  line: String,
) -> Result(String, AppError) {
  simplifile.append(file, line <> "\n")
  |> result.map_error(UnableToAppendPlistFile(file, line, _))
  |> result.map(fn(_) {
    logging.log(
      logging.Debug,
      "[plist] appended to file: " <> file <> ", line: " <> line,
    )
    line
  })
}

fn append_strings_to_plist(
  file: String,
  lines: List(String),
) -> Result(List(String), AppError) {
  lines |> list.map(append_string_to_plist(file, _)) |> result.all
}

/// Recurse src directory and process all the files in that tree, copying the dir to staging, and
/// appending entries to the plist file.
fn process_plist_directory(
  app_dir,
  staging_dir,
  plist_file,
  src_dir,
  dest_dir,
  mode,
  owner,
  group,
) -> Result(String, AppError) {
  let headers = ["@mode " <> mode, "@owner " <> owner, "@group " <> group]

  append_strings_to_plist(plist_file, headers)
  |> result.try(fn(_) {
    let source_dir_path = case filepath.is_absolute(src_dir) {
      False -> filepath.join(app_dir, src_dir)
      True -> src_dir
    }
    simplifile.get_files(source_dir_path)
    |> result.map_error(UnableToGetPlistFiles(plist_file, source_dir_path, _))
    |> result.map(fn(files) {
      let start_len = string.length(source_dir_path)
      let raw_files = files |> list.map(string.drop_start(_, start_len))
      let plist_files = raw_files |> list.map(filepath.join(dest_dir, _))
      let staging_target_dir = filepath.join(staging_dir, dest_dir)
      append_strings_to_plist(plist_file, plist_files)
      |> result.try(fn(_) {
        simplifile.copy_directory(source_dir_path, staging_target_dir)
        |> result.map_error(UnableToCopyPlistDirectory(
          plist_file,
          source_dir_path,
          staging_target_dir,
          _,
        ))
        |> result.map(fn(_) { plist_files })
      })
    })
    |> result.flatten
  })
  |> result.map(fn(lines) { lines |> string.join("\n") })
}

/// Copy plist files into the staging dir.
fn copy_plist_files(
  cfg: Config,
  app_dir: String,
  metadata_dir: String,
  staging_dir: String,
) -> Result(List(String), AppError) {
  let plist_file = filepath.join(metadata_dir, pkg_plist)
  cfg.pkg_plist_lines
  |> list.map(fn(plist_line) {
    case plist_line {
      PlistIncludeDirective(path:) ->
        process_plist_include_directive(plist_file, path)
      PlistDirDirective(path:) -> process_plist_dir_directive(plist_file, path)
      PlistFile(src:, dest:, mode:, owner:, group:) -> {
        process_plist_file_directive(
          app_dir,
          staging_dir,
          plist_file,
          src,
          dest,
          mode,
          owner,
          group,
        )
      }
      PlistDirectory(src_dir:, dest_dir:, mode:, owner:, group:) ->
        process_plist_directory(
          app_dir,
          staging_dir,
          plist_file,
          src_dir,
          dest_dir,
          mode,
          owner,
          group,
        )
    }
  })
  |> result.all
}

/// Copy the raw templates to a directory so that the user can modify them for their own purposes.
pub fn copy_raw_templates(
  target_dir: String,
) -> Result(List(String), AppError) {
  simplifile.copy_directory("./priv/templates/freebsd", target_dir)
  |> result.map_error(fn(e) { UnableToCopyTemplatesToDirectory(target_dir, e) })
  |> result.map(fn(_) {
    simplifile.get_files(target_dir)
    |> result.map_error(fn(e) {
      UnableToGetTemplatesFromDirectory(target_dir, e)
    })
  })
  |> result.flatten
}

/// Generate the files in the staging directory. The files in the staging directory will be packaged into
/// the final FreeBSD package.
///
/// These files are:
///   1. +MANIFEST: the top level file that describes this FreeBSD Package
///   2. +[FILES]: +POST_INSTALL and +PRE_DEINSTALL scripts to execute as part of installing or removing package
///   3. plist: a list of all the files to be copied to the target server as part of installation
///   4. [FILES]: the files (listed in the `plist` above) to be copied to the target server
pub fn gen_staging(
  config: Config,
  app_dir: String,
  metadata_dir: String,
  staging_dir: String,
  default_templates_dir: String,
  user_templates_dir: Result(String, Nil),
  erlang_shipment_dir: String,
) -> Result(Nil, AppError) {
  config
  |> gen_templates(default_templates_dir, user_templates_dir, metadata_dir)
  |> result.try(fn(cfg) { update_config_with_rc_files(cfg, metadata_dir) })
  |> result.try(fn(cfg) {
    update_config_with_erlang_shipment_files(cfg, erlang_shipment_dir)
  })
  |> result.try(fn(cfg) {
    copy_plist_files(cfg, app_dir, metadata_dir, staging_dir)
  })
  |> result.map(fn(_) { Nil })
}

/// Add the erlang shipment directory to the config plist. This will cause this directory
/// to be copied to staging and entries appended to the plist file.
fn update_config_with_erlang_shipment_files(
  cfg: Config,
  erlang_shipment_dir: String,
) -> Result(Config, AppError) {
  let target_deployment_dir =
    filepath.join(filepath.join(cfg.pkg_prefix, "libexec"), cfg.app_name)
  let plist_dir =
    PlistDirectory(
      erlang_shipment_dir,
      target_deployment_dir,
      "0554",
      cfg.pkg_user_name,
      "wheel",
    )
  let updated_pkg_plist_lines = cfg.pkg_plist_lines |> list.prepend(plist_dir)
  Ok(Config(..cfg, pkg_plist_lines: updated_pkg_plist_lines))
}

/// Add the FreeBSD service files to the config plist. This will cause the
/// /etc/rc.d/APP_NAME and /etc/rc.conf.d/APP_NAME service files to be copied to staging
/// and appended to the plist file.
fn update_config_with_rc_files(
  cfg: Config,
  metadata_dir: String,
) -> Result(Config, AppError) {
  let rc_conf_file =
    PlistFile(
      filepath.join(metadata_dir, "rc_conf"),
      filepath.join("/etc/rc.conf.d/", cfg.app_name),
      "0555",
      "root",
      "wheel",
    )
  let rc_file =
    PlistFile(
      filepath.join(metadata_dir, "rc"),
      filepath.join("/etc/rc.d/", cfg.app_name),
      "0555",
      "root",
      "wheel",
    )
  let updated_pkg_plist_lines =
    cfg.pkg_plist_lines
    |> list.prepend(rc_conf_file)
    |> list.prepend(rc_file)

  Ok(Config(..cfg, pkg_plist_lines: updated_pkg_plist_lines))
}

/// Push all the vars from the config into the handler context.
fn new_context(config: Config) -> ctx.Value {
  let pairs_prop_list =
    config.pkg_pairs
    |> list.map(fn(p) { ctx.Prop("pair_" <> p.key, ctx.Str(p.value)) })

  let standard_prop_list = [
    ctx.Prop("app_name", ctx.Str(config.app_name)),
    ctx.Prop("app_version", ctx.Str(config.app_version)),
    ctx.Prop("pkg_command_args", ctx.Str(config.pkg_command_args)),
    ctx.Prop("pkg_command", ctx.Str(config.pkg_command)),
    ctx.Prop("pkg_arch", ctx.Str(config.pkg_arch)),
    ctx.Prop("pkg_www", ctx.Str(config.pkg_www)),
    ctx.Prop("pkg_license_logic", ctx.Str(config.pkg_license_logic)),
    ctx.Prop(
      "pkg_licenses",
      config.pkg_licenses
        |> list.map(fn(x) { "\"" <> x <> "\"" })
        |> string.join(",")
        |> ctx.Str,
    ),
    ctx.Prop("pkg_comment", ctx.Str(config.pkg_comment)),
    ctx.Prop(
      "pkg_app_name_uppercase",
      ctx.Str(config.app_name |> string.uppercase),
    ),
    ctx.Prop("pkg_config_dir", ctx.Str(config.pkg_config_dir)),
    ctx.Prop("pkg_daemon_flags", ctx.Str(config.pkg_daemon_flags)),
    ctx.Prop(
      "pkg_dependencies",
      dependency_list_from_config(config.pkg_dependencies),
    ),
    ctx.Prop("pkg_description", ctx.Str(config.pkg_description)),
    ctx.Prop("pkg_env_file", ctx.Str(config.pkg_env_file)),
    ctx.Prop("pkg_maintainer", ctx.Str(config.pkg_maintainer)),
    ctx.Prop("pkg_origin", ctx.Str(config.pkg_origin)),
    ctx.Prop("pkg_path_extensions", ctx.Str(config.pkg_path_extensions)),
    ctx.Prop("pkg_prefix", ctx.Str(config.pkg_prefix)),
    ctx.Prop("pkg_proc_name", ctx.Str(config.pkg_proc_name)),
    ctx.Prop("pkg_user_name", ctx.Str(config.pkg_user_name)),
    ctx.Prop("pkg_var_dir", ctx.Str(config.pkg_var_dir)),
  ]

  let full_prop_list = list.append(pairs_prop_list, standard_prop_list)
  let full_prop_list = case config.pkg_root_dir {
    Some(root_dir) ->
      [
        ctx.Prop("pkg_root_dir", ctx.Str(root_dir)),
        ctx.Prop("pkg_root_dir_defined", ctx.Bool(True)),
      ]
      |> list.append(full_prop_list)
    _ ->
      [
        ctx.Prop("pkg_root_dir_defined", ctx.Bool(False)),
      ]
      |> list.append(full_prop_list)
  }
  let full_prop_list = case config.pkg_user_uid {
    Some(uid) ->
      [
        ctx.Prop("pkg_user_uid", ctx.Str(uid)),
        ctx.Prop("pkg_user_uid_defined", ctx.Bool(True)),
      ]
      |> list.append(full_prop_list)
    _ ->
      [
        ctx.Prop("pkg_user_uid_defined", ctx.Bool(False)),
      ]
      |> list.append(full_prop_list)
  }

  ctx.Dict(full_prop_list)
}

/// Return a list of dependency configs as handles ctx values.
fn dependency_list_from_config(deps: List(DependencyConfig)) -> ctx.Value {
  deps
  |> list.map(dependency_from_config)
  |> list.map(fn(dep) { ctx.Dict([ctx.Prop("dep", dep)]) })
  |> ctx.List
}

/// Return a dependency config as a handles ctx value.
fn dependency_from_config(dep: DependencyConfig) -> ctx.Value {
  ctx.Dict([
    ctx.Prop("dep_name", ctx.Str(dep.name)),
    ctx.Prop("dep_version", ctx.Str(dep.version)),
    ctx.Prop("dep_origin", ctx.Str(dep.origin)),
  ])
}

/// Reify a template and a context and save as a file in the staging directory.
fn project_template(
  template_path: String,
  context: ctx.Value,
  staging_dir: String,
  partial_templates: List(#(String, handles.Template)),
) -> Result(String, AppError) {
  // load template
  case simplifile.read(template_path) {
    Error(e) -> Error(UnableToReadTemplate(template_path, e))
    Ok(template_text) -> {
      // compile template
      case handles.prepare(template_text) {
        Error(e) -> Error(UnableToPrepareTemplate(template_path, e))
        Ok(template) -> {
          // project template
          let projected_template_path =
            new_projected_template_path(template_path, staging_dir)
          let projected_template_dir_path =
            filepath.directory_name(projected_template_path)
          use _ <- result.try(
            case simplifile.is_directory(projected_template_dir_path) {
              Ok(True) -> Ok(Nil)
              Ok(False) -> {
                case
                  simplifile.create_directory_all(projected_template_dir_path)
                {
                  Ok(_) -> Ok(Nil)
                  Error(e) ->
                    Error(UnableToCreateProjectedTemplateDirectory(
                      projected_template_dir_path,
                      e,
                    ))
                }
              }
              Error(e) ->
                Error(UnableToCheckForMissingProjectedTemplateDirectory(
                  projected_template_dir_path,
                  e,
                ))
            },
          )
          case handles.run(template, context, partial_templates) {
            Error(e) ->
              Error(UnableToProjectTemplate(
                template_path,
                projected_template_path,
                e,
              ))
            Ok(projected_text) -> {
              // save the projection (reified template)
              case
                simplifile.write(
                  projected_template_path,
                  projected_text |> string_tree.to_string,
                )
              {
                Error(e) -> {
                  Error(UnableToWriteProjectedTemplate(
                    template_path,
                    projected_template_path,
                    e,
                  ))
                }
                Ok(_) -> Ok(projected_template_path)
              }
            }
          }
        }
      }
    }
  }
}

/// Return the staging path for a reified template. This only works for templates.
///
/// Example:
///   template_path: /a/b/c/foo.bar.template, staging_dir: /bing/baz
///   -> projected_template_path = /bing/baz/foo.bar
fn new_projected_template_path(
  template_path: String,
  staging_dir: String,
) -> String {
  template_path
  |> filepath.base_name
  |> string.split(".")
  |> list.reverse
  |> list.drop(1)
  |> list.reverse
  |> string.join(".")
  |> filepath.join(staging_dir, _)
}

/// Invoke the FreeBSD 'pkg create' command via a shell. This creates the package in the output_dir.
fn build_package(
  metadata_dir: String,
  staging_dir: String,
  output_dir: String,
) -> Result(String, AppError) {
  let args = [
    "create",
    "-m",
    metadata_dir,
    "-r",
    staging_dir,
    "-p",
    metadata_dir <> "/" <> pkg_plist,
    "-o",
    output_dir,
  ]
  logging.log(logging.Debug, "command: pkg " <> args |> string.join(" "))
  shellout.command(run: "pkg", in: ".", with: args, opt: [])
  |> result.map_error(UnableToBuildPackage)
  |> result.try(fn(_) {
    logging.log(logging.Debug, "ls " <> output_dir)
    shellout.command(run: "/bin/ls", in: ".", with: [output_dir], opt: [])
    |> result.map_error(UnableToListBuiltPackages)
  })
}
