#!/bin/bash
# Copyright 2022 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# This script runs the e2e test with the following steps:
# - Create a new GCP project (Optional)
# - Init with env vars and other setup.
# - Run terraform apply, which create GKE cluster and other resources.
# - Run skaffold to deploy microservices.
# - Test API endpoints.

# Usage:
#
# 1. Log in to gcloud or with a service account. Two options:
# Option 1) gcloud auth login && gcloud auth application-default login
# Option 2) gcloud auth activate-service-account $SA_EMAIL --key-file=$PATH_TO_KEY_FILE
#
# 2. Set up environment variables. If you don't set these values, the script will try to fetch from gcloud config.
# export ORGANIZATION_ID=<your-org-id>
# export FOLDER_ID=<your-folder-id>
# export BILLING_ACCOUNT=<your-billing-id>
#
# 3. Run the script with optional flags:
# Regular e2e test with clean up.
# > sh run_e2e_test.sh
#
# Create new project ID with random UUID and run e2e tests.
# > sh run_e2e_test.sh -n
#
# Run e2e test but skip cleaning up project, for debug purpose.
# > sh run_e2e_test.sh -s #

# To calculate time elapsed.
SECONDS=0

# Hardcoded the project ID for all local development.
declare -a EnvVars=(
  "ORGANIZATION_ID"
  "BILLING_ACCOUNT"
)
for variable in ${EnvVars[@]}; do
  if [[ -z "${!variable}" ]]; then
    printf "$variable is not set.\n"
    exit -1
  fi
done

# The following vars need to be set in the environment when runnin the e2e tests.
# For example, set up env vars and action secrets in Github Action workflow.
echo "ORGANIZATION_ID=$ORGANIZATION_ID"
echo "BILLING_ACCOUNT=$BILLING_ACCOUNT"
echo "GOOGLE_APPLICATION_CREDENTIALS=$GOOGLE_APPLICATION_CREDENTIALS"

# Parsing arguments
skip_cleanup=""
is_create_new_project="false"
while getopts "sn" flag
do
  case "${flag}" in
    s) skip_cleanup="skip_cleanup";;
    g) is_create_new_project="true";;
  esac
done

# Initializing E2E test environment vars
export OUTPUT_FOLDER=".test_output"
export ADMIN_EMAIL=$(gcloud auth list --filter=status:ACTIVE --format='value(account)')

build_template() {
  # Re-build template
  echo yes | sh ./build_tools/build_template.sh
}

# Create a new Google Cloud project
create_new_project() {
  export PROJECT_ID=solutemp-e2e-$(uuidgen | head -c 8 | awk '{print tolower($0)}')
  gcloud projects create $PROJECT_ID --folder $FOLDER_ID --quiet
  gcloud config set project $PROJECT_ID --quiet
}

install_dependencies() {
  # Install Cookiecutter
  python3 -m pip install cookiecutter
  python3 -m pip install pytest --no-input
}

setup_working_folder() {
  mkdir -p $OUTPUT_FOLDER
  
  # Create skeleton code in a new folder with Cookiecutter
  cookiecutter . --overwrite-if-exists --no-input -o $OUTPUT_FOLDER project_id=$PROJECT_ID admin_email=$ADMIN_EMAIL
  
  # Set up working environment:
  cd $OUTPUT_FOLDER/$PROJECT_ID
  export API_DOMAIN=localhost
  export BASE_DIR=$(pwd)
  echo "Current directory: ${BASE_DIR}"
  echo
}

# Test with API endpoint (GKE):
test_api_endpoints_gke() {
  # Run API e2e tests
  cd $BASE_DIR
  bash e2e/gke_api_tests/run_api_tests.sh
  GKE_PYTEST_STATUS=${PIPESTATUS[0]}
}

# Test with API endpoint (CloudRun):
test_api_endpoints_cloudrun() {
  cd $BASE_DIR
  
  # Run API e2e tests
  mkdir -p .test_output
  gcloud run services list --format=json > .test_output/cloudrun_service_list.json
  export SERVICE_LIST_JSON=.test_output/cloudrun_service_list.json
  PYTHONPATH=common/src python3 -m pytest e2e/cloudrun_api_tests/
  CLOUDRUN_PYTEST_STATUS=${PIPESTATUS[0]}
}

# Check API tests result
print_api_test_result() {
  if [[ $GKE_PYTEST_STATUS == 0 && $CLOUDRUN_PYTEST_STATUS == 0 ]]; then
    echo "API Tests passed."
  else
    echo -e '\033[31m ERROR: API Tests failed \033[0m'
    echo "GKE_PYTEST_STATUS=$GKE_PYTEST_STATUS"
    echo "CLOUDRUN_PYTEST_STATUS=$CLOUDRUN_PYTEST_STATUS"
    exit -1
  fi
}

# Clean up GCP resources.
clean_up() {
  if [[ "$skip_cleanup" ==  "" ]]; then
    printf "Cleaning up ${PROJECT_ID}...\n"
    
    echo "BASE_DIR=$BASE_DIR"
    export TF_BUCKET_NAME="${PROJECT_ID}-tfstate"
    
    cd $BASE_DIR/terraform/stages/gke
    terraform init -reconfigure -backend-config=bucket=$TF_BUCKET_NAME
    terraform destroy -auto-approve
    
    cd $BASE_DIR/terraform/stages/cloudrun
    terraform init -reconfigure -backend-config=bucket=$TF_BUCKET_NAME
    terraform destroy -auto-approve
    
    cd $BASE_DIR/terraform/stages/foundation
    terraform init -reconfigure -backend-config=bucket=$TF_BUCKET_NAME
    terraform destroy -auto-approve
    
    # FIXME: This is disabled for now until we find a way to create new project
    # for every e2e test.
    # delete_project
  else
    echo "Skip project cleaning up..."
    echo
  fi
}

# Deleting project. (Disabled)
delete_project() {
  echo "PROJECT_ID=${PROJECT_ID}"
  gcloud projects delete $PROJECT_ID --quiet
  rm -rf $OUTPUT_FOLDER/$PROJECT_ID
}

# Start e2e test steps
if [[ "$is_create_new_project" !=  "true" ]]; then
  echo "Creating new project..."
  # create_new_project
fi
echo "PROJECT_ID=$PROJECT_ID"
export GKE_PYTEST_STATUS=0
export CLOUDRUN_PYTEST_STATUS=0
export TEMPLATE_FEATURES="gke" # "gke|cloudrun"
source setup/init_env_vars.sh

cd $BASE_DIR
build_template
install_dependencies
setup_working_folder
sh setup/setup_all.sh
test_api_endpoints_gke
# test_api_endpoints_gcloud
clean_up
print_api_test_result

echo "PROJECT_ID=$PROJECT_ID"
echo "Elapsed Time: $(expr $SECONDS / 60) minutes"
