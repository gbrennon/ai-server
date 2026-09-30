use std::fs;
use std::io::{Error, ErrorKind};
use std::path::{Path, PathBuf};

pub struct HwmonReader {
    base_path: PathBuf,
}

impl HwmonReader {
    pub fn new(base_path: PathBuf) -> Self {
        Self { base_path }
    }

    pub fn base_path(&self) -> &Path {
        &self.base_path
    }

    pub fn read_temperature_c(&self) -> Result<f32, Error> {
        let path = Self::find_matching_file(&self.base_path, "temp", "_input")?;
        let raw_millidegrees = Self::read_numeric_file(&path)?;
        Ok(raw_millidegrees / 1000.0)
    }

    pub fn read_power_watts(&self) -> Result<f32, Error> {
        let path = Self::find_power_file(&self.base_path)?;
        let raw_microwatts = Self::read_numeric_file(&path)?;
        Ok(raw_microwatts / 1_000_000.0)
    }

    fn find_power_file(dir: &Path) -> Result<PathBuf, Error> {
        Self::find_matching_file(dir, "power", "_average")
            .or_else(|_| Self::find_matching_file(dir, "power", "_input"))
    }

    fn find_matching_file(dir: &Path, prefix: &str, suffix: &str) -> Result<PathBuf, Error> {
        let mut matches: Vec<PathBuf> = fs::read_dir(dir)?
            .filter_map(Result::ok)
            .map(|entry| entry.path())
            .filter(|path| Self::file_name_matches(path, prefix, suffix))
            .collect();
        matches.sort();
        matches
            .into_iter()
            .next()
            .ok_or_else(|| Error::new(ErrorKind::NotFound, "sensor file not found"))
    }

    fn file_name_matches(path: &Path, prefix: &str, suffix: &str) -> bool {
        let Some(file_name) = path.file_name() else {
            return false;
        };
        let lossy_name = file_name.to_string_lossy();
        lossy_name.starts_with(prefix) && lossy_name.ends_with(suffix)
    }

    fn read_numeric_file(path: &Path) -> Result<f32, Error> {
        let content = fs::read_to_string(path)?;
        content
            .trim()
            .parse::<f32>()
            .map_err(|e| Error::new(ErrorKind::InvalidData, e))
    }
}
