<?php
/**
 * Point a migrated Piwigo install's config at its Hetzner database.
 *
 *   php set-piwigo-db.php <local/config/database.inc.php> <db-name> [reference-config]
 *
 *   php set-piwigo-db.php \
 *     /var/www/vhosts/mardini/mardini.net/subs/memories.mardini.net/httpdocs/local/config/database.inc.php \
 *     mardini_memories_website_piwigo
 *
 * The WordPress equivalent (set-site-db.php) does not work here: Piwigo has no
 * wp-config and no .config directory. Its settings live in
 * local/config/database.inc.php as a $conf array:
 *
 *   $conf['db_base']     = '...';
 *   $conf['db_user']     = '...';
 *   $conf['db_password'] = '...';
 *   $conf['db_host']     = '...';
 *
 * As with the WordPress version, the password is COPIED from a site already
 * working on this server, read at the moment it is needed. It is never printed,
 * never passed on a command line, and never written anywhere but the target.
 *
 * Idempotent. Writes a timestamped .bak next to the target first.
 */

declare(strict_types=1);

$target = $argv[1] ?? null;
$dbName = $argv[2] ?? null;
$reference = $argv[3]
    ?? '/var/www/vhosts/dotaim/dotaim.com/httpdocs/.config/master_config.php';

if ($target === null || $dbName === null) {
    fwrite(STDERR, "usage: php set-piwigo-db.php <database.inc.php> <db-name> [reference]\n");
    exit(1);
}

foreach ([$target, $reference] as $f) {
    if (!is_readable($f)) {
        fwrite(STDERR, "not readable: $f\n");
        exit(1);
    }
}

/** Pull a define()'d constant out of the reference without echoing it. */
function read_define(string $file, string $key): ?string
{
    $re = "/define\(\s*'" . preg_quote($key, '/') . "'\s*,\s*'(.*?)'\s*\)/s";
    return preg_match($re, file_get_contents($file), $m) ? $m[1] : null;
}

/** Read a $conf['key'] value from a Piwigo config. */
function read_conf(string $file, string $key): ?string
{
    $re = "/\\\$conf\[\s*'" . preg_quote($key, '/') . "'\s*\]\s*=\s*'(.*?)'\s*;/s";
    return preg_match($re, file_get_contents($file), $m) ? $m[1] : null;
}

$password = read_define($reference, 'DB_PASSWORD');
if ($password === null || $password === '') {
    fwrite(STDERR, "could not read DB_PASSWORD from reference: $reference\n");
    exit(1);
}

// db_user root to match the house convention: local and live differ only in
// the password, and every other site on this box connects as root.
$values = [
    'db_base'     => $dbName,
    'db_user'     => 'root',
    'db_password' => $password,
    'db_host'     => 'localhost',
];

$contents = file_get_contents($target);

$backup = $target . '.bak-' . date('Y-m-d-His');
if (file_put_contents($backup, $contents) === false) {
    fwrite(STDERR, "could not write backup: $backup\n");
    exit(1);
}

foreach ($values as $key => $value) {
    $re = "/(\\\$conf\[\s*'" . preg_quote($key, '/') . "'\s*\]\s*=\s*')(.*?)('\s*;)/s";
    // Escape backreference syntax: a password containing $1 or \1 would
    // otherwise be substituted rather than written literally.
    $safe = str_replace(['\\', '$'], ['\\\\', '\\$'], $value);
    $contents = preg_replace($re, '${1}' . $safe . '${3}', $contents, 1, $count);
    if ($count !== 1) {
        fwrite(STDERR, "failed to replace \$conf['$key'] in $target (matched $count)\n");
        exit(1);
    }
}

if (file_put_contents($target, $contents) === false) {
    fwrite(STDERR, "could not write: $target\n");
    exit(1);
}

printf("updated %s\n", $target);
printf("  backup      %s\n", basename($backup));
printf("  db_base     %s\n", read_conf($target, 'db_base'));
printf("  db_user     %s\n", read_conf($target, 'db_user'));
printf("  db_host     %s\n", read_conf($target, 'db_host'));
printf("  db_password set, %d chars\n", strlen((string) read_conf($target, 'db_password')));
