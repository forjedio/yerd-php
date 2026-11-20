<?php
/**
 * PHP 8.6 source compat for the PECL extensions we build in STATICALLY (spc v3,
 * stable channel). Installed into the spc tree by apply-spc-v3-patches.sh (#8),
 * which makes Package\Target\php\unix::patchBeforeBuildconf() require this file
 * and call yerd_php86_compat() once php-src and every ext source are extracted.
 * No-op below PHP 8.6.
 *
 * PHP 8.6 removed a batch of long-deprecated aliases that apcu 5.1.28, phpredis
 * 6.3.0, pecl imap and protobuf still use (zval_dtor, INI_STR, zval_is_true, ...).
 * spc v3 restores exactly these for *phpize/shared* builds
 * (unix::installRemovedMacroCompatHeader, PR #1226) but not for static ones, so
 * the same block goes onto the end of php-src's main/php.h here, plus:
 *   - php_hash_bin2hex -> zend_bin2hex (8.6 removed the ext/hash inline; same
 *     signature, neither writes a terminator) — phpredis.
 *   - apcu: php_verror() lost its `params` argument in 8.6. Fixed upstream in
 *     apcu master (90899684) but unreleased (5.1.29 was reverted).
 * swoole is NOT fixable this way (every release hard-errors on PHP >= 8.6), so it
 * is dropped for 8.6 in config.sh extensions_for_minor() instead.
 *
 * Drop each piece once the extension ships a release with 8.6 support.
 * Fails loud (throws) on layout drift, like every other yerd spc patch.
 */

function yerd_php86_compat(string $php_src, int $version_id): void
{
    // apcu runs for EVERY minor, before the 8.6 gate: spc v3 SYMLINKS ext sources
    // into php-src/ext (ext/apcu -> source/ext-apcu), and that shared source dir
    // is not re-extracted when the PHP version changes. So the edit must be
    // version-neutral — it selects the php_verror() form at compile time.
    yerd_apcu_php_verror_compat("{$php_src}/ext/apcu/apc.c");

    if ($version_id < 80600) {
        return;
    }

    // --- removed-macro compat block on main/php.h ----------------------------
    $header = "{$php_src}/main/php.h";
    if (!is_file($header)) {
        throw new \RuntimeException("yerd php86 compat: {$header} not found");
    }
    if (!str_contains((string) file_get_contents($header), 'YERD_PHP86_COMPAT')) {
        file_put_contents($header, <<<'C'

            /* yerd-php: aliases removed in PHP 8.6, restored for static PECL builds
             * (scripts/spc-v3-php86-compat.php). Every one is #ifndef-guarded. */
            #ifndef YERD_PHP86_COMPAT
            #define YERD_PHP86_COMPAT
            #ifndef XtOffsetOf
            # define XtOffsetOf(s_type, field) offsetof(s_type, field)
            #endif
            #ifndef ZVAL_IS_NULL
            # define ZVAL_IS_NULL(z) (Z_TYPE_P(z) == IS_NULL)
            #endif
            #ifndef zval_dtor
            # define zval_dtor(zvalue) zval_ptr_dtor_nogc(zvalue)
            #endif
            #ifndef zval_is_true
            # define zval_is_true(op) zend_is_true(op)
            #endif
            #ifndef INI_INT
            # define INI_INT(name) zend_ini_long((name), strlen(name), 0)
            #endif
            #ifndef INI_FLT
            # define INI_FLT(name) zend_ini_double((name), strlen(name), 0)
            #endif
            #ifndef INI_STR
            # define INI_STR(name) zend_ini_string_ex((name), strlen(name), 0, NULL)
            #endif
            #ifndef INI_BOOL
            # define INI_BOOL(name) ((bool) INI_INT(name))
            #endif
            #ifndef ZEND_PARSE_PARAMS_THROW
            # define ZEND_PARSE_PARAMS_THROW 0
            #endif
            #ifndef EMPTY_SWITCH_DEFAULT_CASE
            # define EMPTY_SWITCH_DEFAULT_CASE() default: ZEND_UNREACHABLE(); break;
            #endif
            #ifndef zend_parse_parameters_throw
            # define zend_parse_parameters_throw(num_args, ...) zend_parse_parameters(num_args, __VA_ARGS__)
            #endif
            #ifndef ZEND_WRONG_PARAM_COUNT
            # define ZEND_WRONG_PARAM_COUNT() { zend_wrong_param_count(); return; }
            #endif
            #ifndef WRONG_PARAM_COUNT
            # define WRONG_PARAM_COUNT ZEND_WRONG_PARAM_COUNT()
            #endif
            #ifndef OPENBASEDIR_CHECKPATH
            # define OPENBASEDIR_CHECKPATH(filename) php_check_open_basedir(filename)
            #endif
            #ifndef php_hash_bin2hex
            # define php_hash_bin2hex(out, in, in_len) zend_bin2hex((out), (in), (in_len))
            #endif
            #endif

            C, FILE_APPEND);
        echo "yerd php86 compat: restored removed macros in main/php.h\n";
    }

}

/**
 * apcu: php_verror(docref, params, type, fmt, args) became
 * php_verror(docref, type, fmt, args) in PHP 8.6. The call sits inside a
 * multi-line #define, so it can't be #if'd in place; route it through a
 * YERD_PHP_VERROR wrapper defined at the top of apc.c that picks the form by
 * PHP_VERSION_ID. Idempotent, correct for every minor, and also repairs an apc.c
 * left with the bare 8.6 form. No-op when apcu isn't built; throws on drift.
 */
function yerd_apcu_php_verror_compat(string $apc): void
{
    if (!is_file($apc)) {
        return;
    }
    $src = (string) file_get_contents($apc);
    $call = 'YERD_PHP_VERROR(NULL, "", verbosity, format, args)';
    if (str_contains($src, $call)) {
        return; // already applied
    }
    $n = 0;
    $src = str_replace(
        ['php_verror(NULL, "", verbosity, format, args)', 'php_verror(NULL, verbosity, format, args)'],
        $call,
        $src,
        $n
    );
    if ($n !== 1) {
        throw new \RuntimeException("yerd php86 compat: expected 1 apcu php_verror() call in {$apc}, found {$n}; re-verify the apcu fix");
    }
    $wrapper = <<<'C'
        /* yerd-php: php_verror() lost its params arg in PHP 8.6 (scripts/spc-v3-php86-compat.php) */
        #if PHP_VERSION_ID >= 80600
        # define YERD_PHP_VERROR(docref, params, type, format, args) php_verror((docref), (type), (format), (args))
        #else
        # define YERD_PHP_VERROR(docref, params, type, format, args) php_verror((docref), (params), (type), (format), (args))
        #endif

        C;
    // after the last #include, so PHP_VERSION_ID (php.h) is defined
    $pos = strrpos($src, "\n#include ");
    if ($pos === false) {
        throw new \RuntimeException("yerd php86 compat: no #include in {$apc}; re-verify the apcu fix");
    }
    $eol = strpos($src, "\n", $pos + 1);
    $src = substr($src, 0, $eol + 1) . $wrapper . substr($src, $eol + 1);
    file_put_contents($apc, $src);
    echo "yerd php86 compat: apcu php_verror() routed through YERD_PHP_VERROR\n";
}
