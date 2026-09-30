use serde::Serialize;

use super::PowerMode;

#[derive(Clone, Debug, Serialize)]
pub struct CheckReport {
    power_w: f32,
    mode: PowerMode,
}

impl CheckReport {
    pub fn new(power_w: f32, mode: PowerMode) -> Self {
        Self { power_w, mode }
    }

    pub fn power_w(&self) -> f32 {
        self.power_w
    }

    pub fn mode(&self) -> PowerMode {
        self.mode
    }
}
