#!/bin/bash
set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

is_true() {
    case "$1" in
        1|true|yes|on) return 0 ;;
        *) return 1 ;;
    esac
}

APP_DIR="${APP_DIR:-/var/www/html/monarc}"
cd "$APP_DIR"

echo -e "${GREEN}Starting MONARC FrontOffice...${NC}"

# The data volume may be empty on first start; ensure required subdirs exist.
mkdir -p data/cache \
    data/LazyServices/Proxy \
    data/DoctrineORMModule/Proxy \
    data/import/files

# Wait for the database to be ready
echo -e "${YELLOW}Waiting for MariaDB to be ready...${NC}"
while ! mysqladmin ping -h"${DBHOST}" -u"root" -p"${DBPASSWORD_ADMIN}" --silent 2>/dev/null; do
    echo "Waiting for MariaDB..."
    sleep 2
done
echo -e "${GREEN}MariaDB is ready!${NC}"

USE_BO_COMMON_ENABLED=0
if is_true "${USE_BO_COMMON}"; then
    USE_BO_COMMON_ENABLED=1
fi

# Regenerate local.php every start so env-var changes propagate.
echo -e "${YELLOW}Writing config/autoload/local.php...${NC}"
mkdir -p config/autoload
cat > config/autoload/local.php <<EOF
<?php
\$appdir = getenv('APP_DIR') ? getenv('APP_DIR') : '/var/www/html/monarc';
\$string = file_get_contents(\$appdir.'/package.json');
if(\$string === FALSE) {
    \$string = file_get_contents('./package.json');
}
\$package_json = json_decode(\$string, true);

return [
    'doctrine' => [
        'connection' => [
            'orm_default' => [
                'params' => [
                    'host' => '${DBHOST}',
                    'user' => '${DBUSER_MONARC}',
                    'password' => '${DBPASSWORD_MONARC}',
                    'dbname' => '${DBNAME_COMMON}',
                ],
            ],
            'orm_cli' => [
                'params' => [
                    'host' => '${DBHOST}',
                    'user' => '${DBUSER_MONARC}',
                    'password' => '${DBPASSWORD_MONARC}',
                    'dbname' => '${DBNAME_CLI}',
                ],
            ],
        ],
    ],

    'activeLanguages' => array('fr','en','de','nl','es','ro','it','ja','pl','pt','ru','zh'),

    'appVersion' => \$package_json['version'],

    'checkVersion' => false,
    'appCheckingURL' => 'https://version.monarc.lu/check/MONARC',

    'email' => [
        'name' => 'MONARC',
        'from' => 'info@monarc.lu',
    ],

    'mospApiUrl' => 'https://objects.monarc.lu/api/',

    'monarc' => [
        'ttl' => 60, // timeout
        'salt' => '', // private salt for password encryption
    ],

    'statsApi' => [
        'baseUrl' => 'http://stats-service:5005',
        'apiKey' => '${STATS_API_KEY:-}',
    ],

    'import' => [
        'uploadFolder' => '\$appdir/data/import/files',
        'isBackgroundProcessActive' => false,
    ],
];
EOF

# ---------------------------------------------------------------------------
# Optional: force a clean DB reset when the operator can't wipe the volume
# directly (set RESET_DB=1 in Dokploy, redeploy once, then unset it).
# ---------------------------------------------------------------------------

if is_true "${RESET_DB:-0}"; then
    echo -e "${RED}RESET_DB is set — dropping ${DBNAME_CLI} and ${DBNAME_COMMON}...${NC}"
    mysql -h"${DBHOST}" -u"root" -p"${DBPASSWORD_ADMIN}" -e "DROP DATABASE IF EXISTS ${DBNAME_CLI};"
    if [ "$USE_BO_COMMON_ENABLED" -eq 0 ]; then
        mysql -h"${DBHOST}" -u"root" -p"${DBPASSWORD_ADMIN}" -e "DROP DATABASE IF EXISTS ${DBNAME_COMMON};"
    fi
fi

# ---------------------------------------------------------------------------
# Databases: create on first run, then ensure privileges every start so
# user/password env changes are picked up.
# ---------------------------------------------------------------------------

echo -e "${YELLOW}Ensuring databases exist...${NC}"
DB_EXISTS=$(mysql -h"${DBHOST}" -u"root" -p"${DBPASSWORD_ADMIN}" -e "SHOW DATABASES LIKE '${DBNAME_CLI}';" | grep -c "${DBNAME_CLI}" || true)

if [ "$DB_EXISTS" -eq 0 ]; then
    echo -e "${YELLOW}Creating databases...${NC}"
    mysql -h"${DBHOST}" -u"root" -p"${DBPASSWORD_ADMIN}" -e "CREATE DATABASE IF NOT EXISTS ${DBNAME_CLI} DEFAULT CHARACTER SET utf8 DEFAULT COLLATE utf8_general_ci;"

    if [ "$USE_BO_COMMON_ENABLED" -eq 0 ]; then
        mysql -h"${DBHOST}" -u"root" -p"${DBPASSWORD_ADMIN}" -e "CREATE DATABASE IF NOT EXISTS ${DBNAME_COMMON} DEFAULT CHARACTER SET utf8 DEFAULT COLLATE utf8_general_ci;"

        echo -e "${YELLOW}Populating common database...${NC}"
        export MYSQL_PWD="${DBPASSWORD_MONARC}"
        mysql -h"${DBHOST}" -u"${DBUSER_MONARC}" ${DBNAME_COMMON} < db-bootstrap/monarc_structure.sql
        mysql -h"${DBHOST}" -u"${DBUSER_MONARC}" ${DBNAME_COMMON} < db-bootstrap/monarc_data.sql
        unset MYSQL_PWD
    else
        echo -e "${YELLOW}USE_BO_COMMON is enabled; skipping monarc_common creation and bootstrap.${NC}"
    fi
fi

echo -e "${YELLOW}Ensuring privileges for ${DBUSER_MONARC}...${NC}"
mysql -h"${DBHOST}" -u"root" -p"${DBPASSWORD_ADMIN}" -e "GRANT ALL PRIVILEGES ON ${DBNAME_CLI}.* TO '${DBUSER_MONARC}'@'%';"
if [ "$USE_BO_COMMON_ENABLED" -eq 0 ]; then
    mysql -h"${DBHOST}" -u"root" -p"${DBPASSWORD_ADMIN}" -e "GRANT ALL PRIVILEGES ON ${DBNAME_COMMON}.* TO '${DBUSER_MONARC}'@'%';"
fi
mysql -h"${DBHOST}" -u"root" -p"${DBPASSWORD_ADMIN}" -e "FLUSH PRIVILEGES;"

if [ "$USE_BO_COMMON_ENABLED" -eq 1 ]; then
    COMMON_EXISTS=$(mysql -h"${DBHOST}" -u"root" -p"${DBPASSWORD_ADMIN}" -e "SHOW DATABASES LIKE '${DBNAME_COMMON}';" | grep -c "${DBNAME_COMMON}" || true)
    if [ "$COMMON_EXISTS" -eq 0 ]; then
        echo -e "${RED}USE_BO_COMMON is enabled, but ${DBNAME_COMMON} was not found on ${DBHOST}.${NC}"
        echo -e "${RED}Ensure the BackOffice database is reachable and contains ${DBNAME_COMMON}.${NC}"
        exit 1
    fi
fi

# ---------------------------------------------------------------------------
# Migrations.
#
# Core migration `20230901112005 FixPositionsCleanupDb` assumes a single
# composite index named `anr_id` on rolf_tags/rolf_risks, with no leftover
# duplicates. When monarc_common is built by running the migration chain
# from scratch (i.e. the bootstrap dump wasn't loaded, e.g. because
# monarc_cli existed when monarcfoapp first started), the earlier
# `20161024140431 AddIndex` migration adds a *second* `(anr_id, code)`
# unique index that Phinx auto-names `anr_id_3` (because `anr_id` and
# `anr_id_2` already exist). The 2023 migration then drops `anr_id` and the
# anr_id column, but the leftover composite `anr_id_3` blocks DROP COLUMN
# with MariaDB error 1072.
#
# To avoid this, run Phinx in two stages: everything up to the last
# Core migration before 20230901112005, then pre-clean the duplicates,
# then the remainder. Once the 2023 migration is recorded in phinxlog
# the cleanup becomes a no-op (DROP INDEX errors are swallowed).
# ---------------------------------------------------------------------------

CORE_PHINX=./module/Monarc/Core/migrations/phinx.php
FO_PHINX=./module/Monarc/FrontOffice/migrations/phinx.php

CORE_STAGE1_TARGET=20230110110655
CORE_COMMON_HEAD=$(MYSQL_PWD="${DBPASSWORD_ADMIN}" mysql -h"${DBHOST}" -u"root" -N -B "${DBNAME_COMMON}" \
    -e "SELECT IFNULL(MAX(version), 0) FROM phinxlog;" 2>/dev/null || echo 0)

if [ "${CORE_COMMON_HEAD}" -lt "${CORE_STAGE1_TARGET}" ]; then
    echo -e "${YELLOW}Running Core migrations (stage 1, up to ${CORE_STAGE1_TARGET})...${NC}"
    php ./vendor/robmorgan/phinx/bin/phinx migrate -c "$CORE_PHINX" --target "${CORE_STAGE1_TARGET}"
else
    echo -e "${GREEN}Stage 1 target ${CORE_STAGE1_TARGET} already applied (head=${CORE_COMMON_HEAD}); skipping stage 1 migrate.${NC}"
fi

# Pre-cleanup runs regardless of USE_BO_COMMON: each ALTER is an idempotent
# "DROP IF EXISTS"-style call (errors swallowed), so it's a no-op against a
# correctly-shaped (bootstrap-loaded or BO-owned) schema and only does work
# when the migration chain has built up the duplicate indexes that block
# 20230901112005. Migrating monarc_common is already unconditional, so
# pre-cleaning it for that migration is consistent.
echo -e "${YELLOW}Pre-cleanup before 20230901112005 on ${DBNAME_COMMON}...${NC}"
for tbl in rolf_tags rolf_risks; do
    for idx in anr_id_3 anr_id_4; do
        mysql -h"${DBHOST}" -u"root" -p"${DBPASSWORD_ADMIN}" "${DBNAME_COMMON}" \
            -e "ALTER TABLE ${tbl} DROP INDEX ${idx};" 2>/dev/null || true
    done
    mysql -h"${DBHOST}" -u"root" -p"${DBPASSWORD_ADMIN}" "${DBNAME_COMMON}" \
        -e "ALTER TABLE ${tbl} DROP FOREIGN KEY ${tbl}_ibfk_2;" 2>/dev/null || true
done

echo -e "${YELLOW}Running Core migrations (stage 2)...${NC}"
php ./vendor/robmorgan/phinx/bin/phinx migrate -c "$CORE_PHINX"

echo -e "${YELLOW}Running FrontOffice migrations...${NC}"
php ./vendor/robmorgan/phinx/bin/phinx migrate -c "$FO_PHINX"

# ---------------------------------------------------------------------------
# Seed: once per data volume. Honor the legacy .docker-initialized flag so
# existing deployments don't re-seed.
# ---------------------------------------------------------------------------

if [ -f data/.docker-initialized ] || [ -f data/.docker-seeded ]; then
    echo -e "${GREEN}Database already seeded; skipping.${NC}"
else
    if is_true "${SKIP_SEED:-0}"; then
        echo -e "${YELLOW}Skipping database seeding (SKIP_SEED is set)...${NC}"
    else
        echo -e "${YELLOW}Creating initial user and client...${NC}"
        php ./vendor/robmorgan/phinx/bin/phinx seed:run -c ./module/Monarc/FrontOffice/migrations/phinx.php
    fi
    touch data/.docker-seeded
fi

# Invalidate Laminas config cache so new code/config take effect after redeploy.
touch data/cache/upgrade && chmod 777 data/cache/upgrade

# Permissions on the data volume
echo -e "${YELLOW}Setting permissions...${NC}"
chown -R www-data:www-data data
chmod -R 775 data

echo -e "${GREEN}Setup complete, starting Apache...${NC}"
exec "$@"
