use crate::hardware::PowerMode;
use super::power_directive::PowerDirective;
use super::thermal_curve::{ThermalCurve, EVO_X2_THERMAL_CURVE};

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SafetyPolicy {
    target_power_w: u32,
    clamp_threshold_w: u32,
    curve: ThermalCurve,
}

impl SafetyPolicy {
    pub fn new(mode: PowerMode) -> Self {
        let target_power_w = mode.target_power_watts();
        let clamp_threshold_w = target_power_w + 5;
        Self {
            target_power_w,
            clamp_threshold_w,
            curve: EVO_X2_THERMAL_CURVE,
        }
    }

    pub fn with_curve(mode: PowerMode, curve: ThermalCurve) -> Self {
        let target_power_w = mode.target_power_watts();
        let clamp_threshold_w = target_power_w + 5;
        Self {
            target_power_w,
            clamp_threshold_w,
            curve,
        }
    }

    pub fn target_power_w(&self) -> u32 {
        self.target_power_w
    }

    pub fn clamp_threshold_w(&self) -> u32 {
        self.clamp_threshold_w
    }

    pub fn curve(&self) -> &ThermalCurve {
        &self.curve
    }

    pub fn evaluate_power(&self, current_power_w: f32) -> PowerDirective {
        let threshold = self.clamp_threshold_w as f32;
        match current_power_w > threshold {
            true => PowerDirective::Clamp,
            false => PowerDirective::Allow,
        }
    }

    pub fn fan_duty_for_temp(&self, temp_c: f32) -> u8 {
        self.curve.duty_for_temp(temp_c)
    }
}

#[cfg(test)] mod tests {
    use super::SafetyPolicy;
    use crate::hardware::PowerMode;
    use crate::policy::PowerDirective;

    #[test]
    fn balanced_policy_clamps_power_above_threshold() {
        let policy = SafetyPolicy::new(PowerMode::Balanced);

        assert_eq!(policy.evaluate_power(95.0), PowerDirective::Clamp);
        assert_eq!(policy.evaluate_power(80.0), PowerDirective::Allow);
        assert_eq!(policy.evaluate_power(90.0), PowerDirective::Allow);
    }

    #[test]
    fn safety_policy_delegates_fan_duty_to_curve() {
        let policy = SafetyPolicy::new(PowerMode::Balanced);

        assert_eq!(policy.fan_duty_for_temp(0.0), 38);
        assert_eq!(policy.fan_duty_for_temp(85.0), 100);
    }
}
