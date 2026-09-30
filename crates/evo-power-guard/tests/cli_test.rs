use std::fs::{self, File, OpenOptions};
use std::io::Write;
use std::os::unix::fs::FileExt;
use std::path::{Path, PathBuf};
use std::process::Command;

use evo_power_guard::cli::{Cli, Commands};
use evo_power_guard::cli_runner::CliRunner;
use evo_power_guard::guard_daemon::GuardDaemon;
use evo_power_guard::hardware::PowerMode;
use tempfile::tempdir;

const MOCK_EC_SIZE: usize = 256;
const P_MODE_OFFSET: u64 = 0x31;
const FAN1_DUTY_OFFSET: u64 = 0x33;
const FAN2_DUTY_OFFSET: u64 = 0x34;

#[test]
fn cli_parses_status_subcommand() {
    let cli = Cli::try_parse_from(["evo-power-guard", "status"]).unwrap();
    assert_eq!(cli.command(), &Commands::Status);
}

#[test]
fn cli_parses_check_subcommand() {
    let cli = Cli::try_parse_from(["evo-power-guard", "check"]).unwrap();
    assert_eq!(cli.command(), &Commands::Check);
}

#[test]
fn cli_parses_set_mode_subcommand() {
    let cli = Cli::try_parse_from(["evo-power-guard", "set-mode", "performance"]).unwrap();
    assert_eq!(cli.command(), &Commands::SetMode { mode: PowerMode::Performance });
}

#[test]
fn cli_parses_daemon_subcommand_with_flags() {
    let cli = Cli::try_parse_from(["evo-power-guard", "daemon", "--interval-ms", "3500"]).unwrap();
    assert_eq!(
        cli.command(),
        &Commands::Daemon { interval_ms: Some(3500), target_mode: PowerMode::Performance }
    );
}

#[test]
fn cli_binary_displays_help_successfully() {
    let binary = env!("CARGO_BIN_EXE_evo-power-guard");
    let output = Command::new(binary)
        .arg("--help")
        .output()
        .expect("binary failed to execute");
    assert!(output.status.success());
    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(stdout.contains("evo-power-guard"));
    assert!(stdout.contains("status"));
    assert!(stdout.contains("check"));
    assert!(stdout.contains("set-mode"));
    assert!(stdout.contains("daemon"));
}

#[test]
fn cli_binary_displays_subcommand_help_successfully() {
    let binary = env!("CARGO_BIN_EXE_evo-power-guard");
    let output = Command::new(binary)
        .args(["set-mode", "--help"])
        .output()
        .expect("binary failed to execute");
    assert!(output.status.success());
    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(stdout.contains("mode"));
}

#[test]
fn cli_binary_fails_on_invalid_argument() {
    let binary = env!("CARGO_BIN_EXE_evo-power-guard");
    let output = Command::new(binary)
        .arg("invalid-subcommand")
        .output()
        .expect("binary failed to execute");
    assert!(!output.status.success());
}

#[test]
fn cli_runner_executes_status_with_mock_hardware() {
    let dir = tempdir().unwrap();
    let rapl_path = create_mock_rapl(dir.path());
    let ec_path = create_mock_ec(dir.path());
    let hwmon_path = create_mock_hwmon(dir.path());

    let runner = CliRunner::new(rapl_path, ec_path, hwmon_path, 1000);
    assert!(runner.run(&Commands::Status).is_ok());
}

#[test]
fn cli_runner_executes_set_mode_with_mock_ec() {
    let dir = tempdir().unwrap();
    let rapl_path = create_mock_rapl(dir.path());
    let ec_path = create_mock_ec(dir.path());
    let hwmon_path = create_mock_hwmon(dir.path());

    let runner = CliRunner::new(rapl_path, ec_path.clone(), hwmon_path, 1000);
    let result = runner.run(&Commands::SetMode { mode: PowerMode::Quiet });
    assert!(result.is_ok());

    let p_mode_byte = read_byte_at(&ec_path, P_MODE_OFFSET);
    assert_eq!(p_mode_byte, PowerMode::Quiet.to_ec_byte());
}

#[test]
fn cli_runner_errors_on_set_mode_when_ec_unavailable() {
    let dir = tempdir().unwrap();
    let rapl_path = create_mock_rapl(dir.path());
    let ec_path = dir.path().join("nonexistent_ec_file");
    let hwmon_path = create_mock_hwmon(dir.path());

    let runner = CliRunner::new(rapl_path, ec_path, hwmon_path, 1000);
    let result = runner.run(&Commands::SetMode { mode: PowerMode::Performance });
    assert!(result.is_err());
}

#[test]
fn guard_daemon_poll_once_and_telemetry_with_mock_hardware() {
    let dir = tempdir().unwrap();
    let rapl_path = create_mock_rapl(dir.path());
    let ec_path = create_mock_ec(dir.path());
    let hwmon_path = create_mock_hwmon(dir.path());
    let cpu_freq_base = create_mock_cpu(dir.path());
    let gpu_dpm_path = create_mock_gpu(dir.path());

    let mut daemon = GuardDaemon::new(
        100,
        PowerMode::Balanced,
        rapl_path,
        ec_path.clone(),
        hwmon_path,
        cpu_freq_base,
        gpu_dpm_path,
    );
    let telemetry = daemon.telemetry().unwrap();
    assert_eq!(telemetry.package_temp_c(), 55.0);
    assert_eq!(telemetry.package_power_w(), 42.0);

    daemon.poll_once();
    let p_mode = read_byte_at(&ec_path, P_MODE_OFFSET);
    assert_eq!(p_mode, PowerMode::Balanced.to_ec_byte());

    daemon.handover_to_firmware();
    assert_eq!(read_byte_at(&ec_path, FAN1_DUTY_OFFSET), 0x00);
    assert_eq!(read_byte_at(&ec_path, FAN2_DUTY_OFFSET), 0x00);
}

fn create_mock_rapl(parent: &Path) -> PathBuf {
    let path = parent.join("mock_rapl");
    fs::create_dir_all(&path).unwrap();
    fs::write(path.join("energy_uj"), "10000000\n").unwrap();
    fs::write(path.join("power"), "42000000\n").unwrap();
    fs::write(path.join("constraint_0_power_limit_uw"), "85000000\n").unwrap();
    path
}

fn create_mock_ec(parent: &Path) -> PathBuf {
    let path = parent.join("mock_ec_io");
    let file = File::create(&path).unwrap();
    file.set_len(MOCK_EC_SIZE as u64).unwrap();
    let mut initial = vec![0_u8; MOCK_EC_SIZE];
    initial[P_MODE_OFFSET as usize] = PowerMode::Balanced.to_ec_byte();
    initial[FAN1_DUTY_OFFSET as usize] = 0x80 | 50;
    initial[FAN2_DUTY_OFFSET as usize] = 0x80 | 50;
    let mut writer = OpenOptions::new().write(true).open(&path).unwrap();
    writer.write_all(&initial).unwrap();
    path
}

fn create_mock_hwmon(parent: &Path) -> PathBuf {
    let path = parent.join("mock_hwmon");
    fs::create_dir_all(&path).unwrap();
    fs::write(path.join("name"), "k10temp\n").unwrap();
    fs::write(path.join("temp1_input"), "55000\n").unwrap();
    fs::write(path.join("power1_average"), "42000000\n").unwrap();
    path
}

fn create_mock_cpu(parent: &Path) -> PathBuf {
    let base = parent.join("mock_cpu");
    let cpu0 = base.join("cpu0/cpufreq");
    fs::create_dir_all(&cpu0).unwrap();
    fs::write(cpu0.join("scaling_max_freq"), "5187500\n").unwrap();
    fs::write(cpu0.join("boost"), "1\n").unwrap();
    base
}

fn create_mock_gpu(parent: &Path) -> PathBuf {
    let path = parent.join("power_dpm_force_performance_level");
    fs::write(&path, "high\n").unwrap();
    path
}
fn read_byte_at(path: &Path, offset: u64) -> u8 {
    let file = File::open(path).unwrap();
    let mut byte = [0_u8; 1];
    file.read_exact_at(&mut byte, offset).unwrap();
    byte[0]
}
