<?php
/**
 * Injected static-php-cli patch (passed via `bin/spc build --with-added-patch`).
 * LEGACY CHANNEL ONLY — backport ext/intl's "compile as C++17" fix to EOL PHP < 8.1.
 *
 * spc pins ICU to the latest stable (currently ICU 78). ICU >= 75 requires its
 * *consumers* to compile as C++17. php-src selects the intl C++ standard in
 * ext/intl/config.m4 via `PHP_CXX_COMPILE_STDCXX(<std>, mandatory, PHP_INTL_STDCXX)`:
 *   - PHP 8.1+ passes 17 (upstream bumped it in 8.1.34 / 8.2.20 / 8.3.8), so 8.1
 *     builds against modern ICU — and does, in this same pipeline.
 *   - PHP 7.4.33 / 8.0.30 (EOL, never backported) still pass 11, so their intl
 *     .cpp files fail to compile against ICU 78 headers.
 * Both EOL versions' build/php_cxx_compile_stdcxx.m4 ALREADY understands the "17"
 * argument, so a one-token bump in config.m4 — applied here, before `./buildconf`
 * regenerates `configure` — is the entire fix. No macro changes needed.
 *
 * spc `require`s this at EVERY patch point, so it MUST self-gate on the event name
 * (`patch_point()`) and the PHP version (`builder()`). It FAILS LOUD if the macro
 * line is absent on an affected version — php-src ext/intl layout drift must be
 * caught, not silently skipped (mirrors the §3 fail-if-no-op patch discipline).
 * Idempotent: a re-run that finds the standard already at 17 is a no-op.
 *
 * Helpers `patch_point()` / `builder()` / `logger()` and the SOURCE_PATH constant
 * are provided by the spc runtime (src/globals/functions.php).
 */

if (patch_point() !== 'before-php-buildconf') {
    return;
}

// 8.1+ already ships PHP_CXX_COMPILE_STDCXX(17, ...); only EOL minors need this.
if (builder()->getPHPVersionID() >= 80100) {
    return;
}

$m4 = SOURCE_PATH . '/php-src/ext/intl/config.m4';
if (!file_exists($m4)) {
    // intl isn't part of this build (the legacy set always includes it, so this
    // is just defensive) — nothing to patch.
    return;
}

$src = file_get_contents($m4);
$new = preg_replace(
    '/(PHP_CXX_COMPILE_STDCXX\()\s*11\s*,/',
    '${1}17,',
    $src,
    -1,
    $count
);

if ($count < 1) {
    // Already at 17 → idempotent no-op. Anything else means the line moved/renamed.
    if (str_contains($src, 'PHP_CXX_COMPILE_STDCXX(17,')) {
        return;
    }
    throw new \RuntimeException(
        'legacy intl C++17 patch matched no PHP_CXX_COMPILE_STDCXX(11, ...) in ' . $m4
        . ' for PHP ' . builder()->getPHPVersion()
        . ' — php-src ext/intl layout changed; re-verify the legacy intl patch for this php-src.'
    );
}

file_put_contents($m4, $new);
logger()->info(
    "legacy intl C++17 patch: bumped ext/intl/config.m4 C++ standard 11 -> 17 ({$count} site) "
    . 'for PHP ' . builder()->getPHPVersion()
);
