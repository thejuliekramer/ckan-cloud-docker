#!/usr/bin/env bash

source functions.sh

INSTANCE_ID="${1}"

[ -z "${INSTANCE_ID}" ] && exit 1

INSTANCE_NAMESPACE="${INSTANCE_ID}"
export KUBECONFIG=/etc/ckan-cloud/.kube-config

CKAN_VALUES_FILE=/etc/ckan-cloud/${INSTANCE_ID}_values.yaml
TRAEFIK_VALUES_FILE=/etc/ckan-cloud/traefik-values.yaml
TRAEFIK_HELM_CHART_PATH=/etc/ckan-cloud/datagov-ckan-multi/multi-tenant-cluster/traefik
TRAEFIK_HELM_RELEASE_NAME=traefik
TRAEFIK_NAMESPACE=default
CKAN_HELM_RELEASE_NAME="ckan-multi-${INSTANCE_NAMESPACE}"
CKAN_HELM_CHART_PATH=/etc/ckan-cloud/datagov-ckan-multi/multi-tenant-helm/ckan
CREATE_PULL_SECRET_SCRIPT=/etc/ckan-cloud/.create-pull-secret.sh

! [ -e "${CKAN_VALUES_FILE}" ] && echo missing ${CKAN_VALUES_FILE} && exit 1
! [ -e "${TRAEFIK_VALUES_FILE}" ] && echo missing ${TRAEFIK_VALUES_FILE} && exit 1
! [ -e "${TRAEFIK_HELM_CHART_PATH}" ] && echo missing ${TRAEFIK_HELM_CHART_PATH} && exit 1
! [ -e "${CKAN_HELM_CHART_PATH}" ] && echo missing ${CKAN_HELM_CHART_PATH} && exit 1
! [ -e "${CREATE_PULL_SECRET_SCRIPT}" ] && echo missing ${CREATE_PULL_SECRET_SCRIPT} && exit 1

echo Creating instance: ${INSTANCE_ID}

INSTANCE_DOMAIN=`python3 -c '
import yaml;
print(yaml.load(open("'${CKAN_VALUES_FILE}'")).get("domain", ""))
'`

WITH_SANS_SSL=`python3 -c '
import yaml;
print("1" if yaml.load(open("'${CKAN_VALUES_FILE}'")).get("withSansSSL", False) else "0")
'`

REGISTER_SUBDOMAIN=`python3 -c '
import yaml;
print(yaml.load(open("'${CKAN_VALUES_FILE}'")).get("registerSubdomain", ""))
'`

LOAD_BALANCER_HOSTNAME=$(kubectl -n default get service traefik -o yaml \
    | python3 -c 'import sys, yaml; print(yaml.load(sys.stdin)["status"]["loadBalancer"]["ingress"][0]["hostname"])')


if [ "${REGISTER_SUBDOMAIN}" != "" ]; then
    cluster_register_sub_domain "${REGISTER_SUBDOMAIN}" "${LOAD_BALANCER_HOSTNAME}"
    [ "$?" != "0" ] && exit 1
fi

echo Configuring load balancer for domain "${INSTANCE_DOMAIN}"

grep 'rule = "Host:'${INSTANCE_DOMAIN}'"' /etc/ckan-cloud/traefik-values.yaml \
    && echo instance domain already exists: ${INSTANCE_DOMAIN} && exit 1

cp -f "${TRAEFIK_VALUES_FILE}" /etc/ckan-cloud/backups/traefik-values.yaml.`date +%Y-%m-%d_%H-%M` &&\
cp -f "${TRAEFIK_VALUES_FILE}" /etc/ckan-cloud/backups/traefik-values.yaml.last
[ "$?" != "0" ] && exit 1

TRAEFIK_VALUES_MODIFIED_FILE=/etc/ckan-cloud/traefik-values.yaml

if [ "${WITH_SANS_SSL}" == "1" ]; then
    echo Configuring SSL
    TEMPFILE=`mktemp`
    python3 -c '
import yaml, json;
traefik_values = yaml.load(open("'${TRAEFIK_VALUES_MODIFIED_FILE}'"));
def acme_domains():
    for line in traefik_values["acmeDomains"].splitlines():
        if line.startswith("  sans = ["):
            line = "  sans = " + json.dumps(json.loads(line.strip().split(" = ")[1]) + ["'${INSTANCE_DOMAIN}'"])
        yield line
print(yaml.dump(dict(traefik_values, acmeDomains="\n".join(acme_domains())),
                default_flow_style=False));
' > $TEMPFILE
    [ "$?" != "0" ] && exit 1
    TRAEFIK_VALUES_MODIFIED_FILE=$TEMPFILE
fi

TEMPFILE=`mktemp`
python3 -c '
import yaml;
traefik_values = yaml.load(open("'${TRAEFIK_VALUES_MODIFIED_FILE}'"));
traefik_values["backends"] += " \n\
[backends.'${INSTANCE_ID}'] \n\
  [backends.'${INSTANCE_ID}'.servers.server1] \n\
    url = \"http://nginx.'${INSTANCE_NAMESPACE}'\" \n\
";
traefik_values["frontends"] += " \n\
[frontends.'${INSTANCE_ID}'] \n\
  backend=\"'${INSTANCE_ID}'\" \n\
  passHostHeader = true \n\
  [frontends.'${INSTANCE_ID}'.headers] \n\
    SSLRedirect = true \n\
  [frontends.'${INSTANCE_ID}'.routes.route1] \n\
    rule = \"Host:'${INSTANCE_DOMAIN}'\" \n\
";
print(yaml.dump(traefik_values, default_flow_style=False));
' > $TEMPFILE
[ "$?" != "0" ] && exit 1
TRAEFIK_VALUES_MODIFIED_FILE=$TEMPFILE

mv $TRAEFIK_VALUES_MODIFIED_FILE $TRAEFIK_VALUES_FILE

echo Deploying to kube context `kubectl config current-context`, load balancer hostname: ${LOAD_BALANCER_HOSTNAME}

helm upgrade "${TRAEFIK_HELM_RELEASE_NAME}" "${TRAEFIK_HELM_CHART_PATH}" \
    --namespace "${TRAEFIK_NAMESPACE}" -if "${TRAEFIK_VALUES_FILE}" --dry-run --debug > /dev/stderr &&\
helm upgrade "${TRAEFIK_HELM_RELEASE_NAME}" "${TRAEFIK_HELM_CHART_PATH}" \
    --namespace "${TRAEFIK_NAMESPACE}" -if "${TRAEFIK_VALUES_FILE}"
[ "$?" != "0" ] && exit 1

echo Creating namespace: ${INSTANCE_NAMESPACE}

kubectl create ns "${INSTANCE_NAMESPACE}" &&\
kubectl --namespace "${INSTANCE_NAMESPACE}" \
    create serviceaccount "ckan-${INSTANCE_NAMESPACE}-operator" &&\
kubectl --namespace "${INSTANCE_NAMESPACE}" \
    create role "ckan-${INSTANCE_NAMESPACE}-operator-role" \
                --verb list,get,create \
                --resource secrets,pods,pods/exec,pods/portforward &&\
kubectl --namespace "${INSTANCE_NAMESPACE}" \
    create rolebinding "ckan-${INSTANCE_NAMESPACE}-operator-rolebinding" \
                       --role "ckan-${INSTANCE_NAMESPACE}-operator-role" \
                       --serviceaccount "${INSTANCE_NAMESPACE}:ckan-${INSTANCE_NAMESPACE}-operator"
[ "$?" != "0" ] && exit 1

echo Deploying CKAN instance: ${INSTSANCE_ID}

$CREATE_PULL_SECRET_SCRIPT "${INSTANCE_NAMESPACE}"
[ "$?" != "0" ] && exit 1

helm_upgrade() {
    helm --namespace "${INSTANCE_NAMESPACE}" upgrade "${CKAN_HELM_RELEASE_NAME}" "${CKAN_HELM_CHART_PATH}" \
        -if "${CKAN_VALUES_FILE}" "$@" --dry-run --debug > /dev/stderr &&\
    helm --namespace "${INSTANCE_NAMESPACE}" upgrade "${CKAN_HELM_RELEASE_NAME}" "${CKAN_HELM_CHART_PATH}" \
        -if "${CKAN_VALUES_FILE}" "$@"
}

wait_for_pods() {
    while ! kubectl --namespace "${INSTANCE_NAMESPACE}" get pods -o yaml | python3 -c '
import yaml, sys;
for pod in yaml.load(sys.stdin)["items"]:
    if pod["status"]["phase"] != "Running":
        print(pod["metadata"]["name"] + ": " + pod["status"]["phase"])
        exit(1)
    elif not pod["status"]["containerStatuses"][0]["ready"]:
        print(pod["metadata"]["name"] + ": ckan container is not ready")
        exit(1)
exit(0)
    '; do
        sleep 2
    done &&\
    kubectl --namespace "${INSTANCE_NAMESPACE}" get pods
}

helm_upgrade --set replicas=1 --set nginxReplicas=1 &&\
sleep 2 &&\
wait_for_pods &&\
helm_upgrade &&\
sleep 1 &&\
wait_for_pods
[ "$?" != "0" ] && exit 1

CKAN_ADMIN_PASSWORD=$(python3 -c "import binascii,os;print(binascii.hexlify(os.urandom(12)).decode())")
echo __ CKAN_ADMIN_PASSWORD = "${CKAN_ADMIN_PASSWORD}" > /dev/stderr

CKAN_POD_NAME=$(kubectl -n ${INSTANCE_NAMESPACE} get pods -l "app=ckan" -o 'jsonpath={.items[0].metadata.name}')
echo CKAN_POD_NAME = "${CKAN_POD_NAME}" > /dev/stderr

echo y \
    | kubectl -n ${INSTANCE_NAMESPACE} exec -it ${CKAN_POD_NAME} -- bash -c \
        "ckan-paster --plugin=ckan sysadmin -c /etc/ckan/production.ini add admin password=${CKAN_ADMIN_PASSWORD} email=admin@${INSTANCE_ID}" \
            > /dev/stderr
[ "$?" != "0" ] && exit 1

echo Running sanity tests for CKAN instance ${INSTSANCE_ID} on domain "${INSTANCE_DOMAIN}"

if [ "$(curl https://${INSTANCE_DOMAIN}/api/3)" != '{"version": 3}' ]; then
    kubectl -n default patch deployment traefik \
        -p "{\"spec\":{\"template\":{\"metadata\":{\"labels\":{\"date\":\"`date +'%s'`\"}}}}}" &&\
    kubectl -n default rollout status deployment traefik &&\
    sleep 10 &&\
    [ "$(curl https://${INSTANCE_DOMAIN}/api/3)" != '{"version": 3}' ]
    [ "$?" != "0" ] && exit 1
fi

echo Great Success!
echo CKAN Instance ${INSTANCE_ID} is available at https://${INSTANCE_DOMAIN}
echo CKAN admin password: ${CKAN_ADMIN_PASSWORD}
exit 0