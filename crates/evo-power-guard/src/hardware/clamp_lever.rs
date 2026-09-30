use std::fs;
use std::io::{Error, ErrorKind};
use std::path::{Path, PathBuf};

const CLAMPED_MAX_FREQ_KHZ: u64 = 3_000_000;

pub struct ClampLever {
    cpu_freq_base: PathBuf,
    gpu_dpm_path: PathBuf,
    capped: bool,
    saved_max_freq_khz: u64,
}

impl ClampLever {
    pub fn new(cpu_freq_base: PathBuf, gpu_dpm_path: PathBuf) -> Self {
        Self { cpu_freq_base, gpu_dpm_path, capped: false, saved_max_freq_khz: 0 }
    }

    pub fn with_system_defaults() -> Self {
        Self::new(
            PathBuf::from("/sys/devices/system/cpu"),
            PathBuf::from("/sys/bus/pci/devices/0000:c5:00.0/power_dpm_force_performance_level"),
        )
    }

    pub fn cpu_freq_base(&self) -> &Path { &self.cpu_freq_base }
    pub fn gpu_dpm_path(&self) -> &Path { &self.gpu_dpm_path }
    pub fn saved_max_freq_khz(&self) -> u64 { self.saved_max_freq_khz }
    pub fn is_capped(&self) -> bool { self.capped }

    pub fn engage_clamp(&mut self) -> Result<(), Error> {
        if self.capped { return Ok(()); }
        let saved = self.read_cpu0_max_freq()?;
        let dirs = self.cpu_freq_dirs()?;
        if !self.write_frequency_files(&dirs, CLAMPED_MAX_FREQ_KHZ) {
            return Err(Error::new(ErrorKind::WriteZero, "unable to write any CPU frequency limit"));
        }
        self.saved_max_freq_khz = saved;
        self.write_boost(false);
        self.write_gpu_level("low");
        self.capped = true;
        Ok(())
    }

    pub fn release_clamp(&mut self) -> Result<(), Error> {
        if !self.capped { return Ok(()); }
        let dirs = self.cpu_freq_dirs()?;
        if !self.write_frequency_files(&dirs, self.saved_max_freq_khz) {
            return Err(Error::new(ErrorKind::WriteZero, "unable to restore any CPU frequency limit"));
        }
        self.write_boost(true);
        self.write_gpu_level("high");
        self.capped = false;
        Ok(())
    }

    fn read_cpu0_max_freq(&self) -> Result<u64, Error> {
        let path = self.cpu_freq_path("cpu0", "scaling_max_freq");
        let value = fs::read_to_string(path)?;
        value.trim().parse().map_err(|error| Error::new(ErrorKind::InvalidData, error))
    }

    fn cpu_freq_dirs(&self) -> Result<Vec<PathBuf>, Error> {
        let mut dirs = fs::read_dir(&self.cpu_freq_base)?.filter_map(Result::ok)
            .map(|entry| entry.path()).filter(|path| path.file_name().and_then(|n| n.to_str()).is_some_and(|n| n.starts_with("cpu")) && path.join("cpufreq").is_dir()).collect::<Vec<_>>();
        dirs.sort();
        Ok(dirs)
    }

    fn write_frequency_files(&self, dirs: &[PathBuf], value: u64) -> bool {
        let mut wrote = false;
        for dir in dirs {
            if fs::write(dir.join("cpufreq/scaling_max_freq"), format!("{value}\n")).is_ok() { wrote = true; }
        }
        wrote
    }

    fn write_boost(&self, enabled: bool) {
        let _ = fs::write(self.cpu_freq_path("cpu0", "boost"), if enabled { "1\n" } else { "0\n" });
    }

    fn write_gpu_level(&self, level: &str) { let _ = fs::write(&self.gpu_dpm_path, format!("{level}\n")); }

    fn cpu_freq_path(&self, cpu: &str, file: &str) -> PathBuf {
        self.cpu_freq_base.join(cpu).join("cpufreq").join(file)
    }
}
