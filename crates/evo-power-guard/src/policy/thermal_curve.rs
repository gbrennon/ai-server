#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ThermalCurve {
    points: &'static [(f32, u8)],
}

impl ThermalCurve {
    pub const fn new(points: &'static [(f32, u8)]) -> Self {
        Self { points }
    }

    pub fn duty_for_temp(&self, temperature_c: f32) -> u8 {
        for (threshold, duty) in self.points {
            if temperature_c <= *threshold {
                return *duty;
            }
        }
        self.points.last().map(|(_, duty)| *duty).unwrap_or(100)
    }
}

pub const EVO_X2_THERMAL_CURVE: ThermalCurve = ThermalCurve::new(&[
    (40.0, 38),
    (55.0, 50),
    (65.0, 65),
    (75.0, 80),
    (85.0, 100),
]);
