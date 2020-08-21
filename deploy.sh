#!/usr/bin/env bash

function _usage {
  cat <<END

Deploys a mutable grafana pod with default dashboards for monitoring
system submetrics during workload/benchmark runs

Usage: $(basename "${0}") [-c <kubectl_cmd>] [-n <namespace>] [-p <grafana_pwd>]

       $(basename "${0}") [-i <dash_path>]

       $(basename "${0}") [-d] [-n <namespace>]

  -c <kubectl_cmd>  : The (c)ommand to use for k8s admin (defaults to 'oc' for now)

  -n <namespace>    : The (n)amespace in which to deploy the Grafana instance
                      (defaults to 'dittybopper')

  -p <grafana_pass> : The (p)assword to configure for the Grafana admin user
                      (defaults to 'admin')

  -i <dash_path>    : (I)mport dashboard from given path. Using this flag will
                      bypass the deployment process and only do the import to an
                      already-running Grafana pod. Can be a local path or a remote
                      URL beginning with http.

  -d                : (D)elete an existing deployment

  -h                : Help

END
}

# Set defaults for command options
k8s_cmd='oc'
namespace='dittybopper'
grafana_pass='admin'
grafana_default_pass=True

# Other vars
deploy_template="templates/dittybopper.yaml.template"
arsenal="https://github.com/cloud-bulldozer/arsenal.git"
dashboards=(arsenal/jsonnet/rendered/ocp-performance.json arsenal/jsonnet/rendered/api-performance-overview.json arsenal/jsonnet/rendered/etcd-on-cluster-dashboard.json)

# Capture and act on command options
while getopts ":c:m:n:p:i:dh" opt; do
  case ${opt} in
    c)
      k8s_cmd=${OPTARG}
      ;;
    n)
      namespace="${OPTARG}"
      ;;
    p)
      grafana_pass=${OPTARG}
      grafana_default_pass=False
      ;;
    i)
      dash_import=("${OPTARG}")
      ;;
    d)
      delete=True
      ;;
    h)
      _usage
      exit 1
      ;;
    \?)
      echo -e "\033[32mERROR: Invalid option -${OPTARG}\033[0m" >&2
      _usage
      exit 1
      ;;
    :)
      echo -e "\033[32mERROR: Option -${OPTARG} requires an argument.\033[0m" >&2
      _usage
      exit 1
      ;;
  esac
done


echo -e "\033[32m
    ____  _ __  __        __
   / __ \(_) /_/ /___  __/ /_  ____  ____  ____  ___  _____
  / / / / / __/ __/ / / / __ \/ __ \/ __ \/ __ \/ _ \/ ___/
 / /_/ / / /_/ /_/ /_/ / /_/ / /_/ / /_/ / /_/ /  __/ /
/_____/_/\__/\__/\__, /_.___/\____/ .___/ .___/\___/_/
                /____/           /_/   /_/

\033[0m"
echo "Using k8s command: $k8s_cmd"
echo "Using namespace: $namespace"
if [[ ${grafana_default_pass} ]]; then
  echo "Using default grafana password: $grafana_pass"
else
  echo "Using custom grafana password."
fi


# Get environment values
#FIXME: This is OCP-Specific; needs updating to support k8s
echo ""
echo -e "\033[32mGetting environment vars...\033[0m"
prom_url=$($k8s_cmd get secrets -n openshift-monitoring grafana-datasources -o go-template='{{index .data "prometheus.yaml"}}' | base64 -d | jq '.datasources[0].url')
prom_user="internal"
prom_pass=$($k8s_cmd get secrets -n openshift-monitoring grafana-datasources -o go-template='{{index .data "prometheus.yaml"}}' | base64 -d | jq '.datasources[0].basicAuthPassword')
echo "Prometheus URL is: $prom_url"
echo "Prometheus password collected."

# Two arguments are 'pod label' and 'timeout in seconds'
function get_pod() {
  counter=0
  sleep_time=5
  counter_max=$(( $2 / sleep_time ))
  pod_name="False"
  until [ $pod_name != "False" ] ; do
    sleep $sleep_time
    pod_name=$($k8s_cmd get pods -l "$1" -n "$namespace" -o name | cut -d/ -f2)
    if [ -z "$pod_name" ]; then
      pod_name="False"
    fi
    counter=$(( counter+1 ))
    if [ $counter -eq $counter_max ]; then
      return 1
    fi
  done
  echo "$pod_name"
  return 0
}

function namespace() {
  # Create namespace
  $k8s_cmd "$1" namespace "$namespace"
}

function grafana() {
  sed -e "s;\${GRAFANA_ADMIN_PASSWORD};${grafana_pass};g" -e "s;\${PROMETHEUS_URL};${prom_url};g" -e "s;\${PROMETHEUS_USER};${prom_user};g" -e "s;\${PROMETHEUS_PASSWORD};${prom_pass};g" $deploy_template | $k8s_cmd "$1" -f -

  if [[ ! $delete ]]; then
    echo ""
    echo -e "\033[32mWaiting for pod to be up and ready...\033[0m"
    dittybopper_pod=$(get_pod 'app=dittybopper' 60)
    $k8s_cmd wait --for=condition=Ready -n "$namespace" pods/"$dittybopper_pod" --timeout=60s
  fi
}

function dashboard() {
  git clone ${arsenal} --depth=1
  make -C arsenal/jsonnet/ build
  dittybopper_route=$($k8s_cmd get routes -n "$namespace" -o=jsonpath='{.items[0].spec.host}')
  dashboards=("$@")
  for d in "${dashboards[@]}"; do
    if [[ $d =~ ^http ]]; then
      echo "Fetching remote dashboard $d"
      dashfile="/tmp/$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 8)"
      wget -q $d -O $dashfile >/dev/null
    elif [[ ! -f $d ]]; then
      echo "Dashboard ${d} not found"
      continue
    else
      echo "Using local dashboard $d"
      dashfile=$d
    fi
    echo "Importing dashboard $dashfile"
    dashboard=$(cat ${dashfile})
    echo "{\"dashboard\": ${dashboard}, \"overwrite\": true}" | \
      curl -Ss -k -XPOST -H "Content-Type: application/json" -H "Accept: application/json" -d@- \
      "http://admin:${grafana_pass}@${dittybopper_route}/api/dashboards/db" -o /dev/null
  done
  rm -Rf arsenal
}

if [[ $delete ]]; then
  echo ""
  echo -e "\033[32mDeleting Grafana...\033[0m"
  grafana "delete"
  echo ""
  echo -e "\033[32mDeleting namespace...\033[0m"
  namespace "delete"
  echo ""
  echo -e "\033[32mDeployment deleted!\033[0m"
elif [[ $dash_import ]]; then
  echo ""
  echo -e "\033[32mConfiguring dashboard...\033[0m"
  dashboard "${dash_import[@]}"
else
  echo ""
  echo -e "\033[32mCreating namespace...\033[0m"
  namespace "create"
  echo ""
  echo -e "\033[32mDeploying Grafana...\033[0m"
  grafana "apply"
  echo ""
  echo -e "\033[32mConfiguring dashboards...\033[0m"
  dashboard "${dashboards[@]}"
  echo ""
  echo -e "\033[32mDeployment complete!\033[0m"
  echo "You can access the Grafana instance at http://${dittybopper_route}"
fi
