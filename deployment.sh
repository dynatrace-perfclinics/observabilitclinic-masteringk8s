#!/usr/bin/env bash

################################################################################
### Script deploying the Observ-K8s environment
### Parameters:
### Clustern name: name of your k8s cluster
### dttoken: Dynatrace api token with ingest metrics and otlp ingest scope
### dturl : url of your DT tenant wihtout any / at the end for example: https://dedede.live.dynatrace.com
################################################################################


### Pre-flight checks for dependencies
if ! command -v jq >/dev/null 2>&1; then
    echo "Please install jq before continuing"
    exit 1
fi

if ! command -v git >/dev/null 2>&1; then
    echo "Please install git before continuing"
    exit 1
fi


if ! command -v helm >/dev/null 2>&1; then
    echo "Please install helm before continuing"
    exit 1
fi

if ! command -v kubectl >/dev/null 2>&1; then
    echo "Please install kubectl before continuing"
    exit 1
fi
echo "parsing arguments"
while [ $# -gt 0 ]; do
  case "$1" in
   --dtoperatortoken)
     DTOPERATORTOKEN="$2"
    shift 2
     ;;
   --dtingesttoken)
     DTTOKEN="$2"
    shift 2
     ;;
   --dturl)
     DTURL="${2%/}"
    shift 2
     ;;
  --clustername)
    CLUSTERNAME="$2"
   shift 2
    ;;
  *)
    echo "Warning: skipping unsupported option: $1"
    shift
    ;;
  esac
done
echo "Checking arguments"
if [ -z "$CLUSTERNAME" ]; then
  echo "Error: clustername not set!"
  exit 1
fi
if [ -z "$DTURL" ]; then
  echo "Error: Dt url not set!"
  exit 1
fi

if [ -z "$DTTOKEN" ]; then
  echo "Error: Data ingest api-token not set!"
  exit 1
fi

if [ -z "$DTOPERATORTOKEN" ]; then
  echo "Error: DT operator token not set!"
  exit 1
fi


helm upgrade --install ingress-nginx ingress-nginx  --repo https://kubernetes.github.io/ingress-nginx  --namespace ingress-nginx --create-namespace

### get the ip adress of ingress ####
IP=""
while [ -z $IP ]; do
  echo "Waiting for external IP"
  IP=$(kubectl get svc ingress-nginx-controller -n ingress-nginx -ojson | jq -j '.status.loadBalancer.ingress[].ip')
  [ -z "$IP" ] && sleep 10
done
echo 'Found external IP: '$IP

### Update the ip of the ip adress for the ingres
#TODO to update this part to create the various Gateway rules
sed -i "s,IP_TO_REPLACE,$IP," hipstershop/k8s-manifest.yaml
sed -i "s,IP_TO_REPLACE,$IP," hipstershop/k8s-manifes_v0.yaml
sed -i "s,IP_TO_REPLACE,$IP," k6/loadtest_job.yaml
#### OpenCost
helm install my-prometheus --repo https://prometheus-community.github.io/helm-charts prometheus \
  --namespace prometheus --create-namespace \
  --set prometheus-pushgateway.enabled=false \
  --set alertmanager.enabled=false \
  -f https://raw.githubusercontent.com/opencost/opencost/develop/kubernetes/prometheus/extraScrapeConfigs.yaml

kubectl apply --namespace opencost -f https://raw.githubusercontent.com/opencost/opencost/develop/kubernetes/opencost.yaml

#### Deploy keptn lifecycle Toolkit
helm repo add klt https://charts.lifecycle.keptn.sh
helm repo update
helm upgrade --install keptn klt/klt -n keptn-lifecycle-toolkit-system --create-namespace --wait

#### Deploy the Dynatrace Operator
kubectl create namespace dynatrace
kubectl apply -f https://github.com/Dynatrace/dynatrace-operator/releases/download/v0.11.1/kubernetes.yaml
kubectl apply -f https://github.com/Dynatrace/dynatrace-operator/releases/download/v0.11.1/kubernetes-csi.yaml
kubectl -n dynatrace wait pod --for=condition=ready --selector=app.kubernetes.io/name=dynatrace-operator,app.kubernetes.io/component=webhook --timeout=300s
kubectl -n dynatrace create secret generic dynakube --from-literal="apiToken=$DTOPERATORTOKEN" --from-literal="dataIngestToken=$DTTOKEN"
sed -i "s,TENANTURL_TOREPLACE,$DTURL," dynatrace/dynakube.yaml
sed -i "s,CLUSTER_NAME_TO_REPLACE,$CLUSTERNAME,"  dynatrace/dynakube.yaml
sed -i "s,TENANTURL_TOREPLACE,$DTURL," keptn/metricProvider.yaml
kubectl apply -f dynatrace/dynakube.yaml -n dynatrace


#deploy demo application
kubectl create ns hipster-shop
kubectl create secret generic dynatrace  --from-literal=dynatrace_oltp_url="$DTURL" --from-literal=dt_api_token="$DTTOKEN" -n hipster-shop
kubectl apply -f hipstershop/k8s-manifes_v0.yaml -n hipster-shop

echo " run 1st load test "
kubectl apply -f k6/loadtest_job.yaml -n hipster-shop
echo "--------------Demo--------------------"
echo "url of the demo: "
echo "Otel demo url: http://hipstershop.$IP.nip.io"
echo "========================================================"


