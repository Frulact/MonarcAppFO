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
# Pre-migration fixups: the legacy bootstrap dump (db-bootstrap/*.sql) was
# committed with quirks that some later migrations don't tolerate. These
# ALTERs are idempotent — if the offending object isn't present, the error
# is swallowed and we move on.
# ---------------------------------------------------------------------------

if [ "$USE_BO_COMMON_ENABLED" -eq 0 ]; then
    echo -e "${YELLOW}Pre-migration fixups on ${DBNAME_COMMON}...${NC}"
    # Duplicate anr_id FK on rolf_tags / rolf_risks confuses migration
    # 20230901112005 FixPositionsCleanupDb (MariaDB error 1072 at line 302).
    mysql -h"${DBHOST}" -u"root" -p"${DBPASSWORD_ADMIN}" "${DBNAME_COMMON}" \
        -e "ALTER TABLE rolf_tags DROP FOREIGN KEY rolf_tags_ibfk_2;" 2>/dev/null || true
    mysql -h"${DBHOST}" -u"root" -p"${DBPASSWORD_ADMIN}" "${DBNAME_COMMON}" \
        -e "ALTER TABLE rolf_risks DROP FOREIGN KEY rolf_risks_ibfk_2;" 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# Migrations: Phinx is idempotent, so run every start to pick up new schema
# shipped in this image.
# ---------------------------------------------------------------------------

echo -e "${YELLOW}Running database migrations...${NC}"
php ./vendor/robmorgan/phinx/bin/phinx migrate -c ./module/Monarc/Core/migrations/phinx.php
php ./vendor/robmorgan/phinx/bin/phinx migrate -c ./module/Monarc/FrontOffice/migrations/phinx.php

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
