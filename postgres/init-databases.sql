-- Runs once, when the postgres volume is first initialised: one database per
-- portal service that owns tables. Each service migrates its own schema on
-- start (Alembic). Using an existing PostgreSQL server instead? Create these
-- two databases there and point the services' DATABASE_URL at them.
CREATE DATABASE portal_identity OWNER portal;
CREATE DATABASE portal_execution OWNER portal;
