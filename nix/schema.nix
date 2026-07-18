{
  perSystem = {pkgs, ...}: let
    pulseSchemaDrift =
      pkgs.runCommand "pulse-schema-drift" {
        nativeBuildInputs = [pkgs.postgresql_17 pkgs.diffutils pkgs.gnused pkgs.coreutils];
      } ''
        export LC_ALL=C
        export PGDATA="$TMPDIR/postgres"
        export PGHOST="$TMPDIR/socket"
        export PGPORT=54329
        export PGUSER=postgres
        mkdir -p "$PGHOST"

        initdb -D "$PGDATA" -U postgres --auth=trust >/dev/null
        pg_ctl -D "$PGDATA" \
          -o "-p $PGPORT -c listen_addresses=127.0.0.1 -c unix_socket_directories='$PGHOST' -c fsync=off" \
          -w start >/dev/null
        trap 'pg_ctl -D "$PGDATA" stop -m immediate >/dev/null 2>&1 || true' EXIT

        createdb cortex_schema_drift
        psql -v ON_ERROR_STOP=1 -d cortex_schema_drift -q -f ${../data/pulse-schema.sql}
        pg_dump --schema=pulse --no-owner --no-privileges cortex_schema_drift > "$TMPDIR/before.sql"

        for migration in ${../migrations}/[0-9][0-9][0-9][0-9]_*.sql; do
          psql -v ON_ERROR_STOP=1 -d cortex_schema_drift -q -f "$migration"
        done
        pg_dump --schema=pulse --no-owner --no-privileges cortex_schema_drift > "$TMPDIR/after.sql"
        sed -i '/^\\restrict /d; /^\\unrestrict /d' "$TMPDIR/before.sql" "$TMPDIR/after.sql"
        diff -u "$TMPDIR/before.sql" "$TMPDIR/after.sql"

        latest="$(basename "$(find ${../migrations} -maxdepth 1 -name '[0-9][0-9][0-9][0-9]_*.sql' | sort | tail -n1)")"
        recorded="$(sed -n 's/^-- Migration head: \(.*\)\.$/\1/p' ${../data/pulse-schema.sql})"
        test "$recorded" = "$latest"

        mkdir -p "$out"
        printf '%s\n' "$latest" > "$out/migration-head.txt"
      '';
  in {
    packages.pulse-schema-drift = pulseSchemaDrift;
    checks.pulse-schema-drift = pulseSchemaDrift;
  };
}
