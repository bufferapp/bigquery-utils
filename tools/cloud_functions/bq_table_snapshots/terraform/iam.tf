# Service Accounts for BigQuery Snapshot Functions
#
# This configuration implements least privilege access by creating dedicated
# service accounts with minimal permissions for each Cloud Function.
#
# Architecture:
# - sa-bq-snap-fetcher: Lists tables in source dataset, publishes to Pub/Sub
# - sa-bq-snap-creator: Creates snapshots from source to target dataset

# =============================================================================
# Service Accounts
# =============================================================================

resource "google_service_account" "fetcher" {
  account_id   = "sa-bq-snap-fetcher"
  display_name = "BigQuery Snapshot Fetcher Service Account"
  description  = "Service account for listing tables in source dataset and triggering snapshot creation"
  project      = var.project_id
}

resource "google_service_account" "creator" {
  account_id   = "sa-bq-snap-creator"
  display_name = "BigQuery Snapshot Creator Service Account"
  description  = "Service account for creating BigQuery table snapshots from source to target dataset"
  project      = var.project_id
}

# =============================================================================
# Custom IAM Roles
# =============================================================================

# Custom role for fetcher function
# Permissions: list tables and get dataset metadata from source dataset
resource "google_project_iam_custom_role" "bq_snapshot_fetcher" {
  project     = var.project_id
  role_id     = "bqSnapshotFetcher"
  title       = "BigQuery Snapshot Fetcher"
  description = "Minimal permissions to list tables in a dataset for snapshot processing"
  permissions = [
    "bigquery.tables.list",
    "bigquery.datasets.get"
  ]
}

# NOTE: Using predefined BigQuery roles instead of custom roles.
# Per Google Cloud documentation, only specific predefined roles (dataOwner, admin,
# studioAdmin) can create snapshots with expiration times. Custom roles cannot work
# for this use case due to BigQuery API limitations.

# =============================================================================
# IAM Bindings - Fetcher Service Account
# =============================================================================

# Grant fetcher SA permissions to list tables in source dataset
resource "google_bigquery_dataset_iam_member" "fetcher_source_dataset" {
  project    = var.storage_project_id
  dataset_id = var.source_dataset_name
  role       = google_project_iam_custom_role.bq_snapshot_fetcher.id
  member     = "serviceAccount:${google_service_account.fetcher.email}"
}

# Grant fetcher SA permissions to publish messages to snapshot trigger topic
resource "google_pubsub_topic_iam_member" "fetcher_pubsub" {
  project = var.project_id
  topic   = google_pubsub_topic.bq_snapshot_create_snapshot_topic.name
  role    = "roles/pubsub.publisher"
  member  = "serviceAccount:${google_service_account.fetcher.email}"
}

# =============================================================================
# IAM Bindings - Creator Service Account
# =============================================================================

# Grant creator SA read permissions on source dataset
# Using predefined dataViewer role which includes:
# - bigquery.tables.get (read metadata)
# - bigquery.tables.getData (read data for time-travel)
# - bigquery.tables.createSnapshot (create snapshot from source)
# - bigquery.datasets.get (access dataset)
resource "google_bigquery_dataset_iam_member" "creator_source_dataset" {
  project    = var.storage_project_id
  dataset_id = var.source_dataset_name
  role       = "roles/bigquery.dataViewer"
  member     = "serviceAccount:${google_service_account.creator.email}"
}

# Grant creator SA write permissions on target dataset
# Using predefined dataOwner role which includes:
# - bigquery.tables.create (create snapshot tables)
# - bigquery.tables.createSnapshot (snapshot operation)
# - bigquery.tables.deleteSnapshot (REQUIRED for expiration)
# - bigquery.tables.updateData (write snapshot data)
# - bigquery.tables.update (update table metadata)
# - bigquery.tables.delete (cleanup old snapshots)
# - bigquery.datasets.get (access dataset)
# - bigquery.tables.setIamPolicy (manage table permissions)
#
# IMPORTANT: Per Google Cloud documentation, ONLY bigquery.dataOwner,
# bigquery.admin, and bigquery.studioAdmin can create snapshots with
# expiration times. This is a BigQuery API limitation - dataEditor lacks
# bigquery.tables.deleteSnapshot which is required for setting expiration.
# dataOwner is the least privileged role that supports snapshot expiration.
resource "google_bigquery_dataset_iam_member" "creator_target_dataset" {
  project    = var.storage_project_id
  dataset_id = google_bigquery_dataset.dataset.dataset_id
  role       = "roles/bigquery.dataOwner"
  member     = "serviceAccount:${google_service_account.creator.email}"
}

# Grant creator SA permissions to create BigQuery jobs at project level
# Note: BigQuery jobs are project-scoped resources, so this must be project-level.
# This is a known limitation - the SA can create any BigQuery job type, but this
# is the minimum required for snapshot operations.
resource "google_project_iam_member" "creator_job_user" {
  project = var.project_id
  role    = "roles/bigquery.jobUser"
  member  = "serviceAccount:${google_service_account.creator.email}"
}

# =============================================================================
# Outputs
# =============================================================================

output "fetcher_service_account_email" {
  description = "Email of the fetcher service account"
  value       = google_service_account.fetcher.email
}

output "creator_service_account_email" {
  description = "Email of the creator service account"
  value       = google_service_account.creator.email
}
