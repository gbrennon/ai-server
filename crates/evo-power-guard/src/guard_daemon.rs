use std::error::Error;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::thread;
use std::time::{Duration, Instant};

use nix::sys::signal::{self, SaFlags, SigAction, SigHandler, SigSet, Signal};

use crate::hardware::{
    ClampLever, EcController, HardwareTelemetry, HwmonReader, PowerMode, RaplController,
};
use crate::policy::{PowerDirective, SafetyPolicy};

const DEFAULT_RAPL_PATH: &str = "/sys/class/powercap/intel-rapl:0";
const DEFAULT_EC_PATH: &str = "/sys/kernel/debug/ec/ec0/io";
const DEFAULT_HWMON_PATH: &str = "/sys/class/hwmon";
const DEFAULT_CPU_FREQ_BASE: &str = "/sys/devices/system/cpu";
const DEFAULT_GPU_DPM_PATH: &str =
    "/sys/bus/pci/devices/0000:c5:00.0/power_dpm_force_performance_level";
const SAFE_POLL_THRESHOLD: u32 = 3;
const MIN_CLAMP_DWELL: Duration = Duration::from_secs(60);
static SHUTDOWN: AtomicBool = AtomicBool::new(false);

pub struct GuardDaemon {
    interval_ms: u64,
    target_mode: PowerMode,
    rapl: RaplController,
    ec: EcController,
    hwmon: HwmonReader,
    policy: SafetyPolicy,
    clamp_lever: ClampLever,
    consecutive_safe_polls: u32,
    clamp_engaged_at: Option<Instant>,
    clamp_dwell: Duration,
}

macro_rules! define_daemon_constructor {
    ($name:ident) => {
        impl GuardDaemon {
            pub fn $name(
                interval_ms: u64,
                target_mode: PowerMode,
                rapl_path: PathBuf,
                ec_path: PathBuf,
                hwmon_path: PathBuf,
                cpu_freq_base: PathBuf,
                gpu_dpm_path: PathBuf,
            ) -> Self {
                Self {
                    interval_ms,
                    target_mode,
                    rapl: RaplController::new(rapl_path),
                    ec: EcController::new(ec_path),
                    hwmon: HwmonReader::new(hwmon_path),
                    policy: SafetyPolicy::new(target_mode),
                    clamp_lever: ClampLever::new(cpu_freq_base, gpu_dpm_path),
                    consecutive_safe_polls: 0,
                    clamp_engaged_at: None,
                    clamp_dwell: MIN_CLAMP_DWELL,
                }
            }
        }
    };
}

define_daemon_constructor!(new);

impl GuardDaemon {
    pub fn with_system_defaults(interval_ms: u64, target_mode: PowerMode) -> Self {
        let hwmon_path =
            Self::detect_hwmon_path().unwrap_or_else(|_| PathBuf::from(DEFAULT_HWMON_PATH));
        Self::new(
            interval_ms,
            target_mode,
            PathBuf::from(DEFAULT_RAPL_PATH),
            PathBuf::from(DEFAULT_EC_PATH),
            hwmon_path,
            PathBuf::from(DEFAULT_CPU_FREQ_BASE),
            PathBuf::from(DEFAULT_GPU_DPM_PATH),
        )
    }

    pub fn with_clamp_dwell(mut self, clamp_dwell: Duration) -> Self {
        self.clamp_dwell = clamp_dwell;
        self
    }

    pub fn interval_ms(&self) -> u64 {
        self.interval_ms
    }

    pub fn target_mode(&self) -> PowerMode {
        self.target_mode
    }

    pub fn clamp_lever(&self) -> &ClampLever {
        &self.clamp_lever
    }

    pub fn consecutive_safe_polls(&self) -> u32 {
        self.consecutive_safe_polls
    }

    pub fn telemetry(&self) -> Result<HardwareTelemetry, Box<dyn Error>> {
        let package_power_w = self.rapl.read_power_watts()?;
        let package_temp_c = self.hwmon.read_temperature_c()?;
        let power_mode = self.read_power_mode()?;
        let (fan1_rpm, fan2_rpm) = self.read_tachometers();
        Ok(HardwareTelemetry::new(
            package_temp_c,
            package_power_w,
            power_mode,
            fan1_rpm,
            fan2_rpm,
        ))
    }

    pub fn run(&mut self) -> ! {
        match Self::handle_signals() {
            Ok(()) => {}
            Err(error) => {
                eprintln!("signal handler registration failed: {error}");
                let _ = self.clamp_lever.release_clamp();
                self.handover_to_firmware();
                std::process::exit(1);
            }
        }
        loop {
            match SHUTDOWN.load(Ordering::SeqCst) {
                true => {
                    let _ = self.clamp_lever.release_clamp();
                    self.handover_to_firmware();
                    std::process::exit(0);
                }
                false => {
                    self.poll_once();
                    thread::sleep(Duration::from_millis(self.interval_ms));
                }
            }
        }
    }

    pub fn poll_once(&mut self) {
        let telemetry = match self.telemetry() {
            Ok(value) => value,
            Err(error) => {
                eprintln!("telemetry read failed: {error}");
                return;
            }
        };
        self.enforce_power_limit(telemetry.package_power_w());
        self.reassert_ec(telemetry.package_temp_c());
    }

    fn enforce_power_limit(&mut self, current_power_w: f32) {
        match self.policy.evaluate_power(current_power_w) {
            PowerDirective::Clamp => {
                self.clamp_engaged_at.get_or_insert(Instant::now());
                self.consecutive_safe_polls = 0;
                match self.clamp_lever.engage_clamp() {
                    Ok(()) => {}
                    Err(error) => eprintln!("clamp engage failed: {error}"),
                }
            }
            PowerDirective::Allow => self.handle_safe_power(current_power_w),
        }
    }

    fn handle_safe_power(&mut self, current_power_w: f32) {
        let is_below_target = current_power_w < self.policy.target_power_w() as f32;
        match is_below_target {
            false => self.consecutive_safe_polls = 0,
            true => {
                self.consecutive_safe_polls += 1;
                self.check_release_threshold();
            }
        }
    }

    fn check_release_threshold(&mut self) {
        let below_poll_quota = self.consecutive_safe_polls >= SAFE_POLL_THRESHOLD;
        let elapsed_dwell = self
            .clamp_engaged_at
            .map(|engaged_at| engaged_at.elapsed() >= self.clamp_dwell)
            .unwrap_or(false);
        match below_poll_quota && elapsed_dwell {
            true => {
                match self.clamp_lever.release_clamp() {
                    Ok(()) => self.clamp_engaged_at = None,
                    Err(error) => eprintln!("clamp release failed: {error}"),
                }
                self.consecutive_safe_polls = 0;
            }
            false => {}
        }
    }

    fn reassert_ec(&self, temperature_c: f32) {
        match self.ec.is_available() {
            false => {}
            true => {
                match self.ec.set_p_mode(self.target_mode) {
                    Ok(()) => {}
                    Err(error) => eprintln!("power mode update failed: {error}"),
                }
                let duty = self.policy.fan_duty_for_temp(temperature_c);
                match self.ec.set_fan_duty(duty, duty) {
                    Ok(()) => {}
                    Err(error) => eprintln!("fan duty update failed: {error}"),
                }
            }
        }
    }

    fn read_power_mode(&self) -> Result<PowerMode, Box<dyn Error>> {
        match self.ec.is_available() {
            true => Ok(self.ec.read_p_mode()?),
            false => Ok(self.target_mode),
        }
    }

    fn read_tachometers(&self) -> (u32, u32) {
        match self.ec.is_available() {
            true => self.ec.read_tachometers().unwrap_or((0, 0)),
            false => (0, 0),
        }
    }

    pub fn handover_to_firmware(&self) {
        match self.ec.is_available() {
            false => {}
            true => match self.ec.handover_to_firmware() {
                Ok(()) => {}
                Err(error) => eprintln!("firmware handover failed: {error}"),
            },
        }
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

    fn handle_signals() -> Result<(), nix::Error> {
        SHUTDOWN.store(false, Ordering::SeqCst);
        let handler = SigHandler::Handler(Self::signal_handler);
        let action = SigAction::new(handler, SaFlags::empty(), SigSet::empty());
        unsafe {
            signal::sigaction(Signal::SIGTERM, &action)?;
            signal::sigaction(Signal::SIGINT, &action)?;
        }
        Ok(())
    }

    extern "C" fn signal_handler(_: i32) {
        SHUTDOWN.store(true, Ordering::SeqCst);
    }
}

impl Drop for GuardDaemon {
    fn drop(&mut self) {
        let _ = self.clamp_lever.release_clamp();
        self.handover_to_firmware();
    }
}
