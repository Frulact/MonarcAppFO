#!/bin/sh
# Sourced (not exec'd) by the MariaDB image entrypoint — never use `exit`
# here, otherwise we terminate MariaDB's own init script and the container
# dies before becoming healthy. Use `return` (no-ops if exec'd standalone).

if [ -z "$DBUSER_MONARC" ]; then
    echo "DBUSER_MONARC is not set; skipping dev grants."
else
    mysql -u root -p"$MYSQL_ROOT_PASSWORD" <<EOSQL
GRANT ALL PRIVILEGES ON *.* TO '${DBUSER_MONARC}'@'%';
FLUSH PRIVILEGES;
EOSQL
fi
