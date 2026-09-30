use evo_power_guard::cli::Cli;
use evo_power_guard::cli_runner::CliRunner;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let cli = Cli::parse();
    CliRunner::with_system_defaults().run(cli.command())
}
