# Difftest-S native integration

`Makefile.difftest-s` in the BlackParrot repository root builds the existing
`bp_top/verilator` testbench with optional Difftest-S observations and semantic
checking. Difftest-S is disabled by default (`DIFFTEST_S=0`). The enabled path
uses the shared Difftest-S `HostSession`, independent Spike references and
memory-order checker.

The semantic profile is the synchronous `e_bp_multicore_4_cfg`: four harts,
FSM coherence, writeback data caches and 64-bit memory observations. The
coherence and terminal protocols are required for a final semantic verdict.
Asynchronous clock mappings and other coherence configurations are outside
this profile.

## Dependencies

Provide these dependencies before building:

- GNU Make, Bash, Git, Verilator with `--binary` and timing support, and a C++20
  compiler compatible with the Verilator timing runtime.
- The RTL submodules at the revisions recorded by this repository:
  `external/basejump_stl`, `external/HardFloat` and `external/bedrock`.
- A Difftest-S checkout containing
  `src/test/csrc/difftest/adapters/blackparrot` and the shared `rvwmo` sources.
- An ELF-capable `objcopy`, such as `riscv64-unknown-elf-objcopy`, for the native
  ELF-to-binary-to-Verilog memory collateral. Compiling a new program also
  requires its RISC-V compiler/assembler; a prebuilt ELF does not require the
  full BlackParrot SDK.
- For semantic checking, a compatible Spike source tree or SDK containing
  `difftest/ref_api.h`, a matching BlackParrot profile library, and the caller
  bootstrap source described below. Building that Spike library requires its
  C/C++ build tools and `device-tree-compiler` (`dtc`).

Initialize the RTL submodules with:

```bash
BP_RTL=/absolute/path/to/black-parrot
git -C "$BP_RTL" submodule update --init \
  external/basejump_stl external/HardFloat external/bedrock
```

The root entry runs make from `bp_top/verilator`. All caller-supplied source,
library, program and checkout paths below must be absolute. The entry uses
`bsg_cadenv/cadenv.mk` when present and creates a minimal PATH-based fragment
when it is absent. With a supplied ELF and installed tools, this flow does not
require the `black-parrot-sim` meta repository. The general native testbench
options are documented in [Evaluation Guide](eval_guide.md).

## BlackParrot reference library

Use a Spike implementation of the versioned Difftest handle API. An ordinary
upstream Spike executable or a legacy DiffTest library is insufficient. The
library must report `DIFFTEST_REF_PROFILE_ID_BLACKPARROT` (profile 7), RV64,
FLEN64, the requested hart ID, and the `EXTERNAL_MEMORY`, `STATE_V1` and
`OBSERVER_V2` capabilities. Its headers and library must implement the same
API version.

For a compatible Spike tree whose `difftest/Makefile` supports these options,
build a separate BlackParrot library as follows:

```bash
SPIKE_HOME=/absolute/path/to/spike-with-difftest-handle-api
SPIKE_BUILD=/absolute/path/to/new-blackparrot-spike-build
make -C "$SPIKE_HOME/difftest" \
  CPU=BLACKPARROT MULTICORE_DIFF=1 EXTERNAL_MEMORY=1 PURE_API=1 DEBUG= \
  BUILD_DIR="$SPIKE_BUILD" -j4
```

The output is `$SPIKE_BUILD/riscv64-spike-ref-api.so`. `CPU=BLACKPARROT` is
required; the compatible Makefile otherwise defaults to a different CPU.
`PURE_API=1` exports the handle C API and isolates the reference library's C++
symbols from the native simulator. Use a fresh build directory when changing
CPU profile or library configuration. This is an external dependency; cloning
BlackParrot and Difftest-S alone does not provide it.

The BlackParrot reference profile uses
`rv64imafdc_zicsr_zifencei_zba_zbb_zbs_zicbom_zicboz`. The current checker
supports the scalar subset described below. Keep the matching reference
profile when reporting unsupported hardware instructions.

## Caller bootstrap contract

Set `DIFFTEST_S_BOOTSTRAP_SOURCE` to one caller-owned C++ translation unit
providing:

```cpp
#include <cstdint>

extern "C" int bp_difftest_s_session_start(
    const char *elf, uint32_t harts);
```

The testbench calls this function during initialization with the ELF path from
`+bp_difftest_s_elf` and its configured hart count. The Makefile supplies that
plusarg from `SIM_PROG`. Return zero only after successful setup; a nonzero
return terminates simulation. Catch startup exceptions inside this C entry.
The translation unit must provide or include all of the caller's loader and
initialization implementation.

The caller must complete these steps before any `bp_difftest_s_probe_init`:

1. Validate the four-hart configuration and independently load the program into
   `GlobalMem`. Initialize the checked RAM range and load all relevant ELF
   segments, including BSS, with the caller's loader. The native configuration
   loader starts execution at `0x80000000`; the program image and reference
   entry must match that address and the native memory layout. Expected memory
   must come from the independent image and reference execution.
2. Prepare `rvwmo::HostSessionConfiguration` with `platform = "blackparrot"`,
   `reference_profile = DIFFTEST_REF_PROFILE_ID_BLACKPARROT`, and four
   `initial_harts` in hart-ID order 0 through 3. Supply the PC, privilege, GPRs,
   CSRs and interrupt state appropriate to the start of checking. BlackParrot's
   GPR SRAM has no reset: a zero-filled reference state requires an independently
   justified initialization policy, such as program initialization before any
   register read. Set `verification_scope` explicitly if checking begins at an
   architectural checkpoint rather than the complete program start.
3. Declare the same required producers and event capabilities in
   `HostSessionConfiguration::stream.required_producers` and `producers`.
   Capabilities must include lossless events, source positions and watermarks.
   Use the producer roster below.
4. Construct `rvwmo::HostSession(memory, configuration)` and verify both
   `host.configuration()` and `host.session()`. Construct
   `blackparrot::HostSessionAdapter adapter(host)`, then install the native
   adapter with `blackparrot::install_native_online_session(native, adapter)`
   for `DIFFTEST_S_ONLINE=1`. Check its returned `ConversionResult`.
   For terminal capture/replay with `DIFFTEST_S_ONLINE=0`, use
   `blackparrot::install_native_host_session(native, adapter)` instead.

| Producer | ID helper | Event kinds |
| --- | --- | --- |
| One per hart, harts 0 through 3 | `rvwmo::hart_producer_id(hart)` | `InstructionAllocate`, `InstructionCancelAttempt`, `InstructionSquash`, `LocalStore`, `LoadSample`, `InstructionRetire` |
| One publication producer per cache/hart | `rvwmo::memory_fabric_producer_id(hart)` | `StorePublish` |

Configure `blackparrot::Configuration` with matching channels:

```cpp
blackparrot::Configuration native;
for (uint32_t hart = 0; hart < 4; ++hart) {
  const auto channel = rvwmo::hart_producer_id(hart);
  native.harts.push_back({hart, channel, channel, channel});
  native.publication_producers.push_back(
      rvwmo::memory_fabric_producer_id(hart));
}
```

The public headers are `globalmem.h`, `rvwmo/host_session.h`,
`rvwmo/producer_ids.h` and
`adapters/blackparrot/host_session_adapter.h`. `DIFFTEST_S_SPIKE_HOME` supplies
`difftest/ref_api.h`. The `GlobalMem`, `HostSession`, `HostSessionAdapter` and
any objects borrowed by their callbacks must survive until simulation has
finished, including final callbacks. Keep them in a caller-owned object with
process lifetime; local stack objects in the startup function are insufficient.
The bridge rejects repeated installation or installation after probe startup.

## Build and run

Set absolute paths to the prepared dependencies and caller inputs. Use an ELF
whose initialization, instructions and terminal behavior satisfy the contract
above. This example selects online checking:

```bash
BP_RTL=/absolute/path/to/black-parrot
DIFFTEST_ROOT=/absolute/path/to/difftest-s
SPIKE_HOME=/absolute/path/to/spike-with-difftest-handle-api
SPIKE_BUILD=/absolute/path/to/blackparrot-spike-build
BOOTSTRAP=/absolute/path/to/caller_bootstrap.cpp
PROGRAM=/absolute/path/to/program.riscv

make -C "$BP_RTL" -f Makefile.difftest-s \
  build.verilator sim.verilator \
  CFG=e_bp_multicore_4_cfg TAG=checked_program \
  DIFFTEST_S=1 DIFFTEST_S_SEMANTIC=1 DIFFTEST_S_ONLINE=1 \
  DIFFTEST_S_DIR="$DIFFTEST_ROOT" \
  DIFFTEST_S_SPIKE_HOME="$SPIKE_HOME" \
  DIFFTEST_S_SPIKE_LIBRARY="$SPIKE_BUILD/riscv64-spike-ref-api.so" \
  DIFFTEST_S_BOOTSTRAP_SOURCE="$BOOTSTRAP" \
  SIM_PROG="$PROGRAM" OBJCOPY=riscv64-unknown-elf-objcopy \
  VERILATOR_THREADS=4 OBJCACHE=
```

`DIFFTEST_S_SEMANTIC=1` enables `DIFFTEST_S_COHERENCE=1` and
`DIFFTEST_S_TERMINAL=1` by default and requires both to remain enabled.
`DIFFTEST_S_ONLINE=1` requires semantic checking. Enabled builds have a distinct
Difftest-S tag, with separate semantic and online suffixes. Use a fresh model
directory or tag after changing probes, bootstrap implementation, dependencies
or build options. An explicit `OBJCACHE=ccache` opt-in requires an isolated,
validated cache.

For the native baseline, select `DIFFTEST_S=0` with a suitable native program.
`DIFFTEST_S=1` alone enables observation capture; it does not install a semantic
verifier. The native finish API rejects a run without a finalized verifier, so
capture-only output cannot establish a successful semantic run.

## Completion and supported scope

A successful semantic run requires process success, `[BSG-PASS]` and an
exactly one final `[Difftest-S] Pass`. The wrapper rejects a missing verdict,
`Violation`, `Invalid`, `Unsupported`, `Incomplete` or a simulator failure.
An accepted batch with `Pending` is progress, not a final verdict; final Pending
becomes Incomplete. A terminal source error invalidates any earlier cached
success.

All four harts must actually retire WFI, stop issuing, finish pending
pipeline/writeback work and complete their checked memory effects. The probes
and testbench then seal the instruction sources and close the final memory
prefix. A software done flag, host MMIO finish, heartbeat or temporary idle is
insufficient. Checked memory completion does not assert that every network
FIFO is empty or every dirty cache line has reached DRAM.

The shared session compares PC, raw instruction, integer register results and
ordinary scalar RAM effects against independent references; store address,
data and mask are audited against REF. Full CSR equality, AMO/LRSC, floating
point, vector or split accesses, cache-block/MMIO effects, and trap/interrupt
architecture are outside the current scalar contract. Unsupported source
shapes remain explicit Unsupported or Incomplete.

Ordinary cached scalar stores publish logically at certified WBUF acceptance,
not at the earlier permission grant or the later SRAM drain. Hit stores keep a
provisional REF-audit record and publish without waiting in LocalMem; stores
that retire while their miss is outstanding remain local until replay is
accepted by WBUF. Both paths retain per-byte writer identity and independent
REF address/data/mask audit. Physical drain and continuous ownership/coherence
checks remain mandatory before final success. Use matching updated RTL probes
and the BlackParrot host adapter: the private admission and accepted-miss
records are required in addition to the existing drain records.

Core and cache observations retain their common even/odd half-cycle ticks.
Equal-tick observations from distinct producers do not acquire order from
callback sequence, producer IDs or instruction IDs. A sample/retirement tie,
ambiguous groups containing writes and mixed forwarding can remain Incomplete.
A private stable-byte certificate can establish an order window for an
ordinary SRAM load across an older W-to-R FENCE only after source closure and
absence of any hart's overlapping logical store-input transition.
A tied current-input forwarding sample can use a strictly later model point
inside a closed stable-writer interval after each affected byte writer is
independently matched. This does not invent a cross-hart ordering phase.
Fully forwarded loads crossing a later preceding store-publication boundary,
missing evidence and uncertified intervals remain Incomplete/Unsupported.
The certificate covers the supported scalar window, not every FENCE
combination or a complete coherence-protocol proof.

Terminal capture retains at most 65,536 allocated instructions and 1,048,576
observations. Online mode reclaims accepted source facts and bounds unresolved
work at 65,536 live native identities and 32,768 events in one ready source
prefix. Exhausted bounds fail explicitly. See the Difftest-S repository's
`src/test/csrc/difftest/adapters/blackparrot/README.md` for adapter details.
