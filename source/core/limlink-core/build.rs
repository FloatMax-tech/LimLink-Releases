fn main() {
    println!("cargo:rerun-if-changed=build.rs");
    println!("cargo:rerun-if-env-changed=CARGO_FEATURE_TEST_RNG");
    let profile = std::env::var("PROFILE").unwrap_or_default();
    let test_rng = std::env::var("CARGO_FEATURE_TEST_RNG").is_ok();
    if test_rng && profile == "release" {
        panic!(
            "limlink-core: feature `test-rng` cannot be combined with the release profile \
             (spec 15.10.9 guard 1)"
        );
    }
}
