{{/*
Chart name
*/}}
{{- define "governance.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Fullname: release-name or override
*/}}
{{- define "governance.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "governance.labels" -}}
helm.sh/chart: {{ include "governance.name" . }}-{{ .Chart.Version | replace "+" "_" }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{ include "governance.selectorLabels" . }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "governance.selectorLabels" -}}
app.kubernetes.io/name: {{ include "governance.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
ServiceAccount name
*/}}
{{- define "governance.serviceAccountName" -}}
{{- default (include "governance.fullname" .) .Values.serviceAccount.name }}
{{- end }}

{{/*
Proxy image
*/}}
{{- define "governance.proxy.image" -}}
{{ .Values.proxy.image.repository }}:{{ .Values.proxy.image.tag | default .Chart.AppVersion }}
{{- end }}

{{/*
Build datasources list from enabled backends
*/}}
{{- define "governance.datasources" -}}
{{- $ds := list }}
{{- if .Values.postgres.enabled }}
{{- $ds = append $ds (dict "name" "postgres" "type" "mcp" "url" (printf "http://postgres-mcp.%s.svc.cluster.local:%d/sse" .Release.Namespace (.Values.postgres.mcp.port | int))) }}
{{- end }}
{{- if .Values.prometheus.enabled }}
{{- $ds = append $ds (dict "name" "prometheus" "type" "mcp" "url" (printf "http://prometheus-mcp.%s.svc.cluster.local:%d/sse" .Release.Namespace (.Values.prometheus.mcp.port | int))) }}
{{- end }}
{{- toYaml $ds }}
{{- end }}

{{/*
Build toolCache servers from enabled backends
*/}}
{{- define "governance.toolCacheServers" -}}
{{- $servers := list }}
{{- if .Values.postgres.enabled }}
{{- $servers = append $servers (dict "url" (printf "http://postgres-mcp.%s.svc.cluster.local:%d/sse" .Release.Namespace (.Values.postgres.mcp.port | int)) "defaultTTLSeconds" (.Values.postgres.toolCache.defaultTTLSeconds | int) "tools" .Values.postgres.toolCache.tools) }}
{{- end }}
{{- if .Values.prometheus.enabled }}
{{- $servers = append $servers (dict "url" (printf "http://prometheus-mcp.%s.svc.cluster.local:%d/sse" .Release.Namespace (.Values.prometheus.mcp.port | int)) "defaultTTLSeconds" (.Values.prometheus.toolCache.defaultTTLSeconds | int) "tools" .Values.prometheus.toolCache.tools) }}
{{- end }}
{{- toYaml $servers }}
{{- end }}
