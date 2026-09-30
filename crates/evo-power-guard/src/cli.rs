use std::ffi::OsString;

use clap::{Parser, Subcommand};

use crate::hardware::PowerMode;

#[derive(Parser, Debug, PartialEq)]
#[command(name = "evo-power-guard")]
pub struct Cli {
    #[command(subcommand)]
    command: Commands,
}

#[derive(Subcommand, Clone, Copy, Debug, Eq, PartialEq)]
pub enum Commands {
    #[command(alias = "Status")]
    Status,
    #[command(alias = "Check")]
    Check,
    #[command(alias = "SetMode")]
    SetMode {
        #[arg(value_enum)]
        mode: PowerMode,
    },
    #[command(alias = "Daemon")]
    Daemon {
        #[arg(short, long)]
        interval_ms: Option<u64>,
        #[arg(long, default_value = "performance")]
        target_mode: PowerMode,
    },
}

impl Cli {
    pub fn new(command: Commands) -> Self {
        Self { command }
    }

    pub fn command(&self) -> &Commands {
        &self.command
    }

    pub fn try_parse_from<I, T>(itr: I) -> Result<Self, clap::Error>
    where
        I: IntoIterator<Item = T>,
        T: Into<OsString> + Clone,
    {
        <Self as Parser>::try_parse_from(itr)
    }

    pub fn parse() -> Self {
        <Self as Parser>::parse()
    }
}

#[cfg(test)] mod tests {
    use super::*;

    #[test]
    fn parse_status_command() {
        let cli = Cli::try_parse_from(["evo-power-guard", "status"]).unwrap();
        assert_eq!(cli.command(), &Commands::Status);
    }

    #[test]
    fn parse_check_command() {
        let cli = Cli::try_parse_from(["evo-power-guard", "check"]).unwrap();
        assert_eq!(cli.command(), &Commands::Check);
    }

    #[test]
    fn parse_set_mode_balanced() {
        let cli = Cli::try_parse_from(["evo-power-guard", "set-mode", "balanced"]).unwrap();
        assert_eq!(cli.command(), &Commands::SetMode { mode: PowerMode::Balanced });
    }

    #[test]
    fn parse_set_mode_performance() {
        let cli = Cli::try_parse_from(["evo-power-guard", "set-mode", "performance"]).unwrap();
        assert_eq!(cli.command(), &Commands::SetMode { mode: PowerMode::Performance });
    }

    #[test]
    fn parse_set_mode_quiet() {
        let cli = Cli::try_parse_from(["evo-power-guard", "set-mode", "quiet"]).unwrap();
        assert_eq!(cli.command(), &Commands::SetMode { mode: PowerMode::Quiet });
    }

    #[test]
    fn parse_daemon_default() {
        let cli = Cli::try_parse_from(["evo-power-guard", "daemon"]).unwrap();
        assert_eq!(
            cli.command(),
            &Commands::Daemon { interval_ms: None, target_mode: PowerMode::Performance }
        );
    }

    #[test]
    fn parse_daemon_with_long_flag() {
        let cli = Cli::try_parse_from(["evo-power-guard", "daemon", "--interval-ms", "3000"]).unwrap();
        assert_eq!(
            cli.command(),
            &Commands::Daemon { interval_ms: Some(3000), target_mode: PowerMode::Performance }
        );
    }

    #[test]
    fn parse_daemon_with_short_flag() {
        let cli = Cli::try_parse_from(["evo-power-guard", "daemon", "-i", "1500"]).unwrap();
        assert_eq!(
            cli.command(),
            &Commands::Daemon { interval_ms: Some(1500), target_mode: PowerMode::Performance }
        );
    }

    #[test]
    fn parse_daemon_with_quiet_target() {
        let cli = Cli::try_parse_from(["evo-power-guard", "daemon", "--target-mode", "quiet"]).unwrap();
        assert_eq!(
            cli.command(),
            &Commands::Daemon { interval_ms: None, target_mode: PowerMode::Quiet }
        );
    }

    #[test]
    fn parse_help_flag() {
        let result = Cli::try_parse_from(["evo-power-guard", "--help"]);
        assert!(result.is_err());
    }

    #[test]
    fn parse_invalid_subcommand_fails() {
        let result = Cli::try_parse_from(["evo-power-guard", "unknown"]);
        assert!(result.is_err());
    }

    #[test]
    fn cli_constructor_and_getter() {
        let cli = Cli::new(Commands::Status);
        assert_eq!(cli.command(), &Commands::Status);
    }
}
