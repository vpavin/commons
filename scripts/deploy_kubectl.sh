#!/bin/bash
# uncomment to debug the script
#set -x
# copy the script below into your app code repo (e.g. ./scripts/deploy_kubectl.sh) and 'source' it from your pipeline job
#    source ./scripts/deploy_kubectl.sh
# alternatively, you can source it from online script:
#    source <(curl -sSL "https://raw.githubusercontent.com/open-toolchain/commons/master/scripts/deploy_kubectl.sh")
# ------------------
# source: https://raw.githubusercontent.com/open-toolchain/commons/master/scripts/deploy_kubectl.sh
# Input env variables (can be received via a pipeline environment properties.file.
echo "REGISTRY_URL=${REGISTRY_URL}"
echo "REGISTRY_NAMESPACE=${REGISTRY_NAMESPACE}"
echo "IMAGE_NAME=${IMAGE_NAME}"
echo "IMAGE_TAG=${IMAGE_TAG}"

#View build properties
# cat build.properties
# also run 'env' command to find all available env variables
# or learn more about the available environment variables at:
# https://console.bluemix.net/docs/services/ContinuousDelivery/pipeline_deploy_var.html#deliverypipeline_environment

# Input env variables from pipeline job
echo "PIPELINE_KUBERNETES_CLUSTER_NAME=${PIPELINE_KUBERNETES_CLUSTER_NAME}"

CLUSTER_NAMESPACE=default
echo "=========================================================="
#Check cluster availability
IP_ADDR=$( bx cs workers $PIPELINE_KUBERNETES_CLUSTER_NAME | grep normal | head -n 1 | awk '{ print $2 }' )
if [ -z "$IP_ADDR" ]; then
  echo "$PIPELINE_KUBERNETES_CLUSTER_NAME not created or workers not ready"
  exit 1
fi
echo ""
echo "DEPLOYING USING MANIFEST:"
cat deployment.yml
kubectl apply -f deployment.yml  
echo ""
echo "=========================================================="
IMAGE_REPOSITORY=${REGISTRY_URL}/${REGISTRY_NAMESPACE}/${IMAGE_NAME}
echo -e "CHECKING deployment status of ${IMAGE_REPOSITORY}:${IMAGE_TAG}"
echo ""
for ITERATION in {1..30}
do
  DATA=$( kubectl get pods --namespace ${CLUSTER_NAMESPACE} -o json )
  NOT_READY=$( echo $DATA | jq '.items[].status.containerStatuses[] | select(.image=="'"${IMAGE_REPOSITORY}:${IMAGE_TAG}"'") | select(.ready==false) ' )
  if [[ -z "$NOT_READY" ]]; then
    echo -e "All pods are ready:"
    echo $DATA | jq '.items[].status.containerStatuses[] | select(.image=="'"${IMAGE_REPOSITORY}:${IMAGE_TAG}"'") | select(.ready==true) '
    break # deployment succeeded
  fi
  REASON=$(echo $DATA | jq '.items[].status.containerStatuses[] | select(.image=="'"${IMAGE_REPOSITORY}:${IMAGE_TAG}"'") | .state.waiting.reason')
  echo -e "${ITERATION} : Deployment still pending..."
  echo -e "NOT_READY:${NOT_READY}"
  echo -e "REASON: ${REASON}"
  if [[ ${REASON} == *ErrImagePull* ]] || [[ ${REASON} == *ImagePullBackOff* ]]; then
    echo "Detected ErrImagePull or ImagePullBackOff failure. "
    echo "Please check proper authenticating to from cluster to image registry (e.g. image pull secret)"
    break; # no need to wait longer, error is fatal
  elif [[ ${REASON} == *CrashLoopBackOff* ]]; then
    echo "Detected CrashLoopBackOff failure. "
    echo "Application is unable to start, check the application startup logs"
    break; # no need to wait longer, error is fatal
  fi
  sleep 5
done

APP_NAME=$(kubectl get pods --namespace ${CLUSTER_NAMESPACE} -o json | jq -r '.items[].status.containerStatuses[] | select(.image=="'"${IMAGE_REPOSITORY}:${IMAGE_TAG}"'") | .name' | head -n 1)
echo -e "APP: ${APP_NAME}"
echo "DEPLOYED PODS:"
kubectl describe pods --selector app=${APP_NAME}
APP_SERVICE=$(kubectl get services --namespace ${CLUSTER_NAMESPACE} -o json | jq -r ' .items[] | select (.spec.selector.app=="'"${APP_NAME}"'") | .metadata.name ')
echo -e "SERVICE: ${APP_SERVICE}"
echo "DEPLOYED SERVICES:"
kubectl describe services ${APP_SERVICE}
echo "Application Logs"
kubectl logs --selector app=${APP_NAME} --namespace ${CLUSTER_NAMESPACE}  
echo ""
if [[ ! -z "$NOT_READY" ]]; then
  echo ""
  echo "=========================================================="
  echo "DEPLOYMENT FAILED"
  exit 1
fi

echo ""
echo "=========================================================="
echo "DEPLOYMENT SUCCEEDED"
echo ""
IP_ADDR=$(bx cs workers ${PIPELINE_KUBERNETES_CLUSTER_NAME} | grep normal | head -n 1 | awk '{ print $2 }')
PORT=$( kubectl get services | grep ${APP_SERVICE} | sed 's/.*:\([0-9]*\).*/\1/g' )
echo ""
echo -e "VIEW THE APPLICATION AT: http://${IP_ADDR}:${PORT}"