#!/bin/bash
#!/bin/bash

# Exit immediately if a command exits with a non-zero status
set -e

# Function to handle errors
handle_error() {
  echo "ERROR: An error occurred at line $1, command: $2, exiting..."
  exit 1
}

# Set up error handling
trap 'handle_error $LINENO "$BASH_COMMAND"' ERR

# Function to log messages with timestamps
log() {
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1"
}

# Function to validate inputs
validate_inputs() {
  log "Validating inputs..."
  #if [[ -z "$GCP_PROJECT_ID" || -z "$GCP_FOLDER" || -z "$BILLING_ACCOUNT" || -z "$ARTIFACT_REGISTRY_NAME" ]]; then
  if [[ -z "$GCP_PROJECT_ID" || -z "$ARTIFACT_REGISTRY_NAME" ]]; then
    echo "ERROR: All inputs must be provided."
    exit 1
  fi

  log "Using the following values:"
  log "GCP Project ID: ${GCP_PROJECT_ID}"
#  log "GCP Folder ID: ${GCP_FOLDER}"
# log "Billing Account ID: ${BILLING_ACCOUNT}"
  log "Artifact Registry Name: ${ARTIFACT_REGISTRY_NAME}"
}

# Function to create and set GCP project
setup_project() {
  log "Step 1: Creating GCP project..."
  # Check if project already exists
  if gcloud projects describe ${GCP_PROJECT_ID} &>/dev/null; then
    log "Project ${GCP_PROJECT_ID} already exists, skipping creation."
  else
    gcloud projects create ${GCP_PROJECT_ID} --folder=${GCP_FOLDER}
    log "GCP project created."
  fi
}

# Function to enable required APIs
enable_apis() {
  log "Step 4: Enabling APIs..."
  APIS_TO_ENABLE=(
    "compute.googleapis.com"
    "artifactregistry.googleapis.com"
    "config.googleapis.com"
    "storage.googleapis.com"
    "developerconnect.googleapis.com"
    "cloudbuild.googleapis.com"
    "saasservicemgmt.googleapis.com"
  )

  for API in "${APIS_TO_ENABLE[@]}"; do
    log "Enabling API: $API"
    gcloud services enable $API --project=${GCP_PROJECT_ID}
  done
  log "APIs enabled."
}

# Function to get project number
get_project_number() {
  log "Step 5: Setting project number..."
  GCP_PROJECT_NUMBER=$(gcloud projects describe ${GCP_PROJECT_ID} --format="value(projectNumber)" --project=${GCP_PROJECT_ID})
  if [[ -z "$GCP_PROJECT_NUMBER" ]]; then
    echo "ERROR: Failed to retrieve project number."
    exit 1
  fi
  log "Project number: ${GCP_PROJECT_NUMBER}"

  # Set derived variables
  SAAS_RUNTIME_P4SA="service-${GCP_PROJECT_NUMBER}@gcp-sa-saasservicemgmt.iam.gserviceaccount.com"
  COMPUTE_DEFAULT_SA="${GCP_PROJECT_NUMBER}-compute@developer.gserviceaccount.com"
}

# Function to setup SaaS runtime service account
setup_saas_runtime_sa() {
  log "Step 6: Checking SaaS runtime service account..."
  if gcloud iam service-accounts describe ${SAAS_RUNTIME_P4SA} --project=${GCP_PROJECT_ID} &>/dev/null; then
    log "SaaS runtime service account already exists."
  else
    # Trigger p4sa account creation with proper error handling
    log "Triggering p4sa account creation..."

    # Create a temporary SaaS type to trigger account creation
    TEMP_SAAS_NAME="hellosaas-$(date +%s)"
    gcloud alpha saas saas-types create ${TEMP_SAAS_NAME} --location=us-central1 --locations=name=us-central1 --project=${GCP_PROJECT_ID} || \
      log "Warning: Creating SaaS type may have failed, but this could be expected."

    # Wait a moment for the account to propagate
    log "Waiting for service account creation to propagate..."
    sleep 10

    # Delete the temporary SaaS type
    gcloud alpha saas saas-types delete ${TEMP_SAAS_NAME} --location=us-central1 --quiet --project=${GCP_PROJECT_ID} || \
      log "Warning: Deleting SaaS type may have failed, but this could be expected."

    # Wait a moment for deletion
    sleep 5
  fi
}

# Function to grant permissions to a service account
grant_permissions() {
  local account=$1
  local roles=("${!2}")
  local description=$3

  log "Granting $description permissions..."
  for ROLE in "${roles[@]}"; do
    log "Granting permission: ${ROLE} to serviceAccount:${account}"
    gcloud projects add-iam-policy-binding ${GCP_PROJECT_ID} \
      --member="serviceAccount:${account}" \
      --role="${ROLE}" \
      --condition=None
  done
  log "$description permissions granted."
}

# Function to setup infra manager service account
setup_infra_manager_sa() {
  log "Step 7: Setting up Inframanager service account..."
  INFRA_MANAGER_SA_NAME="infra-manager-sa"
  INFRA_MANAGER_SA_EMAIL="${INFRA_MANAGER_SA_NAME}@${GCP_PROJECT_ID}.iam.gserviceaccount.com"

  # Check if service account already exists
  if gcloud iam service-accounts describe ${INFRA_MANAGER_SA_EMAIL} --project=${GCP_PROJECT_ID} &>/dev/null; then
    log "Inframanager service account already exists."
  else
    log "Creating service account: ${INFRA_MANAGER_SA_EMAIL}"
    gcloud iam service-accounts create ${INFRA_MANAGER_SA_NAME} --display-name="Inframanager SA used for Deployment actuation" --project=${GCP_PROJECT_ID}
  fi
}

# Function to setup compute default service account
setup_compute_sa() {
  log "Step 8: Verifying Compute Default SA exists..."

  # Check if the Compute service account exists
  if gcloud iam service-accounts describe ${COMPUTE_DEFAULT_SA} --project=${GCP_PROJECT_ID} &>/dev/null; then
    BUILD_SA="${COMPUTE_DEFAULT_SA}"
    log "Using Compute service account: ${BUILD_SA}"
  else
    log "WARNING: Compute service account not found. This is unusual."
    log "Will attempt to create a new service account."

    # Create a new service account if it doesn't exist
    BUILD_SA_NAME="compute-sa"
    BUILD_SA="${BUILD_SA_NAME}@${GCP_PROJECT_ID}.iam.gserviceaccount.com"
    gcloud iam service-accounts create ${BUILD_SA_NAME} \
      --display-name="Compute Service Account" \
      --project=${GCP_PROJECT_ID}

    log "Created new service account: ${BUILD_SA}"
  fi
}

# Function to create artifact registry
create_artifact_registry() {
  log "Step 9: Creating artifact registry..."
  REGION="us-central1"

  # Check if artifact registry already exists
  if gcloud artifacts repositories describe ${ARTIFACT_REGISTRY_NAME} \
    --location=${REGION} --project=${GCP_PROJECT_ID} &>/dev/null; then
    log "Artifact registry ${ARTIFACT_REGISTRY_NAME} already exists."
  else
    gcloud artifacts repositories create ${ARTIFACT_REGISTRY_NAME} \
      --repository-format=docker \
      --location=${REGION} \
      --description="Artifact Registry to store SaaS Runtime blueprints" \
      --project=${GCP_PROJECT_ID}
    log "Artifact registry created."
  fi
}

# Main function to execute all steps
main() {
  # Prompt for input variables
  read -p "Enter GCP Project ID: " GCP_PROJECT_ID
  #read -p "Enter GCP Folder ID: " GCP_FOLDER
  #read -p "Enter Billing Account ID: " BILLING_ACCOUNT
  read -p "Enter Artifact Registry Name: " ARTIFACT_REGISTRY_NAME

  # Run all setup functions in sequence
  validate_inputs
  setup_project
  #link_billing
  enable_apis
  get_project_number
  setup_saas_runtime_sa

  # Define roles for all service accounts
  SAAS_ROLES=(
    "roles/artifactregistry.admin"
    "roles/iam.serviceAccountShortTermTokenMinter"
    "roles/config.admin"
    "roles/storage.admin"
    "roles/iam.serviceAccountUser"
  )

  INFRA_ROLES=(
    "roles/config.admin"
    "roles/storage.admin"
    "roles/container.admin"
    "roles/iam.serviceAccountUser"
    "roles/compute.admin"
  )

  BUILD_ROLES=(
    "roles/cloudbuild.builds.builder"
    "roles/artifactregistry.writer"
    "roles/developerconnect.admin"
    "roles/developerconnect.tokenAccessor"
    "roles/logging.logWriter"
    "roles/storage.admin"
  )

  # Grant permissions to SaaS runtime SA
  grant_permissions "${SAAS_RUNTIME_P4SA}" SAAS_ROLES[@] "SaaS runtime service account"

  # Setup and grant permissions to Infrastructure Manager SA
  setup_infra_manager_sa
  grant_permissions "${INFRA_MANAGER_SA_EMAIL}" INFRA_ROLES[@] "Inframanager"

  # Setup and grant permissions to Compute SA
  setup_compute_sa
  grant_permissions "${BUILD_SA}" BUILD_ROLES[@] "Compute Default SA"

  create_artifact_registry

  log "Script completed successfully."
}

# Execute main function
main
