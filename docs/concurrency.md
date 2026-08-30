# Concurrency and bounded work

Swift 6 strict concurrency is on, `TranscriptionManager` is `@MainActor`, and WhisperKit and
Sparkle are imported `@preconcurrency`. This file covers the parts where that combination bites:
the stall watchdog, the two bounds on model loading, the destructive-removal contract, and the
actor-hop hazards that a plausible edit would reintroduce.

---

## Why anything here is bounded at all

**Backs:** `Speech2Text/ModelDownloadWatchdog.swift` · `Speech2Text/TranscriptionManager.swift`

`startTranscription()` flips `status` to `.loadingModel` before awaiting the download, so an await
that never returns pins `isProcessing` true for the rest of the process: the Transcribe button
stays disabled, the status line reads "Downloading and loading model (first time may take a
while)..." forever, and Sparkle's
relaunch-postpone loop (`UpdaterDelegate`) polls a busy flag that will never clear — which loses
the update entirely. See [distribution.md#relaunch-not-check](distribution.md#relaunch-not-check)
for the other end of that dependency.

That is reachable today, not theoretical. WhisperKit's Hub downloader *looks* defended — a 10 s
request timeout and 5 retries — but **the retry budget resets on every 10 MB chunk written**, so a
connection that trickles a chunk now and then retries forever. And the metadata phase that
precedes each file runs on `URLSession.shared`, whose resource timeout is **7 days**. Neither is
configurable through any WhisperKit-level API.

**Only model loading is bounded.** `isProcessing` is also true while transcribing, and that path
is unwatched: `extractAudio` awaits `AVAssetExportSession` on the user's file, ordinarily local
compute but not immune — an input on a network or removable volume that vanishes mid-export can
hang, stranding an update exactly as above. Bounding it needs a different mechanism (export
publishes progress, and the legitimate duration is the length of the user's audio), so it is
knowingly left open rather than papered over.

---

## Stall watchdog

**Backs:** `Speech2Text/ModelDownloadWatchdog.swift` (`withStallWatchdog`) ·
`Speech2Text/TranscriptionManager.swift` (`loadModel`) · `Speech2TextTests/StallWatchdogTests.swift`

`withStallWatchdog` runs an operation and fails with `StallTimeout` if a `ProgressTicker` reports
no progress for `idle`.

**A stall watchdog, not a deadline.** A slow-but-progressing operation is never penalized, however
long it takes. A 1.5 GB model on a thin link legitimately takes hours, so any wall-clock timeout
generous enough to be safe would be too generous to be useful. Slow is fine; silent is not.

A caller with nothing to tick from can still use it as a plain ceiling: a ticker nobody ticks makes
`idle` a wall-clock deadline. `loadModel(named:)` uses it both ways.

`ProgressTicker` only ever has its *changing* observed — the value itself is never interpreted,
which is why wrap-around (`&+`) is fine and why the ticker doesn't care what a "unit" of progress
is. It is `Sendable` and lock-guarded because WhisperKit's `ProgressCallback` is `@Sendable` and is
invoked from whatever context the Hub downloader is on, never the main actor.

`StallTimeout` is deliberately its own error type rather than a `TranscriptionError` case: the two
phases it guards fail for different reasons and tell the user different things, so each caller maps
it to its own case.

### Abandon, not await

The obvious spelling — a `withThrowingTaskGroup` racing the operation against a sleep — **cannot
work here**. The group awaits every child at scope exit, so a wedged operation would wedge the
group and reproduce the exact bug this file exists to prevent. So the operation runs in an
unstructured task, and whichever arm finishes first resumes the caller through `OneShot`, which
drops the late arrival.

`OneShot` also tolerates a result arriving *before* the continuation does, which is what makes the
cancellation handler safe: cancellation can land while `withCheckedThrowingContinuation` is still
handing over the continuation. The `onCancel` arm exists because the caller is parked on a
continuation, which cancellation cannot reach on its own — it hops back to the actor and resumes it.

Both tasks are cancelled on the way out. The watchdog is normally stopped by the arm awaiting the
operation, but that arm can't run its `defer` until `work.value` returns — so against a
cancellation-deaf operation, a cancelled caller would otherwise leave the watchdog polling the main
actor until `idle` elapsed, long after the caller was gone.

**Never keep what an abandoned operation returns.** WhisperKit's Hub *swallows* cancellation:
`HubApi.snapshot` returns its destination URL as a **success** when the task is cancelled
mid-download, pointing at an incomplete snapshot. So the stall path throws, and the caller must not
cache anything the abandoned task produces later. This is also why the verdict is latched
(`isTimingOut`) *before* draining — an operation that completes during the drain must not win the
race and hand back its result.

### Suspending clock

`SuspendingClock`, **not** `ContinuousClock`: a continuous clock keeps counting while the machine
is asleep, so a closed lid longer than `idle` would make the first poll after wake declare a stall
on a download that never had a chance to resume. What this measures is "has progress happened
lately *while we were running*", which is exactly what a suspending clock counts.

### The drain

Cancelling the operation on the way out is best-effort — it only stops work that honors
cancellation — but it is what keeps a wedged download from holding its socket and writing into the
model cache after failure has already been reported. `drain` then holds the failure back until it
has actually stopped.

**Both** recoveries available to the user race that orphan, not just the obvious one:

- an immediate retry starts a second downloader on the same partial file;
- "delete the downloaded models" is admitted too — `wipeDirectory` guards on `!isProcessing` and
  `deletion == nil`, and neither blocks once the error lands: `isProcessing` goes false with the
  `status = .error(…)` assignment on the failure path, and `deletion` is set and cleared only
  *inside* `wipeDirectory`, so a download never set it at all. A delete that runs under a live
  writer can leave a
  repopulated snapshot whose `.metadata` disagrees with what is on disk, so the *next* attempt
  resumes from a stale offset.

Neither is fatal — every outcome is one more delete away from clean, and Settings re-walks and
reports residual bytes — and the drain makes both unlikely rather than likely.

**It is a shrunk window, not a lock.** An operation deaf to cancellation is abandoned when the
drain elapses, because a recovery path that waits indefinitely on a wedged task is the bug this
file exists to remove. The alternative — refusing deletes while an orphan is unaccounted for —
would gate the recovery path on a task that by definition might never finish.

`Drain` is the small shared box between the two arms: `isTimingOut` latches the verdict so a late
completion can't overturn it, and `didFinish` is how the watchdog knows the orphan has actually
stopped and the drain can end early.

### Parameters

- `idle` — how long a silence may last before the operation is treated as wedged.
- `poll` — how often that silence is checked. **Granularity, not precision:** the effective
  detection window is `idle` rounded up to the next poll.
- `ticker` — the `ProgressTicker` the operation reports progress into. This is the parameter the
  whole stall-vs-deadline distinction hinges on: a ticker the operation actually ticks makes this a
  stall watchdog; **a ticker nobody ticks turns `idle` into a plain wall-clock deadline**, which is
  how the `loadModels()` ceiling is expressed.
- `drain` — how long to wait, after cancelling a stalled operation, for it to actually unwind
  before the failure is reported.
- `operation` — runs on the main actor, like its caller; the awaits inside it (network, file I/O)
  leave the actor as usual.

---

## Two-phase model load

**Backs:** `Speech2Text/TranscriptionManager.swift` (`loadModel(named:)`)

`loadModel` is `WhisperKit(model:downloadBase:)` taken apart into its two phases so the download
half can be watched. **It is a faithful split, not a reinterpretation:** with a non-nil `model`,
WhisperKit's own `setupModels` passes the name straight to `WhisperKit.download(variant:)` with
these same repo/endpoint defaults, and constructing with `download: false` and no `modelFolder` is
a no-op rather than an error. `downloadBase` keeps models in the app-owned Application Support
folder (see [architecture.md#model-cache-directory](architecture.md#model-cache-directory)) instead
of the Hub default `~/Documents/huggingface`.

**Both phases are bounded, but not in the same way.** The download reports progress, so it gets a
true stall watchdog. `loadModels()` cannot be watched that way — it reports nothing a watchdog
could read, and Core ML specialization is legitimately slow the first time a model meets a chip —
so it gets a plain ceiling instead, deliberately far beyond any real load.

It needs one. **`loadModels()` is NOT purely local.** It ends in `loadTokenizerIfNeeded()`, which
falls back to fetching the tokenizer from the Hub whenever no local `tokenizer.json` is found — the
normal first-run case. That download can wedge exactly like the model download can, and it would
pin `.loadingModel` forever. A half-hour ceiling is a poor error message but a correct backstop:
the busy flag clears, so the UI and Sparkle's relaunch-postpone loop both come back.

Splitting the phases also moves loading **into** `.loadingModel`, where the status line already
claims it happens. WhisperKit otherwise defers loading to the first `transcribe(...)` call — same
work, reported as transcription progress. `transcribe` won't reload what is already loaded, so
nothing happens twice.

**Assignment is deliberately last.** A partial download leaves a snapshot that `loadModels()`
rejects, and caching a half-built engine would make every later run fail the same way from the
"already loaded" fast path.

### Engine release ordering

The engine being replaced is released **before** the new one allocates its weights. Holding both
across the load would roughly double peak memory on a model switch — the old code never did,
because it left loading to the first `transcribe(...)`, by which point the old engine was already
gone. On failure this leaves no engine loaded, which costs a reload from the on-disk cache and
keeps `loadedModel` honest about what is in memory.

This covers the ordinary switch, **not** the ceiling timeout: an abandoned `loadModels()` keeps its
`kit` alive until it finishes on its own, so a retry after that rare failure really can hold two
sets of weights. Core ML loading isn't cancellable in any way that could be relied on, so there is
nothing better to do than let it finish.

---

## Idle-timeout arithmetic

**Backs:** `Speech2Text/TranscriptionManager.swift` (`modelDownloadIdleTimeout`,
`modelDownloadPollInterval`, `modelDownloadDrain`, `modelLoadCeiling`)

`modelDownloadIdleTimeout` is **half an hour, and must not be tightened.** The window is not a
guess, it is arithmetic.

WhisperKit's Hub downloader reports progress only when it flushes a **10 MB chunk**, so the window
sets a hard throughput floor of 10 MB per window:

Taking the chunk as 10 MiB (10,485,760 B):

| Window | Implied floor |
| --- | --- |
| 30 minutes | ~5,825 B/s — ~5.7 KiB/s, ≈46 kbps |
| 10 minutes | ~17,476 B/s — ~17.1 KiB/s, ≈140 kbps |

A link under the floor is declared stalled no matter how healthy it is — and because Hub's resume
state *also* only advances per flushed chunk, every retry restarts from the same boundary, so **the
model becomes permanently undownloadable rather than merely slow.** That is the exact inversion of
the watchdog's purpose, so the floor has to sit below any link someone might plausibly be waiting
on: even the 75 MB `tiny` model is a multi-hour download at 46 kbps.

Silence isn't only about bandwidth. The repo file listing and the per-file metadata requests that
precede each download emit nothing, and neither does the hash verification of an already-cached
snapshot — sweeps whose duration scales with file count and latency.

The cost of being generous is only how long a genuinely wedged download takes to report. Fast
failure was never the goal; a bounded busy flag is.

**`modelDownloadPollInterval`** (5 s) is granularity, not precision — no reason to notice a
half-hour stall within less than a few seconds.

**`modelDownloadDrain`** (30 s) is generous on purpose: the user cannot read the error message,
open Settings and click Delete inside it, and 30 seconds is invisible next to the half-hour stall
that preceded it. See [the drain](#the-drain).

**`modelLoadCeiling`** (30 min) is not a stall window — that phase reports nothing to watch — so it
has to clear the slowest legitimate case by a wide margin: a first-ever Core ML specialization of
the largest model on the oldest supported chip, minutes rather than tens of minutes. Half an hour
is far past that, which is the point: it never fires on slow hardware, and it still guarantees
`.loadingModel` ends.

---

## The removal contract

**Backs:** `Speech2Text/TranscriptionManager.swift` (`wipeDirectory`, `deleteAllModels`,
`removeAllAppData`, `deleteCache`) · `Speech2Text/ContentView.swift` (`performRemoval`)

`wipeDirectory` is the shared machinery behind both destructive removals.

- **Refuses** (returns `nil`, nothing touched) while a transcription is in flight — removing files
  out from under a live `transcribe(...)` would corrupt the run — or while another removal is going.
- **Marks `deletion` synchronously before the first suspension**, so a transcription started
  concurrently (also on the main actor) sees `canTranscribe == false` and can't begin reading or
  writing the directory mid-removal. Because `deletion` is independent of `status`, a concurrent
  `clearFiles()` (→ `.idle`) can't drop the guard mid-removal.
- **Runs the blocking `removeItem` to completion off the main actor** via `Task.detached` — a
  half-removed tree is worse than a finished one, and `removeItem` isn't cancellation-aware —
  capturing existence in the same hop.
- **Drops the in-memory engine whenever the directory *existed*** before the attempt, not only on
  full success: a partial removal (children unlinked, final node removal failed) can still have
  deleted the weight files, leaving a loaded engine pointing at missing files, which would let the
  next `startTranscription()` take the "already loaded" fast path against a gutted cache. Only a
  genuine no-op leaves a loaded engine alone.
- **Leaves `status` untouched** — a removal is orthogonal, owned by `deletion`.

The three-valued return matters: `nil` = the guard refused and nothing was touched; `false` = a
real attempt that didn't fully remove; `true` = fully removed. Settings re-walks and surfaces
residual bytes on a partial failure rather than publishing 0.

`deleteCache`'s boolean **cannot** distinguish "nothing was there" from "children were unlinked but
the final node removal failed" — `removeItem` recurses depth-first, so a late failure can leave
weight files already gone yet return `false`. Callers that need to know whether the tree was
*touched* must check existence separately.

### Remove All App Data

Settings are cleared through the injected `UserDefaults` (`removeObject`), **not** by deleting the
`.plist` file: writes are mediated by `cfprefsd`, which would just re-materialize the file from its
in-memory cache after a raw delete. Using the injected store also keeps this hermetic under the
app-hosted test process.

`restoreDefaults()` is deliberately **not** called afterward — its `didSet` writers would
immediately re-persist the keys just cleared. In-memory values are left as they are; a relaunch
loads the code defaults from the now-empty store. The settings clear runs after `wipeDirectory`
returns and is synchronous (no `await` before it), so it can't interleave with a concurrent
transcription; it still runs on a no-op removal, because settings live independently of the folder.

Sparkle's own preferences are deliberately outside `Keys.all` — see
[distribution.md#the-seam](distribution.md#the-seam).

---

## SE-0338 and the actor hops

**Backs:** `Speech2Text/ContentView.swift` (`performRemoval`, `refreshSize`) ·
`Speech2Text/TranscriptionManager.swift` (`currentCacheSize`, `cacheSize(of:)`)

Under SE-0338 a **nonisolated async** member executes on the cooperative pool, not the caller's
actor. That cuts both ways here, and both directions are load-bearing.

**`performRemoval`'s `removal` parameter must be `@MainActor`.** A nonisolated
`() async -> Bool` would hop off the main actor at `await removal()` *before*
`deleteAllModels`/`removeAllAppData` runs, leaving `deletion` nil across a suspension that a
refocus (`controlActiveState` → `.key` on dialog dismissal) could slip a fresh walk into. With
`@MainActor` the call is same-actor and runs straight into `wipeDirectory`, which sets `deletion`
before it suspends.

**`currentCacheSize` is nonisolated on purpose**, so the synchronous `cacheSize` walk runs *off*
the main actor. It stays in the caller's structured task tree, so a superseded refresh cancelling
its task propagates into `cacheSize`'s `Task.isCancelled` loop and aborts the walk.

A `false` result from a removal is ambiguous: a genuine failure (a real attempt that left the
target on disk), or the manager *refusing* because work is in flight — which leaves everything
intact by design and is **not** an error. Only a real attempt clears the busy flags by the time it
returns, so if either is still set the call was refused and the alert is suppressed. That check runs
synchronously right after `removal()` on the main actor, so the flags reflect the exact post-call
state with no interleaving.

---

## Cache-walk ownership

**Backs:** `Speech2Text/ContentView.swift` (`refreshSize`)

`refreshSize()` recomputes the cache size off the main actor, and five separate things keep it
honest — four in `refreshSize` itself, plus the pre-delete cancel that `performRemoval` owns:

- **Coalesced via `isMeasuring`** — a call while a walk is running is a no-op, so the
  `.task` + `.onChange(controlActiveState)` double-fire on first open (and rapid refocus) collapses
  to a single walk. A genuine refocus after it finishes still re-measures. The delete path clears
  `isMeasuring` where it cancels the walk — **it cannot rely on the cancelled walk clearing the
  flag itself**, because that walk may not have resumed yet, and until it does the failure branch's
  `refreshSize()` would be coalesced away and Settings would keep showing the pre-delete size.
- **Cancelled before a delete starts** — `performRemoval` cancels the in-flight walk so a GB-scale
  enumerator isn't racing `removeItem` over the same tree, reading entries as they are unlinked.
- **Bails while a delete is in flight** — a walk begun against a tree being removed could read a
  partial size and land after the delete publishes `0`. `deleteAllModels` sets `isRemovingData`
  synchronously before its first suspension and clears it only after, so this guard covers the
  whole delete: no walk can start mid-delete.
- **Does NOT blank `cacheBytes`** — the first measure already starts from `nil` (showing
  "Calculating…"), while a refresh that already has a value keeps the prior figure on screen until
  the new one lands. No "Calculating…" flash on every refocus. `.utility` priority keeps the
  background size calc off the foreground's back.
- **Ownership via `measureGeneration`** — each walk captures the generation it was launched under
  and only mutates the shared `isMeasuring`/`cacheBytes` while it is still the current walk. A
  superseded walk bails without clearing `isMeasuring` (which now belongs to a newer walk) or
  overwriting `cacheBytes`. Without this, a late-resuming cancelled walk could clear the coalescing
  flag mid-walk, letting a later refocus spawn a second concurrent, untracked walk.

---

## Upstream facts (WhisperKit 1.x)

Re-verify these on a WhisperKit bump. The drift job runs the end-to-end suite, so it catches a
*behavioural* break — but none of these facts is asserted anywhere, so a change that stays green
while shifting them (a different chunk size, a new resume strategy) passes unnoticed.
See [testing.md#whisperkit-drift](testing.md#whisperkit-drift).

- Hub reports download progress **only per flushed 10 MB chunk**, and resume state advances on the
  same boundary.
- The Hub downloader's retry budget (5 retries, 10 s request timeout) **resets on every chunk**.
- The per-file metadata phase runs on `URLSession.shared` — **7-day** resource timeout.
- `HubApi.snapshot` returns its destination URL as a **success** when cancelled mid-download.
- `loadModels()` ends in `loadTokenizerIfNeeded()`, which **fetches from the Hub** on first run.
- `setupModels` with a non-nil `model` passes the name straight to `WhisperKit.download(variant:)`;
  constructing with `download: false` and no `modelFolder` is a no-op, not an error.
