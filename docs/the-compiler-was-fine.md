# I fed my hand-optimized vault to a new Solidity compiler. The compiler was fine. My vault was not.

Yesterday I saw a tweet about [oksolc](https://github.com/okcontract/oksolc), a from-scratch reimplementation of the Solidity compiler in Zig that claims byte-identical output to solc 0.8.36. I had an eight-month-old repo that looked like the perfect test input: [YulSafe](https://github.com/yodablocks/yulsafe), an ERC4626 vault with twelve inline assembly blocks, packed storage, raw LOG opcodes and Solady underneath. The plan was to throw it at the new compiler and file whatever broke.

The compiler did not break. Everything else did. Here is what two days of taking my own project seriously looked like, in the order it happened.

## Day one: the repo was not what its README said

YulSafe's README claimed "up to 59% gas savings on zkSync Era", 127 passing tests, and "production ready" three paragraphs above an "unaudited" disclaimer. The badge linked to a placeholder username. There was no LICENSE file, so the "MIT" in the README was legally nothing. No CI. And the zkSync profile in the Foundry config was commented out, which meant every gas number had been measured on a plain EVM and never on the chain the project was named after.

None of that is unusual for a side project. All of it is the kind of thing you stop seeing after the first week.

## The donation attack that cannot happen

While writing real invariants I found that the existing "share price never decreases" invariant asserted that an unsigned integer was at least zero. It could not fail. Its comment also claimed donations could raise the share price, which for this vault is false: the contract never reads its own token balance. The price comes from a packed storage word that only changes inside deposit, mint, withdraw and redeem. Send tokens straight to the vault and the price moves by exactly zero wei.

That makes the classic ERC4626 inflation attack inert. The 1000-share burn on the first deposit, which the README presented as the defense, is a second layer for a rounding edge case. I replaced the empty invariant with two real ones, then mutated the vault check to make sure they actually fail. They do. The trade-off, now written down: tokens sent to the vault directly are stranded forever, and there is deliberately no sweep function, because a sweep turns "no stranded value" into a trust assumption about the owner.

## Thinking like an attacker found a real bug

Then I read every line as an adversary. The worst finding was boring and real: the custom error for capacity overflow was raised from assembly with a hard-coded selector, in six places, and the selector was wrong. `ExceedsMaxCapacity()` hashes to `0x2ba549be`. The contract emitted `0x83920801`. Any integrator matching on that error would never catch it. No test had noticed because no test matched on it.

The rest was ERC4626 compliance. `withdraw` and `mint` always rounded up by adding one, even when the division was exact, so the preview functions disagreed with the real calls and `withdraw(maxWithdraw(owner))` could revert. The view functions read `totalAssets` from the packed slot but `totalSupply` from the ERC20, and shares were minted after the token transfer, which is the read-only reentrancy pattern: a token with transfer hooks could observe an inflated price mid-deposit. Fixing that last one had a side effect I did not expect. Reading both totals from one slot cut `convertToShares` from 4,774 gas to 2,674, and the headline saving against Solady's own ERC4626 went from 59% to 67%.

## Then I measured the thing the README was named after

The vault compiles through zksolc and passes its whole suite on the EraVM emulator. So far so good. But forge's gas report is useless on zkSync, every test shows about 994 million gas because of a fixed bootloader cost, and `gasleft()` inside the emulator returns nonsense like 465 gas for a storage read. So I deployed both vaults to a local zkSync node, sent the same transaction sequence to each, and read `gasUsed` from the receipts.

On EraVM, YulSafe's writes cost 5 to 16% more than Solady's baseline, the same pattern as on the EVM, because the security checks are not free. The views, 67% cheaper on the EVM, were 6 to 8% cheaper by `estimateGas`. EraVM charges every transaction a large fixed cost for the bootloader and for publishing state to L1, and a single saved SLOAD barely moves the total.

The README now opens with "an EVM-optimized ERC4626 vault, tested on the EVM and on zkSync Era". It used to say "for zkSync Era". Publishing the number that corrects your own headline is uncomfortable and it is the entire point of measuring.

## The compiler

Building oksolc needs Zig 0.16.0, Bun 1.4.2 and TypeScript 7.0.2, exact versions, because the CLI embeds a browser UI and the build script compares tool version strings byte for byte. Homebrew's Zig pulls LLVM 21 as a multi-gigabyte dependency; the official tarball is 50 MB and self-contained. Build time, two and a half minutes.

Then the comparison. I pointed Foundry at the oksolc binary, rebuilt the via-IR profile on solc 0.8.36, and diffed every artifact against the upstream build: 45 contracts including Solady, forge-std and all the tests. Creation bytecode, runtime bytecode, ABI and metadata identical in all 45. Then I removed Foundry from the loop and fed one hand-built Standard JSON request to both compilers directly. Identical bytecode, identical metadata down to the embedded compiler version string, and the same 60 warnings with the same text.

I filed that as [issue #2](https://github.com/okcontract/oksolc/issues/2) on their repo, the first issue they had. Their frozen compatibility corpus has five reference outputs, so real-world assembly-heavy code is a useful data point. A contributor closed it within minutes: "Thanks for the (positive) report!"

## Day two: static analysis, a property suite, and a redeploy

Slither found nothing exploitable, but its summary printer flagged that the vault can receive ETH with no way to send it out. Solady marks its five ownership functions `payable` to save gas, two of them callable by anyone, and Solidity forbids overriding `payable` as non-payable. So ETH attached to those calls is locked forever. Low severity, now documented. Aderyn found the same thing independently, once I stopped using the version on crates.io, which is a stale 0.1.9 that crashes on its own update check; the real project is at 0.6.8. Both analyzers now run in CI with every triaged finding written down next to its verdict.

The a16z ERC4626 property suite passes all 26 properties with zero tolerance at 2,000 fuzz runs. The old testnet deployment predated the selector fix, so the v0.2.0 code is redeployed and verified on zkSync Sepolia. Verification needed a small script, because foundry-zksync's verifier sends settings the explorer rejects and the explorer forbids remappings.

## What it added up to

| | Before | After |
|---|---|---|
| Tests | 127 | 166 |
| CI pipelines | 0 | 5 (EVM, via-IR, EraVM, Slither, Aderyn) |
| Real contract bugs fixed | 0 | 1, plus four compliance fixes |
| Gas claim | 59%, EVM only, labelled zkSync | 67% on EVM, 6 to 8% on EraVM, both published |
| License file | none | MIT |
| Compiler conformance | none | byte-identical on oksolc, 45 artifacts |

Fourteen pull requests, one tagged release, and a README I can link to without caveats.

The lesson I keep coming back to: I went looking for bugs in someone else's compiler and found them in my own vault, because I had never pointed the same scrutiny at my own code. The tools that made the difference were not exotic. Real invariants instead of placeholder ones. A mutation check to prove the invariants can fail. Measuring on the actual target instead of the convenient one. And reading the code as if I wanted to steal from it.

oksolc is at [github.com/okcontract/oksolc](https://github.com/okcontract/oksolc). YulSafe is at [github.com/yodablocks/yulsafe](https://github.com/yodablocks/yulsafe), unaudited, and now honest about it.

## Postscript: did the assembly matter?

After publishing this I asked the question the write-up left open. I rewrote the vault in plain Solidity with the same storage layout, two `uint96` fields next to each other, and not one line of assembly. It passes the same 26 ERC4626 properties.

The views cost the same to within five gas. The compiler emits one SLOAD for two adjacent 96-bit fields on its own. The plain version is about 1,400 gas cheaper on every write, on the EVM and on EraVM alike. The only thing the hand-written Yul buys is a smaller deployment, and under via-IR that gap is 2%.

So the entire gas advantage over Solady's vault comes from a two-line layout decision. The twelve assembly blocks were technique, not savings. The numbers are in the README under "Did the assembly matter?", and I would rather have found that out myself than have a reader find it for me.

