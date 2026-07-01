<?php
/**
 * generate-manifest.php — produce the new php.json (§7).
 *
 * The manifest is the single source of truth and must list EVERY current build
 * (supported_minors × targets × cli/fpm), not just the ones rebuilt this run:
 *   - carry over each still-supported entry from the previous manifest verbatim
 *     (its file/sha256/size stay valid — we don't have those tarballs locally);
 *   - overwrite the entries we rebuilt this run with fresh php/revision/file/
 *     sha256/size computed from the actual tarball bytes in --assets-dir;
 *   - drop entries for minors no longer supported (retention / §2).
 *
 * Usage:
 *   php generate-manifest.php --built=built.json --assets-dir=dist \
 *       --minors="8.2 8.3 8.4 8.5" [--old-manifest=old.json] \
 *       [--generated-at=2026-07-01T00:00:00Z] [--schema=1]
 *
 * --built is the resolve-builds matrix .include array (or any array of
 * {minor,php,os,arch,revision}); each referenced tarball must exist in --assets-dir.
 */

declare(strict_types=1);

function fail(string $m): never { fwrite(STDERR, "FATAL: $m\n"); exit(1); }

function parse_args(array $argv): array {
    $out = [];
    foreach (array_slice($argv, 1) as $a) {
        if (!str_starts_with($a, '--')) fail("unexpected arg: $a");
        $a = substr($a, 2);
        if (str_contains($a, '=')) { [$k, $v] = explode('=', $a, 2); $out[$k] = $v; }
        else $out[$a] = true;
    }
    return $out;
}

function read_json(string $p, string $label): array {
    $raw = @file_get_contents($p);
    if ($raw === false) fail("cannot read $label at $p");
    $d = json_decode($raw, true);
    if (!is_array($d)) fail("invalid JSON in $label at $p");
    return $d;
}

/** Canonical asset name — MUST match scripts/config.sh asset_name(). */
function asset_name(string $php, int $rev, string $kind, string $os, string $arch): string {
    return "php-$php-$rev-$kind-$os-$arch.tar.gz";
}

/** Build a cli/fpm object {file,sha256,size} from a real tarball, or fail. */
function asset_obj(string $dir, string $php, int $rev, string $kind, string $os, string $arch): array {
    $file = asset_name($php, $rev, $kind, $os, $arch);
    $path = "$dir/$file";
    if (!is_file($path)) fail("expected asset $file not found in $dir (needed for freshly-built entry)");
    $sha = hash_file('sha256', $path);
    $size = filesize($path);
    if ($size === false || $size <= 0) fail("empty/unreadable asset $file");
    return ['file' => $file, 'sha256' => $sha, 'size' => $size];
}

$args = parse_args($argv);
foreach (['built', 'assets-dir', 'minors'] as $r) if (empty($args[$r])) fail("--$r is required");

$built      = read_json($args['built'], 'built');
$built       = $built['include'] ?? $built;   // accept either the matrix wrapper or a bare array
$assetsDir  = rtrim((string) $args['assets-dir'], '/');
$supported  = array_flip(preg_split('/\s+/', trim((string) $args['minors']), -1, PREG_SPLIT_NO_EMPTY));
$schema     = (int) ($args['schema'] ?? 1);
$generated  = (string) ($args['generated-at'] ?? gmdate('Y-m-d\TH:i:s\Z'));

// index keyed by "minor|os|arch"
$index = [];

// 1. carry over still-supported entries from the previous manifest.
if (!empty($args['old-manifest']) && is_file($args['old-manifest'])) {
    $old = read_json($args['old-manifest'], 'old-manifest');
    foreach ($old['builds'] ?? [] as $b) {
        if (!isset($b['minor'])) continue;
        if (!isset($supported[$b['minor']])) continue;   // drop out-of-range minors (§2)
        $index["{$b['minor']}|{$b['os']}|{$b['arch']}"] = $b;
    }
}

// 2. overwrite/insert the entries we rebuilt this run (fresh bytes from disk).
foreach ($built as $e) {
    foreach (['minor', 'php', 'os', 'arch', 'revision'] as $k) if (!isset($e[$k])) fail("built entry missing $k");
    if (!isset($supported[$e['minor']])) fail("built entry for unsupported minor {$e['minor']}");
    $rev = (int) $e['revision'];
    $index["{$e['minor']}|{$e['os']}|{$e['arch']}"] = [
        'php'      => $e['php'],
        'minor'    => $e['minor'],
        'os'       => $e['os'],
        'arch'     => $e['arch'],
        'revision' => $rev,
        'cli'      => asset_obj($assetsDir, $e['php'], $rev, 'cli', $e['os'], $e['arch']),
        'fpm'      => asset_obj($assetsDir, $e['php'], $rev, 'fpm', $e['os'], $e['arch']),
    ];
}

// 3. validate + normalise every final entry (§7 field rules).
$builds = array_values($index);
usort($builds, fn($a, $b) => [$a['minor'], $a['os'], $a['arch']] <=> [$b['minor'], $b['os'], $b['arch']]);

$seen = [];
foreach ($builds as $b) {
    foreach (['php', 'minor', 'os', 'arch', 'revision', 'cli', 'fpm'] as $k) if (!isset($b[$k])) fail("final entry missing $k: " . json_encode($b));
    if (!preg_match('/^\d+\.\d+\.\d+$/', $b['php'])) fail("bad php '{$b['php']}'");
    if (!str_starts_with($b['php'], $b['minor'] . '.')) fail("minor '{$b['minor']}' != prefix of php '{$b['php']}'");
    if (!in_array($b['os'], ['macos', 'linux'], true)) fail("bad os '{$b['os']}'");
    if (!in_array($b['arch'], ['aarch64', 'x86_64'], true)) fail("bad arch '{$b['arch']}'");
    if ((int) $b['revision'] < 1) fail("revision must be >= 1 for {$b['php']} {$b['os']}-{$b['arch']}");
    foreach (['cli', 'fpm'] as $kind) {
        $o = $b[$kind];
        if (empty($o['file']) || !preg_match('/^[0-9a-f]{64}$/', $o['sha256'] ?? '') || (int) ($o['size'] ?? 0) < 1)
            fail("bad $kind object for {$b['php']} {$b['os']}-{$b['arch']}");
        $want = asset_name($b['php'], (int) $b['revision'], $kind, $b['os'], $b['arch']);
        if ($o['file'] !== $want) fail("$kind file '{$o['file']}' != expected '$want'");
    }
    $key = "{$b['minor']}|{$b['os']}|{$b['arch']}";
    if (isset($seen[$key])) fail("duplicate (minor,os,arch) $key — uniqueness violated");
    $seen[$key] = true;
}

$manifest = ['schema' => $schema, 'generated_at' => $generated, 'builds' => $builds];
echo json_encode($manifest, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES) . "\n";
fwrite(STDERR, "generate-manifest: " . count($builds) . " build(s) written.\n");
