#![no_main]
use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: (bool, &str)| {
    let include_tests = match data.0 {
        true => geiger::IncludeTests::Yes,
        false => geiger::IncludeTests::No,
    };
    let _ = geiger::find_unsafe_in_string(data.1, include_tests);
});
