use std::fs::{File, OpenOptions};
use std::io::{self, ErrorKind};
use std::os::unix::fs::FileExt;
use std::path::{Path, PathBuf};
use std::thread;
use std::time::Duration;

use super::PowerMode;

const P_MODE_OFFSET: u64 = 0x31;
const FAN1_DUTY_OFFSET: u64 = 0x33;
const FAN2_DUTY_OFFSET: u64 = 0x34;
const TACHOMETER_OFFSET: u64 = 0x35;
const FIRMWARE_FAN_MODE: u8 = 0;
const MANUAL_FAN_MODE: u8 = 0x80;
const INVALID_TACHOMETER_RPM: u16 = 8000;

pub struct EcController { device_path: PathBuf }

impl EcController {
    pub fn new(device_path: PathBuf) -> Self { Self { device_path } }
    pub fn device_path(&self) -> &Path { &self.device_path }
    pub fn is_available(&self) -> bool { File::open(&self.device_path).is_ok() }

    pub fn set_p_mode(&self, mode: PowerMode) -> Result<(), io::Error> {
        self.write_byte(P_MODE_OFFSET, mode.to_ec_byte())
    }

    pub fn read_p_mode(&self) -> Result<PowerMode, io::Error> {
        let byte = self.read_byte(P_MODE_OFFSET)?;
        PowerMode::from_ec_byte(byte).ok_or_else(|| io::Error::new(ErrorKind::InvalidData, "unknown EC power mode"))
    }

    pub fn set_fan_duty(&self, fan1: u8, fan2: u8) -> Result<(), io::Error> {
        if fan1 > 100 || fan2 > 100 { return Err(io::Error::new(ErrorKind::InvalidInput, "fan duty must be 0..=100")); }
        self.write_byte(FAN1_DUTY_OFFSET, MANUAL_FAN_MODE | fan1)?;
        self.write_byte(FAN2_DUTY_OFFSET, MANUAL_FAN_MODE | fan2)
    }

    pub fn read_tachometers(&self) -> Result<(u32, u32), io::Error> {
        let first = self.sample_tachometers()?;
        thread::sleep(Duration::from_millis(20));
        let second = self.sample_tachometers()?;
        Ok((Self::resolve_rpm(first.0, second.0), Self::resolve_rpm(first.1, second.1)))
    }

    pub fn handover_to_firmware(&self) -> Result<(), io::Error> {
        self.write_byte(FAN1_DUTY_OFFSET, FIRMWARE_FAN_MODE)?;
        self.write_byte(FAN2_DUTY_OFFSET, FIRMWARE_FAN_MODE)
    }

    fn sample_tachometers(&self) -> Result<(u16, u16), io::Error> {
        Ok((self.read_u16(TACHOMETER_OFFSET)?, self.read_u16(TACHOMETER_OFFSET + 2)?))
    }

    fn resolve_rpm(first: u16, second: u16) -> u32 {
        let value = if second == 0 { first } else { second };
        if value == 0 || value == INVALID_TACHOMETER_RPM { 0 } else { value as u32 }
    }

    fn read_u16(&self, offset: u64) -> Result<u16, io::Error> {
        let bytes = [self.read_byte(offset)?, self.read_byte(offset + 1)?];
        Ok(u16::from_le_bytes(bytes))
    }

    fn read_byte(&self, offset: u64) -> Result<u8, io::Error> {
        let file = File::open(&self.device_path)?;
        let mut byte = [0_u8; 1];
        file.read_exact_at(&mut byte, offset)?;
        Ok(byte[0])
    }

    fn write_byte(&self, offset: u64, value: u8) -> Result<(), io::Error> {
        let file = OpenOptions::new().read(true).write(true).open(&self.device_path)?;
        file.write_all_at(&[value], offset)
    }
}
