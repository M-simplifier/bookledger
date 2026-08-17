# CI performance experiment

Bookledger is a small Haskell CLI, but a fresh GitHub-hosted runner originally
spent almost eight minutes building and testing it. This experiment asked a
narrower question than whether Haskell builds are universally fast:

> Can an ordinary source change receive a full independent build and test on a
> stock GitHub-hosted runner in under three minutes, without skipping checks?

## Conditions

- GitHub-hosted `ubuntu-24.04` x64 runner
- Dependencies fixed by `cabal.project.freeze`
- All library and executable targets built
- All 17 tests run
- Only `~/.cabal/packages` and `~/.cabal/store` cached; Bookledger itself is
  compiled from source on every run

The current workflow uses GHC 9.10.3 and cabal-install 3.16.1.0. It disables
optimization for every package because its purpose is typechecking and testing
this personal CLI, not producing a release binary. Earlier measurements used
GHC 9.6.7 and cabal-install 3.12.1.0 as noted below.

## Results

Measurements were taken on 2026-08-18. The first four rows establish the
original cache experiment. The remaining rows measure the final all-package
unoptimized configuration and the recommended-toolchain upgrade.

| Toolchain | Dependency state | Optimization | Job time | Build + test |
| --- | --- | --- | ---: | ---: |
| GHC 9.6.7 | No cache action | `-O1` | 7m 52s | 5m 53s |
| GHC 9.6.7 | Empty cache | `-O1` | 7m 54s | 5m 55s |
| GHC 9.6.7 | Warm cache | `-O1` | 1m 59s–2m 06s | 18s |
| GHC 9.6.7 | Warm cache | Bookledger only `-O0` | 1m 45s–2m 02s | 13–14s |
| GHC 9.6.7 | Compiled cache cold; package sources restored | All packages `-O0` | 5m 59s | 4m 05s |
| GHC 9.6.7 | Warm cache | All packages `-O0` | 1m 57s | 13s |
| GHC 9.10.3 | Empty cache | All packages `-O0` | 5m 11s | 3m 07s |
| GHC 9.10.3 | Warm cache | All packages `-O0` | 2m 16s | 15s |

The dependency cache is about 280 MB and normally restores in a few seconds.
With GHC 9.6.7, disabling optimization for dependencies reduced the cold build
step from 5m 38s to 3m 53s, a 31% reduction. The source-restored row is not a
strictly empty machine: the old compiled artifacts could not be reused, but the
package index and source tarballs could.

After upgrading to the recommended GHC 9.10.3 toolchain, a genuinely empty
toolchain-specific cache completed in 5m 11s. Its build and test took 3m 07s;
the warm rerun took 2m 16s overall. On warm runs, installing GHC and Cabal now
dominates the job at roughly 1m 34s–1m 54s.

Supporting runs:

- [Pre-cache baseline](https://github.com/M-simplifier/bookledger/actions/runs/32044429198)
- [Empty cache and optimized warm reruns](https://github.com/M-simplifier/bookledger/actions/runs/32046892874)
- [Bookledger-only unoptimized warm reruns](https://github.com/M-simplifier/bookledger/actions/runs/32047929646)
- [All-package unoptimized cold-equivalent and warm runs](https://github.com/M-simplifier/bookledger/actions/runs/32050660954)
- [GHC 9.10.3 empty-cache and warm runs](https://github.com/M-simplifier/bookledger/actions/runs/32052325835)

## Conclusion

For this application, slow CI was primarily a failure to reuse compiled
dependencies, not the cost of compiling the application or running its tests.
The under-three-minute target is met on an ephemeral hosted runner without a
self-hosted machine, a custom container, or reduced test coverage.

Turning off dependency optimization also materially improved the empty-cache
case and requires only one small Cabal project file. It is retained. Further
optimization is deliberately out of scope: warm CI is already fast enough for
this project, and more elaborate toolchain caching would add complexity mainly
to save time in a job whose dominant cost is provisioning the compiler.
