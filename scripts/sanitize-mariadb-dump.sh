#!/usr/bin/env bash
#
# Filter a MariaDB dump into something MySQL 8.x will accept.
# Reads SQL on stdin, writes SQL on stdout.
#
#   bzcat db/foo.sql.bz2 | ./sanitize-mariadb-dump.sh | mysql target_db
#
# Why this exists as a separate filter rather than being folded into the dump
# step: the captured dumps stay byte-faithful to the source. A backup that has
# been quietly rewritten is not a backup of what was there. Transformation
# happens at restore time, visibly, and is re-runnable.
#
# What it rewrites, and why:
#
#   utf8mb3_uca1400_*  ->  utf8mb3_unicode_ci
#     MariaDB 11.x defaults new tables to the UCA 14.0.0 collation family.
#     MySQL 8.0 has never heard of it and refuses the import outright
#     (ERROR 1273 Unknown collation). utf8mb3_unicode_ci is the closest thing
#     MySQL has: also Unicode, also accent-insensitive, older UCA revision.
#     Sort order for exotic scripts can differ slightly; for the data this
#     touches (a photo gallery) that is immaterial.
#
# What it deliberately does NOT do:
#
#   - utf8mb3 -> utf8mb4. Tempting, since utf8mb3 has been deprecated since
#     MySQL 8.0 and is slated for removal in a future release, so this will
#     have to happen eventually. But widening the charset changes index key
#     lengths and can push a table over the limit, so it is a migration
#     decision to take deliberately and test, not a side effect of a restore
#     filter. Flagged in docs/inventory.md instead.
#   - Touch utf8mb3_bin or any collation MySQL already understands.
#
# Idempotent: running it on already-sanitised SQL changes nothing.

set -euo pipefail

sed -E \
  -e 's/utf8mb3_uca1400_[a-z0-9_]+/utf8mb3_unicode_ci/g' \
  -e 's/utf8mb4_uca1400_[a-z0-9_]+/utf8mb4_unicode_ci/g'
