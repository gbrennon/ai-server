# Pi and OMP Coding-Agent Performance Investigation

This note records evidence about slow coding-agent sessions using the local Qwen3-30B model.

## Scope

- Investigation only; no deployment or service changes were performed.
- Sources include Pi session JSONL, OMP session JSONL, and OMP `stats.db`.
- Measurements are historical and tied to the recorded session paths below.

## Previously Established Pi Evidence

Session root: `~/.pi/agent/sessions/`.

Session file:
`2026-09-25T03-22-54-219Z_01a0d696-5f8b-76b8-bd31-e6b72c8f4793.jsonl`

Task: read `card.rs` and implement a `ManaCost` value object.

- About four hours elapsed.
- 178 local-model assistant responses were recorded.
- 83 `read` calls were made.
- 83 `edit` calls were made.
- 81 edits failed and 2 edits succeeded.
- The known failed-edit breakdown was 61 stale exact-text mismatches and 20
  identical replacements.
- The dominant loop was `read -> edit -> failure -> read -> edit`.
- The model was configured with thinking disabled.

The quality hook was not the primary delay. It added work after writes, but the
repeated failed tool calls multiplied the delay much more significantly.

## OMP Evidence From the Same Task

Session root: `~/.omp/agent/sessions/`.

Session file:
`2026-09-25T17-17-43-491Z_01a0d992-acc3-73f7-ac04-c9809a4d16e4.jsonl`

The OMP session used the same local Qwen3-30B model and the same user request:
read `src/domain/entities/card.rs` and implement a value object for mana cost.

Observed behavior:

- OMP started in plan mode, so the working tree was read-only.
- The file mention injected approximately 701 lines of `card.rs` into the first
  request context.
- The first local-model response took 33.6 seconds, with 32.8 seconds to first
  token, and only issued a `read` call.
- The next local-model response took 5.5 seconds and delegated research.
- Three OMP scout agents were started, all using the same local model.
- The scouts performed 43 reads, 8 greps, and 6 globs combined.
- The scouts produced no implementation edit before the session ended.
- The parent waited for roughly six minutes, then the wait was aborted when the
  session was disposed.
- The parent session made no successful code edit.

OMP therefore confirms the same underlying weakness in a different harness:
large injected context causes a slow first turn, and delegation can add a long
research phase without reaching implementation.

## OMP Configuration Factors

The active OMP configuration at `~/.omp/agent/config.yml` contains several
important defaults:

- `plan.defaultOnStartup` is `true`.
- `task.prewalk` is `true`.
- `tier.subagent` is `inherit`.
- The configured `slow` and `tiny` roles use the local Qwen3-30B model.
- The configured `default`, `task`, and `web` roles use remote models, but the
  reproduced session explicitly used the local model.

This means OMP can add plan-mode restrictions and prewalk/delegation overhead
before implementation. These are harness policy costs, separate from model
generation speed, and should be measured in any fair comparison.

## OMP Aggregate Measurements

The OMP database is `/home/gbrennon/.omp/stats.db`.

For all OMP HellStone sessions using the short model identifier
`Qwen3-30B-A3B-Instruct-2507-Q4_K_M.gguf`:

- Main-agent messages: 1,278.
- Main-agent average response duration: 5.45 seconds.
- Main-agent average time to first token: 2.61 seconds.
- Main-agent tool calls: 1,268 recorded in the project aggregate.
- Main-agent `read` errors: 491 of 810, or 60.6 percent.
- Main-agent `edit` errors: 281 of 373, or 75.3 percent.

For the OMP mana-cost session specifically:

- Parent local-model turns: 3, averaging 13.82 seconds.
- Scout local-model turns: 59, averaging 17.87 seconds.
- Scout tool calls: 43 reads, 8 greps, and 6 globs.
- Scout read errors: 3 combined.
- The OMP database recorded 626,667 cache-read tokens for the parent and
  581,828 for the scouts.

The aggregate edit-error rate closely matches the Pi observation. This makes
failed edit recovery a harness/model interaction problem, not a Pi-only issue.

## OMP Error Categories

Across OMP HellStone sessions, the recorded tool errors included:

- 519 other edit errors.
- 85 wrong block locators.
- 49 hashline syntax or header errors.
- 10 range/body mismatches.
- 497 read errors.
- 447 bash errors.
- One plan-mode write-blocked edit.
- One provider stream/socket failure.

OMP uses a hashline editing protocol in these sessions. Some failures are
protocol-specific, but the repeated retry behavior is still relevant: the agent
receives a precise tool error and often continues issuing incompatible edits
instead of switching to a fresh full-file read or a different edit method.

## Deeper Findings

1. **The model is not the only bottleneck.**
   Normal local-model turns can be several seconds, but a bad tool trajectory
   creates dozens or hundreds of turns.

2. **Context size causes first-turn latency.**
   In the OMP reproduction, the 701-line file mention preceded a 32.8-second
   time-to-first-token response. Large prompt assembly and model prefill must be
   measured separately from generation speed.

3. **Thinking-off is a reliability tradeoff.**
   The Pi session had thinking disabled. OMP used medium planning behavior, but
   still failed to reach implementation because plan mode and delegation added
   process overhead. More reasoning alone is not a sufficient fix.

4. **Edit protocol correctness is a major failure surface.**
   Pi failed mainly on stale exact-text and identical replacements. OMP added
   hashline locator and range-body failures. A model that cannot reliably form
   the active edit protocol will spend its entire budget on recovery.

5. **There is no effective circuit breaker.**
   Neither harness stopped the trajectory after repeated edit failures, repeated
   read failures, or no progress toward a successful write. OMP can also wait
   for delegated work until session disposal.

6. **Delegation can improve exploration but worsen completion latency.**
   OMP parallelized three read-only scouts, but the parent did not synthesize and
   implement before disposal. Delegation needs a bounded completion contract,
   not only a spawn-and-wait mechanism.

7. **Quality gates are downstream.**
   The observed failures occur before meaningful verification. Relaxing or
   removing quality gates would not address the dominant failure mode.

## Highest-Value Next Measurements

- Add per-turn timestamps for prompt assembly, time to first token, generation,
  tool execution, and tool-result handling in both harnesses.
- Classify every edit failure by protocol error, stale content, identical change,
  path error, and provider failure.
- Measure turns and wall time from first failed edit to first successful edit.
- Measure the effect of omitting automatic file mentions and replacing them with
  a bounded symbol-level read.
- Run the same task with thinking off, low thinking, and medium thinking while
  holding context and tool protocol constant.
- Add a bounded recovery experiment: after two consecutive edit failures, force
  one fresh read and prohibit another identical edit; after four failures, stop
  and ask for intervention.
- Compare direct implementation against OMP delegation with a strict scout time
  limit and an explicit parent synthesis step.

## Current Conclusion

The dominant performance problem is an uncontrolled tool-use failure loop. The
local 30B model is adequate for short application requests and simple coding
steps, but its coding throughput collapses when a tool call fails and the agent
continues without changing strategy. The first engineering target should be
progress-aware recovery and bounded trajectories, followed by context-size and
model-thinking experiments.
