# CI performance experiment

Bookledger is a small Haskell CLI, but a fresh GitHub-hosted runner originally
spent almost eight minutes building and testing it. This experiment asks a
narrower question than whether Haskell builds are universally fast:

> Can an ordinary source change receive a full independent build and test on a
> stock GitHub-hosted runner in under three minutes, without skipping checks?

## Conditions

- GitHub-hosted `ubuntu-24.04` x64 runner
- GHC 9.6.7 and cabal-install 3.12.1.0
- Dependencies fixed by `cabal.project.freeze`
- All library and executable targets built
- All 17 tests run
- Only `~/.cabal/packages` and `~/.cabal/store` cached; Bookledger itself is
  compiled from source on every run

The CI build disables optimization because its purpose is typechecking and
testing this personal CLI, not producing a release binary.

## Results

Measurements were taken on 2026-08-18. Ranges contain two consecutive warm
runs; GitHub runner provisioning accounts for most of the variation.

| Configuration | Job time | Build + test |
| --- | ---: | ---: |
| No cache, optimized | 7m 52s | 5m 53s |
| Empty cache, optimized | 7m 54s | 5m 55s |
| Warm dependency cache, optimized | 1m 59s–2m 06s | 18s |
| Warm dependency cache, unoptimized | 1m 45s–2m 02s | 13–14s |

The dependency cache is about 280 MB and restores in four to seven seconds.
A warm run is 74–78% shorter than the pre-cache baseline. Disabling
optimization consistently saves another four seconds in the build step, but
has little influence on total time because installing GHC and Cabal now takes
roughly 81–95 seconds.

Supporting runs:

- [Pre-cache baseline](https://github.com/M-simplifier/bookledger/actions/runs/32044429198)
- [Empty cache and optimized warm reruns](https://github.com/M-simplifier/bookledger/actions/runs/32046892874)
- [Unoptimized warm reruns](https://github.com/M-simplifier/bookledger/actions/runs/32047929646)

## What this establishes

For this application, slow CI was primarily a failure to reuse compiled
dependencies, not the cost of compiling the application or running its tests.
The under-three-minute target is met on an ephemeral hosted runner without a
self-hosted machine, a custom container, or reduced test coverage.

This is not evidence that cold Haskell builds are cheap, nor that the result
generalizes to large projects or other operating systems. Cold builds remain
close to eight minutes. The next meaningful experiment would target toolchain
provisioning, which now dominates warm CI; further application-level tuning
would save only seconds.
