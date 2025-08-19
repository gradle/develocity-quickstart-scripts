#!/usr/bin/env bash
# This installation script sets up a lightweight Kubernetes (K3s) environment in which Develocity is deployed using Helm.
# It performs the following actions in a sequence:
# - Installs K3s server
# - Start K3s server
# - Installs Helm
# - Fetches the Develocity charts from the Helm repository
# - Initializes the Develocity Pods in K3s
# - Creates a base settings.gradle.kts file which is pre-configured for your new instance

# Shellcheck
# shellcheck disable=SC2015

set -e

trap cleanup SIGINT SIGTERM ERR EXIT

# --- Variables ---
DV_CHART_REGISTRY_URL=${DV_CHART_REGISTRY_URL:-"https://helm.gradle.com/"}
SCRIPT_VERSION="0.1"

# Log File
LOGFILE="$(pwd)/install_$(date +'%Y%m%d_%H%M%S').log"

# --- Functions ---
# Colors
setup_colors() {
  if [[ -t 2 ]] && [[ -z "${NO_COLOR-}" ]] && [[ "${TERM-}" != "dumb" ]]; then
    NOFORMAT='\033[0m' RED='\033[00;31m' GREEN='\033[0;32m' ORANGE='\033[38;5;202m' YELLOW='\033[00;33m' BOLD='\033[1m' WHITE='\033[01;37m'
  else
    NOFORMAT='' RED='' GREEN='' ORANGE='' YELLOW='' BOLD='' WHITE=''
  fi
}

# Load colors
setup_colors

# Exit the script with an error message
die() {
  local msg=$1
  local code=${2-1} # default exit status 1
  msg "$msg"
  exit "$code"
}

# Cleanup
cleanup() {
  trap - SIGINT SIGTERM ERR EXIT
  # script cleanup here
}

# Log Info
logInfo(){
    #echo >&2 -e "[INFO]$  ${1-}"
    log_output "[INFO]  $1"
}

exitError(){
  #echo >&2 -e "${RED}[ERROR]${NOFORMAT}  ${1-}"
  log_output "${RED}[ERROR]${NOFORMAT}  ${1-}"
  exit 1
}

warn(){
    #echo >&2 -e "${ORANGE}[WARN]${NOFORMAT}  ${1-}"
    log_output "${ORANGE}[WARN]${NOFORMAT}  ${1-}"
}

# Message
msg() {
  echo >&2 -e "${1-}"
}

log_output() {
    local message="$1"

    # Log to the file without colors
    echo -e "$message" | tee -a "$LOGFILE" | sed 's/\x1b\[[0-9;]*m//g' > /dev/null

    # Display the message in the terminal with colors
    echo -e "$message"
}

usage() {
echo -e "${WHITE}${BOLD}Develocity Installation Script${NOFORMAT}"
echo -e "\nUsage: $(basename "${BASH_SOURCE[0]}") [-h][-v][-l][-hn] [-u]"

echo -e "\n${WHITE}${BOLD}Example: ./install.sh -l develocity.license -hn develocity.example.io${NOFORMAT}"

echo -e "\nThe script sets up a lightweight Kubernetes (K3s) environment in which Develocity is deployed using Helm."
echo -e "The license (-l, --license) and hostname (-hn, --hostname) flags are always required."

echo -e "\nThe script is tested with Ubuntu 24.04 x86_64 (AMI)."

echo -e "If you have questions please contact the Develocity support team."

echo -e "\nDevelocity Documentation: https://gradle.com/develocity/resources/"

echo -e "\n${WHITE}${BOLD}Available options:${NOFORMAT}"
echo -e "${YELLOW}-h, --help${NOFORMAT}          Print this help and exit"
echo -e "${YELLOW}-v, --version${NOFORMAT}       Print the version of the script and exit"
echo -e "${YELLOW}-l, --license${NOFORMAT}       Path to license file (required)"
echo -e "${YELLOW}-hn, --hostname${NOFORMAT}     Hostname (required)"
echo -e "${YELLOW}-u, --uninstall${NOFORMAT}     Uninstall Develocity Platform"

exit
}

# Check if the OS is Linux and x86_64
validateOS () {
    local OS_TYPE
    OS_TYPE=$(uname)
    if [ "$OS_TYPE" != "Linux" ]; then
      exitError "This script is only supported on Linux."
    fi

    local ARCHITECTURE
    ARCHITECTURE=$(uname -m)
    if [ "$ARCHITECTURE" != "x86_64" ]; then
      exitError "This script is only supported on x86_64 architecture."
    fi
}

# Check the system resources
checkResource() {
    local recommendedMinRAM=6291456              # 6G Total RAM => 16*1024*1024k=6291456
    local recommendedMinCPU=4

    local osType
    osType=$(uname)
    local freeCPU=

    logInfo "Validating system requirements"

    if [[ $osType == "Linux" ]]; then
        totalRAM="$(grep ^MemTotal /proc/meminfo | awk '{print $2}')"
        freeCPU="$(grep -c ^processor /proc/cpuinfo)"
    fi

    local msg=""

   if [[ ${totalRAM} -lt ${recommendedMinRAM} ]]; then
    totalRAMToShow=$((totalRAM / 1024 / 1024))
    recommendedMinRAMToShow=$((recommendedMinRAM / 1024 / 1024))
    warn "Running with ${totalRAMToShow}GB Total RAM. Recommended value: ${recommendedMinRAMToShow}GB"
    fi

    if [ "${freeCPU}" -lt ${recommendedMinCPU} ]; then
        warn "Running with ${freeCPU} CPU Cores. Recommended value: ${recommendedMinCPU} Cores"
    fi;
}

# Check required tools
checkTools(){
    local toolsList="curl"
    local notInstalled=""

    for tool in ${toolsList}; do
        if ! hash "${tool}" >/dev/null 2>&1; then
            notInstalled="${notInstalled} ${tool}"
        fi
    done
    if [ -n "${notInstalled}" ]; then
        exitError "The following tools [ ${notInstalled} ] are missing, the script uses these to perform few actions, please install them and retry."
    fi
}

# Check if the URL is accessible
checkUrl(){
    local url="$1"
    if ! curl --output /dev/null -L --silent --head --fail "$url"; then
      exitError "Unable to access the url [ $url ], check if this environment has access to internet"
    fi
}

# https://unix.stackexchange.com/questions/396630/the-proper-way-to-test-if-a-service-is-running-in-a-script
# systemctl is-active --quiet k3s && echo Service is running
checkK3sStatus() {
  local retries=0
  local max_retries=10
  local sleep_interval=2  # seconds

  while (( retries < max_retries )); do
    # Check if k3s service is active
    if systemctl is-active --quiet k3s; then
      echo "k3s service is running."
      return 0  # k3s is running, continue the script
    else
      echo "k3s service is not running. Retrying... ($((retries + 1))/$max_retries)"
      ((retries++))
      sleep "$sleep_interval"
    fi
  done
}

# --- Installation functions ---
# Check Develocity connectivity
checkDevelocity(){
    logInfo "Checking Develocity connectivity"
    curl -sw \\n --fail-with-body --show-error http://"${hostname}"/ping || exitError "Develocity is not reachable"
}

# Install K3s
installK3s(){
  if hash k3s >/dev/null 2>&1; then
      logInfo "k3s is installed"
      return
  fi

  local baseUrl="https://get.k3s.io"
  checkUrl "${baseUrl}"

  logInfo "Installing K3s..."
   curl -s -fL ${baseUrl} | sh - || exitError "Failed to install k3s"
}

configureK3s(){
    logInfo "Configuring K3s, this requires sudo access..."
    # Set the KUBECONFIG file permissions
    sudo chown $UID /etc/rancher/k3s/k3s.yaml
    # Create the .kube directory
    mkdir -p "${HOME}/.kube"
    # Create a symbolic link to the KUBECONFIG file
    ln -sf /etc/rancher/k3s/k3s.yaml "${HOME}/.kube/config"
}

# Install Helm
installHelm(){
  if hash helm >/dev/null 2>&1; then
      logInfo "Helm client is installed"
      return
  fi

  local url="https://raw.githubusercontent.com/helm/helm/master/scripts/get-helm-3"
  checkUrl "${url}"

  logInfo "Installing Helm..."
  curl -fsSL -o get_helm.sh ${url} && \
  chmod 700 get_helm.sh && \
  ./get_helm.sh || exitError "Failed to install Helm client"
}

# Install the platform chart
installPlatformChart(){
  logInfo "Installing/Upgrading DV Platform Helm chart using license path: ${license}"
    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

    local baseUrl="${DV_CHART_REGISTRY_URL}"
    checkUrl "${baseUrl}"
    helm repo add gradle "${baseUrl}" && \
    helm repo update && \
    helm install \
    --create-namespace --namespace develocity \
    ge-standalone \
    gradle/gradle-enterprise-standalone \
    --set global.hostname="${hostname}" \
    --set-file global.license.file=./"${license}" \
    || exitError "Failed to install the Develocity Helm chart"
}

# ---Uninstall and cleanup functions ---
# Uninstall Develocity Platform
uninstallDevelocityPlatform(){
  read -rp "Are you sure you want to uninstall Develocity Platform? (y/n): " confirm
  if [[ "$confirm" =~ ^[Yy]$ ]]; then
    logInfo "Uninstalling Develocity Platform"
    helm uninstall ge-standalone -n develocity
  else
    logInfo "Uninstallation cancelled"
  fi
}

# Cleanup Helm
# Remove get_helm.sh from installation dir
cleanupHelm(){
  if [[ -f get_helm.sh ]]; then
    logInfo "Removing get_helm.sh installation script"
    rm -f get_helm.sh
  fi
}

# --- kubectl functions ---
# Get the Develocity password
getDevelocityPassword(){
    logInfo "Getting Develocity password"
    local password
    password=$(kubectl -n develocity get secret gradle-default-system-password-secret --template="{{.data.password}}" | base64 --decode)
    logInfo "Develocity password: ${password}"
}

# Save the Develocity credentials to a file
saveCredentials(){
    local password
    password=$(kubectl -n develocity get secret gradle-default-system-password-secret --template="{{.data.password}}" | base64 --decode)
    echo "Develocity user: system" > credentials.txt
    echo "Develocity password: ${password}" >> credentials.txt
    echo "Develocity host: http://${hostname}" >> credentials.txt
}

# Display installation in progress with a progress output and check the state of the Pods in the background.
# Once all Pods a ready display the end banner.
# If there is an error display the error output and point in the message to the logfile
checkInstallState() {
  logInfo "Checking installation status ..."

  # Define variables
  NAMESPACE="develocity"
  MAX_WAIT_TIME=600   # Maximum wait time in seconds (10 minutes)
  CHECK_INTERVAL=30   # Time between checks in seconds (30 seconds)
  START_TIME=$(date +%s)

  # Check if kubectl is installed
  if ! command -v kubectl &> /dev/null; then
      echo "kubectl could not be found. Please install kubectl and try again."
      exit 1
  fi

  # Sleep for ten seconds to give Helm some time
  sleep 10

  # Get all pods in the namespace
  PODS=$(kubectl get pods -n "$NAMESPACE" --selector '!batch.kubernetes.io/job-name' -o jsonpath='{.items[*].metadata.name}')

  # Total number of pods
  TOTAL_PODS=$(echo "$PODS" | wc -w)
  READY_PODS=0
  FAILED_PODS=0

  # Function to check readiness of all pods
  check_pods_status() {
      READY_PODS=0
      FAILED_PODS=0

      for POD in $PODS; do
          # Check if the Pod is running
          POD_STATUS=$(kubectl get pods "$POD" -n "$NAMESPACE" -o jsonpath='{.status.phase}')
          if [[ "$POD_STATUS" != "Running" ]]; then
              FAILED_PODS=$((FAILED_PODS + 1))
              continue
          fi

          # Check if the Pod is ready
          POD_READY=$(kubectl get pods "$POD" -n "$NAMESPACE" -o jsonpath='{.status.containerStatuses[0].ready}')
          if [[ "$POD_READY" != "true" ]]; then
              FAILED_PODS=$((FAILED_PODS + 1))
              continue
          fi

          READY_PODS=$((READY_PODS + 1))
      done
  }

  # Main loop to check Pods status periodically until all are ready or timeout occurs
  while true; do
      # Call function to check status
      check_pods_status

      # Display progress bar
      # shellcheck disable=SC2004
      PROGRESS=$(($READY_PODS * 100 / $TOTAL_PODS))
      BAR=$(printf "%-${PROGRESS}s" "#" | tr ' ' '#')
      printf "\r[$BAR] $PROGRESS%% (Ready: $READY_PODS / $TOTAL_PODS)"

      # Check if all Pods are ready
      if [[ $READY_PODS -eq $TOTAL_PODS ]]; then
          echo -e "\nAll pods are ready!"
          return 0
      fi

      # Check if the maximum wait time has passed
      CURRENT_TIME=$(date +%s)
      ELAPSED_TIME=$((CURRENT_TIME - START_TIME))
      if [[ $ELAPSED_TIME -ge $MAX_WAIT_TIME ]]; then
          echo -e "\nTimeout reached. Some pods are still not ready."
          return 1
      fi

      # Wait for the specified interval before checking again
      sleep $CHECK_INTERVAL
  done

}

# Create Gradle build file for this instance
createBuildFile() {
  EOL=$'\n'  # Define End Of Line

  # Content of the settings.gradle.kts file
  # renovate: depName=com.gradle.develocity packageName=com.gradle.develocity:com.gradle.develocity.gradle.plugin
  DEVELOCITY_PLUGIN_VERSION=4.1.1
  # renovate: depName=org.gradle.toolchains.foojay-resolver-convention packageName=org.gradle.toolchains.foojay-resolver-convention:org.gradle.toolchains.foojay-resolver-convention.gradle.plugin
  FOOJAY_RESOLVER_VERSION=1.0.0
  SETTINGS_CONTENT="
plugins {
    // Develocity Gradle Plugin
    id(\"com.gradle.develocity\") version \"$DEVELOCITY_PLUGIN_VERSION\"
    id(\"org.gradle.toolchains.foojay-resolver-convention\") version \"$FOOJAY_RESOLVER_VERSION\"
}$EOL
develocity {
    // The hostname of the Develocity instance
    server.set(\"http://${hostname}\")
    // Disable SSL
    allowUntrustedServer.set(true)
}
rootProject.name = \"gradle-build-scan-quickstart\"$EOL
"
# Write to the settings.gradle.kts file
    echo "$SETTINGS_CONTENT" > settings.gradle.kts

    echo "settings.gradle.kts file created successfully!"

}

# --- Banner functions ---
# Do not use for production installations
# Start banner
bannerStart() {
    echo
    echo -e "${BOLD}${WHITE}Develocity Platform Installation${NOFORMAT}"
    echo
    log_output "${WHITE}This script will setup a Develocity instance which is customized for evaluating purpose only.${NOFORMAT}"
    read -rp "Press Enter to continue..."
}

# End banner
postInstallMsg(){
  local password
  password=$(kubectl -n develocity get secret gradle-default-system-password-secret --template="{{.data.password}}" | base64 --decode)
    #echo -e """
    log_output """
${BOLD}${WHITE}Your Develocity instance is deployed.${NOFORMAT}
Access Develocity via the browser at: ${GREEN}http://${hostname}${NOFORMAT}

      Develocity user: system
      Develocity password: ${password}

      Credentials are also saved to credentials.txt file in the current directory.

      For more information, please visit:

      Develocity Administration Manual: https://docs.gradle.com/develocity/helm-admin/current/
      Helm Chart Documentation: https://docs.gradle.com/develocity/tutorials/helm-standalone/current/

      You can check the status of the Platform by running the following command:

      ${WHITE}kubectl --namespace develocity get pods${NOFORMAT}

      If you have any questions or need any assistance contact the Develocity support team or your customer success representative.

      The installation script created a pre-configured setting.gradle.kts file for you.


  """
  }

    #---
    parse_params() {
      license=''
      hostname=''

      while :; do
        case "${1-}" in
          -h | --help) usage ;;
          -v | --version) echo "$Script_Version"; exit 0 ;;
          --no-color) NO_COLOR=1 ;;
          -l | --license)
            if [[ -f "${2-}" ]]; then
              license="${2-}"
            else
              die "License file not found: ${2-}"
            fi
            shift
            ;;
          -hn | --hostname)
            hostname="${2-}"
            shift
            ;;
          -u | --uninstall) uninstallDevelocityPlatform; exit 0 ;;
          --) shift; break ;;
          -?*) die "Unknown option: $1" ;;
          *) break ;;
        esac
        shift
      done
    #---

    # Check required params
    [[ -z "${license-}" ]] && usage
    [[ -z "${hostname-}" ]] && usage
    return 0
}

parse_params "$@"

# --- Script logic here ---

# Display the start banner
bannerStart

# Validate OS, resources and tools
validateOS
checkResource
checkTools

# Install k3s
installK3s

# Check if k3s is running
checkK3sStatus

# Configure k3s
configureK3s

# Install Helm
installHelm

# Install the platform chart
installPlatformChart

# Display installation in progress screen
checkInstallState

# Check if we can ping the URL
checkDevelocity

# Save the Develocity credentials
saveCredentials

# Display the post install message
postInstallMsg

# Save example build file for gradle
createBuildFile

# Remove get_helm.sh installation script
cleanupHelm