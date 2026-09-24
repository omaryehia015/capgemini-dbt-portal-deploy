# Bake mode: ship the portal with the client's dbt project inside the image.
# Fits clients who already package their dbt project as a container image, or
# who want an immutable, versioned portal build per project release.
#
#   docker build -f deploy/bake/Dockerfile \
#     --build-arg CLIENT_DBT_IMAGE=registry.client.com/analytics/dbt:2.3.0 \
#     --build-arg CLIENT_PROJECT_PATH=/usr/app/dbt \
#     -t registry.client.com/analytics/dbt-portal-backend:2.3.0 .
#
# Build the portal backend image first (capgemini-dbt-portal-backend:local).
# To bake from a local checkout instead of an image, replace the COPY --from
# line with `COPY <path-in-build-context> /workspace`.
ARG PORTAL_BACKEND_IMAGE=capgemini-dbt-portal-backend:local
ARG CLIENT_DBT_IMAGE
FROM ${CLIENT_DBT_IMAGE} AS client

FROM ${PORTAL_BACKEND_IMAGE}
# Where the dbt project (the folder with dbt_project.yml) sits in the client image.
ARG CLIENT_PROJECT_PATH=/usr/app/dbt
COPY --from=client --chown=appuser:appuser ${CLIENT_PROJECT_PATH}/ /workspace/
