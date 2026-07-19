<?php
/**
 * Injected static-php-cli patch (passed via `bin/spc build --with-added-patch`).
 * LEGACY CHANNEL — force the portable memcmp fallback for zend_string_equal_val
 * when compiling with clang, instead of PHP's hand-written x86_64/i386 inline asm.
 *
 * PHP 7.4/8.0/8.1 (and 8.3) implement zend_string_equal_val() as GNU inline asm on
 * i386/x86_64 (Zend/zend_string.c), with a memcmp() fallback for every other target
 * (the `#else` in Zend/zend_string.h). arm64 already takes that fallback — which is
 * why it builds fine. On x86_64 the asm is selected whenever __GNUC__ is defined,
 * and clang defines __GNUC__ too. Built by Linux gcc the asm is fine; built by the
 * macOS runner's clang (Xcode 16.4, x86_64) it corrupts the caller's frame and the
 * very first module-startup hash lookup dies with a silent __stack_chk_fail:
 *   php_module_startup -> zend_startup_modules -> zend_startup_module_ex (session's
 *   "spl" dependency lookup, zend_API.c:1835) -> zend_hash_find ->
 *   zend_string_equal_content -> zend_string_equal_val (asm) -> SIGABRT.
 * The crash is x86_64-AND-clang-specific: arm64 (no asm) and Linux x86_64 (gcc) are
 * both unaffected, so a `&& !defined(__clang__)` on the asm guards routes clang to
 * the memcmp fallback and leaves gcc untouched. memcmp is always correct, so this is
 * a safe demotion, not a behavioural change.
 *
 * Two files, three guards, kept in lockstep so exactly one definition survives:
 *   Zend/zend_string.h : the `#if <asm-arch>` that extern-declares the asm version
 *                        (its `#else` is the memcmp inline) — must go false on clang.
 *   Zend/zend_string.c : the i386 `#if` and the x86_64 `#elif` that DEFINE the asm —
 *                        must both go false on clang (else a dangling extern decl).
 *
 * spc `require`s this at EVERY patch point, so it self-gates on the event name.
 * Idempotent: a re-run detects the already-patched guard form and no-ops. FAILS LOUD
 * if a guard is neither in its base nor its patched form — an upstream reword/refactor
 * of this code must be caught, not silently skipped (mirrors the §3 fail-if-no-op patch
 * discipline). Legacy-only, and every legacy minor (7.4/8.0/8.1) ships this asm, so a
 * missing guard is genuinely an error, never an expected "newer php-src" case.
 *
 * Helpers patch_point() / builder() / logger() and SOURCE_PATH are provided by the
 * spc runtime (src/globals/functions.php).
 */

if (patch_point() !== 'before-php-buildconf') {
    return;
}

// One guard edit. Detects the exact patched form first (idempotent no-op), else the
// exact base form (patch it), else throws — a drifted guard must not be silently
// skipped. Returns the number of substitutions made (0 when already patched).
$patch_guard = static function (string $path, string $find, string $replace, string $label): int {
    if (!file_exists($path)) {
        throw new \RuntimeException("legacy zend-string-asm patch: $path not found ($label) — php-src Zend layout changed; re-verify this patch.");
    }
    $src = file_get_contents($path);
    if (str_contains($src, $replace)) {
        return 0; // already carries `!defined(__clang__)` on this exact guard
    }
    $count = 0;
    $new = str_replace($find, $replace, $src, $count);
    if ($count < 1) {
        throw new \RuntimeException(
            "legacy zend-string-asm patch: guard not found in {$path} ({$label}): {$find} "
            . '— php-src Zend/zend_string layout changed; re-verify this patch for '
            . builder()->getPHPVersion() . '.'
        );
    }
    file_put_contents($path, $new);
    return $count;
};

$h = SOURCE_PATH . '/php-src/Zend/zend_string.h';
$c = SOURCE_PATH . '/php-src/Zend/zend_string.c';

$total = 0;
// Header: the combined i386||x86_64 guard that extern-declares the asm version.
$total += $patch_guard(
    $h,
    '#if defined(__GNUC__) && (defined(__i386__) || (defined(__x86_64__) && !defined(__ILP32__)))',
    '#if defined(__GNUC__) && !defined(__clang__) && (defined(__i386__) || (defined(__x86_64__) && !defined(__ILP32__)))',
    'zend_string.h asm decl guard'
);
// Source: the i386 definition guard.
$total += $patch_guard(
    $c,
    '#if defined(__GNUC__) && defined(__i386__)',
    '#if defined(__GNUC__) && !defined(__clang__) && defined(__i386__)',
    'zend_string.c i386 asm guard'
);
// Source: the x86_64 definition guard.
$total += $patch_guard(
    $c,
    '#elif defined(__GNUC__) && defined(__x86_64__) && !defined(__ILP32__)',
    '#elif defined(__GNUC__) && !defined(__clang__) && defined(__x86_64__) && !defined(__ILP32__)',
    'zend_string.c x86_64 asm guard'
);

if ($total === 0) {
    logger()->info('legacy zend-string-asm patch: already applied (clang uses memcmp fallback).');
} else {
    logger()->info(
        "legacy zend-string-asm patch: routed clang to the memcmp zend_string_equal_val "
        . "fallback ({$total} guard(s)) for PHP " . builder()->getPHPVersion()
    );
}
