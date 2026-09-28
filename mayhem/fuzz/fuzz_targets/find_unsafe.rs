#![no_main]
use libfuzzer_sys::fuzz_target;
use std::sync::Once;

// syn's recursive-descent parser (reached via geiger::find_unsafe_in_string) has no
// recursion-depth limit, so a deeply nested type/expression overflows the stack —
// but only once the stack is smaller than whatever headroom the ambient container/
// runner ulimit happens to leave (varies by environment: 8 MiB here masks most of
// the mayhemheroes-run-36 crashers, which need well under 4 MiB to trip). Clamp our
// own soft RLIMIT_STACK down before any recursion happens so the crash — a real,
// unbounded-recursion bug in syn's code, not a harness artifact — reproduces the
// same way regardless of the caller's ulimit.
static CLAMP_STACK: Once = Once::new();

fn clamp_stack() {
    CLAMP_STACK.call_once(|| unsafe {
        let mut rl: libc::rlimit = std::mem::zeroed();
        if libc::getrlimit(libc::RLIMIT_STACK, &mut rl) == 0 {
            let want: libc::rlim_t = 4 * 1024 * 1024; // 4 MiB
            if rl.rlim_cur > want {
                rl.rlim_cur = want;
                libc::setrlimit(libc::RLIMIT_STACK, &rl);
            }
        }
    });
}

fuzz_target!(|data: (bool, &str)| {
    clamp_stack();
    let include_tests = match data.0 {
        true => geiger::IncludeTests::Yes,
        false => geiger::IncludeTests::No,
    };
    let _ = geiger::find_unsafe_in_string(data.1, include_tests);
});
