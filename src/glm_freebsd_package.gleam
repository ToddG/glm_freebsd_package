import argv
import clip.{type Command}
import clip/help
import clip/opt.{type Opt}
import gleam/io
import gleam/string
import glm_freebsd_package/packager

type App {
  App(
    app_dir: String,
    default_templates_dir: String,
    user_templates_dir: Result(String, Nil),
    staging_dir: String,
    output_dir: String,
  )
}

fn app_dir_path_opt() -> Opt(String) {
  opt.new("application")
  |> opt.short("a")
  |> opt.default(".")
  |> opt.help(
    "gleam target application directory (location of the target app's gleam.toml file)",
  )
}

fn default_templates_dir_path_opt() -> Opt(String) {
  opt.new("default_templates")
  |> opt.short("dt")
  |> opt.default("/usr/local/etc/glm_freebsd_package/templates")
  |> opt.help("path to default templates directory")
}

fn user_templates_dir_path_opt() -> Opt(Result(String, Nil)) {
  opt.new("user_templates")
  |> opt.short("ut")
  |> opt.optional
  |> opt.help("path to user templates directory")
}

fn output_dir_path_opt() -> Opt(String) {
  opt.new("output")
  |> opt.short("o")
  |> opt.default("./packages")
  |> opt.help("path to place generated (output) files (will create directory)")
}

fn staging_dir_path_opt() -> Opt(String) {
  opt.new("staging")
  |> opt.short("s")
  |> opt.default("./staging")
  |> opt.help(
    "path to place intermediate (staging) files (will create directory)",
  )
}

fn command() -> Command(App) {
  clip.command({
    use app_dir <- clip.parameter
    use default_templates_dir <- clip.parameter
    use user_templates_dir <- clip.parameter
    use staging_dir <- clip.parameter
    use output_dir <- clip.parameter

    App(
      app_dir:,
      default_templates_dir:,
      user_templates_dir:,
      staging_dir:,
      output_dir:,
    )
  })
  |> clip.opt(app_dir_path_opt())
  |> clip.opt(default_templates_dir_path_opt())
  |> clip.opt(user_templates_dir_path_opt())
  |> clip.opt(staging_dir_path_opt())
  |> clip.opt(output_dir_path_opt())
}

pub fn main() -> Nil {
  let result =
    command()
    |> clip.help(help.simple(
      "package",
      "package target gleam application as a FreeBSD package with service scripts",
    ))
    |> clip.run(argv.load().arguments)

  case result {
    Error(e) -> io.println_error(e)
    Ok(app) -> {
      case
        packager.run(
          app.app_dir,
          app.default_templates_dir,
          app.user_templates_dir,
          app.staging_dir,
          app.output_dir,
        )
      {
        Error(e) -> io.println_error(e |> string.inspect)
        Ok(o) -> io.println(o)
      }
      Nil
    }
  }
}
