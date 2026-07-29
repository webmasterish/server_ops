<?php
/**
 * Point a migrated site's production config at its Hetzner database.
 *
 *   php set-site-db.php <target-config> <db-name> [reference-config]
 *
 *   php set-site-db.php \
 *     /var/www/vhosts/dotaim/videotizer.com/httpdocs/.config/master_config.php \
 *     videotizer_website_wp
 *
 * These sites keep production settings in .config/master_config.php -- wp-config
 * picks it by $_SERVER['SERVER_NAME'], with .config/config.php as the generic
 * fallback and develop_config.php for *.localhost. On Hostinger master_config
 * held the u918436082_* names; on Hetzner it must hold the local-convention
 * names (<project>_website_wp / root), since by house convention local and live
 * differ only in the password.
 *
 * The password is COPIED from a site already working on this server, read
 * directly out of its config at the moment it is needed. It is never printed,
 * never passed on a command line (so it cannot appear in ps), and never written
 * anywhere except the target file. CLAUDE.md sanctions exactly this.
 *
 * Idempotent. Writes a timestamped .bak next to the target before changing it.
 */

declare(strict_types=1);

$target = $argv[1] ?? null;
$dbName = $argv[2] ?? null;
$reference = $argv[3]
    ?? '/var/www/vhosts/dotaim/dotaim.com/httpdocs/.config/master_config.php';

if ($target === null || $dbName === null) {
    fwrite(STDERR, "usage: php set-site-db.php <target-config> <db-name> [reference-config]\n");
    exit(1);
}

foreach ([$target, $reference] as $f) {
    if (!is_readable($f)) {
        fwrite(STDERR, "not readable: $f\n");
        exit(1);
    }
}

/** Extract a define()'d constant's value without ever echoing it. */
function read_define(string $file, string $key): ?string
{
    $re = "/define\(\s*'" . preg_quote($key, '/') . "'\s*,\s*'(.*?)'\s*\)/s";
    return preg_match($re, file_get_contents($file), $m) ? $m[1] : null;
}

$password = read_define($reference, 'DB_PASSWORD');
if ($password === null || $password === '') {
    fwrite(STDERR, "could not read DB_PASSWORD from reference: $reference\n");
    exit(1);
}

$values = [
    'DB_NAME'     => $dbName,
    'DB_USER'     => 'root',
    'DB_PASSWORD' => $password,
    'DB_HOST'     => 'localhost',
];

$contents = file_get_contents($target);

$backup = $target . '.bak-' . date('Y-m-d-His');
if (file_put_contents($backup, $contents) === false) {
    fwrite(STDERR, "could not write backup: $backup\n");
    exit(1);
}

foreach ($values as $key => $value) {
    $re = "/(define\(\s*'" . preg_quote($key, '/') . "'\s*,\s*')(.*?)('\s*\))/s";
    // Escape backreference syntax in the replacement -- a password containing
    // $1 or \1 would otherwise be mangled into something else entirely.
    $safe = str_replace(['\\', '$'], ['\\\\', '\\$'], $value);
    $contents = preg_replace($re, '${1}' . $safe . '${3}', $contents, 1, $count);
    if ($count !== 1) {
        fwrite(STDERR, "failed to replace $key in $target (matched $count times)\n");
        exit(1);
    }
}

if (file_put_contents($target, $contents) === false) {
    fwrite(STDERR, "could not write: $target\n");
    exit(1);
}

// Report names only. The password is deliberately reported as a length.
printf("updated %s\n", $target);
printf("  backup      %s\n", basename($backup));
printf("  DB_NAME     %s\n", read_define($target, 'DB_NAME'));
printf("  DB_USER     %s\n", read_define($target, 'DB_USER'));
printf("  DB_HOST     %s\n", read_define($target, 'DB_HOST'));
printf("  DB_PASSWORD set, %d chars\n", strlen((string) read_define($target, 'DB_PASSWORD')));
