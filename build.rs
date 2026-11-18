//! Lists the puzzle files in `puzzles/` for `include_str!` (src/puzzle), so a
//! new puzzle is a new file and nothing else.

use std::path::Path;

fn main() {
    let root = std::env::var("CARGO_MANIFEST_DIR").expect("CARGO_MANIFEST_DIR");
    let dir = Path::new(&root).join("puzzles");
    println!("cargo:rerun-if-changed=build.rs");
    println!("cargo:rerun-if-changed=puzzles");
    let mut names: Vec<String> = std::fs::read_dir(&dir)
        .map(|entries| {
            entries
                .filter_map(|e| e.ok())
                .map(|e| e.file_name().to_string_lossy().into_owned())
                .filter(|n| n.ends_with(".json"))
                .collect()
        })
        .unwrap_or_default();
    names.sort();
    let mut out = String::from("/// (file name, contents) of every puzzle in `puzzles/`, sorted by name.\npub static PUZZLE_FILES: &[(&str, &str)] = &[\n");
    for n in &names {
        let path = dir.join(n);
        out += &format!("    ({n:?}, include_str!({:?})),\n", path.to_string_lossy());
    }
    out += "];\n";
    let dest = Path::new(&std::env::var("OUT_DIR").expect("OUT_DIR")).join("puzzle_files.rs");
    std::fs::write(dest, out).expect("write puzzle_files.rs");
}
