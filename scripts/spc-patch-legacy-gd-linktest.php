<?php
/**
 * Injected static-php-cli patch (passed via `bin/spc build --with-added-patch`).
 * LEGACY CHANNEL ONLY — backport PHP 8.0's PHP_TEST_BUILD change to EOL PHP 7.4.
 *
 * PHP 7.4's build/php.m4 defines PHP_TEST_BUILD with AC_RUN_IFELSE — it compiles,
 * links, AND EXECUTES a trivial probe binary. PHP 8.0 rewrote the SAME macro to
 * AC_LINK_IFELSE (link-only, never executed). ext/gd/config.m4 calls PHP_TEST_BUILD
 * as its final "GD build test", so on 7.4 `./configure` runs a code-less probe that
 * segfaults at load on the macOS x86_64 runner (Apple-framework init in the CI
 * sandbox) and aborts with "GD build test failed" — even though the link itself
 * succeeds and NO gd/image code is in the probe. 8.0/stable never run it, so they
 * pass. (Linux is immune anyway: the aarch64-on-x86 gnu-docker build is cross, and
 * AC_RUN_IFELSE's cross branch skips execution.)
 *
 * The real php/php-fpm binary is unaffected — the probe links no gd code, and the
 * stable channel builds --enable-gd against the same static libs on the same runner
 * and passes the §5 gate. The correct, upstream-aligned fix is 8.0's macro: switch
 * AC_RUN_IFELSE -> AC_LINK_IFELSE inside 7.4's PHP_TEST_BUILD. AC_LINK_IFELSE takes
 * only success/fail actions; the macro's now-unused 4th (cross) arg is ignored by
 * autoconf. This also hardens 7.4's other PHP_TEST_BUILD run-probes (openssl, ...).
 *
 * Applied at before-php-buildconf so `./buildconf` regenerates `configure` from the
 * patched macro. Only 7.x still ships the AC_RUN_IFELSE form (8.0+ are already
 * link-only), so gate on PHP < 8.0. Idempotent; fails loud on php.m4 layout drift
 * (§3 patch discipline). Anchored on the PHP_TEST_BUILD body so it touches ONLY
 * that macro's AC_RUN_IFELSE, never the other run-probes in php.m4.
 *
 * Helpers patch_point() / builder() / logger() and SOURCE_PATH come from the spc
 * runtime (src/globals/functions.php).
 */

if (patch_point() !== 'before-php-buildconf') {
    return;
}

// 8.0+ already ship AC_LINK_IFELSE; only 7.x has the executing AC_RUN_IFELSE form.
if (builder()->getPHPVersionID() >= 80000) {
    return;
}

$m4 = SOURCE_PATH . '/php-src/build/php.m4';
if (!file_exists($m4)) {
    throw new \RuntimeException('legacy GD link-test patch: build/php.m4 not found at ' . $m4);
}

$src = file_get_contents($m4);

// Tolerant of whitespace between the LIBS assignment and the macro call. The
// `LIBS="$4 $LIBS"` line is unique to PHP_TEST_BUILD (uses the macro's 4th arg),
// so this never rewrites any of php.m4's other AC_RUN_IFELSE run-probes.
$new = preg_replace(
    '/(LIBS="\$4 \$LIBS"\s*\n\s*)AC_RUN_IFELSE\(/',
    '${1}AC_LINK_IFELSE(',
    $src,
    1,
    $count
);

if ($count < 1) {
    // Already link-only (idempotent) is fine; anything else is a layout change.
    if (preg_match('/LIBS="\$4 \$LIBS"\s*\n\s*AC_LINK_IFELSE\(/', $src)) {
        return;
    }
    throw new \RuntimeException(
        'legacy GD link-test patch: PHP_TEST_BUILD / AC_RUN_IFELSE anchor not found in ' . $m4
        . ' for PHP ' . builder()->getPHPVersion() . ' — php.m4 layout changed; re-verify.'
    );
}

file_put_contents($m4, $new);
logger()->info(
    'legacy GD link-test patch: PHP_TEST_BUILD AC_RUN_IFELSE -> AC_LINK_IFELSE '
    . "({$count} site) for PHP " . builder()->getPHPVersion()
);
