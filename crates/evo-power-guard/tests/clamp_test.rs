use std::fs::{self, File, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::time::Duration;

use evo_power_guard::guard_daemon::GuardDaemon;
use evo_power_guard::hardware::{ClampLever, PowerMode};
use tempfile::tempdir;

const MOCK_EC_SIZE: usize = 256;
const P_MODE_OFFSET: u64 = 0x31;
const FAN1_DUTY_OFFSET: u64 = 0x33;
const FAN2_DUTY_OFFSET: u64 = 0x34;

#[test]
fn clamp_lever_engages_and_updates_all_files() {
    let dir = tempdir().unwrap();
    let cpu_base = create_mock_cpu_topology(dir.path());
    let gpu_path = create_mock_gpu_file(dir.path());

    let mut lever = ClampLever::new(cpu_base.clone(), gpu_path.clone());
    assert!(!lever.is_capped());

    let engage_result = lever.engage_clamp();
    assert!(engage_result.is_ok());
    assert!(lever.is_capped());
    assert_eq!(lever.saved_max_freq_khz(), 5_187_500);

    assert_eq!(read_file_trimmed(&cpu_base.join("cpu0/cpufreq/scaling_max_freq")), "3000000");
    assert_eq!(read_file_trimmed(&cpu_base.join("cpu1/cpufreq/scaling_max_freq")), "3000000");
    assert_eq!(read_file_trimmed(&cpu_base.join("cpu0/cpufreq/boost")), "0");
    assert_eq!(read_file_trimmed(&gpu_path), "low");
}

#[test]
fn clamp_lever_releases_and_restores_original_state() {
    let dir = tempdir().unwrap();
    let cpu_base = create_mock_cpu_topology(dir.path());
    let gpu_path = create_mock_gpu_file(dir.path());

    let mut lever = ClampLever::new(cpu_base.clone(), gpu_path.clone());
    assert!(lever.engage_clamp().is_ok());
    assert!(lever.is_capped());

    let release_result = lever.release_clamp();
    assert!(release_result.is_ok());
    assert!(!lever.is_capped());

    assert_eq!(read_file_trimmed(&cpu_base.join("cpu0/cpufreq/scaling_max_freq")), "5187500");
    assert_eq!(read_file_trimmed(&cpu_base.join("cpu1/cpufreq/scaling_max_freq")), "5187500");
    assert_eq!(read_file_trimmed(&cpu_base.join("cpu0/cpufreq/boost")), "1");
    assert_eq!(read_file_trimmed(&gpu_path), "high");
}

#[test]
fn clamp_lever_engage_and_release_are_idempotent() {
    let dir = tempdir().unwrap();
    let cpu_base = create_mock_cpu_topology(dir.path());
    let gpu_path = create_mock_gpu_file(dir.path());

    let mut lever = ClampLever::new(cpu_base.clone(), gpu_path.clone());
    assert!(lever.engage_clamp().is_ok());
    assert_eq!(lever.saved_max_freq_khz(), 5_187_500);

    assert!(lever.engage_clamp().is_ok());
    assert_eq!(lever.saved_max_freq_khz(), 5_187_500);

    assert!(lever.release_clamp().is_ok());
    assert!(!lever.is_capped());

    assert!(lever.release_clamp().is_ok());
    assert!(!lever.is_capped());
    assert_eq!(read_file_trimmed(&cpu_base.join("cpu0/cpufreq/scaling_max_freq")), "5187500");
}

#[test]
fn clamp_lever_tolerates_missing_gpu_and_non_fatal_write_errors() {
    let dir = tempdir().unwrap();
    let cpu_base = create_mock_cpu_topology(dir.path());
    let invalid_gpu_path = dir.path().join("nonexistent_dir/gpu_level");

    let mut lever = ClampLever::new(cpu_base.clone(), invalid_gpu_path);
    assert!(lever.engage_clamp().is_ok());
    assert!(lever.is_capped());
    assert_eq!(read_file_trimmed(&cpu_base.join("cpu0/cpufreq/scaling_max_freq")), "3000000");

    assert!(lever.release_clamp().is_ok());
    assert!(!lever.is_capped());
    assert_eq!(read_file_trimmed(&cpu_base.join("cpu0/cpufreq/scaling_max_freq")), "5187500");
}

#[test]
fn guard_daemon_hysteresis_engages_on_high_power_and_releases_after_three_safe_polls() {
    let dir = tempdir().unwrap();
    let rapl_path = create_mock_rapl(dir.path());
    let ec_path = create_mock_ec(dir.path());
    let hwmon_path = create_mock_hwmon(dir.path());
    let cpu_base = create_mock_cpu_topology(dir.path());
    let gpu_path = create_mock_gpu_file(dir.path());

    let mut daemon = GuardDaemon::new(
        100,
        PowerMode::Balanced,
        rapl_path.clone(),
        ec_path,
        hwmon_path,
        cpu_base.clone(),
        gpu_path,
    )
    .with_clamp_dwell(Duration::ZERO);

    write_power_microwatts(&rapl_path, 95_000_000);
    daemon.poll_once();
    assert!(daemon.clamp_lever().is_capped());
    assert_eq!(read_file_trimmed(&cpu_base.join("cpu0/cpufreq/scaling_max_freq")), "3000000");
    assert_eq!(daemon.consecutive_safe_polls(), 0);

    write_power_microwatts(&rapl_path, 80_000_000);
    daemon.poll_once();
    assert!(daemon.clamp_lever().is_capped());
    assert_eq!(daemon.consecutive_safe_polls(), 1);

    daemon.poll_once();
    assert!(daemon.clamp_lever().is_capped());
    assert_eq!(daemon.consecutive_safe_polls(), 2);

    daemon.poll_once();
    assert!(!daemon.clamp_lever().is_capped());
    assert_eq!(read_file_trimmed(&cpu_base.join("cpu0/cpufreq/scaling_max_freq")), "5187500");
    assert_eq!(daemon.consecutive_safe_polls(), 0);
}

#[test]
fn guard_daemon_holds_clamp_for_minimum_dwell_despite_safe_power() {
    let dir = tempdir().unwrap();
    let rapl_path = create_mock_rapl(dir.path());
    let ec_path = create_mock_ec(dir.path());
    let hwmon_path = create_mock_hwmon(dir.path());
    let cpu_base = create_mock_cpu_topology(dir.path());
    let gpu_path = create_mock_gpu_file(dir.path());

    let mut daemon = GuardDaemon::new(
        100,
        PowerMode::Balanced,
        rapl_path.clone(),
        ec_path,
        hwmon_path,
        cpu_base.clone(),
        gpu_path,
    );

    write_power_microwatts(&rapl_path, 95_000_000);
    daemon.poll_once();
    assert!(daemon.clamp_lever().is_capped());

    write_power_microwatts(&rapl_path, 80_000_000);
    daemon.poll_once();
    daemon.poll_once();
    daemon.poll_once();
    daemon.poll_once();
    assert!(daemon.clamp_lever().is_capped());
    assert_eq!(
        read_file_trimmed(&cpu_base.join("cpu0/cpufreq/scaling_max_freq")),
        "3000000"
    );
}

fn create_mock_cpu_topology(parent: &Path) -> PathBuf {
    let base = parent.join("mock_cpu");
    let cpu0 = base.join("cpu0/cpufreq");
    let cpu1 = base.join("cpu1/cpufreq");
    fs::create_dir_all(&cpu0).unwrap();
    fs::create_dir_all(&cpu1).unwrap();
    fs::write(cpu0.join("scaling_max_freq"), "5187500\n").unwrap();
    fs::write(cpu0.join("boost"), "1\n").unwrap();
    fs::write(cpu1.join("scaling_max_freq"), "5187500\n").unwrap();
    base
}

fn create_mock_gpu_file(parent: &Path) -> PathBuf {
    let path = parent.join("power_dpm_force_performance_level");
    fs::write(&path, "high\n").unwrap();
    path
}

fn create_mock_rapl(parent: &Path) -> PathBuf {
    let path = parent.join("mock_rapl");
    fs::create_dir_all(&path).unwrap();
    fs::write(path.join("energy_uj"), "10000000\n").unwrap();
    fs::write(path.join("power"), "42000000\n").unwrap();
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

fn write_power_microwatts(rapl_path: &Path, microwatts: u64) {
    fs::write(rapl_path.join("power"), format!("{microwatts}\n")).unwrap();
}

fn read_file_trimmed(path: &Path) -> String {
    fs::read_to_string(path).unwrap().trim().to_string()
}
