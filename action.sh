#!/usr/bin/env bash

ACTION_DIR="$( cd $( dirname "${BASH_SOURCE[0]}" ) >/dev/null 2>&1 && pwd )"

function usage {
  echo "Usage: ${0} --command=[start|stop] <arguments>"
}

function safety_on {
  set -o errexit -o pipefail -o noclobber -o nounset
}

function safety_off {
  set +o errexit +o pipefail +o noclobber +o nounset
}

source "${ACTION_DIR}/vendor/getopts_long.sh"

command=
token=
project_id=
service_account_key=
runner_ver=
machine_region=
machine_zone=
machine_type=
boot_disk_type=
disk_size=
runner_service_account=
image_project=
image=
image_family=
network_tier=
network=
scopes=
shutdown_timeout=
subnet=
provisioning_model=
ephemeral=
no_external_address=
actions_preinstalled=
maintenance_policy_terminate=
arm=
accelerator=
vm_create_timeout=90
vm_create_retries=2
max_run_duration=1800
instance_termination_action=DELETE

OPTIND=1
while getopts_long :h opt \
  command required_argument \
  token required_argument \
  project_id required_argument \
  service_account_key required_argument \
  runner_ver required_argument \
  machine_region optional_argument \
  machine_zone optional_argument \
  machine_type required_argument \
  boot_disk_type optional_argument \
  disk_size optional_argument \
  runner_service_account optional_argument \
  image_project optional_argument \
  image optional_argument \
  image_family optional_argument \
  network_tier optional_argument \
  network optional_argument \
  scopes required_argument \
  shutdown_timeout required_argument \
  subnet optional_argument \
  provisioning_model required_argument \
  ephemeral required_argument \
  no_external_address required_argument \
  actions_preinstalled required_argument \
  arm required_argument \
  maintenance_policy_terminate optional_argument \
  accelerator optional_argument \
  vm_create_timeout optional_argument \
  vm_create_retries optional_argument \
  max_run_duration optional_argument \
  instance_termination_action optional_argument \
  help no_argument "" "$@"
do
  case "$opt" in
    command)
      command=$OPTLARG
      ;;
    token)
      token=$OPTLARG
      ;;
    project_id)
      project_id=$OPTLARG
      ;;
    service_account_key)
      service_account_key="$OPTLARG"
      ;;
    runner_ver)
      runner_ver=$OPTLARG
      ;;
    machine_region)
      machine_region=$OPTLARG
      ;;
    machine_zone)
      machine_zone=$OPTLARG
      ;;
    machine_type)
      machine_type=$OPTLARG
      ;;
    boot_disk_type)
      boot_disk_type=${OPTLARG-$boot_disk_type}
      ;;
    disk_size)
      disk_size=${OPTLARG-$disk_size}
      ;;
    runner_service_account)
      runner_service_account=${OPTLARG-$runner_service_account}
      ;;
    image_project)
      image_project=${OPTLARG-$image_project}
      ;;
    image)
      image=${OPTLARG-$image}
      ;;
    image_family)
      image_family=${OPTLARG-$image_family}
      ;;
    network_tier)
      network_tier=${OPTLARG-$network_tier}
      ;;
    network)
      network=${OPTLARG-$network}
      ;;
    scopes)
      scopes=$OPTLARG
      ;;
    shutdown_timeout)
      shutdown_timeout=$OPTLARG
      ;;
    subnet)
      subnet=${OPTLARG-$subnet}
      ;;
    provisioning_model)
      provisioning_model=$OPTLARG
      ;;
    ephemeral)
      ephemeral=$OPTLARG
      ;;
    no_external_address)
      no_external_address=$OPTLARG
      ;;
    actions_preinstalled)
      actions_preinstalled=$OPTLARG
      ;;
    maintenance_policy_terminate)
      maintenance_policy_terminate=${OPTLARG-$maintenance_policy_terminate}
      ;;
    arm)
      arm=$OPTLARG
      ;;
    accelerator)
      accelerator=$OPTLARG
      ;;
    vm_create_timeout)
      vm_create_timeout=${OPTLARG-$vm_create_timeout}
      ;;
    vm_create_retries)
      vm_create_retries=${OPTLARG-$vm_create_retries}
      ;;
    max_run_duration)
      max_run_duration=${OPTLARG-$max_run_duration}
      ;;
    instance_termination_action)
      instance_termination_action=${OPTLARG-$instance_termination_action}
      ;;
    h|help)
      usage
      exit 0
      ;;
    :)
      printf >&2 '%s: %s\n' "${0##*/}" "$OPTLERR"
      usage
      exit 1
      ;;
  esac
done

function gcloud_auth {
  # NOTE: when --project is specified, it updates the config
  echo ${service_account_key} | gcloud --project  ${project_id} --quiet auth activate-service-account --key-file - &>/dev/null
  echo "✅ Successfully configured gcloud."
}

function start_vm {
  echo "Starting GCE VM ..."
  if [[ -z "${service_account_key}" ]] || [[ -z "${project_id}" ]]; then
    echo "Won't authenticate gcloud. If you wish to authenticate gcloud provide both service_account_key and project_id."
  else
    echo "Will authenticate gcloud."
    gcloud_auth
  fi

  RUNNER_TOKEN=$(curl -S -s -XPOST \
      -H "authorization: Bearer ${token}" \
      https://api.github.com/repos/${GITHUB_REPOSITORY}/actions/runners/registration-token |\
      jq -r .token)
  echo "✅ Successfully got the GitHub Runner registration token"

  VM_ID="gce-gh-runner-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}"
  service_account_flag=$([[ -z "${runner_service_account}" ]] || echo "--service-account=${runner_service_account}")
  image_project_flag=$([[ -z "${image_project}" ]] || echo "--image-project=${image_project}")
  image_flag=$([[ -z "${image}" ]] || echo "--image=${image}")
  image_family_flag=$([[ -z "${image_family}" ]] || echo "--image-family=${image_family}")
  disk_size_flag=$([[ -z "${disk_size}" ]] || echo "--boot-disk-size=${disk_size}")
  boot_disk_type_flag=$([[ -z "${boot_disk_type}" ]] || echo "--boot-disk-type=${boot_disk_type}")
  provisioning_model_flag=$([[ -z "${provisioning_model}" ]] || echo "--provisioning-model=${provisioning_model}")
  ephemeral_flag=$([[ "${ephemeral}" == "true" ]] && echo "--ephemeral" || echo "")
  no_external_address_flag=$([[ "${no_external_address}" == "true" ]] && echo "--no-address" || echo "")
  network_tier_flag=$([[ -n "${network_tier}" ]] && echo "--network-tier=${network_tier}" || echo "")
  network_flag=$([[ -n "${network}" ]] && echo "--network=${network}" || echo "")
  subnet_flag=$([[ -n "${subnet}" ]] && echo "--subnet=${subnet}" || echo "")
  accelerator=$([[ -n "${accelerator}" ]] && echo "--accelerator=${accelerator} --maintenance-policy=TERMINATE" || echo "")
  maintenance_policy_flag=$([[ -n "${maintenance_policy_terminate}" ]] && echo "--maintenance-policy=TERMINATE" || echo "")

  echo "The new GCE VM will be ${VM_ID}"


  if $actions_preinstalled ; then
    echo "✅ Startup script won't install GitHub Actions (pre-installed)"
    runner_setup_script="#!/bin/bash
    cd /actions-runner"
  else
    if [[ "$runner_ver" = "latest" ]]; then
      response=$(curl -sL https://api.github.com/repos/actions/runner/releases/latest)
      latest_ver=$(echo "$response" | jq -r '.tag_name' | sed -e 's/^v//')
      runner_ver="$latest_ver"
      echo "✅ runner_ver=latest is specified. v$latest_ver is detected as the latest version."
      if [[ -z "$latest_ver" || "null" == "$latest_ver" ]]; then
        echo "❌ could not retrieve the latest version of a runner"
        echo "🔍 Debug: Raw GitHub API response (first 500 chars):"
        echo "$response" | head -c 500
        echo ""
        echo "🔍 Debug: Raw tag_name: '$(echo "$response" | jq -r '.tag_name')'"
        exit 2
      fi
    fi
    echo "✅ Startup script will install GitHub Actions v$runner_ver"
    if $arm ; then
      runner_setup_script="#!/bin/bash
      mkdir /actions-runner
      cd /actions-runner
      curl -o actions-runner-linux-arm64-${runner_ver}.tar.gz -L https://github.com/actions/runner/releases/download/v${runner_ver}/actions-runner-linux-arm64-${runner_ver}.tar.gz
      tar xzf ./actions-runner-linux-arm64-${runner_ver}.tar.gz
      ./bin/installdependencies.sh"
    else
      runner_setup_script="#!/bin/bash
      mkdir /actions-runner
      cd /actions-runner
      curl -o actions-runner-linux-x64-${runner_ver}.tar.gz -L https://github.com/actions/runner/releases/download/v${runner_ver}/actions-runner-linux-x64-${runner_ver}.tar.gz
      tar xzf ./actions-runner-linux-x64-${runner_ver}.tar.gz
      ./bin/installdependencies.sh"
    fi
  fi

  # GCE VM label values requirements:
  # - can contain only lowercase letters, numeric characters, underscores, and dashes
  # - have a maximum length of 63 characters
  # ref: https://cloud.google.com/compute/docs/labeling-resources#requirements
  #
  # Github's requirements:
  # - username/organization name
  #   - Max length: 39 characters
  #   - All characters must be either a hyphen (-) or alphanumeric
  # - repository name
  #   - Max length: 100 code points
  #   - All code points must be either a hyphen (-), an underscore (_), a period (.),
  #     or an ASCII alphanumeric code point
  # ref: https://github.com/dead-claudia/github-limits
  function truncate_to_label {
    local in="${1}"
    in="${in:0:63}"                              # ensure max length
    in="${in//./_}"                              # replace '.' with '_'
    in=$(tr '[:upper:]' '[:lower:]' <<< "${in}") # convert to lower
    echo -n "${in}"
  }
  gh_repo_owner="$(truncate_to_label "${GITHUB_REPOSITORY_OWNER}")"
  gh_repo="$(truncate_to_label "${GITHUB_REPOSITORY##*/}")"
  gh_run_id="${GITHUB_RUN_ID}"

  # Validate either machine_region or machine_zone is provided
  if [[ -z "$machine_region" && -z "$machine_zone" ]]; then
    echo "❌ Either machine_region or machine_zone must be specified"
    exit 1
  fi

  # If both region and zone are provided, zone takes precedence
  local zones=()
  if [[ -n "$machine_zone" ]]; then
    # Split machine_zone by commas and trim whitespace
    IFS=',' read -r -a zones <<< "$machine_zone"
    # Trim whitespace from each zone
    for i in "${!zones[@]}"; do
      zones[$i]=$(echo "${zones[$i]}" | xargs)
    done
    if [[ ${#zones[@]} -eq 0 ]]; then
      echo "❌ No valid zones specified in machine_zone"
      exit 1
    fi
    echo "🔍 Using specified zones: ${zones[*]}"
  elif [[ -n "$machine_region" ]]; then
    # If only region is provided, discover zones in the region
    zones=($(gcloud compute zones list --filter="region:${machine_region}$" --format='value(name)' | sort -r))
    if [[ ${#zones[@]} -eq 0 ]]; then
      echo "❌ No zones found in region ${machine_region}"
      exit 1
    fi
    echo "🔍 Found ${#zones[@]} zones in region ${machine_region}"
  fi

  # Create VM with retry logic
  local retry_count=0
  local zone_index=0
  local vm_created=false

  while [[ $retry_count -le $vm_create_retries ]]; do
    # If this is a retry, create a new VM ID to avoid conflicts and try next zone if available
    if [[ $retry_count -gt 0 ]]; then
      VM_ID="gce-gh-runner-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}-retry${retry_count}"
      echo "Retrying VM creation (attempt $retry_count of $vm_create_retries)..."
      echo "The new GCE VM will be ${VM_ID}"
      
      # Move to the next zone
      zone_index=$((zone_index + 1))
      
      # If we've gone through all zones, start over from the first zone
      if [[ $zone_index -ge ${#zones[@]} ]]; then
        zone_index=0
      fi
      
      echo "🔄 Trying zone ${zones[$zone_index]} ($((zone_index + 1)) of ${#zones[@]})"
    fi
    
    # Set the current zone from the zones array
    local current_zone=${zones[$zone_index]}
    export current_zone  # Make it available to subprocesses
    echo "🏗️  Creating VM in zone: $current_zone"

  # Define startup script now that current_zone is available
  startup_script="
	# Create a systemd service in charge of shutting down the machine once the workflow has finished
	cat <<-EOF > /etc/systemd/system/shutdown.sh
	#!/bin/sh
	sleep ${shutdown_timeout}
	gcloud compute instances delete $VM_ID --zone=${current_zone} --quiet
	EOF

	cat <<-EOF > /etc/systemd/system/shutdown.service
	[Unit]
	Description=Shutdown service
	[Service]
	ExecStart=/etc/systemd/system/shutdown.sh
	[Install]
	WantedBy=multi-user.target
	EOF

	chmod +x /etc/systemd/system/shutdown.sh
	systemctl daemon-reload
	systemctl enable shutdown.service

	cat <<-EOF > /usr/bin/gce_runner_shutdown.sh
	#!/bin/sh
	echo \"✅ Self deleting $VM_ID in ${current_zone} in ${shutdown_timeout} seconds ...\"
	# We tear down the machine by starting the systemd service that was registered by the startup script
	systemctl start shutdown.service
	EOF

	# Install and configure GitHub Actions runner
	${runner_setup_script}

	# See: https://docs.github.com/en/actions/hosting-your-own-runners/managing-self-hosted-runners/running-scripts-before-or-after-a-job
	echo "ACTIONS_RUNNER_HOOK_JOB_COMPLETED=/usr/bin/gce_runner_shutdown.sh" >.env
	gcloud compute instances add-labels ${VM_ID} --zone=${current_zone} --labels=gh_ready=0 && \\
	RUNNER_ALLOW_RUNASROOT=1 ./config.sh --url https://github.com/${GITHUB_REPOSITORY} --token ${RUNNER_TOKEN} --labels ${VM_ID} --unattended ${ephemeral_flag} --disableupdate && \\
	./svc.sh install && \\
	./svc.sh start && \\
	gcloud compute instances add-labels ${VM_ID} --zone=${current_zone} --labels=gh_ready=1
	# 3 days represents the max workflow runtime. This will shutdown the instance if everything else fails.
	nohup sh -c \"sleep 3d && gcloud --quiet compute instances delete ${VM_ID} --zone=${current_zone}\" > /dev/null &
  "

  # Create VM instance
    if gcloud compute instances create ${VM_ID} \
      --zone=${current_zone} \
      ${disk_size_flag} \
      ${boot_disk_type_flag} \
      --machine-type=${machine_type} \
      --scopes=${scopes} \
      ${service_account_flag} \
      ${image_project_flag} \
      ${image_flag} \
      ${image_family_flag} \
      ${provisioning_model_flag} \
      ${no_external_address_flag} \
      ${network_tier_flag} \
      ${network_flag} \
      ${subnet_flag} \
      ${accelerator} \
      ${maintenance_policy_flag} \
      --max-run-duration=${max_run_duration}s \
      --instance-termination-action=${instance_termination_action} \
      --labels=gh_ready=0,gh_repo_owner="${gh_repo_owner}",gh_repo="${gh_repo}",gh_run_id="${gh_run_id}" \
      --metadata=startup-script="$startup_script"; then

      echo "label=${VM_ID}" >> $GITHUB_OUTPUT

      # Wait for VM to be ready
      safety_off
      local i=0
      local wait_time=$((vm_create_timeout / 5))
      while (( i < wait_time )); do
        GH_READY=$(gcloud compute instances describe ${VM_ID} --zone=${current_zone} --format='json(labels)' | jq -r .labels.gh_ready)
        if [[ $GH_READY == 1 ]]; then
          vm_created=true
          break
        fi
        echo "${VM_ID} not ready yet, waiting 5 secs ... ($(( (i+1) * 5 ))/${vm_create_timeout} seconds)"
        sleep 5
        i=$((i+1))
      done

      # Check if VM is ready
      if [[ $vm_created == true ]]; then
        echo "✅ ${VM_ID} ready ..."
        break
      else
        echo "Timeout waiting for ${VM_ID} to be ready after ${vm_create_timeout} seconds, deleting VM..."
        gcloud --quiet compute instances delete ${VM_ID} --zone=${current_zone}
      fi
    else
      echo "❌ Failed to create VM instance ${VM_ID}"
    fi

    retry_count=$((retry_count+1))

    # If we've exhausted all retries, exit with error
    if [[ $retry_count -gt $vm_create_retries ]]; then
      echo "❌ Failed to create a working VM after ${vm_create_retries} retries"
      exit 1
    fi
  done

  # Restore safety settings
  safety_on

  # If VM creation was not successful, exit with error
  if [[ $vm_created != true ]]; then
    echo "❌ Failed to create a working VM within the timeout"
    exit 1
  fi
}

safety_on
case "$command" in
  start)
    start_vm
    ;;
  *)
    echo "Invalid command: \`${command}\`, valid values: start" >&2
    usage
    exit 1
    ;;
esac
