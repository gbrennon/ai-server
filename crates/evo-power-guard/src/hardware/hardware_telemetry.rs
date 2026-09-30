use serde::Serialize;

use super::PowerMode;

#[derive(Clone, Copy, Debug, PartialEq, Serialize)]
pub struct HardwareTelemetry {
    package_temp_c: f32,
    package_power_w: f32,
    power_mode: PowerMode,
    fan1_rpm: u32,
    fan2_rpm: u32,
}

impl HardwareTelemetry {
    pub fn new(
        package_temp_c: f32,
        package_power_w: f32,
        power_mode: PowerMode,
        fan1_rpm: u32,
        fan2_rpm: u32,
    ) -> Self {
        Self {
            package_temp_c,
            package_power_w,
            power_mode,
            fan1_rpm,
            fan2_rpm,
        }
    }

    pub fn package_temp_c(&self) -> f32 {
        self.package_temp_c
    }

    pub fn package_power_w(&self) -> f32 {
        self.package_power_w
    }

    pub fn power_mode(&self) -> PowerMode {
        self.power_mode
    }

    pub fn fan1_rpm(&self) -> u32 {
        self.fan1_rpm
    }

    pub fn fan2_rpm(&self) -> u32 {
        self.fan2_rpm
    }
}

#[cfg(test)] mod tests {
    use super::HardwareTelemetry;
    use crate::hardware::PowerMode;

    #[test]
    fn hardware_telemetry_preserves_constructor_values() {
        let telemetry = HardwareTelemetry::new(72.5, 118.75, PowerMode::Performance, 2_400, 2_650);

        assert_eq!(telemetry.package_temp_c(), 72.5);
        assert_eq!(telemetry.package_power_w(), 118.75);
        assert_eq!(telemetry.power_mode(), PowerMode::Performance);
        assert_eq!(telemetry.fan1_rpm(), 2_400);
        assert_eq!(telemetry.fan2_rpm(), 2_650);
    }
}
