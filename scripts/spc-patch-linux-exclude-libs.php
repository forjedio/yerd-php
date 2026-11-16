<?php
/**
 * Injected static-php-cli patch (passed via `bin/spc build --with-added-patch`).
 * ALL CHANNELS, LINUX ONLY (build-target.sh passes it only for OS=linux).
 *
 * Hide static-archive symbols from php/php-fpm's dynamic symbol table so a library
 * dlopened via FFI (libvips, yerd#252) binds to its own system libpng/libjpeg/libxml2
 * instead of PHP's statically linked copies. The generated Makefile has no LDFLAGS
 * line and spc overrides EXTRA_LDFLAGS_PROGRAM on the make command line, so the flag
 * goes into the BUILD_CLI / BUILD_FPM link recipes themselves. PHP's own objects are
 * not archive members, so the PHP API stays exported for dynamic extensions.
 *
 * No idempotency check: configure regenerates the Makefile on every build. Fails
 * loud on layout drift (§3 patch discipline); §5.8 of verify-artifact.sh is the
 * end-to-end proof.
 *
 * Helpers patch_point() / logger() and SOURCE_PATH come from the spc runtime.
 */

if (patch_point() !== 'before-php-make') {
    return;
}

$makefile = SOURCE_PATH . '/php-src/Makefile';
if (!file_exists($makefile)) {
    throw new \RuntimeException('linux exclude-libs patch: Makefile not found at ' . $makefile);
}

$src = file_get_contents($makefile);
$flag = '-Wl,--exclude-libs,ALL';

foreach (['BUILD_CLI', 'BUILD_FPM'] as $var) {
    $src = preg_replace_callback(
        '/^' . $var . ' = .*$/m',
        static function (array $m) use ($var, $flag): string {
            $anchor = '$(EXTRA_LDFLAGS_PROGRAM)';
            $pos = strpos($m[0], $anchor);
            if ($pos === false) {
                throw new \RuntimeException(
                    "linux exclude-libs patch: {$var} has no {$anchor} — php-src link recipe changed; re-verify."
                );
            }
            return substr_replace($m[0], $anchor . ' ' . $flag, $pos, strlen($anchor));
        },
        $src,
        1,
        $count
    );
    if ($count !== 1) {
        throw new \RuntimeException("linux exclude-libs patch: '{$var} = ' line not found in {$makefile}");
    }
    logger()->info("linux exclude-libs patch: added {$flag} to {$var}");
}

file_put_contents($makefile, $src);
