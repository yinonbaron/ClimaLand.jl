# Stable Representative Validation v1 readiness

Audit date: 2026-08-01. Repository revision at the start of the audit:
`4e3852acb575e713d371d4d82f98689020048ec2`.

The public entry point is:

```sh
julia --startup-file=no --project=test \
  test/testbed_validation/validation_runner.jl \
  --scope representative --models all --reference pinned \
  --output validation-output
```

The same command is used by the Representative scientific-validation workflow.
It writes `validation-output/validation_report.toml` in success, scientific
failure, timeout, and preflight-failure paths.

## Acceptance status

| Ticket #57 criterion | Status | Evidence or blocker |
| --- | --- | --- |
| One runner and aggregate report for all five models | In progress | Bounded model processes and deterministic aggregation are connected. CASA-C, CASA-CN, MIMICS-C, and MIMICS-CN have pinned worker adapters. CORPSE payload staging is fail-closed pending a published payload schema and scientific executor. |
| Pinned artifacts and forced-fresh mode | Blocked | Reference publication defines immutable role-addressed bundles, but CORPSE/MIMICS bundles are not published. Real fresh build and model commands are not connected to the public runner. |
| CI and local command use the same path | Ready | Both use `validation_runner.jl` with Representative, all models, and pinned references. |
| Scope, model, reference, report, eligibility, publication, and alias documentation | Partial | The ADRs and this directory document the contracts. A consolidated user guide should be completed after the remaining execution paths exist. |
| Focused and relevant repository tests | Partial | Focused runner and orchestration tests pass. The all-five Representative execution cannot run before publication and CORPSE/fresh integration. |
| Timings against the one-hour budget | Partial | Existing CASA Core/Smoke timings are recorded below. Per-model Representative timings require the published all-five run. |

## Measured checks

Measurements used Julia 1.12.6 on macOS with the repository test environment.

| Check | Result | Wall time |
| --- | ---: | ---: |
| `model_process_orchestration_tests.jl` | 28/28 passed | 5.60 s |
| `validation_runner_tests.jl` baseline | 121/121 passed | 818.56 s |
| Pinned Core and Smoke CASA-C scientific testset | 26/26 passed | 598.0 s |
| Synthetic five-model report aggregation | passed | 7.6 s including Julia startup |
| Public default preflight without unpublished bundles | expected exit 2 with a five-model report | 27 s including Julia startup |

The baseline runner suite was measured before the multi-model adapter edit; the
post-edit checks were deliberately limited to static loading, policy loading,
payload-role resolution, CLI preflight paths, and synthetic aggregation to avoid
repeating the ten-minute scientific baseline while required artifacts remain
unpublished.

## Remaining blocking contracts

1. Publish and bind the Representative CORPSE, MIMICS-C, and MIMICS-CN
   references as one compatible set with the forcing and CASA references.
2. Define the scientific schema of CORPSE's `boundaries` and `reduced_history`
   payloads and connect them to the current calibrated CORPSE executor. The
   publication manifest currently proves file identity but does not define how
   the scientific arrays map to comparison variables and stages.
3. Connect real pinned Fortran build and per-model fresh execution commands to
   the existing ephemeral fresh-reference process orchestration.
4. Run the exact all-five Representative command, record every model timing and
   aggregate timing, and close any scientific or report-schema failures.
