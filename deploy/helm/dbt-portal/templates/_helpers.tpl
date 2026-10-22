{{/*
Names. Resource names are <fullname>-<component>; with the release name "dbt-portal" that
gives dbt-portal-backend, dbt-portal-frontend, dbt-portal-cube... (the names the previous
Kustomize install used).
*/}}
{{- define "dbt-portal.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "dbt-portal.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "dbt-portal.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* The name of one component's resources. Call with (dict "root" $ "component" "backend"). */}}
{{- define "dbt-portal.componentName" -}}
{{- printf "%s-%s" (include "dbt-portal.fullname" .root | trunc 50 | trimSuffix "-") .component -}}
{{- end -}}

{{/* Labels that select a component's pods (immutable once deployed). */}}
{{- define "dbt-portal.selectorLabels" -}}
app.kubernetes.io/name: {{ include "dbt-portal.name" .root }}
app.kubernetes.io/instance: {{ .root.Release.Name }}
app.kubernetes.io/component: {{ .component }}
{{- end -}}

{{- define "dbt-portal.labels" -}}
helm.sh/chart: {{ include "dbt-portal.chart" .root }}
{{ include "dbt-portal.selectorLabels" . }}
app.kubernetes.io/part-of: dbt-portal
app.kubernetes.io/version: {{ .root.Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .root.Release.Service }}
{{- end -}}

{{- define "dbt-portal.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "dbt-portal.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{/*
An image reference. Call with (dict "root" $ "image" .Values.backend.image).
registry/repository:tag, or registry/repository@digest. A tag (or digest) is required and
"latest" is refused unless allowLatestTag is true.
*/}}
{{- define "dbt-portal.image" -}}
{{- $registry := default .root.Values.imageRegistry .image.registry -}}
{{- $repository := required "an image repository is required" .image.repository -}}
{{- $base := ternary (printf "%s/%s" $registry $repository) $repository (ne $registry "") -}}
{{- if .image.digest -}}
{{- printf "%s@%s" $base .image.digest -}}
{{- else -}}
{{- $tag := required (printf "an image tag is required for %s: set <component>.image.tag, or pass the tags from releases.yml (scripts/release-tags.sh --format helm-values)" $repository) .image.tag -}}
{{- if and (eq $tag "latest") (not .root.Values.allowLatestTag) -}}
{{- fail (printf "the image tag for %s is 'latest', which is not a release: pin a tag (releases.yml), or set allowLatestTag=true for a throwaway install" $repository) -}}
{{- end -}}
{{- printf "%s:%s" $base $tag -}}
{{- end -}}
{{- end -}}

{{- define "dbt-portal.pullPolicy" -}}
{{- default .root.Values.imagePullPolicy .image.pullPolicy -}}
{{- end -}}

{{/*
A map of annotations or labels, every key and value quoted: Kubernetes only accepts strings,
and `--set key=3600` would otherwise render a number. Call with the map; use with nindent.
*/}}
{{- define "dbt-portal.stringMap" -}}
{{- range $key, $value := . }}
{{ $key | quote }}: {{ $value | toString | quote }}
{{- end }}
{{- end -}}

{{/* The image pull secrets of a pod spec. */}}
{{- define "dbt-portal.imagePullSecrets" -}}
{{- with .Values.imagePullSecrets }}
imagePullSecrets:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- end -}}

{{/* The Secret that holds every secret: created by the chart, or yours. */}}
{{- define "dbt-portal.secretName" -}}
{{- if .Values.secrets.create -}}
{{- default (printf "%s-secrets" (include "dbt-portal.fullname" . | trunc 50 | trimSuffix "-")) .Values.secrets.name -}}
{{- else -}}
{{- required "secrets.existingSecret is required when secrets.create is false: name the Secret that holds JWT_SECRET, CUBE_API_SECRET, PORTAL_SECRET_KEY and the database and Redis settings" .Values.secrets.existingSecret -}}
{{- end -}}
{{- end -}}

{{/* The ConfigMap of non-secret settings. */}}
{{- define "dbt-portal.configName" -}}
{{- printf "%s-config" (include "dbt-portal.fullname" . | trunc 50 | trimSuffix "-") -}}
{{- end -}}

{{/* PersistentVolumeClaim names: an existing claim, or <fullname>-<workspace|data|backups>. */}}
{{- define "dbt-portal.claimName" -}}
{{- if .persistence.existingClaim -}}
{{- .persistence.existingClaim -}}
{{- else -}}
{{- include "dbt-portal.componentName" (dict "root" .root "component" .component) -}}
{{- end -}}
{{- end -}}

{{/*
Checks that fail the render with a useful message instead of producing a broken install.
Included once from the ConfigMap, which always renders.
*/}}
{{- define "dbt-portal.validate" -}}
{{- $project := .Values.project -}}
{{- if not (has $project.source (list "git" "volume")) -}}
{{- fail (printf "project.source must be 'git' or 'volume' (got '%s'); a host folder cannot be mounted on Kubernetes" (toString $project.source)) -}}
{{- end -}}
{{- if and (eq $project.source "git") (not $project.git.url) -}}
{{- fail "project.source is 'git' but project.git.url is empty: set it, or use project.source=volume" -}}
{{- end -}}
{{- if regexMatch "^https?://[^/@]*@" (toString $project.git.url) -}}
{{- fail "project.git.url embeds credentials (https://user:token@host/...): they would sit in clear text in the Deployment spec. Use the Secret key DBT_PROJECT_GIT_TOKEN and project.git.username" -}}
{{- end -}}
{{- if and (eq $project.source "volume") $project.git.url -}}
{{- fail "project.git.url is set but project.source is 'volume': the backend would never clone it. Set project.source=git" -}}
{{- end -}}
{{- if and (not .Values.secrets.create) .Values.secrets.values -}}
{{- fail "secrets.values is only used when secrets.create is true; with an existing Secret put the keys in that Secret" -}}
{{- end -}}
{{- if and .Values.secrets.create .Values.secrets.existingSecret -}}
{{- fail "secrets.existingSecret is set but secrets.create is true: choose one (create=false to use your own Secret)" -}}
{{- end -}}
{{- end -}}

{{/*
The environment shared by the backend and the worker: everything except what differs.
Call with the root context.
  - the non-secret ConfigMap and the Secret, as envFrom
  - the keys the portal cannot run without, as explicit secretKeyRefs: a missing key fails the
    pod at start ("couldn't find key"), instead of the app generating a different key per pod
  - DATABASE_URL and REDIS_URL: built from the bundled service's password, or taken whole from
    the Secret. Never injected empty.
*/}}
{{- define "dbt-portal.sharedEnv" -}}
- name: JWT_SECRET
  valueFrom:
    secretKeyRef:
      name: {{ include "dbt-portal.secretName" . }}
      key: JWT_SECRET
- name: CUBE_API_SECRET
  valueFrom:
    secretKeyRef:
      name: {{ include "dbt-portal.secretName" . }}
      key: CUBE_API_SECRET
- name: PORTAL_SECRET_KEY
  valueFrom:
    secretKeyRef:
      name: {{ include "dbt-portal.secretName" . }}
      key: PORTAL_SECRET_KEY
{{- if .Values.postgresql.enabled }}
- name: POSTGRES_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ include "dbt-portal.secretName" . }}
      key: POSTGRES_PASSWORD
- name: DATABASE_URL
  value: {{ printf "postgresql+psycopg2://%s:$(POSTGRES_PASSWORD)@%s:5432/%s" .Values.postgresql.auth.username (include "dbt-portal.componentName" (dict "root" . "component" "postgres")) .Values.postgresql.auth.database | quote }}
{{- else }}
- name: DATABASE_URL
  valueFrom:
    secretKeyRef:
      name: {{ include "dbt-portal.secretName" . }}
      key: DATABASE_URL
{{- end }}
{{- if .Values.redis.enabled }}
- name: REDIS_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ include "dbt-portal.secretName" . }}
      key: REDIS_PASSWORD
- name: REDIS_URL
  value: {{ printf "redis://:$(REDIS_PASSWORD)@%s:6379/0" (include "dbt-portal.componentName" (dict "root" . "component" "redis")) | quote }}
{{- else }}
- name: REDIS_URL
  valueFrom:
    secretKeyRef:
      name: {{ include "dbt-portal.secretName" . }}
      key: REDIS_URL
{{- end }}
{{- end -}}

{{/* envFrom shared by the backend and the worker. */}}
{{- define "dbt-portal.envFrom" -}}
- configMapRef:
    name: {{ include "dbt-portal.configName" . }}
- secretRef:
    name: {{ include "dbt-portal.secretName" . }}
{{- end -}}

{{/* The profiles.yml Secret volume and mount, when configured. */}}
{{- define "dbt-portal.profilesVolume" -}}
{{- with .Values.project.profiles.existingSecret }}
- name: dbt-profiles
  secret:
    secretName: {{ . }}
    items:
      - key: {{ $.Values.project.profiles.key }}
        path: profiles.yml
{{- end }}
{{- end -}}

{{- define "dbt-portal.profilesMount" -}}
{{- if .Values.project.profiles.existingSecret }}
- name: dbt-profiles
  mountPath: /etc/dbt
  readOnly: true
{{- end }}
{{- end -}}

{{/*
One probe: the handler plus the timing values, or nothing when disabled.
Call with (dict "name" "startupProbe" "probe" .Values.x.probes.startup "handler" <map>).
*/}}
{{- define "dbt-portal.probe" -}}
{{- if .probe.enabled -}}
{{ .name }}:
  {{- toYaml .handler | nindent 2 }}
  {{- toYaml (omit .probe "enabled") | nindent 2 }}
{{- end -}}
{{- end -}}

{{/* Standard scheduling fields of a pod spec. Call with the component's values map. */}}
{{- define "dbt-portal.scheduling" -}}
{{- with .nodeSelector }}
nodeSelector:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with .affinity }}
affinity:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with .tolerations }}
tolerations:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with .priorityClassName }}
priorityClassName: {{ . }}
{{- end }}
{{- end -}}

{{/* A PersistentVolumeClaim. Call with (dict "root" $ "component" "workspace" "persistence" .Values.workspace.persistence). */}}
{{- define "dbt-portal.pvc" -}}
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: {{ include "dbt-portal.componentName" (dict "root" .root "component" .component) }}
  labels:
    {{- include "dbt-portal.labels" (dict "root" .root "component" .component) | nindent 4 }}
  {{- if or .root.Values.persistence.retainOnUninstall .persistence.annotations }}
  annotations:
    {{- if .root.Values.persistence.retainOnUninstall }}
    helm.sh/resource-policy: keep
    {{- end }}
    {{- with .persistence.annotations }}
    {{- include "dbt-portal.stringMap" . | nindent 4 }}
    {{- end }}
  {{- end }}
spec:
  accessModes:
    {{- toYaml .persistence.accessModes | nindent 4 }}
  {{- if .persistence.storageClass }}
  storageClassName: {{ if eq .persistence.storageClass "-" }}""{{ else }}{{ .persistence.storageClass | quote }}{{ end }}
  {{- end }}
  resources:
    requests:
      storage: {{ .persistence.size | quote }}
{{- end -}}
