use clap::ValueEnum;
use serde::Serialize;

#[derive(Clone, Copy, Debug, Eq, PartialEq, ValueEnum, Serialize)]
#[clap(rename_all = "lowercase")]
#[serde(rename_all = "lowercase")]
pub enum PowerMode {
    Balanced,
    Performance,
    Quiet,
}

impl PowerMode {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Balanced => "balanced",
            Self::Performance => "performance",
            Self::Quiet => "quiet",
        }
    }


    pub fn to_ec_byte(&self) -> u8 {
        match self {
            Self::Balanced => 0x00,
            Self::Performance => 0x01,
            Self::Quiet => 0x02,
        }
    }

    pub fn from_ec_byte(byte: u8) -> Option<PowerMode> {
        match byte {
            0x00 => Some(Self::Balanced),
            0x01 => Some(Self::Performance),
            0x02 => Some(Self::Quiet),
            _ => None,
        }
    }

    pub fn target_power_watts(&self) -> u32 {
        match self {
            Self::Balanced => 85,
            Self::Performance => 140,
            Self::Quiet => 54,
        }
    }

    pub fn classify_measured(power_w: f32) -> Self {
        match power_w > 110.0 {
            true => Self::Performance,
            false => match power_w > 68.0 {
                true => Self::Balanced,
                false => Self::Quiet,
            },
        }
    }
}
impl std::str::FromStr for PowerMode {
    type Err = ();

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s {
            "balanced" => Ok(Self::Balanced),
            "performance" => Ok(Self::Performance),
            "quiet" => Ok(Self::Quiet),
            _ => Err(()),
        }
    }
}

#[cfg(test)] mod tests {
    use super::PowerMode;

    #[test]
    fn power_mode_string_conversions_cover_all_modes() {
        assert_eq!(PowerMode::Balanced.as_str(), "balanced");
        assert_eq!(PowerMode::Performance.as_str(), "performance");
        assert_eq!(PowerMode::Quiet.as_str(), "quiet");

        use std::str::FromStr;

        assert_eq!(PowerMode::from_str("balanced"), Ok(PowerMode::Balanced));
        assert_eq!(PowerMode::from_str("performance"), Ok(PowerMode::Performance));
        assert_eq!(PowerMode::from_str("quiet"), Ok(PowerMode::Quiet));
        assert_eq!(PowerMode::from_str("BALANCED"), Err(()));
        assert_eq!(PowerMode::from_str("unknown"), Err(()));
    }

    #[test]
    fn power_mode_ec_byte_conversions_cover_all_modes() {
        assert_eq!(PowerMode::Balanced.to_ec_byte(), 0x00);
        assert_eq!(PowerMode::Performance.to_ec_byte(), 0x01);
        assert_eq!(PowerMode::Quiet.to_ec_byte(), 0x02);

        assert_eq!(PowerMode::from_ec_byte(0x00), Some(PowerMode::Balanced));
        assert_eq!(PowerMode::from_ec_byte(0x01), Some(PowerMode::Performance));
        assert_eq!(PowerMode::from_ec_byte(0x02), Some(PowerMode::Quiet));
        assert_eq!(PowerMode::from_ec_byte(0x03), None);
        assert_eq!(PowerMode::from_ec_byte(u8::MAX), None);
    }

    #[test]
    fn power_mode_target_watts_match_hardware_profiles() {
        assert_eq!(PowerMode::Balanced.target_power_watts(), 85);
        assert_eq!(PowerMode::Performance.target_power_watts(), 140);
        assert_eq!(PowerMode::Quiet.target_power_watts(), 54);
    }
}
