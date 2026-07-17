<?php
/**
 * resolve-builds.php — decide what to build this run and at which revision (§7, §9, §10.1).
 *
 * The revision counter is read from the PREVIOUS manifest (the single source of
 * truth), never derived by scanning possibly-pruned asset filenames.
 *
 * Per (php, os, arch), relative to the previously-published manifest:
 *   - new patch      (target absent, or old.php != latest patch) -> revision = 1
 *   - rebuild same   (target present with old.php == latest)      -> revision = old.revision + 1
 *                                                                    (only when --force)
 *
 * Output (stdout): a GitHub Actions matrix — {"include":[ {minor,php,os,arch,revision,runner,spc,name}, ... ]}
 * containing only the targets that need building this run. A human summary goes to stderr.
 *
 * Usage:
 *   php resolve-builds.php --latest=latest.json --targets=targets.json \
 *       --minors="8.2 8.3 8.4 8.5" [--old-manifest=old.json] [--only-minor=8.4] \
 *       [--only-target=macos-aarch64] [--force]
 *
 * --only-target restricts to a single "<os>-<arch>" (e.g. for iterating on a
 * single failing target); it must match one of the targets in --targets.
 */

declare(strict_types=1);

function fail(string $msg): never { fwrite(STDERR, "FATAL: $msg\n"); exit(1); }

/** Parse `--key=value` / `--flag` args into an assoc array. */
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

function read_json_file(string $path, string $label): array {
    $raw = @file_get_contents($path);
    if ($raw === false) fail("cannot read $label at $path");
    $data = json_decode($raw, true);
    if (!is_array($data)) fail("invalid JSON in $label at $path");
    return $data;
}

$args = parse_args($argv);

foreach (['latest', 'targets', 'minors'] as $req) {
    if (empty($args[$req])) fail("--$req is required");
}

$latest    = read_json_file($args['latest'], 'latest-patches');   // {"8.4":"8.4.12", ...}
$targets   = read_json_file($args['targets'], 'targets');         // [{os,arch,runner,spc}, ...]
$minors     = preg_split('/\s+/', trim((string) $args['minors']), -1, PREG_SPLIT_NO_EMPTY);
$onlyMinor  = $args['only-minor'] ?? null;
$onlyTarget = $args['only-target'] ?? null;   // "<os>-<arch>", e.g. macos-aarch64
$force      = isset($args['force']);

// Fail loud on a typo'd --only-target rather than silently building nothing.
if ($onlyTarget !== null) {
    $known = array_map(fn($t) => "{$t['os']}-{$t['arch']}", $targets);
    if (!in_array($onlyTarget, $known, true))
        fail("--only-target '$onlyTarget' matches no target (known: " . implode(', ', $known) . ")");
}

// Previous manifest is optional (first run has none). Build an index keyed by
// "minor|os|arch" for O(1) lookup of the current (php, revision).
$oldIndex = [];
if (!empty($args['old-manifest']) && is_file($args['old-manifest'])) {
    $old = read_json_file($args['old-manifest'], 'old-manifest');
    foreach ($old['builds'] ?? [] as $b) {
        if (!isset($b['minor'], $b['os'], $b['arch'], $b['php'], $b['revision'])) continue;
        $oldIndex["{$b['minor']}|{$b['os']}|{$b['arch']}"] = $b;
    }
}

$include = [];
$summary = [];

foreach ($minors as $minor) {
    if ($onlyMinor !== null && $minor !== $onlyMinor) continue;

    $php = $latest[$minor] ?? null;
    if ($php === null) fail("no latest patch resolved for minor $minor");
    if (!str_starts_with($php, "$minor.")) fail("latest '$php' is not within minor '$minor'");

    foreach ($targets as $t) {
        if ($onlyTarget !== null && "{$t['os']}-{$t['arch']}" !== $onlyTarget) continue;
        $key  = "$minor|{$t['os']}|{$t['arch']}";
        $prev = $oldIndex[$key] ?? null;

        if ($prev === null) {
            // Brand-new (minor, target) — first build of this patch.
            $revision = 1; $reason = 'new build';
        } elseif ($prev['php'] !== $php) {
            if (version_compare($php, $prev['php'], '<')) {
                // DOWNGRADE: the resolved "latest" patch is LOWER than what's
                // already published — almost always a transient php.net read.
                // Never regress the manifest: refuse it, keep the published
                // build, and don't reset the revision (which would break the
                // monotonic (patch,revision) auto-heal contract, §7). Loud so a
                // genuine upstream retraction is noticed.
                fwrite(STDERR, "  WARN: resolved $php < published {$prev['php']} for $minor {$t['os']}-{$t['arch']} — refusing downgrade\n");
                $summary[] = "  skip  $php {$t['os']}-{$t['arch']} (refused downgrade from {$prev['php']})";
                continue;
            }
            // Genuine newer patch — reset the revision.
            $revision = 1; $reason = "new patch {$prev['php']} -> $php";
        } elseif ($force) {
            // Rebuild of an unchanged patch (c-ares cutover, spc bump, security).
            $revision = ((int) $prev['revision']) + 1; $reason = "rebuild r{$prev['revision']} -> r$revision";
        } else {
            // Same patch, not forced — nothing to do; the old entry carries over.
            $summary[] = "  skip  $php {$t['os']}-{$t['arch']} (already at r{$prev['revision']})";
            continue;
        }

        $entry = [
            'minor'    => $minor,
            'php'      => $php,
            'os'       => $t['os'],
            'arch'     => $t['arch'],
            'revision' => $revision,
            'runner'   => $t['runner'],
            'spc'      => $t['spc'],
            // Convenience display token used for job names / logs.
            'name'     => "$php-$revision-{$t['os']}-{$t['arch']}",
        ];
        $include[] = $entry;
        $summary[] = sprintf("  BUILD %s-%d %s-%s  (%s)", $php, $revision, $t['os'], $t['arch'], $reason);
    }
}

fwrite(STDERR, "resolve-builds: " . count($include) . " target(s) to build" .
    ($force ? " [force]" : "") . ($onlyMinor ? " [only-minor $onlyMinor]" : "") .
    ($onlyTarget ? " [only-target $onlyTarget]" : "") . "\n");
fwrite(STDERR, implode("\n", $summary) . "\n");

echo json_encode(['include' => $include], JSON_UNESCAPED_SLASHES) . "\n";
