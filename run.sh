#!/usr/bin/env bash
set -Eeuo pipefail
#set -x #debug
__TMP="/tmp/strimzi-backup" && mkdir -p $__TMP
__HOME="" && pushd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" >/dev/null \
    && { __HOME=$PWD; popd >/dev/null; }

SOURCE_NS="${SOURCE_NS:-test}"
TARGET_NS="${TARGET_NS:-test}"
CLUSTER_NAME="${CLUSTER_NAME:-my-cluster}"
BACKUP_DIR="${BACKUP_DIR:-/tmp}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-300s}"

# custom configmap names
# i.e. external logging configuration (log4j)
CUSTOM_CMS=(
    "log4j-properties"
    "custom-test"
)

# custom secret names
# i.e. listener's certificate, registry authentication
CUSTOM_SECRETS=(
    "ext-listener-crt"
    "registry-authn"
    "custom-test"
)

__error() {
    local message="$1"
    echo "$message"
    exit 1
}

__whoami() {
    printf $(kubectl config current-context | cut -d "/" -f3)
}

__confirm() {
    local message="$1"
    if [[ -n $message ]]; then
        read -p "$message (y/n) " reply
        if [[ ! $reply =~ ^[Yy]$ ]]; then
            exit 0
        fi
    fi
}

__select_ns() {
    local ns="$1"
    if [[ -n $ns ]]; then
        kubectl config set-context --current --namespace=$ns
    fi
}

__export_env() {
    local op_name="strimzi-cluster-operator"
    local op_pod="$(kubectl get pods | grep $op_name | grep Running | cut -d " " -f1)"
    kubectl exec -it $op_pod -- env | grep "VERSION" \
        | sed -e "s/^/declare -- /" > $__TMP/env ||true
    local filter="data-$CLUSTER_NAME-zookeeper"
    ZOO_REPLICAS=$(kubectl get pvc | grep $filter | wc -l)
    ZOO_PVC_SIZE=$(kubectl get pvc | grep $filter-0 | awk '{print $4}')
    ZOO_PVC_CLASS=$(kubectl get pvc | grep $filter-0 | awk '{print $6}')
    JBOD_VOL_NUM=$(kubectl get pvc | grep $CLUSTER_NAME-kafka-0 | wc -l)
    if ((JBOD_VOL_NUM > 0)); then
        filter="data-0-$CLUSTER_NAME-kafka"
    else
        filter="data-$CLUSTER_NAME-kafka"
    fi
    KAFKA_REPLICAS=$(kubectl get pvc | grep $filter | wc -l)
    KAFKA_PVC_SIZE=$(kubectl get pvc | grep $filter-0 | awk '{print $4}')
    KAFKA_PVC_CLASS=$(kubectl get pvc | grep $filter-0 | awk '{print $6}')
    declare -px ZOO_REPLICAS ZOO_PVC_SIZE ZOO_PVC_CLASS JBOD_VOL_NUM \
        KAFKA_REPLICAS KAFKA_PVC_SIZE KAFKA_PVC_CLASS >> $__TMP/env
}

__export_res() {
    local name="$1"
    local label="${2-}"
    if [[ -n $name ]]; then
        local crs=$(kubectl get $name -o name -l "$label")
        if [[ -n $crs ]]; then
            echo "Exporting $name"
            # delete runtime metadata expression
            local exp="del(.metadata.namespace, .items[].metadata.namespace, \
                .metadata.resourceVersion, .items[].metadata.resourceVersion, \
                .metadata.selfLink, .items[].metadata.selfLink, \
                .metadata.uid, .items[].metadata.uid, \
                .status, .items[].status)"
            local id=$(printf $name | sed 's/\//-/g;s/ //g')
            kubectl get $crs -o yaml | yq eval "$exp" - > $__TMP/resources/$SOURCE_NS-$id.yaml
        fi
    fi
}

__create_pvc() {
    local pvc="$1"
    local size="$2"
    local class="${3-}"
    if [[ -n $pvc && -n $size ]]; then
        local exp="s/\$pvc/$pvc/g; s/\$size/$size/g; /storageClassName/d"
        if [[ -n $class ]]; then
            exp="s/\$pvc/$pvc/g; s/\$size/$size/g; s/\$class/$class/g"
        fi
        echo "Creating pvc $pvc of size $size"
        sed "$exp" $__HOME/pvc.yaml | kubectl create -f -
    else
        __error "Missing required parameters"
    fi
}

__rsync() {
    local source="$1"
    local target="$2"
    if [[ -n $source && -n $target ]]; then
        echo "Rsync from $source to $target"
        local pod_name="backup"
        local patch=$(sed "s/\$pvc/$pvc/g" $__HOME/patch.json)
        kubectl run $pod_name --image="dummy" --restart="Never" --overrides="$patch"
        kubectl wait --for condition="ready" pod $pod_name --timeout="$WAIT_TIMEOUT"
        if [[ $source == *"$__TMP"* ]]; then
            # upload from local to pod
            tar -C $source -c . | kubectl exec -i $pod_name -- sh -c "tar -C /data -xv"
        else
            # incremental download from pod to local
            local flags="-c --no-check-device --no-acls --no-xattrs --totals \
                --listed-incremental /data/backup.snar --exclude=./backup.snar"
            if [ -z "$(ls -A $__TMP/data)" ]; then
                # empty data, fallback to full download
                flags="$flags --level=0"
            fi
            kubectl exec -i $pod_name -- sh -c "tar $flags -C /data ." | tar -C $target -xv -f -
        fi
        kubectl delete pod $pod_name
    else
        __error "Missing required parameters"
    fi
}

__compress() {
    local source_dir="$1"
    local file_path="$2"
    if [[ -n $source_dir && -n $file_path ]]; then
        echo "Compressing $source_dir to $file_path"
        local backup_dir=$(dirname "$file_path")
        local backup_name=$(basename "$file_path")
        local current_dir=$(pwd)
        cd $source_dir
        zip -qr $backup_name *
        mkdir -p $backup_dir
        mv $backup_name $backup_dir
        cd $current_dir
    else
        __error "Missing required parameters"
    fi
}

__uncompress() {
    local file_path="$1"
    local dest_dir="$2"
    if [[ -n $file_path && -n $dest_dir ]]; then
        echo "Uncompressing $file_path to $dest_dir"
        rm -rf $dest_dir
        unzip -qo $file_path -d $dest_dir
        chmod -R o+rw $dest_dir
    else
        __error "Missing required parameters"
    fi
}

backup() {
    if [ $# -lt 3 ]; then
        __error "Missing required arguments"
    else
        SOURCE_NS="$1"
        CLUSTER_NAME="$2"
        BACKUP_DIR="$3"
    fi

    # context init
    __select_ns $SOURCE_NS
    __TMP="$__TMP/$SOURCE_NS/$CLUSTER_NAME"
    __confirm "Backup $SOURCE_NS/$CLUSTER_NAME as $(__whoami) - cluster will be unavailable"
    mkdir -p $__TMP/resources $__TMP/data
    __export_env

    # export resources
    __export_res "kafkas"
    __export_res "kafkatopics"
    __export_res "kafkausers"
    __export_res "kafkabridges"
    __export_res "kafkaconnectors"
    __export_res "kafkaconnects"
    __export_res "kafkaconnects2is"
    __export_res "kafkamirrormaker2s"
    __export_res "kafkamirrormakers"
    __export_res "kafkarebalances"
    # internal certificates and user secrets
    __export_res "secrets" "strimzi.io/name=strimzi"
    # custom configmap and secrets
    for name in "${CUSTOM_CMS[@]}"; do
        __export_res "cm/$name"
    done
    for name in "${CUSTOM_SECRETS[@]}"; do
        __export_res "secret/$name"
    done

    # stop operator and statefulsets
    kubectl scale deployment strimzi-cluster-operator --replicas 0
    kubectl wait --for="delete" pod \
        --selector="name=strimzi-cluster-operator" --timeout="$WAIT_TIMEOUT"
    kubectl scale statefulset $CLUSTER_NAME-kafka --replicas 0
    kubectl wait --for="delete" pod \
        --selector="strimzi.io/name=$CLUSTER_NAME-kafka" --timeout="$WAIT_TIMEOUT"
    kubectl scale statefulset $CLUSTER_NAME-zookeeper --replicas 0
    kubectl wait --for="delete" pod \
        --selector="strimzi.io/name=$CLUSTER_NAME-zookeeper" --timeout="$WAIT_TIMEOUT"

    # for each PVC, rsync data from PV to backup
    for ((i = 0; i < $ZOO_REPLICAS; i++)); do
        local pvc="data-$CLUSTER_NAME-zookeeper-$i"
        local local_path="$__TMP/data/$pvc"
        mkdir -p $local_path
        __rsync $pvc $local_path
    done
    for ((i = 0; i < $KAFKA_REPLICAS; i++)); do
        if ((JBOD_VOL_NUM > 0)); then
            for ((j = 0; j < $JBOD_VOL_NUM; j++)); do
                local pvc="data-$j-$CLUSTER_NAME-kafka-$i"
                local local_path="$__TMP/data/$pvc"
                mkdir -p $local_path
                __rsync $pvc $local_path
            done
        else
            local pvc="data-$CLUSTER_NAME-kafka-$i"
            local local_path="$__TMP/data/$pvc"
            mkdir -p $local_path
            __rsync $pvc $local_path
        fi
    done

    # start the operator
    kubectl scale deployment strimzi-cluster-operator --replicas 1

    local backup_name="$CLUSTER_NAME-$(date +%Y%m%d%H%M%S)"
    __compress $__TMP $BACKUP_DIR/$backup_name.zip
    echo "DONE"
}

restore() {
    if [ $# -lt 3 ]; then
        __error "Missing required arguments"
    else
        TARGET_NS="$1"
        CLUSTER_NAME="$2"
        BACKUP_FILE="$3"
    fi

    # context init
    __select_ns $TARGET_NS
    __TMP="$__TMP/$TARGET_NS/$CLUSTER_NAME"
    __confirm "Restore $TARGET_NS/$CLUSTER_NAME as $(__whoami)"
    __uncompress $BACKUP_FILE $__TMP
    source $__TMP/env

    # for each PVC, create it and rsync data from backup to PV
    # this must be done *before* deploying the cluster
    for ((i = 0; i < $ZOO_REPLICAS; i++)); do
        local pvc="data-$CLUSTER_NAME-zookeeper-$i"
        __create_pvc $pvc $ZOO_PVC_SIZE $ZOO_PVC_CLASS
        __rsync $__TMP/data/$pvc/. $pvc
    done
    for ((i = 0; i < $KAFKA_REPLICAS; i++)); do
        if ((JBOD_VOL_NUM > 0)); then
            for (( j = 0; j < $JBOD_VOL_NUM; j++ )); do
                local pvc="data-$j-$CLUSTER_NAME-kafka-$i"
                __create_pvc $pvc $KAFKA_PVC_SIZE $KAFKA_PVC_CLASS
                __rsync $__TMP/data/$pvc/. $pvc
            done
        else
            local pvc="data-$CLUSTER_NAME-kafka-$i"
            __create_pvc $pvc $KAFKA_PVC_SIZE $KAFKA_PVC_CLASS
            __rsync $__TMP/data/$pvc/. $pvc
        fi
    done

    # import resources
    # KafkaTopic resources must be created *before*
    # deploying the Topic Operator or it will delete them
    kubectl apply -f $__TMP/resources 2>/dev/null ||true

    echo "DONE"
}

USAGE="Usage: $(basename "$0") [options]

Options:
  -b, --backup   <source-ns> <cluster-name> <backup-dir>
  -r, --restore  <target-ns> <cluster-name> <backup-file>"
case "${1-}" in
    -b|--backup)
        shift
        backup "$@"
        ;;
    -r|--restore)
        shift
        restore "$@"
        ;;
    *)
        __error "$USAGE"
esac
