//! Math in issue messages. A message may mark math with `$…$` in a small TeX subset
//! (the one the app typesets): `$w_0$`, `$0.25\,\lambda$`, `$n^2 - k^2$`. The app shows
//! that source typeset; everything else (the CLI, logs) uses [`plain`], which flattens
//! it to Unicode: `w₀`, `0.25 λ`, `n² − k²`.

/// `text` with `$` escaped, for putting a name into a message that has math.
pub fn escape(text: &str) -> String {
    text.replace('$', "\\$")
}

/// `source` with its math flattened to plain Unicode.
pub fn plain(source: &str) -> String {
    let mut out = String::new();
    let mut chars = source.chars().peekable();
    let mut math: Option<String> = None;
    while let Some(c) = chars.next() {
        if c == '\\' && chars.peek() == Some(&'$') {
            chars.next();
            match &mut math {
                Some(m) => m.push_str("\\$"),
                None => out.push('$'),
            }
        } else if c == '$' {
            match math.take() {
                Some(m) => out.push_str(&plain_math(&m)),
                None => math = Some(String::new()),
            }
        } else {
            match &mut math {
                Some(m) => m.push(c),
                None => out.push(c),
            }
        }
    }
    // An unclosed `$` is kept as written.
    if let Some(m) = math {
        out.push('$');
        out.push_str(&m);
    }
    out
}

#[derive(Clone, Copy, PartialEq)]
enum Position {
    Base,
    Superscript,
    Subscript,
}

fn symbol(name: &str) -> Option<&'static str> {
    Some(match name {
        "lambda" => "λ",
        "varphi" => "φ",
        "phi" => "ϕ",
        "theta" => "θ",
        "beta" => "β",
        "pi" => "π",
        "omega" => "ω",
        "varepsilon" => "ε",
        "epsilon" => "ϵ",
        "mu" => "µ",
        "angle" => "∠",
        "cdot" => "·",
        "times" => "×",
        "approx" => "≈",
        "pm" => "±",
        "infty" => "∞",
        "dagger" => "†",
        _ => return None,
    })
}

const FUNCTIONS: [&str; 8] = ["exp", "arg", "Re", "Im", "sin", "cos", "log", "ln"];
const BINARY: [&str; 5] = ["+", "−", "×", "·", "±"];
const RELATIONS: [&str; 4] = ["=", "≈", "<", ">"];

/// One parsed piece of math, with where it sits.
struct Atom {
    text: String,
    position: Position,
    operator_name: bool,
}

fn plain_math(tex: &str) -> String {
    let chars: Vec<char> = tex.chars().collect();
    let mut i = 0;
    let atoms = parse_list(&chars, &mut i, Position::Base, None);

    // Group consecutive atoms by position, so a script group converts as a whole.
    let mut out = String::new();
    let mut k = 0;
    while k < atoms.len() {
        let atom = &atoms[k];
        if atom.position != Position::Base {
            let mut group = String::new();
            let position = atom.position;
            while k < atoms.len() && atoms[k].position == position {
                group.push_str(&atoms[k].text);
                k += 1;
            }
            out.push_str(&scripted(&group, position));
            continue;
        }
        let previous = atoms[..k].iter().rev().find(|a| a.position == Position::Base && !a.text.trim().is_empty());
        let is_binary = BINARY.contains(&atom.text.as_str());
        let is_relation = RELATIONS.contains(&atom.text.as_str());
        let unary = previous.is_none_or(|p| {
            BINARY.contains(&p.text.as_str()) || RELATIONS.contains(&p.text.as_str()) || ["(", "[", "{"].contains(&p.text.as_str())
        });
        if is_relation || (is_binary && !unary) {
            out.push(' ');
            out.push_str(&atom.text);
            out.push(' ');
        } else {
            out.push_str(&atom.text);
        }
        if atom.operator_name {
            if let Some(next) = atoms.get(k + 1) {
                if next.position == Position::Base && !next.text.starts_with(['(', '[', '{']) {
                    out.push(' ');
                }
            }
        }
        k += 1;
    }
    out
}

fn parse_list(chars: &[char], i: &mut usize, position: Position, closing: Option<char>) -> Vec<Atom> {
    let mut atoms = Vec::new();
    while *i < chars.len() {
        let c = chars[*i];
        if Some(c) == closing {
            *i += 1;
            break;
        }
        if c == ' ' {
            *i += 1;
            continue;
        }
        if c == '^' || c == '_' {
            *i += 1;
            let script = if c == '^' { Position::Superscript } else { Position::Subscript };
            atoms.extend(parse_atom(chars, i, script));
        } else {
            atoms.extend(parse_atom(chars, i, position));
        }
    }
    atoms
}

fn parse_atom(chars: &[char], i: &mut usize, position: Position) -> Vec<Atom> {
    while *i < chars.len() && chars[*i] == ' ' {
        *i += 1;
    }
    let Some(&c) = chars.get(*i) else { return Vec::new() };
    *i += 1;
    let atom = |text: &str| vec![Atom { text: text.to_string(), position, operator_name: false }];
    match c {
        '{' => parse_list(chars, i, position, Some('}')),
        '-' => atom("−"),
        '\'' => atom("′"),
        '\\' => {
            let Some(&first) = chars.get(*i) else { return atom("\\") };
            if !first.is_alphabetic() {
                *i += 1;
                return match first {
                    ',' | ' ' => atom(" "),
                    other => atom(&other.to_string()),
                };
            }
            let mut name = String::new();
            while let Some(&c) = chars.get(*i) {
                if !c.is_alphabetic() {
                    break;
                }
                name.push(c);
                *i += 1;
            }
            if name == "operatorname" || name == "mathrm" {
                let mut word = parse_atom(chars, i, position);
                if name == "operatorname" {
                    if let Some(last) = word.last_mut() {
                        last.operator_name = true;
                    }
                }
                return word;
            }
            if FUNCTIONS.contains(&name.as_str()) {
                return vec![Atom { text: name, position, operator_name: true }];
            }
            match symbol(&name) {
                Some(s) => atom(s),
                None => atom(&format!("\\{name}")),
            }
        }
        other => atom(&other.to_string()),
    }
}

/// `text` in Unicode script characters; a superscript Unicode lacks becomes `^(…)`, a
/// subscript stays as it is.
fn scripted(text: &str, position: Position) -> String {
    let map = |c: char| -> Option<char> {
        let (from, to) = match position {
            Position::Superscript => ("0123456789+−ni", "⁰¹²³⁴⁵⁶⁷⁸⁹⁺⁻ⁿⁱ"),
            Position::Subscript => ("0123456789+−aeoxhklmnpstijruv", "₀₁₂₃₄₅₆₇₈₉₊₋ₐₑₒₓₕₖₗₘₙₚₛₜᵢⱼᵣᵤᵥ"),
            Position::Base => return Some(c),
        };
        from.chars().position(|f| f == c).and_then(|k| to.chars().nth(k))
    };
    if let Some(mapped) = text.chars().map(map).collect::<Option<String>>() {
        return mapped;
    }
    match position {
        Position::Superscript if text.chars().count() > 1 => format!("^({text})"),
        Position::Superscript => format!("^{text}"),
        _ => text.to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn flattens_the_subset() {
        assert_eq!(plain(r"within 0.25 $\lambda$ of the edge"), "within 0.25 λ of the edge");
        assert_eq!(plain(r"wider than $w_0$ (waist below $\lambda/2$)"), "wider than w₀ (waist below λ/2)");
        assert_eq!(plain(r"$n^2 - k^2$ must be at least 1 ($\varepsilon' < 1$)"), "n² − k² must be at least 1 (ε′ < 1)");
        assert_eq!(plain(r"$x = -1$"), "x = −1");
        assert_eq!(plain(r"$\operatorname{Re} E$ and $\arg(E)$"), "Re E and arg(E)");
        assert_eq!(plain(r"$e^{j\varphi}$ and $z_R$"), "e^(jφ) and zR");
        assert_eq!(plain(r"price \$5, $k$"), "price $5, k");
        assert_eq!(plain("unclosed $x"), "unclosed $x");
        assert_eq!(plain(&format!("{} is close", escape("Lens $2"))), "Lens $2 is close");
    }
}
