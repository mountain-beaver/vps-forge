# Database profile

The rules that matter most: **never expose a database to the internet**, give each app its own least-privilege role, and back it up with dumps rather than by copying files.

## Exposure

| Engine | Bind locally | Check |
|---|---|---|
| PostgreSQL | `listen_addresses = 'localhost'` in `postgresql.conf` (or a conf.d drop-in) | `ss -tlnp \| grep 5432` shows 127.0.0.1/::1 only |
| MySQL/MariaDB | `bind-address = 127.0.0.1` in `/etc/mysql/*.conf.d/` | `ss -tlnp \| grep 3306` |
| Redis/Valkey | `bind 127.0.0.1 -::1`, `protected-mode yes`, ACL user or `requirepass` | `ss -tlnp \| grep 6379` |
| MongoDB | `net.bindIp: 127.0.0.1`, `security.authorization: enabled` | `ss -tlnp \| grep 27017` |
| In Docker | no `ports:` mapping at all; apps connect over the compose network | `docker ps` shows no published DB port |

Remote access for the user's tools (DBeaver, psql, TablePlus) goes through an SSH tunnel (`ssh -L 5432:127.0.0.1:5432 <host>`) or the VPN interface. Never a public firewall rule.

## Auth

- PostgreSQL 14+ defaults to `scram-sha-256`. Make sure `pg_hba.conf` has no `trust` lines except for local `peer` admin access, and no `md5` for new roles.
- One role and one database per app. The app role isn't a superuser and doesn't own other apps' schemas.
- MySQL/MariaDB: do what `mysql_secure_installation` does (it's interactive, so don't run it over SSH) with SQL: remove anonymous users and the test database, and make sure root can only log in locally via unix socket.
- Generate passwords on the server (`openssl rand -base64 32`), put them in the app's `.env` (600), and never echo them into chat.

## Backups

Use logical dumps in a restic pre-hook (backups.md):
- PostgreSQL: `pg_dump -Fc -d <db> -f /var/backups/db/<db>.dump` for each database (as the postgres user), plus `pg_dumpall --globals-only` for roles.
- MySQL/MariaDB: `mysqldump --single-transaction --routines --triggers --databases <db> > /var/backups/db/<db>.sql`.
- Redis: `redis-cli --rdb /var/backups/db/redis.rdb` if its data matters. Often it's a cache that doesn't need a backup.
- In Docker: `docker compose exec -T db pg_dump -U <user> -Fc <db> > /var/backups/db/<db>.dump`.
- SQLite (PocketBase's `pb_data/`, n8n, Uptime Kuma, many small apps): a file copy of a live database can catch a write halfway and restore as corrupt. Find them during recon (`find /opt /srv /home /var/lib/docker/volumes -name '*.db' -o -name '*.sqlite' -o -name '*.sqlite3' 2>/dev/null`, then `file` on each hit), install `sqlite3`, and dump each one with the online backup API, which is safe while the app writes: `sqlite3 <path> ".backup '/var/backups/db/<app>.sqlite'"`. For a database inside a Docker volume, run it on the host against the volume path. Then add the live file and its `-wal` and `-shm` files to `/etc/restic/exclude`, so the dump is the only copy and nobody restores the torn one.

Restore test: load the dump into a scratch database (`createdb restore_test && pg_restore -d restore_test <file>`), count rows in a key table, then drop it. For SQLite, `sqlite3 <restored file> 'PRAGMA integrity_check'` must print `ok`, and a row count of a key table must match the source.

## Sizing hints

- PostgreSQL on a small VPS: `shared_buffers` ≈ 25% of RAM, `effective_cache_size` ≈ 50–70%, `work_mem` small (4–16 MB). PGTune-style calculators are fine starting points.
- Keep swap on database boxes. `vps-forge-health` does not watch swapping, memory or load, so check `vmstat 1` when queries slow down, or add a metrics agent (alerts-monitoring.md) if swapping must page someone.
