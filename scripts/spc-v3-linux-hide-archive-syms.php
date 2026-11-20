<?php
/**
 * Linux, spc v3 (stable channel): hide static-archive symbols from php/php-fpm's
 * dynamic symbol table (yerd#252) — the v3 replacement for -Wl,--exclude-libs,ALL.
 *
 * Why not a linker flag: v3 links Linux with zig (`zig cc`), and
 *   - --exclude-libs is rejected outright ("unsupported linker arg"), failing
 *     PHP's configure ("C compiler cannot create executables");
 *   - --version-script is ACCEPTED but silently dropped for executables (zig's
 *     src/link/Lld.zig only forwards it when building a shared library).
 *
 * So the hiding happens in the inputs instead: once every library is built (php's
 * buildconf stage), every global symbol DEFINED in buildroot/lib/*.a is set to
 * HIDDEN visibility in place with llvm-objcopy --set-symbols-visibility. Hidden
 * symbols still link normally, but the linker never exports them — exactly what
 * --exclude-libs,ALL did. PHP's own objects are untouched, so with
 * --export-dynamic the PHP API (what yerd-dump / pcov link against) stays
 * exported, while a library dlopened via FFI (libvips) binds to its own system
 * libpng/libxml2 instead of PHP's static copies.
 *
 * Needs llvm-objcopy >= 19 (build-target.sh installs llvm-19 if absent). §5.8 of
 * verify-artifact.sh is the end-to-end proof. Fails loud (throws) rather than
 * ever shipping an unhidden binary. Idempotent (re-hiding hidden is a no-op).
 */

function yerd_find_llvm_objcopy(): string
{
    $candidates = [];
    if (($env = getenv('YERD_LLVM_OBJCOPY')) !== false && $env !== '') {
        $candidates[] = $env;
    }
    $candidates[] = 'llvm-objcopy';
    // versioned binaries (Ubuntu/Debian: /usr/bin/llvm-objcopy-18), newest first
    $versioned = glob('/usr/bin/llvm-objcopy-*') ?: [];
    usort($versioned, static fn (string $a, string $b): int => version_compare(substr($b, strrpos($b, '-') + 1), substr($a, strrpos($a, '-') + 1)));
    array_push($candidates, ...$versioned);

    foreach ($candidates as $c) {
        $help = [];
        $rc = 0;
        exec(escapeshellarg($c) . ' --help 2>/dev/null', $help, $rc);
        if ($rc === 0 && str_contains(implode("\n", $help), '--set-symbols-visibility')) {
            return $c;
        }
    }
    throw new \RuntimeException('yerd hide-archive-syms: no llvm-objcopy with --set-symbols-visibility (need LLVM >= 19; tried: ' . implode(', ', $candidates) . ')');
}

/** @return string[] global symbols defined in the archive */
function yerd_archive_defined_globals(string $archive): array
{
    $out = [];
    $rc = 0;
    // -g: external only; --defined-only: skip U; -P: "name type ..." per line
    exec('nm -g --defined-only -P ' . escapeshellarg($archive) . ' 2>/dev/null', $out, $rc);
    if ($rc !== 0) {
        throw new \RuntimeException("yerd hide-archive-syms: nm failed ({$rc}) on {$archive}");
    }
    $syms = [];
    foreach ($out as $line) {
        // archive member headers ("libfoo.a[bar.o]:") end in ':' — skip them
        $parts = preg_split('/\s+/', trim($line));
        if (count($parts) < 2 || str_ends_with($parts[0], ':')) {
            continue;
        }
        $syms[$parts[0]] = true;
    }
    return array_keys($syms);
}

/** symbol => visibility (from readelf) for the given names in an archive */
function yerd_archive_symbol_visibility(string $archive, array $names): array
{
    $out = [];
    exec('readelf -Ws ' . escapeshellarg($archive) . ' 2>/dev/null', $out);
    $want = array_flip($names);
    $vis = [];
    foreach ($out as $line) {
        // Num: Value Size Type Bind Vis Ndx Name
        $p = preg_split('/\s+/', trim($line));
        if (count($p) >= 8 && isset($want[$p[7]]) && $p[6] !== 'UND') {
            $vis[$p[7]] = $p[5];
        }
    }
    return $vis;
}

function yerd_linux_hide_archive_syms(string $lib_dir): void
{
    $archives = glob("{$lib_dir}/*.a") ?: [];
    // never hide PHP itself (only present if an embed/libphp build ever lands here)
    $archives = array_values(array_filter($archives, static fn (string $a): bool => !str_contains(basename($a), 'php')));
    if ($archives === []) {
        throw new \RuntimeException("yerd hide-archive-syms: no static archives in {$lib_dir}");
    }
    $objcopy = yerd_find_llvm_objcopy();

    $total = 0;
    $list = tempnam(sys_get_temp_dir(), 'yerd-hide-');
    try {
        foreach ($archives as $a) {
            $syms = yerd_archive_defined_globals($a);
            if ($syms === []) {
                continue;
            }
            file_put_contents($list, implode("\n", $syms) . "\n");
            $out = [];
            $rc = 0;
            exec(escapeshellarg($objcopy) . ' --set-symbols-visibility=' . escapeshellarg($list) . '=hidden ' . escapeshellarg($a) . ' 2>&1', $out, $rc);
            if ($rc !== 0) {
                throw new \RuntimeException("yerd hide-archive-syms: {$objcopy} failed ({$rc}) on {$a}: " . implode(' ', array_slice($out, 0, 5)));
            }
            $total += count($syms);
        }
    } finally {
        @unlink($list);
    }

    // prove it on the same probes §5.8 checks in the final binary
    foreach (['libpng16.a' => 'png_create_read_struct', 'libxml2.a' => 'xmlReadMemory'] as $lib => $probe) {
        $vis = yerd_archive_symbol_visibility("{$lib_dir}/{$lib}", [$probe])[$probe] ?? null;
        if ($vis !== 'HIDDEN') {
            throw new \RuntimeException("yerd hide-archive-syms: {$probe} in {$lib} is " . ($vis ?? 'missing') . ' after hiding, expected HIDDEN');
        }
    }
    echo "yerd hide-archive-syms: {$total} archive symbols in " . count($archives) . " archives set HIDDEN ({$objcopy})\n";
}
