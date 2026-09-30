use std::error::Error;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::thread;
use std::time::{Duration, Instant};

use crate::cli::Commands;
use crate::guard_daemon::GuardDaemon;
use crate::hardware::{CheckReport, EcController, HwmonReader, PowerMode, RaplController};

const DEFAULT_RAPL_PATH: &str = "/sys/class/powercap/intel-rapl:0";
const DEFAULT_EC_PATH: &str = "/sys/kernel/debug/ec/ec0/io";
const DEFAULT_HWMON_PATH: &str = "/sys/class/hwmon";
const DEFAULT_INTERVAL_MS: u64 = 2000;
const DEFAULT_CPU_FREQ_BASE: &str = "/sys/devices/system/cpu";
const DEFAULT_GPU_DPM_PATH: &str =
    "/sys/bus/pci/devices/0000:c5:00.0/power_dpm_force_performance_level";

pub struct CliRunner {
    rapl_path: PathBuf,
    ec_path: PathBuf,
    hwmon_path: PathBuf,
    default_interval_ms: u64,
}

impl CliRunner {
    pub fn new(
        rapl_path: PathBuf,
        ec_path: PathBuf,
        hwmon_path: PathBuf,
        default_interval_ms: u64,
    ) -> Self {
        Self {
            rapl_path,
            ec_path,
            hwmon_path,
            default_interval_ms,
        }
    }

    pub fn with_system_defaults() -> Self {
        let hwmon_path = Self::detect_hwmon_path().unwrap_or_else(|_| PathBuf::from(DEFAULT_HWMON_PATH));
        Self::new(
            PathBuf::from(DEFAULT_RAPL_PATH),
            PathBuf::from(DEFAULT_EC_PATH),
            hwmon_path,
            DEFAULT_INTERVAL_MS,
        )
    }

    pub fn rapl_path(&self) -> &Path {
        &self.rapl_path
    }

    pub fn ec_path(&self) -> &Path {
        &self.ec_path
    }

    pub fn hwmon_path(&self) -> &Path {
        &self.hwmon_path
    }

    pub fn default_interval_ms(&self) -> u64 {
        self.default_interval_ms
    }

    pub fn run(&self, command: &Commands) -> Result<(), Box<dyn Error>> {
        match command {
            Commands::Status => self.execute_status(),
            Commands::Check => self.execute_check(),
            Commands::SetMode { mode } => self.execute_set_mode(*mode),
            Commands::Daemon { interval_ms, target_mode } => {
                self.execute_daemon(*interval_ms, *target_mode)
            }
        }
    }

    fn execute_status(&self) -> Result<(), Box<dyn Error>> {
        let daemon = GuardDaemon::new(
            self.default_interval_ms,
            PowerMode::Balanced,
            self.rapl_path.clone(),
            self.ec_path.clone(),
            self.hwmon_path.clone(),
            PathBuf::from(DEFAULT_CPU_FREQ_BASE),
            PathBuf::from(DEFAULT_GPU_DPM_PATH),
        );
        let telemetry = daemon.telemetry()?;
        let json = serde_json::to_string_pretty(&telemetry)?;
        println!("{json}");
        Ok(())
    }

    fn execute_check(&self) -> Result<(), Box<dyn Error>> {
        let report = self.run_load_probe()?;
        let json = serde_json::to_string_pretty(&report)?;
        println!("{json}");
        Ok(())
    }

    fn execute_set_mode(&self, mode: PowerMode) -> Result<(), Box<dyn Error>> {
        let ec = EcController::new(self.ec_path.clone());
        match ec.is_available() {
            false => Err(io::Error::new(
                io::ErrorKind::NotFound,
                "embedded controller device is unavailable",
            )
            .into()),
            true => {
                ec.set_p_mode(mode)?;
                Ok(())
            }
        }
    }

    fn execute_daemon(
        &self,
        interval_ms: Option<u64>,
        target_mode: PowerMode,
    ) -> Result<(), Box<dyn Error>> {
        let interval = interval_ms.unwrap_or(self.default_interval_ms);
        let mut daemon = GuardDaemon::new(
            interval,
            target_mode,
            self.rapl_path.clone(),
            self.ec_path.clone(),
            self.hwmon_path.clone(),
            PathBuf::from(DEFAULT_CPU_FREQ_BASE),
            PathBuf::from(DEFAULT_GPU_DPM_PATH),
        );
        daemon.run();
    }

    pub fn run_load_probe(&self) -> Result<CheckReport, Box<dyn Error>> {
        let rapl = RaplController::new(self.rapl_path.clone());
        let stop = Arc::new(AtomicBool::new(false));
        let stop_worker = Arc::clone(&stop);
        let worker = thread::spawn(move || Self::run_worker_load(stop_worker));
        let power_w = self.measure_probe_power(&rapl);
        stop.store(true, Ordering::Relaxed);
        let _ = worker.join();
        let power = power_w?;
        let mode = PowerMode::classify_measured(power);
        Ok(CheckReport::new(power, mode))
    }

    fn run_worker_load(stop: Arc<AtomicBool>) {
        let mut count: u64 = 0;
        loop {
            match stop.load(Ordering::Relaxed) {
                true => break,
                false => {
                    count = count.wrapping_add(1);
                    std::hint::black_box(count);
                }
            }
        }
    }

    fn measure_probe_power(&self, rapl: &RaplController) -> Result<f32, Box<dyn Error>> {
        let initial = rapl.read_energy_uj().ok();
        let start = Instant::now();
        thread::sleep(Duration::from_secs(1));
        let elapsed = start.elapsed().as_secs_f32();
        let final_energy = rapl.read_energy_uj().ok();
        self.compute_probe_power(initial, final_energy, elapsed, rapl)
    }

    fn compute_probe_power(
        &self,
        start_uj: Option<u64>,
        end_uj: Option<u64>,
        elapsed: f32,
        rapl: &RaplController,
    ) -> Result<f32, Box<dyn Error>> {
        match (start_uj, end_uj) {
            (Some(start), Some(end)) => match end >= start && elapsed > 0.0 {
                true => Ok((end - start) as f32 / (elapsed * 1_000_000.0)),
                false => self.fallback_probe_power(rapl),
            },
            _ => self.fallback_probe_power(rapl),
        }
    }

    fn fallback_probe_power(&self, rapl: &RaplController) -> Result<f32, Box<dyn Error>> {
        match rapl.read_power_watts() {
            Ok(watts) => Ok(watts),
            Err(_) => self.read_hwmon_power(),
        }
    }

    fn read_hwmon_power(&self) -> Result<f32, Box<dyn Error>> {
        let reader = HwmonReader::new(self.hwmon_path.clone());
        let watts = reader.read_power_watts()?;
        Ok(watts)
    }

    fn detect_hwmon_path() -> Result<PathBuf, Box<dyn Error>> {
        fs::read_dir(DEFAULT_HWMON_PATH)?
            .filter_map(Result::ok)
            .map(|entry| entry.path())
            .find(|path| Self::is_supported_hwmon(path))
            .ok_or_else(|| "no supported hwmon device found".into())
    }

    fn is_supported_hwmon(path: &Path) -> bool {
        let name_path = path.join("name");
        let Ok(name) = fs::read_to_string(name_path) else {
            return false;
        };
        matches!(name.trim(), "k10temp" | "amdgpu")
    }
}
