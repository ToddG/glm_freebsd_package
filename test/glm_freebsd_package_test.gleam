import birdie
import filepath
import gleam/erlang/application
import gleam/list
import gleam/option
import gleam/result
import gleam/set
import gleam/string
import gleeunit
import glm_freebsd_package/packager
import simplifile
import temporary
import tom

pub fn main() -> Nil {
  gleeunit.main()
}

// path to the default templates for things like +POST_INSTALL, etc.
// pub const default_templates_path = "./priv/templates/freebsd"
pub const default_templates_path = "templates/freebsd"

pub fn gleam_toml_text() {
  "
name = \"example\"
version = \"1.0.0\"
description = \"description\"

[freebsd]
pkg_origin=\"example_company/example\"
pkg_comment=\"A simple one-line comment about this packge.\"
pkg_arch=\"freebsd:15:x86:64\"
pkg_www=\"https://github.com/toddg/some_repo\"
pkg_license_logic=\"single\"
pkg_licenses=[\"MIT\"]
pkg_description = \"\"\"
line 01 : multi-line-package description....
line 02 : multi-line-package description....
line 03 : multi-line-package description....
line 04 : multi-line-package description....
line 05 : multi-line-package description....
\"\"\"
pkg_maintainer = \"package_maintainer@example.com\"
pkg_config_dir = \"/tmp/example\"
pkg_env_file = \"example.env\"
pkg_user_name = \"example\"
pkg_user_uid = \"1234\"
pkg_proc_name = \"beam.smp\"
pkg_path_extensions = \"/usr/local/lib/erlang28/bin\"
pkg_var_dir=\"/var/example\"
pkg_prefix= \"/usr/local\"
pkg_command=\"entrypoint.sh\"
pkg_command_args=\"run\"
pkg_daemon_flags=\"\"
pkg_plist_lines=[
  {
    type=\"file\",
    src=\"test/data/wibble.txt\",
    dest=\"/usr/local/wibble/wibble.txt\",
    mode=\"0700\",
    owner=\"\",
    group=\"\",
  },
  {
    type=\"directory\",
    src_dir=\"test/data/baz\",
    dest_dir=\"/usr/local/wobble\",
    mode=\"0700\",
    owner=\"\",
    group=\"\",
  },
  {
    type=\"dir_directive\",
    path=\"/usr/local/wibble\"
  },
  {
    type=\"dir_directive\",
    path=\"/usr/local/wibble\"
  },
  {
    type=\"include_directive\",
    path=\"relative_path_to_another_plist_file\"
  }
]

[[freebsd.dependencies]]
name = \"vim\"
version = \"9.2.0204\"
origin = \"editors/vim\"

[[freebsd.dependencies]]
name = \"tree\"
version = \"2.2.1\"
origin = \"sysutils/tree\"

[[freebsd.pairs]]
key = \"key1\"
value = \"value1\"

[[freebsd.pairs]]
key = \"key2\"
value = \"value2\"
"
}

// gleeunit test functions end in `_test`
pub fn load_toml_test() {
  // write temporary gleam.toml
  let assert Ok(_) =
    temporary.create(temporary.file(), fn(file) {
      let assert Ok(_) = simplifile.write(gleam_toml_text(), to: file)
      // load gleam.toml
      let assert Ok(toml) = packager.load_toml(file)
      let assert Ok(config) = packager.new_config(toml)
      // validate the config returned
      assert config.app_name == "example"
      assert config.app_version == "1.0.0"
      assert config.pkg_user_name == "example"
      let assert option.Some(uid) = config.pkg_user_uid
      assert uid == "1234"
      assert config.pkg_description |> string.starts_with("line 01")
      assert config.pkg_maintainer == "package_maintainer@example.com"
      assert config.pkg_config_dir == "/tmp/example"
      assert config.pkg_path_extensions == "/usr/local/lib/erlang28/bin"
      assert config.pkg_var_dir == "/var/example"
      assert config.pkg_command == "entrypoint.sh"
      assert config.pkg_command_args == "run"
      assert list.length(config.pkg_dependencies) == 2
      let _ =
        config.pkg_dependencies
        |> list.map(fn(dep) {
          case dep.name {
            "vim" -> {
              assert dep.version == "9.2.0204"
              assert dep.origin == "editors/vim"
            }
            "tree" -> {
              assert dep.version == "2.2.1"
              assert dep.origin == "sysutils/tree"
            }
            _ -> {
              panic
            }
          }
        })
      assert list.length(config.pkg_pairs) == 2
      let _ =
        config.pkg_pairs
        |> list.map(fn(p) {
          case p.key {
            "key1" -> {
              assert p.value == "value1"
            }
            "key2" -> {
              assert p.value == "value2"
            }
            _ -> {
              panic
            }
          }
        })
    })
}

pub fn gen_staging_test() {
  let assert Ok(priv_dir) = application.priv_directory("glm_freebsd_package")
  let toml_text = gleam_toml_text()
  let assert Ok(toml_dict) = tom.parse(toml_text)
  let assert Ok(cfg) = packager.new_config(toml_dict)
  let _ =
    temporary.create(temporary.directory(), fn(temp_dir) {
      // create test resources
      let app_dir = filepath.join(temp_dir, "app")
      let erlang_shipment_dir = filepath.join(app_dir, "build/erlang-shipment")
      let assert Ok(_) = simplifile.create_directory_all(erlang_shipment_dir)
      let assert Ok(_) =
        simplifile.append(
          filepath.join(erlang_shipment_dir, "dummy_shipment_file"),
          "# dummy file",
        )
      let data_dir = filepath.join(app_dir, "test/data")
      let baz_dir = filepath.join(data_dir, "baz")
      let assert Ok(_) = simplifile.create_directory_all(baz_dir)
      let assert Ok(_) =
        simplifile.append(filepath.join(data_dir, "wibble.txt"), "# wibble")
      let assert Ok(_) =
        simplifile.append(filepath.join(baz_dir, "wobble.txt"), "# wobble")

      let staging_dir = filepath.join(temp_dir, "staging")
      let metadata_dir = filepath.join(temp_dir, "metadata")
      let default_templates_path =
        filepath.join(priv_dir, default_templates_path)
      let assert Ok(True) = simplifile.is_directory(default_templates_path)
      let assert Ok(_) =
        packager.gen_staging(
          cfg,
          app_dir,
          metadata_dir,
          staging_dir,
          default_templates_path,
          Error(Nil),
          erlang_shipment_dir,
        )
      // verify that expected files are present
      let assert Ok(metadata_files) = simplifile.get_files(metadata_dir)
      let file_names_set =
        metadata_files |> list.map(filepath.base_name) |> set.from_list
      assert set.contains(file_names_set, "+MANIFEST")
      assert set.contains(file_names_set, "+POST_INSTALL")
      assert set.contains(file_names_set, "+PRE_DEINSTALL")
      assert set.contains(file_names_set, "rc")
      assert set.contains(file_names_set, "rc_conf")
      assert set.contains(file_names_set, "pkg-plist")

      //verify metadata file contents
      let metadata_dir_len = string.length(metadata_dir)
      let _ =
        metadata_files
        |> list.map(string.drop_start(_, metadata_dir_len))
        |> list.map(birdie_file_contents(metadata_dir, _, "standard_templates_"))

      //verify staging file contents
      let assert Ok(staging_files) = simplifile.get_files(staging_dir)
      let staging_dir_len = string.length(staging_dir)
      let _ =
        staging_files
        |> list.map(string.drop_start(_, staging_dir_len))
        |> list.map(birdie_file_contents(
          staging_dir,
          _,
          "standard_staging_files_",
        ))
    })
  Nil
}

fn birdie_file_contents(staging_dir: String, f: String, title_prefix: String) {
  let assert Ok(contents) = simplifile.read(filepath.join(staging_dir, f))
  contents |> birdie.snap(title_prefix <> f)
}

/// use customized templates
pub fn gen_custom_templates_test() {
  let assert Ok(priv_dir) = application.priv_directory("glm_freebsd_package")
  let _ =
    temporary.create(temporary.directory(), fn(temp_dir) {
      // create test resources
      let app_dir = filepath.join(temp_dir, "app")
      let erlang_shipment_dir = filepath.join(app_dir, "build/erlang-shipment")
      let assert Ok(_) = simplifile.create_directory_all(erlang_shipment_dir)
      let assert Ok(_) =
        simplifile.append(
          filepath.join(erlang_shipment_dir, "dummy_shipment_file"),
          "# dummy file",
        )
      let data_dir = filepath.join(app_dir, "test/data")
      let baz_dir = filepath.join(data_dir, "baz")
      let assert Ok(_) = simplifile.create_directory_all(baz_dir)
      let assert Ok(_) =
        simplifile.append(filepath.join(data_dir, "wibble.txt"), "# wibble")
      let assert Ok(_) =
        simplifile.append(filepath.join(baz_dir, "wobble.txt"), "# wobble")

      let custom_templates_dir = filepath.join(temp_dir, "templates")
      let staging_dir = filepath.join(temp_dir, "staging")
      let metadata_dir = filepath.join(temp_dir, "metadata")
      let _ = case simplifile.create_directory_all(staging_dir) {
        Error(_) -> {
          let assert Ok(_) = simplifile.clear_directory(staging_dir)
        }
        _ -> Ok(Nil)
      }
      let _ = case simplifile.create_directory_all(custom_templates_dir) {
        Error(_) -> {
          let assert Ok(_) = simplifile.clear_directory(custom_templates_dir)
        }
        _ -> Ok(Nil)
      }
      let assert Ok(templates) =
        packager.copy_raw_templates(custom_templates_dir)

      let assert Ok(_) =
        templates
        |> list.map(simplifile.append(
          _,
          "# key1={{ pair_key1 }}\n# key2={{ pair_key2 }}\n",
        ))
        |> result.all

      let toml_text = gleam_toml_text()
      let assert Ok(toml_dict) = tom.parse(toml_text)
      let assert Ok(cfg) = packager.new_config(toml_dict)
      let assert Ok(True) = simplifile.is_directory(custom_templates_dir)
      let default_templates_path =
        filepath.join(priv_dir, default_templates_path)
      let assert Ok(_) =
        packager.gen_staging(
          cfg,
          app_dir,
          metadata_dir,
          staging_dir,
          default_templates_path,
          custom_templates_dir |> Ok,
          erlang_shipment_dir,
        )

      // verify that expected files are present
      let assert Ok(metadata_files) = simplifile.get_files(metadata_dir)
      let file_names_set =
        metadata_files |> list.map(filepath.base_name) |> set.from_list
      assert set.contains(file_names_set, "+MANIFEST")
      assert set.contains(file_names_set, "+POST_INSTALL")
      assert set.contains(file_names_set, "+PRE_DEINSTALL")
      assert set.contains(file_names_set, "rc")
      assert set.contains(file_names_set, "rc_conf")
      assert set.contains(file_names_set, "pkg-plist")

      //verify metadata file contents
      let metadata_dir_len = string.length(metadata_dir)
      let _ =
        metadata_files
        |> list.map(string.drop_start(_, metadata_dir_len))
        |> list.map(birdie_file_contents(metadata_dir, _, "custom_templates_"))

      //verify staging file contents
      let assert Ok(staging_files) = simplifile.get_files(staging_dir)
      let staging_dir_len = string.length(staging_dir)
      let _ =
        staging_files
        |> list.map(string.drop_start(_, staging_dir_len))
        |> list.map(birdie_file_contents(
          staging_dir,
          _,
          "custom_staging_files_",
        ))
    })
  Nil
}
