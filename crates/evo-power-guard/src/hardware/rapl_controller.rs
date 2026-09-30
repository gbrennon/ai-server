use std::fs;
use std::io::{Error, ErrorKind};
use std::path::{Path, PathBuf};
use std::thread;
use std::time::{Duration, Instant};

pub struct RaplController {
    base_path: PathBuf,
}

macro_rules! define_power_limit_setter {
    ($name:ident) => {
        impl RaplController {
            pub fn $name(&self, limit_uw: u64) -> Result<(), Error> {
                let path = self.base_path.join("constraint_0_power_limit_uw");
                match path.exists() {
                    false => Ok(()),
                    true => fs::write(path, format!("{}\n", limit_uw)),
                }
            }
        }
    };
}

define_power_limit_setter!(set_power_limit_uw);

impl RaplController {
    pub fn new(base_path: PathBuf) -> Self {
        Self { base_path }
    }

    pub fn base_path(&self) -> &Path {
        &self.base_path
    }

    pub fn read_energy_uj(&self) -> Result<u64, Error> {
        let path = self.base_path.join("energy_uj");
        Self::read_u64_file(&path)
    }

    pub fn read_power_limit_uw(&self) -> Result<u64, Error> {
        let path = self.base_path.join("constraint_0_power_limit_uw");
        Self::read_u64_file(&path)
    }

    pub fn read_power_watts(&self) -> Result<f32, Error> {
        let power_path = self.base_path.join("power");
        match power_path.is_file() {
            true => {
                let microwatts = Self::read_u64_file(&power_path)?;
                Ok(microwatts as f32 / 1_000_000.0)
            }
            false => self.sample_power_watts_from_energy(Duration::from_millis(50)),
        }
    }

    fn sample_power_watts_from_energy(&self, sample_duration: Duration) -> Result<f32, Error> {
        let initial_energy = self.read_energy_uj()?;
        let start_time = Instant::now();
        thread::sleep(sample_duration);
        let final_energy = self.read_energy_uj()?;
        let elapsed_seconds = start_time.elapsed().as_secs_f32();

        Self::calculate_watts(initial_energy, final_energy, elapsed_seconds)
    }

    fn calculate_watts(
        initial_energy: u64,
        final_energy: u64,
        elapsed_seconds: f32,
    ) -> Result<f32, Error> {
        let is_valid = elapsed_seconds > 0.0 && final_energy >= initial_energy;
        match is_valid {
            false => Ok(0.0),
            true => {
                let delta_energy_uj = (final_energy - initial_energy) as f32;
                Ok(delta_energy_uj / (elapsed_seconds * 1_000_000.0))
            }
        }
    }

    fn read_u64_file(path: &Path) -> Result<u64, Error> {
        let content = fs::read_to_string(path)?;
        content
            .trim()
            .parse::<u64>()
            .map_err(|e| Error::new(ErrorKind::InvalidData, e))
    }
}
