{{/* vim: set filetype=mustache: */}}
{{/*
Expand the name of the chart.
*/}}
{{- define "prometurbo.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "prometurbo.fullname" -}}
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

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "prometurbo.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Compute service account name with default protection
*/}}
{{- define "serviceAccountName" -}}
{{- $defaultServiceAccount := .Values.serviceAccountName | default "prometurbo" -}}
{{- printf "%s-%s" $defaultServiceAccount .Release.Name -}}
{{- end -}}

{{/*
Compute cluster role binding name with default protection
*/}}
{{- define "clusterRoleBindingName" -}}
{{- $defaultCRB := .Values.roleBinding | default "prometurbo-binding" -}}
{{- printf "%s-%s-%s" $defaultCRB .Release.Name .Release.Namespace -}}
{{- end -}}

{{/*
Compute user input cluster role name with default protection
*/}}
{{- define "inputClusterRoleName" -}}
{{- $defaultCR := .Values.role | default "prometurbo" -}}
{{- printf "%s" $defaultCR -}}
{{- end -}}

{{/*
Compute cluster role name
*/}}
{{- define "clusterRoleName" -}}
{{- $defaultCR := include "inputClusterRoleName" . -}}
{{- if eq $defaultCR "prometurbo" }}
{{- printf "%s-%s-%s" $defaultCR .Release.Name .Release.Namespace -}}
{{- else }}
{{- printf "%s" $defaultCR -}}
{{- end -}}
{{- end -}}
