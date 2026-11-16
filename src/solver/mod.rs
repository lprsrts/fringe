//! Solver interface and the solve pipeline.

use serde::{Deserialize, Serialize};

#[derive(Serialize, Deserialize, Clone, Copy, Debug, PartialEq, Eq, Hash, Default)]
#[serde(rename_all = "snake_case")]
pub enum Method {
    #[default]
    Fdtd,
    Fem,
    Mom,
}

impl Method {
    pub fn name(self) -> &'static str {
        match self {
            Method::Fdtd => "fdtd",
            Method::Fem => "fem",
            Method::Mom => "mom",
        }
    }

    pub fn label(self) -> &'static str {
        match self {
            Method::Fdtd => "FDTD",
            Method::Fem => "FEM",
            Method::Mom => "MoM",
        }
    }

    pub fn parse(s: &str) -> Option<Method> {
        match s.trim().to_ascii_lowercase().as_str() {
            "fdtd" => Some(Method::Fdtd),
            "fem" => Some(Method::Fem),
            "mom" => Some(Method::Mom),
            _ => None,
        }
    }

    pub const ALL: [Method; 3] = [Method::Fdtd, Method::Fem, Method::Mom];
}

#[derive(Serialize, Deserialize, Clone, Copy, Debug, PartialEq, Eq, Hash)]
#[serde(rename_all = "snake_case")]
pub enum Quality {
    Preview,
    Final,
}

impl Quality {
    pub fn name(self) -> &'static str {
        match self {
            Quality::Preview => "preview",
            Quality::Final => "final",
        }
    }

    pub fn parse(s: &str) -> Option<Quality> {
        match s.trim().to_ascii_lowercase().as_str() {
            "preview" => Some(Quality::Preview),
            "final" => Some(Quality::Final),
            _ => None,
        }
    }
}
